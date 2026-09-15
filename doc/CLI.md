# CLI reference

Every command accepts `--help`. Unless shown otherwise, configuration
defaults to `tool/mssql_orm.yaml`.

## init

```console
dart run mssql_orm_dev:init [--config PATH]
```

Creates missing starter configuration, directories, an example SQL file, and
crash-recovery ignore entries (staging, backup, journal). Existing files are
kept.

## doctor

```console
dart run mssql_orm_dev:doctor [--config PATH] [--connect]
```

Checks Dart SDK compatibility, native assets, TLS availability, configuration,
output directories, snapshots, and generated API contracts. It stays local
unless `--connect` is supplied.

## snapshot

```console
dart run mssql_orm_dev:snapshot [--config PATH] [--out PATH] [--check]
```

Captures live catalog metadata. `--out` overrides the configured snapshot
path. `--check` compares the live checksum with the stored snapshot and
writes nothing.

## generate

```console
dart run mssql_orm_dev:generate [options]
```

Options:

| Option | Meaning |
|---|---|
| `--config PATH`, `-c PATH` | Configuration file |
| `--dry-run` | Print planned changes and write nothing |
| `--check` | Dry-run and exit non-zero when output would change |
| `--report text|json` | Human or machine-readable result |
| `--only TABLE` | Limit table output; repeat or pass comma-separated values |
| `--snapshot` | Generate from the configured snapshot |

When credentials are unresolved, generation selects snapshot mode. A partial
`--only` run does not perform a global stale-file sweep.

`generate --check` answers "is the generated code up to date with the schema
files?"; `check_schema` answers "is it still valid against the live
database?" — see [GENERATION.md](GENERATION.md) for the two gates.

## check_schema

```console
dart run mssql_orm_dev:check_schema \
  [--config PATH] [--strict] [--report text|json]
```

Compares a stored snapshot with the live schema when available; otherwise it
uses fingerprints in generated headers. Breaking differences fail normally.
`--strict` also fails for benign differences.

## verify_queries

```console
dart run mssql_orm_dev:verify_queries \
  [--config PATH] [--report text|json]
```

Re-describes hand-written SQL against the live database and reports contracts
that no longer match.

## Exit behavior

Successful commands return zero. Drift/check findings return non-zero.
Malformed arguments, invalid configuration, missing inputs, naming/query
contract errors, and connection failures use distinct non-zero exit paths so
automation can distinguish them.

| Code | Meaning |
|---|---|
| `0` | success (also `generate --check` when nothing would change) |
| `1` | drift/check finding: `generate --check`, `snapshot --check`, `check_schema`, `verify_queries` |
| `64` | malformed command arguments |
| `65` | naming/query/format contract errors: ambiguous names, `.sql` directives, API-version mismatch, invalid config scalars |
| `66` | required snapshot missing |
| `69` | SQL Server failure |
| `78` | invalid configuration (`ConfigError`) |

`--report json` prints one JSON object on stdout; the key sets are documented
in [GENERATION.md](GENERATION.md).

## Environment

| Variable | Purpose |
|---|---|
| `MSSQL_CONNECTION_STRING` | Recommended live connection input |
| `MSSQL_TLS_CA` | PEM certificate-authority file |
| `MSSQL_TLS_SYSTEM` | Select the system's default trust paths |
| `MSSQL_TLS_INSECURE` | Encrypt without certificate verification |

Configuration may also reference individual connection values through its
supported environment syntax. These TLS variables are optional because
connection encryption defaults to `off`. Do not commit secrets into YAML.
