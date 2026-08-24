# Defs - ELC (Extract, Load, Check) - load()

## Overview

Loads compressed CSV files from a Snowflake table stage into a Snowflake table. The public entry point is `load()`,
which opens a single Snowflake connection (temporary tables are session-scoped), creates a temporary table from the
staged file schema, validates column name case-insensitivity, moves data to the final table based on `run.load_mode`,
and optionally sets a primary key constraint.

When `run.load_mode` is `truncate`, the staged chunks are ignored entirely: `load()` empties the destination table
via `_truncate_sftable()` (keeping its schema and constraints) and returns `None` if the table does not exist.

## Operations

1. `load()` receives context, run, asset, and `list[SfStageChunkCsvGz]` from `extract()`.
2. Open a single Snowflake connection — all subsequent operations share it because temporary tables are session-scoped.
   - When `run.load_mode` is `truncate`, call `_truncate_sftable()` and skip steps 3-6 (the staged chunks are ignored).
3. `_copy_sfstage_to_sftabletemp()` creates a temporary table and runs `COPY INTO` from the stage directory with
   `MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE`. The temp table creation depends on `asset.schema_infer`:
   - `True` → `USING TEMPLATE` with `INFER_SCHEMA` on the first staged chunk (types inferred from data).
   - `False` → `CREATE TEMPORARY TABLE ... LIKE {dest}` cloning the existing target table's schema. Raises
     `RuntimeError` if the target table does not exist.
4. `_check_sftable_is_case_insensitive()` runs `DESCRIBE TABLE` on the temp table and raises `ValueError` if any
   column names collide when lowered.
5. `_sftabletemp_into_sftable()` moves data to the final table within a Snowflake Scripting block
   (`BEGIN ... BEGIN TRANSACTION ... COMMIT ... EXCEPTION WHEN OTHER THEN ROLLBACK; RAISE; END;`)
   based on `run.load_mode`:
   - Table does not exist OR `overwrite` → `CREATE OR REPLACE TABLE ... AS SELECT * FROM temp`
   - `append` → `INSERT INTO ... SELECT * FROM temp`
   - `append_dedup` with pkey → `DELETE FROM dest USING temp WHERE pkey matches`, then
     `INSERT INTO ... SELECT * FROM temp`
   - `append_dedup` without pkey → raises `ValueError`
6. `_set_pkey_on_sftable()` drops any existing primary key constraint, then adds one from `asset.pkey` if non-empty.
7. Return `SfTable`.

## Types

### Run

- Detailed documentation: [Run](defs-elc.md#run)

### Asset

- Detailed documentation: [Asset](config.md#asset)

### Config

- Detailed documentation: [Config](config.md#config)

### Job

- Detailed documentation: [Job](config.md#job)

### SfStageChunkCsvGz

- Detailed documentation: [SfStageChunkCsvGz](defs-elc.md#sfstagechunkcsvgz)

### SfTableTemp

`data_import.defs.elc.step.load_types.SfTableTemp` — a Snowflake temporary table used to load all the CSV files from
SfStageChunkCsvGz. Frozen dataclass.

- This temporary table must respect the same constraints as the final Snowflake table:
    - Primary key must be set from `asset.pkey` (a list of strings corresponding to the primary key columns) if it is
      set.
    - The column names must be case-insensitive so we don't need to put quotes around them.
    - When `asset.schema_infer` is true, column types are inferred from the first chunk via `INFER_SCHEMA`
      (`NUMBER` types are normalized to `NUMBER(38,0)`, other types use the inferred type).
      When false, the schema is cloned from the existing target table via `LIKE`.

| Key         | Type  | Description                                           |
|-------------|-------|-------------------------------------------------------|
| asset_cd    | `str` | The code of the Asset                                 |
| run_cd      | `str` | The code of the Run                                   |
| destination | `str` | The asset destination (e.g. `RAW.QIMAONE.INSPECTION`) |
| row_nb      | `int` | Number of rows loaded into the temporary table        |
| path        | `str` | Property: `{destination}__TEMP`                       |

### SfTable

- Detailed documentation: [SfTable](defs-elc.md#sftable)

## Functions

### load()

- Inputs: `context: dg.AssetExecutionContext`, `run: Run`, `asset: Asset`,
  `sf_stage_chunks: list[SfStageChunkCsvGz]`
- Output: `SfTable | None` (`None` when `load_mode="truncate"` and the destination table does not exist)
- Public entry point. Opens a single Snowflake connection and orchestrates all load sub-steps. For `load_mode="truncate"`,
  delegates to `_truncate_sftable()` and skips the temp-table flow.

### _truncate_sftable()

- Inputs: `elc_logger: ElcLogger`, `conn: SnowflakeConnection`, `run: Run`, `asset: Asset`
- Output: `SfTable | None`
- Empties the destination table while keeping its schema, columns, and primary key constraint by running
  `TRUNCATE TABLE IF EXISTS {dest}`. Checks `INFORMATION_SCHEMA.TABLES` first: if the table does not exist, logs a
  warning and returns `None` (no-op). On success returns an `SfTable` with `row_nb=0` and `row_inc_nb=0`.

### _copy_sfstage_to_sftabletemp()

- Inputs: `elc_logger: ElcLogger`, `conn: SnowflakeConnection`, `asset: Asset`, `run: Run`,
  `sf_stage_chunks: list[SfStageChunkCsvGz]`
- Output: `SfTableTemp`
- Creates a temporary table and runs `COPY INTO` from the stage directory (`@{destination}/{run_cd}/`) with
  `MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE`. When `asset.schema_infer` is true, uses `USING TEMPLATE` with
  `INFER_SCHEMA` on the first staged chunk (`NUMBER` types normalized to `NUMBER(38,0)`, other types use inferred
  type). When false, clones the existing target table's schema via `CREATE TEMPORARY TABLE ... LIKE {dest}`;
  raises `RuntimeError` if the target table does not exist.

### _check_sftable_is_case_insensitive()

- Inputs: `elc_logger: ElcLogger`, `conn: SnowflakeConnection`, `sf_table_temp: SfTableTemp`
- Output: `None`
- Runs `DESCRIBE TABLE` and raises `ValueError` if column names collide when lowered.

### _sftabletemp_into_sftable()

- Inputs: `elc_logger: ElcLogger`, `conn: SnowflakeConnection`, `run: Run`, `asset: Asset`,
  `sf_table_temp: SfTableTemp`
- Output: `SfTable`
- Copies the data from the temporary table to the final Snowflake table within a Snowflake Scripting block
  (`BEGIN ... BEGIN TRANSACTION ... COMMIT ... EXCEPTION WHEN OTHER THEN ROLLBACK; RAISE; END;`).
  The behavior depends on table existence and the `load_mode` of the run:
    - Table does not exist or `overwrite`: `CREATE OR REPLACE TABLE ... AS SELECT * FROM temp`.
    - `append`: the data from the temporary table is appended to the final table.
    - `append_dedup` with pkey: deletes rows from the final table where primary key columns match the temp table
      (`DELETE FROM dest USING temp WHERE dest.col = temp.col`), then inserts all rows from temp.
    - `append_dedup` without pkey: raises `ValueError`.

### _set_pkey_on_sftable()

- Inputs: `elc_logger: ElcLogger`, `conn: SnowflakeConnection`, `asset: Asset`, `sf_table: SfTable`
- Output: `None`
- Drops any existing primary key constraint, then adds one from `asset.pkey`. Only called when `asset.pkey` is
  non-empty.

