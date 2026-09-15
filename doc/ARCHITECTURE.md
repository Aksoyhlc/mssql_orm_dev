# Architecture

This document describes the implementation pipeline of
`mssql_orm_dev`. Source is authoritative when documentation differs.

## Boundary

This package is development tooling. Applications place it in
`dev_dependencies`. The emitted code depends on `mssql_orm` and
`mssql_native`; generator-only libraries such as `args`, `yaml`,
`dart_style`, and `glob` stay out of the production dependency graph.

Six executables are declared in `pubspec.yaml`: `init`, `doctor`,
`snapshot`, `generate`, `check_schema`, and `verify_queries`.

## Inputs

`GeneratorConfig` loads `tool/mssql_orm.yaml` and resolves:

- live connection settings, normally from environment variables
- output, model, extension, query-input, and snapshot paths
- included schemas, tables, and views
- naming and per-column query methods
- read-only, hidden, soft-delete, timestamp, and hierarchy metadata
- inferred, excluded, renamed, and explicitly declared relations
- projections, enums, converters, and decimal mode

Per-table and per-column keyed settings track whether they matched schema
objects. Unmatched settings are reported instead of being ignored.

The schema input is either a live catalog read or
`MssqlSchemaSnapshot`. Custom SQL files add separately described query and
procedure contracts.

## Pipeline

```text
config + schema + SQL files
           |
           v
      Generator.run
           |
           +--> naming / relation resolution
           +--> query and procedure description
           +--> API contract validation
           |
           v
      GenerationPlan
           |
           +--> create
           +--> replace
           +--> remove
           +--> unchanged
           |
           v
       AtomicWriter
           |
           v
 generated files + one-time scaffolds
```

`GenerationPlan` is the seam between deciding and writing. Dry-run, check,
text reporting, and JSON reporting all inspect the same planned actions.

Emitters are split by concern: table/runtime bindings, fields, relations,
projections, custom queries, and stored procedures. Output includes generator
version, API contract version, and schema fingerprints where applicable.

## Atomic writes and ownership

Generated files may be replaced or removed. User-owned model and extension
scaffolds are created only when absent. SQL input is never generator output.

The writer stages a complete change set, records a journal, moves previous
files to backup, and promotes staged files. Recovery either completes or
rolls back an interrupted operation. Journals are written through a sibling
temporary file and rename so a truncated journal is not accepted as valid.

Do not bypass this writer with direct output writes. Doing so breaks the
all-old-or-all-new generation guarantee.

## Snapshot behavior

`snapshot` reads catalog metadata including objects, columns, keys, indexes,
foreign keys, triggers, and server compatibility. It never reads application
table rows and does not serialize credentials.

Case-ambiguous database names are refused because they would collide after
Dart/name folding. Snapshot checks compare deterministic checksums.

## Custom SQL

Query files are parsed into named declarations. Server-describable statements
are described against SQL Server. Manual descriptions are accepted as explicit
contracts. A query-shape cache supports offline generation when its inputs
still match.

`verify_queries` re-describes live queries and compares them with generated
contracts. Arbitrary mutating SQL is not assumed retry-safe; retry metadata
requires an explicit read-only declaration.

## TLS and native runtime

Live commands initialize `mssql_native` once per process. Connections are
plaintext by default. When an encrypted mode is selected, trust selection is:

1. `MSSQL_TLS_INSECURE` when true
2. `MSSQL_TLS_CA` when set
3. system trust when `MSSQL_TLS_SYSTEM` is true
4. no TLS trust configuration when none of those variables is set

`connection.encryption: require` or `strict` opts into TLS. Connection
secrets are resolved for live commands but are not printed or stored in
snapshots.

## Source map

- `bin/*.dart`: command parsing and exit policy
- `lib/src/config.dart`: YAML and environment contract
- `lib/src/generator.dart`: orchestration
- `lib/src/generation_plan.dart`: planned file actions and reports
- `lib/src/atomic_writer.dart`: staging, promotion, rollback, recovery
- `lib/src/emitter.dart`, `lib/src/emit/`: Dart output
- `lib/src/relations.dart`: relation resolution
- `lib/src/query_file.dart`, `describe.dart`: custom SQL contracts
- `lib/src/query_shape_cache.dart`: offline query metadata
- `lib/src/schema_drift.dart`: live/generated comparison

## Invariants

1. Generated output follows the schema and configuration, not old docs.
2. Unknown or unmatched configuration is not silently accepted.
3. Generated files and application-owned files have distinct policies.
4. A dry run and a real run derive from the same plan.
5. Output promotion is recoverable and never intentionally leaves a mixed set.
6. Offline generation never pretends a manual query shape was server-verified.
7. Credentials never enter generated files or snapshots.
8. Generator API contract versions must match the runtime.
