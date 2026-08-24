# Configuration

## Overview

The config system has three layers: environment variables, Python settings, and Snowflake metadata tables. Secrets live
in env vars, static settings live in Python, and dynamic asset/connection definitions live in Snowflake.

```
.env                          Environment variables (secrets, Snowflake credentials)
  |
  v
Settings (pydantic-settings)  Validated, typed Python settings singleton
  |
  v
Snowflake _CONFIG tables      CONNECTION, ASSET, and JOB definitions (loaded at runtime)
  |
  v
Config snapshot               Immutable dataclass combining config tables
```

## Operations

### Environment variables

All secrets and infrastructure coordinates are set via environment variables, loaded from `.env` locally and from
K8s/ESO/Vault in production.

Snowflake destination variables:

| Variable                         | Purpose                                                         |
|----------------------------------|-----------------------------------------------------------------|
| `ENVIRONMENT`                    | `dev` or `prod` — controls target database (`RAW_DEV` vs `RAW`) |
| `DESTINATION_SNOWFLAKE_ACCOUNT`          | Snowflake account identifier                                    |
| `DESTINATION_SNOWFLAKE_USER`             | Service account username                                        |
| `DESTINATION_SNOWFLAKE_PRIVATE_KEY_PATH` | Path to PEM private key (supports `~`)                          |
| `DESTINATION_SNOWFLAKE_DATABASE`         | Target database name                                            |
| `DESTINATION_SNOWFLAKE_WAREHOUSE`        | Compute warehouse                                               |
| `DESTINATION_SNOWFLAKE_ROLE`             | Snowflake role                                                  |

Source connection secrets — one block per connection code (CD column from `_CONFIG.CONNECTION`):

```
CONNECTION_{CD}_USERNAME
CONNECTION_{CD}_PASSWORD
CONNECTION_{CD}_SSH_USERNAME
CONNECTION_{CD}_SSH_PRIVATE_KEY_PATH
```

Example: for connection code `QSP__ORDERBUSINESSDB`, set `CONNECTION_QSP__ORDERBUSINESSDB_USERNAME`.
See `.env.example` for the full template.

### Python settings

`data_import.config.settings.Settings` — a pydantic-settings model that validates and types all `DESTINATION_SNOWFLAKE_*`
variables at import time. Accessed via the `get_settings()` function, which is cached with `@functools.cache`.

Key behaviors:

- Private key paths are expanded (`~`) and resolved to absolute paths via a field validator.
- The `dest_db` property maps `ENVIRONMENT` to the Snowflake database name (`dev` -> `RAW_DEV`, `prod` -> `RAW`).
- Extra env vars are ignored, so the same `.env` file serves both this module and connection secrets.

### Snowflake metadata tables

Three tables in `{dest_db}._CONFIG` drive asset discovery and scheduling at runtime.

**CONNECTION** — defines source database endpoints. Credentials are not stored here — they are resolved from env vars
at access time via `@property` methods on the Connection dataclass.

| Column     | Purpose                              |
|------------|--------------------------------------|
| `CD`       | Unique connection code (PK)          |
| `COMMENT`  | Free-text comment                    |
| `TYPE`     | Database type (postgresql, mysql, mssql, oracle) or API type (tarq, epicor) |
| `HOST`     | Source database hostname             |
| `PORT`     | Source database port                 |
| `DATABASE` | Source database name                 |
| `SSH_HOST` | SSH tunnel host (optional)           |
| `SSH_PORT` | SSH tunnel port (optional)           |

Full DDL: `scripts/DST/RAW/_CONFIG/TABLE/CONNECTION.sql`

**Ad-hoc `BI__SNOWFLAKE` connection** — in addition to the table rows, `load_connections()` appends one synthetic
connection, `BI__SNOWFLAKE` (built by `data_import.config.obj.connection.bi_snowflake_connection`). It is not stored in
`_CONFIG.CONNECTION`: its `host`/`database` come from the `DESTINATION_SNOWFLAKE_*` settings and it authenticates with
the same private-key mechanism as the destination (no `CONNECTION_BI__SNOWFLAKE_*` env vars needed). Pair it with an
asset whose `READER` is `snowflake` to copy a table from the destination Snowflake account into another Snowflake table.

**ASSET** — defines what to extract and where to land it. Scheduling is delegated to JOB via `FULL_JOB` and `INC_JOB`.

| Column        | Purpose                                                                |
|---------------|------------------------------------------------------------------------|
| `CD`          | Unique asset code (PK)                                                 |
| `COMMENT`     | Free-text comment                                                      |
| `ACTIVE`      | Whether the asset is enabled                                           |
| `CONNECTION`  | FK to `CONNECTION.CD`                                                  |
| `SOURCE`      | Source table, format: `{schema}.{table}`                               |
| `DESTINATION` | Destination table, format: `{schema}.{table}` (database from Settings) |
| `READER`      | Method used to read data from the source (e.g. `postgresql`, `oracle`, `tarq`, `epicor`, `snowflake`) |
| `PKEY`        | Primary key column(s), also used for deduplication                     |
| `CHUNK_SIZE`    | Row batch size for extraction (default 10000, NOT NULL)                |
| `SCHEMA_INFER`  | Whether to infer column types from data (default true, NOT NULL)       |
| `FULL_JOB`      | Name of the job used for full synchronization (FK to `JOB.CD`)         |
| `INC_JOB`     | Name of the job used for incremental synchronization (FK to `JOB.CD`)  |
| `INC_FIELD`   | Column used for incremental watermark                                  |
| `INC_MIN`     | Manual lower bound for incremental field (exclusive `>`)               |
| `INC_MAX`     | Manual upper bound for incremental field (inclusive `<=`)              |
| `CHECKS`      | `VARIANT` JSON dict of asset checks, `{test_name: expected_value}` (see [defs-elc-check.md](defs-elc-check.md#asset-checks)) |

Full DDL: `scripts/DST/RAW/_CONFIG/TABLE/ASSET.sql`

**JOB** — defines scheduling and execution parameters for asset synchronization jobs.

| Column           | Purpose                                                                                          |
|------------------|--------------------------------------------------------------------------------------------------|
| `CD`             | Unique job code (PK)                                                                             |
| `COMMENT`        | Free-text comment                                                                                |
| `ACTIVE`         | Whether the job is active (default false, NOT NULL)                                              |
| `CRON`           | Cron expression for scheduling                                                                   |
| `EXTRACT_MODE`   | Mode of data extraction, e.g. `full`, `inc` (default `full`, NOT NULL)                           |
| `LOAD_MODE`      | Mode of data loading, e.g. `overwrite`, `append`, `append_dedup` (default `overwrite`, NOT NULL) |
| `CONCURRENT_MAX` | Maximum number of concurrent runs (default 2, NOT NULL)                                          |

Valid `EXTRACT_MODE`-`LOAD_MODE` combinations (sync modes): `full-overwrite`, `full-append`, `inc-append`,
`inc-append_dedup`. Invalid combinations are rejected at Job construction time.

Full DDL: `scripts/DST/RAW/_CONFIG/TABLE/JOB.sql`

### Config snapshot

`data_import.config.config.Config.load()` queries the config tables and returns a frozen dataclass. This is the entry
point for Dagster asset generation and pipeline execution.

## Types

### Config

`data_import.config.config.Config` — immutable snapshot of all connections and assets. Frozen dataclass.

| Key            | Type                    | Description                   |
|----------------|-------------------------|-------------------------------|
| `connection_d` | `dict[str, Connection]` | All connections keyed by `cd` |
| `asset_d`      | `dict[str, Asset]`      | All assets keyed by `cd`      |
| `job_d`        | `dict[str, Job]`        | All jobs keyed by `cd`        |

### Asset

`data_import.config.obj.asset.Asset` — a single extraction asset. Frozen dataclass.

| Key            | Type          | Description                                                            |
|----------------|---------------|------------------------------------------------------------------------|
| `cd`           | `str`         | Unique asset code (PK); three `/`-separated terms forming the composite Dagster asset key (see `cd_key`) |
| `comment`      | `str \| None` | Free-text comment                                                      |
| `active`       | `bool`        | Whether the asset is enabled                                           |
| `connection`   | `str \| None` | FK to `Connection.cd`                                                  |
| `source`       | `str \| None` | Source table, format: `{schema}.{table}`                               |
| `dest_db`      | `str`         | Target Snowflake database (from `Settings.dest_db`)                    |
| `dest_schema`  | `str \| None` | Destination schema (first part of `DESTINATION` column)                |
| `dest_table`   | `str \| None` | Destination table (second part of `DESTINATION` column)                |
| `reader`       | `str \| None` | Method used to read data from the source (e.g. `postgresql`, `oracle`, `tarq`, `epicor`, `snowflake`) |
| `pkey`         | `list[str]`   | Primary key column(s), also used for deduplication                     |
| `chunk_size`   | `int`         | Row batch size for extraction (default 10000)                          |
| `schema_infer` | `bool`        | Whether to infer column types from data or clone the target table schema |
| `full_job`     | `str \| None` | Name of the job for full synchronization (FK to `JOB.CD`)              |
| `inc_job`      | `str \| None` | Name of the job for incremental synchronization (FK to `JOB.CD`)       |
| `inc_field`    | `str \| None` | Column used for incremental watermark (must be a `datetime` or monotonic `int` column) |
| `inc_min`      | `str \| None` | Manual lower bound for incremental field (exclusive `>`); parsed to a typed bound at resolution |
| `inc_max`      | `str \| None` | Manual upper bound for incremental field (inclusive `<=`); parsed to a typed bound at resolution |
| `checks`       | `dict[str, Any]` | Asset checks, `{test_name: expected_value}` (empty when none configured) |
| `dest_fqn`     | `str`         | Property: `{dest_db}.{dest_schema}.{dest_table}`                       |
| `cd_key`       | `tuple[str, str, str]` | Property: composite Dagster asset key, the three `/`-separated terms of `cd`; raises `ValueError` if `cd` contains characters outside `[A-Z0-9_/]` or is not exactly three non-empty terms |
| `cd_group`     | `str`         | Property: the first two terms of `cd_key` joined with `__`                 |

The `DESTINATION` column from Snowflake (format `{schema}.{table}`) is split at load time into `dest_schema` and
`dest_table`. The `dest_db` comes from `Settings.dest_db`, which maps `ENVIRONMENT` to the database name
(`dev` -> `RAW_DEV`, `prod` -> `RAW`).

### Job

`data_import.config.obj.job.Job` — a synchronization job defining scheduling and execution parameters. Frozen
dataclass.

| Key              | Type          | Description                                                                            |
|------------------|---------------|----------------------------------------------------------------------------------------|
| `cd`             | `str`         | Unique job code (PK)                                                                   |
| `comment`        | `str \| None` | Free-text comment                                                                      |
| `active`         | `bool`        | Whether the job is active (default false)                                              |
| `cron`           | `str \| None` | Cron expression for scheduling                                                         |
| `extract_mode`   | `str`         | Mode of data extraction, e.g. `full`, `inc` (default `full`)                           |
| `load_mode`      | `str`         | Mode of data loading, e.g. `overwrite`, `append`, `append_dedup` (default `overwrite`) |
| `concurrent_max` | `int`         | Maximum number of concurrent runs (default 2)                                          |
| `sync_mode`      | `str`         | Property: `"{extract_mode}-{load_mode}"`. Validated against `VALID_SYNC_MODES`         |

### Connection

`data_import.config.obj.connection.Connection` — a source database connection with optional SSH tunnel. Frozen
dataclass.

| Key        | Type          | Description                                |
|------------|---------------|--------------------------------------------|
| `cd`       | `str`         | Unique connection code (PK)                |
| `comment`  | `str \| None` | Free-text comment                          |
| `type`     | `str \| None` | Database type (`postgresql`, `mysql`, `mssql`, `oracle`) |
| `host`     | `str \| None` | Source database hostname                   |
| `port`     | `str \| None` | Source database port                       |
| `database` | `str \| None` | Source database name                       |
| `ssh_host` | `str \| None` | SSH tunnel host (optional)                 |
| `ssh_port` | `str \| None` | SSH tunnel port (optional)                 |

Secret properties — resolved from environment variables at access time:

| Property               | Env var pattern                        |
|------------------------|----------------------------------------|
| `username`             | `CONNECTION_{cd}_USERNAME`             |
| `password`             | `CONNECTION_{cd}_PASSWORD`             |
| `ssh_username`         | `CONNECTION_{cd}_SSH_USERNAME`         |
| `ssh_private_key_path` | `CONNECTION_{cd}_SSH_PRIVATE_KEY_PATH` |

## Functions

### Config.load()

- Input: none
- Output: `Config`
- Queries the Snowflake `_CONFIG` tables and returns an immutable snapshot.

### Config.active_assets()

- Input: none
- Output: `list[Asset]`
- Returns only assets with `active=True`.

### Config.active_jobs()

- Input: none
- Output: `list[Job]`
- Returns only jobs with `active=True`.

### Config.assets_for_job(job)

- Input: `job: Job`
- Output: `list[Asset]`
- Returns active assets linked to a job. Matches via `full_job` when `extract_mode="full"`, via `inc_job` when
  `extract_mode="inc"`. Raises `ValueError` when `load_mode="append_dedup"` and any matched asset has no `pkey`.
  Sync mode validation (`full-overwrite`, `full-append`, `inc-append`, `inc-append_dedup`) is enforced at Job
  construction time via `Job.__post_init__`.

### Config.connection_for(asset)

- Input: `asset: Asset`
- Output: `Connection`
- Looks up the connection via the asset's `connection` FK. Raises `ValueError` if the FK is `None`.

### Config.to_json(indent=2, table=None)

- Input: `indent: int` (default `2`), `table: str | None` (default `None`)
- Output: `str`
- Serializes the config snapshot to a JSON string. When `table` is given (`"assets"`, `"connections"`, or `"jobs"`),
  serializes only that table; otherwise serializes the full snapshot. Raises `ValueError` for an unknown `table`.