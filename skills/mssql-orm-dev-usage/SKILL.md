---
name: mssql-orm-dev-usage
description: Use when setting up, running, reviewing, or debugging mssql_orm_dev database-first generation, including YAML configuration, live catalogs, schema snapshots, generated ownership, custom SQL, drift checks, and CLI failures.
---

# Use mssql_orm_dev

This package is a development-time generator. It reads SQL Server catalog
metadata or a committed snapshot and produces the typed API consumed through
`mssql_orm`.

## Establish inputs and ownership

Read [README](../../README.md), [CLI](../../doc/CLI.md), and
[architecture](../../doc/ARCHITECTURE.md). Inspect the consumer's
`tool/mssql_orm.yaml` before proposing commands or generated names.

- Replaceable: the configured generated output and ownership ledger.
- Create once: model and extension scaffolds.
- Application-owned: configuration, model subclasses, extensions, and custom
  SQL input.
- Reproducibility inputs: the schema snapshot and custom-query metadata cache.

Never solve a generation problem by editing a generated application file.
Change the schema, configuration, SQL input, or generator source that owns it.

## Baseline workflow

```yaml
connection:
  from: env:MSSQL_CONNECTION_STRING
output: lib/db/generated
models_output: lib/db/models
extensions_output: lib/db/extensions
snapshot: tool/mssql_schema.json
queries_input: lib/db/queries
database_class: AppDatabase
```

```console
dart run mssql_orm_dev:init
dart run mssql_orm_dev:doctor
dart run mssql_orm_dev:snapshot
dart run mssql_orm_dev:generate
```

`snapshot` requires a live catalog but stores metadata only, never credentials
or table rows. `generate --snapshot` is the reproducible offline path.

## Choose the command by intent

| Intent | Command |
|---|---|
| Preview output changes without writing | `generate --dry-run` |
| Fail CI when generated output is stale | `generate --check` |
| Compare the live catalog with the stored snapshot | `snapshot --check` |
| Check generated schema compatibility against live SQL Server | `check_schema` |
| Re-describe custom SQL and compare its result contract | `verify_queries` |

These checks answer different questions. Do not substitute one for another.
Read `bin/` when exact exit behavior matters.

## Preserve generator invariants

- Use the same `GenerationPlan` for preview, check, and write modes.
- Apply multi-file output through `AtomicWriter`; direct overwrites bypass
  staging, backup, rollback, and ownership checks.
- A partial `--only` run must not mark unrelated generated files as stale.
- Unknown configuration keys and references to missing schema objects must be
  reported, not ignored.
- Manual custom-SQL descriptions are declarations, not live server
  verification.
- Keep generator and ORM runtime API contract versions aligned; reject output
  that targets an unsupported contract.
- Configure process-wide TLS trust before live encrypted commands and keep
  passwords and connection strings out of output, snapshots, and logs.
- Inspect actual generated output instead of inferring names from table names.
