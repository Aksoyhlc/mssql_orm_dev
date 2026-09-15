# Example workflow

This package is a CLI, so its examples are commands and generated layout rather
than a runtime application.

```console
dart run mssql_orm_dev:init
export MSSQL_CONNECTION_STRING='Server=localhost;Database=app;User Id=sa;Password=...;'
dart run mssql_orm_dev:snapshot
dart run mssql_orm_dev:generate
```

For an offline regeneration after committing the snapshot:

```console
dart run mssql_orm_dev:generate --snapshot
```

Inspect the generated API in `lib/db/generated`. Add application behavior to
`lib/db/models` and `lib/db/extensions`, and place custom SQL under
`lib/db/queries`. Never edit generated output directly.

See the package [README](../README.md) and [CLI reference](../doc/CLI.md).
