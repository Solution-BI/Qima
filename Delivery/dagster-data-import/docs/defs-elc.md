# Defs - ELC

## Overview

Definition of the ELC (Extract, Load, Check) data pipeline. This is the main production pipeline that extracts data
from source databases, loads it into Snowflake, and checks data integrity.

## Operations

The pipeline processes data through three sequential steps, transforming it from a source database row into a validated
Snowflake table.

```
DataSource -> extract() -> SfStageChunkCsvGz -> load() -> SfTable -> check() -> AssetMetrics
```

Transformations:

- `extract()` — [defs-elc-extract.md](defs-elc-extract.md)
- `load()` — [defs-elc-load.md](defs-elc-load.md)
- `check()` — [defs-elc-check.md](defs-elc-check.md)

### Dynamic Definition Generation

All ELC Dagster definitions (assets, jobs, schedules) are generated dynamically from `_CONFIG` tables at startup.
`data_import.definitions.defs()` loads `Config` once and passes it to the three generators:

- `make_assetsdef_l(config)` — one `@dg.asset` per active asset row
- `make_jobdef_l(config)` — one `define_asset_job` per active job row with matching assets
- `make_scheduledef_l(config)` — one `ScheduleDefinition` per active job with a valid 5-field cron

Asset names and groups are parsed from the `cd` field (split on first hyphen). Jobs select assets via `FULL_JOB`
(when `extract_mode="full"`) or `INC_JOB` (when `extract_mode="inc"`). Each job passes `extract_mode` and `load_mode`
as run tags so the `elc()` function knows how to execute each step.

Jobs with no matching assets are skipped. Schedules with non-standard cron expressions (not 5 fields) are skipped
with a warning.

### Execution Flow

`elc(context, asset, connection)` reads `extract_mode` and `load_mode` from run tags (defaulting to `"full"` and
`"overwrite"` respectively), then runs:

1. `extract(context, run, asset, connection)` — extract data from source to Snowflake stage
2. `load(context, run, asset, sf_stage_chunks)` — load staged data into Snowflake table
3. `check(context, extract_mode, sf_table, asset, run)` — validate loaded data

### Logging

- Use `ElcLogger` (`data_import.util.logging.ElcLogger`) for all logging in the ELC pipeline so logs appear in the
  Dagster UI. `ElcLogger` wraps `DagsterLogManager` and formats metadata as pipe-separated values.

## Types

### Asset

- Detailed documentation: [Asset](config.md#asset)

### Config

- Detailed documentation: [Config](config.md#config)

### Job

- Detailed documentation: [Job](config.md#job)

### Run

`data_import.config.obj.run.Run` — metadata for a single execution of a Dagster job. Frozen dataclass. Constructed
by `elc()` from the execution context.

| Key          | Type       | Description                                               |
|--------------|------------|-----------------------------------------------------------|
| uuid         | `str`      | Dagster run ID (from `context.run_id`)                    |
| start_ts     | `datetime` | Timezone-aware UTC timestamp                              |
| extract_mode | `str`      | `"full"`, `"inc"`, or `"none"`                            |
| load_mode    | `str`      | `"overwrite"`, `"append"`, `"append_dedup"`, or `"truncate"` |
| sync_mode    | `str`      | Property: `"{extract_mode}-{load_mode}"`. Valid combinations: `full-overwrite`, `full-append`, `inc-append`, `inc-append_dedup`, `none-truncate` |
| cd           | `str`      | Property: `"{start_ts:%Y%m%dT%H%M%S}-{sync_mode}-{uuid}"` |

### SfStageChunkCsvGz

`data_import.defs.elc.step.extract_types.SfStageChunkCsvGz` — a compressed CSV file stored in a Snowflake table
stage, ready to be copied into a Snowflake temporary table. Frozen dataclass. Each file must respect
`_CONFIG.CSV_IMPORT` Snowflake file format
([CSV_IMPORT.sql](../scripts/DST/RAW/_CONFIG/FILE_FORMAT/CSV_IMPORT.sql)).

| Key         | Type  | Description                                           |
|-------------|-------|-------------------------------------------------------|
| id          | `int` | The chunk id                                          |
| asset_cd    | `str` | The code of the Asset                                 |
| run_cd      | `str` | The code of the Run                                   |
| destination | `str` | The asset destination (e.g. `RAW.QIMAONE.INSPECTION`) |
| path        | `str` | Property: `@{destination}/{run_cd}/{id:08d}.csv.gz`   |

### SfTable

`data_import.defs.elc.step.load_types.SfTable` — final Snowflake table where the data is loaded and checked. Frozen
dataclass.

- This table must respect these constraints:
    - Primary key must be set from asset.pkey (a list of strings corresponding to the primary key columns) if it is set
    - The column names must be case-insensitive so we don't need to put quotes around them.
    - When `asset.schema_infer` is true, column types are inferred from the first chunk via `INFER_SCHEMA`.
      When false, the schema is cloned from the existing target table via `LIKE`.

| Key         | Type  | Description                                           |
|-------------|-------|-------------------------------------------------------|
| asset_cd    | `str` | The code of the Asset                                 |
| run_cd      | `str` | The code of the Run                                   |
| destination | `str` | The asset destination (e.g. `RAW.QIMAONE.INSPECTION`) |
| row_nb      | `int` | Number of rows in the final table after load          |
| row_inc_nb  | `int` | Number of rows loaded in this run (from SfTableTemp)  |
| path        | `str` | Property: `{destination}`                             |

### AssetMetrics

`data_import.defs.elc.step.check_types.AssetMetrics` — metrics computed on the final Snowflake table after load.
Frozen dataclass. Returned by `check()` and surfaced as Dagster metadata on `MaterializeResult`.

| Key                   | Type           | Description                                          |
|-----------------------|----------------|------------------------------------------------------|
| `byte_size`           | `int`          | Size of the table in bytes (ACTIVE_BYTES)            |
| `row_nb`              | `int`          | Number of rows                                       |
| `column_nb`           | `int`          | Number of columns                                    |
| `pkey_nonunique_nb`   | `int \| None`  | Number of non-unique primary key values (`None` if no pkey) |
| `field_increment_min` | `str \| None`  | Minimum value of the incremental field (`None` if no inc_field) |
| `field_increment_max` | `str \| None`  | Maximum value of the incremental field (`None` if no inc_field) |
| `row_inc_nb`          | `int`          | Number of rows loaded during this ELC run            |
| `exec_time_min`       | `float`        | Execution time of the ELC pipeline in minutes        |

## Functions

### make_assetsdef_l(config)

- Input: `config: Config`
- Output: `list[dg.AssetsDefinition]`
- Generates one Dagster asset per active config row. Skips assets with missing connections.

### make_jobdef_l(config)

- Input: `config: Config`
- Output: `list[UnresolvedAssetJobDefinition]`
- Generates one Dagster job per active job row. Each job selects its assets via `Config.assets_for_job()` and sets
  `extract_mode` and `load_mode` as run tags. Jobs with no matching assets are skipped.
- All generated jobs share a common `op_retry_policy` (see `MAX_RETRIES` and `RETRY_DELAY_SECONDS` in
  `data_import.defs.elc.jobs`): on transient failures (e.g. server timeouts), each asset op retries up to
  `MAX_RETRIES` times with a `RETRY_DELAY_SECONDS` delay between attempts. This policy applies to every reader
  type (`postgresql`, `oracle`, `mssql`, `mysql`, `tarq`, `snowflake`, and any future reader).

### make_scheduledef_l(config)

- Input: `config: Config`
- Output: `list[dg.ScheduleDefinition]`
- Generates one schedule per active job with a valid 5-field cron expression. Invalid crons are skipped.

### extract()

- Input: `context: AssetExecutionContext`, `run: Run`, `asset: Asset`, `connection: Connection`
- Output: `list[SfStageChunkCsvGz]`
- Detailed documentation: [defs-elc-extract.md](defs-elc-extract.md)

### load()

- Input: `context: AssetExecutionContext`, `run: Run`, `asset: Asset`,
  `sf_stage_chunks: list[SfStageChunkCsvGz]`
- Output: `SfTable | None` (`None` when `load_mode="truncate"` and the destination table does not exist)
- Detailed documentation: [defs-elc-load.md](defs-elc-load.md)

### check()

- Input: `context: AssetExecutionContext`, `mode: str`, `sf_table: SfTable`, `asset: Asset`, `run: Run`
- Output: `AssetMetrics`
- Detailed documentation: [defs-elc-check.md](defs-elc-check.md)