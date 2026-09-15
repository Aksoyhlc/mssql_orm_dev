# mssql_orm_dev

Database-first code generation for Microsoft SQL Server.

`mssql_orm_dev` reads a SQL Server schema and writes the Dart that matches it:
typed rows, fields, entity queries, relations, write inputs and an
`AppDatabase`. Hand-written `.sql` files become typed methods on the same
database object.

There are no migrations. The database is the source of truth, and this package
keeps the generated Dart in step with it. Three read-only commands report when
the two have drifted apart, which is what you run in CI.

It is a development dependency. The generated code depends on
[`mssql_orm`](https://pub.dev/packages/mssql_orm) and
[`mssql_native`](https://pub.dev/packages/mssql_native); this package itself
never reaches a production build.

```console
$ dart run mssql_orm_dev:generate --dry-run
would create  lib/db/generated/orders.g.dart
would rewrite lib/db/generated/database.g.dart
would delete  lib/db/generated/legacy_audit.g.dart
unchanged     4 file(s)
```

Nothing is written until `--dry-run` is removed. Files are deleted only when
the generation manifest records them as generated, so hand-written files in
the output directory are left alone.

## Contents

- [Install](#install)
- [Quick start](#quick-start)
- [What is generated](#what-is-generated)
- [Commands](#commands)
- [Configuration](#configuration)
- [Custom SQL](#custom-sql)
- [Drift detection](#drift-detection)
- [Generating without a database](#generating-without-a-database)
- [How files are written](#how-files-are-written)
- [Exit codes](#exit-codes)
- [Documentation](#documentation)

## Install

```yaml
dependencies:
  mssql_native: ^0.0.2
  mssql_orm: ^0.0.2
dev_dependencies:
  mssql_orm_dev: ^0.0.2
```

The generator is a separate package from the runtime for one reason: a `bin/`
script resolves against its own package's `dependencies`, not its
`dev_dependencies`. Keeping the generator apart means the analyzer and the
formatter it needs stay out of your application's dependency graph.

## Quick start

```console
dart run mssql_orm_dev:init
dart run mssql_orm_dev:doctor
export MSSQL_CONNECTION_STRING='Server=localhost;Database=app;User Id=sa;Password=…;'
dart run mssql_orm_dev:snapshot
dart run mssql_orm_dev:generate
```

`init` creates `tool/mssql_orm.yaml`, the output directories, an example SQL
file and the recovery entries for `.gitignore`. Existing files are kept.

Then, in the application:

```dart
import 'package:app/db/generated/generated.dart';

final db = await AppDatabase.open(config);
final orders = await db.orders.whereStatus('open').get();
```

## What is generated

For each table: a row class, a fields class of typed columns, a query class
with a `whereX` method per column, create and patch inputs, relations inferred
from foreign keys, and the entry that puts it on `AppDatabase`. A barrel file
covers the whole database in one import.

Three directories are involved, and they have different rules:

| Directory | Written | Ownership |
|---|---|---|
| `output` | every run | the generator |
| `models_output` | once | yours after that |
| `extensions_output` | once | yours after that |
| `queries_input` | never | yours |

Model subclasses and query scopes are created the first time and never
overwritten, so anything you add to them survives regeneration.

## Commands

Command names use underscores: `verify_queries`, not `verify-queries`. Every
command accepts `--help` and `--config PATH`.

| Command | Purpose |
|---|---|
| `init` | create the configuration and directory layout |
| `doctor` | check the machine, the configuration and the generated contract |
| `snapshot` | record the schema as JSON so later runs need no database |
| `generate` | write the Dart |
| `check_schema` | compare the live database with what was generated |
| `verify_queries` | re-describe hand-written `.sql` files against the database |

`doctor` stays local unless `--connect` is given. It reports the Dart SDK
version, native asset availability, TLS support, configuration validity,
output directories, snapshot state and the generated API contract version,
along with what to do about anything that failed.

`generate` takes the options that matter in a build:

| Option | Meaning |
|---|---|
| `--dry-run` | print the plan and write nothing |
| `--check` | dry-run, and exit non-zero if the output would change |
| `--only TABLE` | limit to named tables; repeat or comma-separate |
| `--snapshot` | generate from the committed snapshot instead of a live catalog |
| `--report text\|json` | human-readable output, or one JSON object |

A `--only` run does not sweep for stale files, because it did not examine the
tables whose output it would be deleting.

## Configuration

One file, `tool/mssql_orm.yaml`:

```yaml
connection:
  from: env:MSSQL_CONNECTION_STRING
output: lib/db/generated
models_output: lib/db/models
extensions_output: lib/db/extensions
queries_input: lib/db/queries
snapshot: tool/mssql_schema.json
database_class: AppDatabase
decimal_mode: exact
schemas: [dbo]
```

Everything else is optional:

```yaml
include: ['dbo.Orders', 'dbo.Order*']     # or exclude:
include_views: true

class_names:
  dbo.Orders: Order                       # OrderRow / OrderQuery / OrderFields
field_names:
  dbo.Orders.PlacedAt: placedOn
query_methods:
  dbo.Orders.Status: withStatus           # renames the generated whereX

soft_delete_columns:
  dbo.Orders: DeletedAt
timestamps:
  dbo.Orders: { created: CreatedAt, updated: UpdatedAt }

hierarchy_parents:
  dbo.Employees: ManagerId                # which self-reference is the parent

enum_columns:
  dbo.Orders.Status:
    dart: OrderStatus
    import: package:app/order_status.dart
    unknown: error                        # or member / wrap
converters:
  dbo.Orders.Amount:
    dart: Money
    converter: MoneyConverter
    import: package:app/money.dart

readonly_columns: ['*.RowVersion']
hidden_columns: ['dbo.Users.PasswordHash']
projections:
  OrderListItem:
    table: dbo.Orders
    fields: [Id, Code, Total, {path: Customer.Name, alias: CustomerName}]
```

Only `include` and `exclude` take a general pattern, where `*` stands for any
run of characters and `exclude` wins over `include`. `readonly_columns` and
`hidden_columns` take the single form `*.Column`, meaning that column name on
every selected table. Every other key — `class_names`, `field_names`,
`soft_delete_columns`, `enum_columns`, `exclude_relations` and the rest, and
`generate --only` — names one table, column or relation exactly, with or
without its schema and in any case. See
[How names are matched](doc/GENERATION.md#how-names-are-matched).

Three rules apply to the whole file, so that a configuration cannot stop
taking effect without saying so:

- A key that matches nothing is an error. A `class_names` entry for an
  excluded table, or for a column that was renamed away, fails the run.
- A key the generator does not read is an error, and the message names the
  closest key it does read.
- A value that is not a boolean where a boolean is expected is an error.
  `scaffold: ture` stops the run instead of meaning `false`.

Connection values can come from the environment with `env:NAME`. Encryption
defaults to `off` and is set with `connection.encrypt`, which takes `off`,
`request`, `require` or `strict`. Certificate trust is process-wide in
FreeTDS, so `connection.trust_server_certificate` is refused here; the CLI
reads `MSSQL_TLS_CA`, `MSSQL_TLS_SYSTEM` or `MSSQL_TLS_INSECURE` for its own
connection instead.

See [doc/GENERATION.md](doc/GENERATION.md) for the complete reference.

## Custom SQL

Every `.sql` file under `queries_input` becomes a typed method on
`db.reports`. Directives are leading `--` comments:

```sql
-- lib/db/queries/category_trend.sql
-- name: categoryTrend
-- param: rootId int
-- param: since datetime2
-- returns: list
WITH tree AS (…)
SELECT c.Name AS Category, SUM(o.Total) AS Revenue
FROM tree AS c JOIN dbo.Orders AS o ON o.CategoryId = c.Id
WHERE c.RootId = @rootId AND o.PlacedAt >= @since
GROUP BY c.Name;
```

```dart
final rows = await db.reports.categoryTrend(rootId: 1, since: month);
```

The result shape is described by SQL Server. Parameters are described first,
so a parameter that determines a result column is declared in the describe
call and the statement compiles.

When the server cannot describe a statement, such as one over a `#temp` table
or built dynamically, declare the shape instead:

```sql
-- describe: manual
-- column: MonthStart date notnull
-- column: Revenue decimal(18,4)
```

`-- returns:` accepts `list`, `single`, `single_or_null`, `scalar` or
`affected`. `-- procedure: dbo.usp_x` describes a stored procedure rather than
a statement.

## Drift detection

Without migrations, the equivalent safeguard is three checks. They answer
different questions:

| Question | Command | Reads the database |
|---|---|---|
| Is the generated Dart stale against the schema files? | `generate --check` | no |
| Has the live database moved away from what was generated? | `check_schema` | yes |
| Has a hand-written `.sql` file's result shape changed? | `verify_queries` | yes |

All three write nothing and need no write access.

`verify_queries` also re-describes manual declarations. Generation trusts a
manual description, which is the point of declaring one, but a drift check
that trusted it would report a query as valid without having looked at it.
Where SQL Server genuinely cannot describe a statement, it is reported as
unverified rather than as passing.

## Generating without a database

A snapshot records the schema so that later runs need no connection:

```console
dart run mssql_orm_dev:snapshot
git add tool/mssql_schema.json
dart run mssql_orm_dev:generate --snapshot
```

The snapshot also makes schema changes reviewable. A change arrives as a diff
of the JSON rather than as different generated output that nobody asked for.
`snapshot --check` compares the live schema against the stored file and writes
nothing.

If credentials cannot be resolved, `generate` selects snapshot mode on its
own. Failures that have nothing to do with secrets, such as an invalid port or
a misspelled key, still stop the run.

## How files are written

Generation decides everything before it writes anything. The plan is published
in four steps, per output directory:

1. Every file is written into a staging directory.
2. The journal records the plan, and existing targets are backed up.
3. Files are moved into place.
4. Staging, backup and journal are removed.

If a run is interrupted, the next one reads the journal and completes or
reverses it, depending on which step it stopped at. The output directory is
locked for the duration, so two concurrent runs cannot remove each other's
staging or backups.

Ownership is recorded in `.mssql_orm.json`. A generated file whose table has
disappeared from the schema is deleted; a file the manifest does not list is
never touched.

## Exit codes

`--report json` prints a single JSON object on stdout, so automation does not
have to parse prose. The exit code says which kind of failure occurred:

| Code | Meaning |
|---|---|
| `0` | success, including `generate --check` when nothing would change |
| `1` | a drift finding from `generate --check`, `snapshot --check`, `check_schema` or `verify_queries` |
| `64` | malformed command arguments |
| `65` | a contract error: ambiguous names, bad `.sql` directives, API version mismatch |
| `66` | a required snapshot is missing |
| `69` | SQL Server failure |
| `78` | invalid configuration |

## Documentation

| | |
|---|---|
| [Generation reference](doc/GENERATION.md) | every configuration key and `.sql` directive |
| [CLI reference](doc/CLI.md) | each command, its options and its exit codes |
| [Architecture](doc/ARCHITECTURE.md) | how planning, emitting and writing are separated |
| [Example layout](example/README.md) | what a generated project looks like |
| [Runtime behaviour](https://github.com/Aksoyhlc/mssql_orm/blob/main/doc/GENERATION.md) | what the generated code does, documented by `mssql_orm` |

The package also ships `skills/mssql-orm-dev-usage/SKILL.md` for compatible AI
coding agents.

## Related packages

- [`mssql_orm`](https://pub.dev/packages/mssql_orm) — the runtime the generated
  code targets. Required.
- [`mssql_native`](https://pub.dev/packages/mssql_native) — the SQL Server
  driver used to read the catalog. Required.

The three packages are versioned and released together.

## License

MIT. See [LICENSE](LICENSE).
