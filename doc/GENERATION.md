# Generation, configuration, and custom SQL

This is the reference the starter `mssql_orm.yaml` points to. Command syntax
and exit behavior are in [CLI.md](CLI.md); the runtime behaviour of what the
generator produces is documented by the `mssql_orm` package.

## What is committed, and what is not

```text
lib/db/
  generated/        replaced by every generation; commit it
    generated.dart  barrel over the per-table files
    database.g.dart AppDatabase
    queries.g.dart  typed custom-SQL methods
    procedures.g.dart
    <file>.g.dart   one per table
    .mssql_orm.json ownership ledger used by the stale sweep
  models/           <file>.dart scaffold (created once; application-owned)
  extensions/       <file>_scopes.dart scaffold (created once; owned)
  queries/          hand-written .sql input
tool/
  mssql_orm.yaml
  mssql_schema.json            live snapshot
  mssql_schema.queries.json    describe cache for offline custom SQL
```

A generation replaces exactly the files `generated/` owns. `models/` and
`extensions/` scaffolds are written once and never overwritten; regeneration
prints `kept N existing scaffold file(s) untouched`. When a schema change
needs a new scaffold contract, generation warns that the existing scaffold
still carries the old constructor/extension shape — regenerate, then review
the scaffold against the new generated types.

Crash recovery artifacts (`.mssql_orm_staging/`,
`.mssql_orm_backup/`, `.mssql_orm_journal.json`, next to the
output directory) are gitignored by `init`.

### Offline reproducibility

Commit both `tool/mssql_schema.json` and, when the project has custom SQL,
`tool/mssql_schema.queries.json`. The live `generate` writes the query cache
next to the snapshot; `generate --snapshot` verifies its hash and refuses a
missing or edited cache. `snapshot --check` in CI keeps the committed
snapshot honest.

## Configuration

Defaults in brackets.

| Key                    | Meaning |
|------------------------|---|
| `connection`           | `from: env:NAME` (ADO-style string), or split keys `host`, `port`, `database`, `user`, `password`, `encrypt`, each accepting `env:NAME`. `encrypt` is `off` (default), `request`, `require` or `strict`. `trust_server_certificate` is refused: FreeTDS decides certificate trust once per process, through `MssqlRuntime.initialize(tls: ...)` in the application. |
| `output`               | `lib/db/generated` — replaced on generation |
| `models_output`        | `lib/db/models` — scaffolds, created once |
| `extensions_output`    | `lib/db/extensions` — scope scaffolds, created once |
| `queries_input`        | `lib/db/queries` — hand-written `.sql` files |
| `snapshot`             | `tool/mssql_schema.json` |
| `database_class`       | `AppDatabase` |
| `schemas`              | `[dbo]` |
| `include` / `exclude`  | `['*']` / `['sysdiagrams']` — table patterns; see [How names are matched](#how-names-are-matched) |
| `include_views`        | `true` |
| `scaffold`             | `true` — emit application-owned model/extension files |
| `decimal_mode`         | `exact` (default), `text`, or `double`. `decimal_as_double` is **refused** with a message |
| `json`                 | `false` — also generate JSON helpers |
| `class_names`          | `{dbo.Orders: Order}` — set the stem |
| `field_names`          | `{dbo.Orders.Code: code}` — rename a field |
| `query_methods`        | rename generated `whereX` methods |
| `readonly_columns`     | `['*.CreatedAt']`-style column patterns |
| `hidden_columns`       | column patterns omitted from generated row classes |
| `conventions`          | naming conventions section |
| `soft_delete_columns`  | `{Table: Column}` (or per-table settings) |
| `hierarchy_parents`    | self-referencing walk configuration |
| `timestamps`           | per-table created/updated column settings |
| `relation_names`       | rename a relation |
| `exclude_relations`    | drop a relation |
| `declared_relations`   | add relations the schema cannot infer |
| `projections`          | generated DTO queries |
| `enum_columns`         | map columns to Dart enums |
| `converters`           | map columns to custom Dart types |

Unknown or misspelled keys are refused rather than ignored, at the root and
inside `connection`, with the nearest known spelling when there is one. A
boolean must read as one: `scaffold: ture` is an error, not `false`.

### How names are matched

Not every key matches the same way. Three rules, and which one applies is a
property of the key, not of what you write in it:

| Keys | Matching |
|---|---|
| `include`, `exclude` | glob: `*` stands for any run of characters, anywhere in the pattern |
| `readonly_columns`, `hidden_columns` | the leading form `*.Column` only, plus exact names |
| every other keyed setting | exact names — no `*` |

All three ignore case, as SQL Server's default collations do, and all three
take a table with or without its schema: `Orders`, `dbo.Orders` and
`DBO.ORDERS` are one table. Column and relation keys append one more segment
to that: `dbo.Orders.Status`, `dbo.Orders.customer`.

`include` and `exclude` are the only place a general pattern works, and
`exclude` wins over `include` when both match a table:

```yaml
include: ['dbo.Order*', 'Customers']   # Orders, OrderLines, OrderStatus, Customers
exclude: ['*_Archive', 'dbo.OrderStatus']
```

These two are also the only keys where an entry matching nothing is not an
error — `exclude` defaults to `sysdiagrams`, which most databases do not have.
A misspelled `include` entry therefore leaves that table out instead of
failing, and only a selection that comes back completely empty stops the run.
When a long `include` list is the selection, `generate --dry-run` is what shows
which tables it actually resolved to.

`readonly_columns` and `hidden_columns` take one pattern shape and no other:
`*.RowVersion` means that column name on every selected table. Anything else
is read as an exact `schema.Table.Column`, so `dbo.Orders.*` and `*.Created*`
match nothing — and a key that matches nothing is an error, so the run stops
rather than quietly skipping the setting.

Every remaining keyed setting — `class_names`, `field_names`,
`query_methods`, `soft_delete_columns`, `timestamps`, `hierarchy_parents`,
`relation_names`, `exclude_relations`, `declared_relations`, `enum_columns`,
`converters`, `projections.table` — names one table, column or relation
exactly. There is no `class_names: 'dbo.*'`. The same holds for
`generate --only`, which names tables rather than matching patterns.

Relation keys need the generated relation name, not the foreign key's:
a single-column foreign key whose column ends in `Id` drops it and
camel-cases the rest (`CustomerId` → `customer`); otherwise the target
table's name is camel-cased. The other direction takes the owning table's
name (`OrderLines` → `orderLines`).

## Custom SQL

Every `.sql` file under `queries_input` becomes a method on `AppDatabase`.
Directives are leading `--` comments only; comments further down belong to
the SQL.

```sql
-- name: searchProducts
-- returns: list
SELECT ProductId, Name FROM dbo.Products
WHERE Name LIKE @term;
```

| Directive | Meaning |
|---|---|
| `-- name:` | method name (required; stated, never taken from the file name) |
| `-- returns:` | `list` (default), `single`, `single_or_null`, `scalar`, or `affected` |
| `-- param:` | `name sqltype [null|not null] [default] [output|inout]` |
| `-- output:` / `-- inout:` | the parameter with that direction |
| `-- notnull:` | comma-separated columns read as non-null |
| `-- describe: manual` | declare the result shape yourself |
| `-- column:` | `name sqltype [null|not null]`, one per declared column |
| `-- procedure:` | run through `callProcedure`, required once output/inout/TVP/multiple result sets are used |
| `-- tvp:` | `name dbo.TableType` — a table-valued parameter |
| `-- tvp_column:` | `paramName ColumnName sqltype` — one per TVP column |
| `-- resultset:` | starts a later result set (`column` directives after it belong to it) |
| `-- extra_sets:` | `error` (default) or `ignore` |
| `-- read_only: true` | declare the statement safe to repeat after a lost connection |

Parameters are not nullable by default; write `null` to say otherwise.
`-- column:` without `describe: manual` is an error, and `manual` without any
`column:` is one too.

### Manual description

Without a live database the generator cannot describe the result shape, so
the file says it:

```sql
-- name: dailyTotal
-- returns: scalar
-- describe: manual
-- column: Value decimal(18,2) not null
SELECT SUM(Amount) AS Value FROM dbo.Sales
WHERE SaleDate = @day;
```

Procedures, output/`inout` parameters, TVPs and multiple result sets require
`-- procedure:` — they are `callProcedure` calls, not statements.

## The two CI gates

`generate --check` answers "is the generated code up to date with the schema
files?" — it writes nothing and exits `1` when output would change, so
stale code fails CI.

`check_schema` answers "is the generated code still valid against this
*database*?" It compares the committed snapshot (when present) or the
generated fingerprints with the live schema, needs no write access, and
fails on breaking differences (everything with `--strict`).

`verify_queries` re-describes hand-written SQL against the live database and
reports contracts that no longer match.

## Reports

`--report json` prints one object on stdout; the key set is a downstream
contract.

`generate`:

```json
{
  "generationId": "…",
  "changed": true,
  "files": [{"path": "lib/db/generated/orders.g.dart", "action": "update"}],
  "warnings": [],
  "skippedScaffolds": 2
}
```

`check_schema`: `clean`, `strict`, `failed`, `breaking`, and `differences`
(each with `table`, `column`, `kind`, `severity`, `expected`, `actual`,
`remedy`).

`verify_queries`: `clean` and `drift` (each with `query`, `message`).

## Exit codes

| Code | Meaning |
|---|---|
| `0` | success (also: `generate --check` when nothing would change) |
| `1` | drift/check finding: `generate --check`, `snapshot --check`, `check_schema`, `verify_queries` |
| `64` | malformed command arguments |
| `65` | naming/query/format contract errors: ambiguous names, `.sql` directives, API-version mismatch, invalid config scalars |
| `66` | required snapshot missing |
| `69` | SQL Server failure |
| `78` | invalid configuration (`ConfigError`) |
