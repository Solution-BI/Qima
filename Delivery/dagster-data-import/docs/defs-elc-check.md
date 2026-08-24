# Defs - ELC (Extract, Load, Check) - check()

## Overview

This step computes metrics on the loaded Snowflake table for monitoring, alerting, and data quality checks. It queries
the final `SfTable` for size, row count, column count, primary key uniqueness, and incremental field bounds, then
returns an `AssetMetrics` object that is surfaced as Dagster metadata.

## Types

### SfTable

- Detailed documentation: [SfTable](defs-elc.md#sftable)

### AssetMetrics

- Detailed documentation: [AssetMetrics](defs-elc.md#assetmetrics)

## Functions

### check()

- Input: `context: dg.AssetExecutionContext`, `mode: str`, `sf_table: SfTable`, `asset: Asset`, `run: Run`
- Output: `AssetMetrics`

Opens a Snowflake connection, calls each sub-function, computes `exec_time_min` from `run.start_ts`, and returns
`AssetMetrics`.

### _byte_size()

- Input: `conn: SnowflakeConnection`, `sf_table: SfTable`
- Output: `int`

Queries `INFORMATION_SCHEMA.TABLE_STORAGE_METRICS` for `ACTIVE_BYTES`. Returns `0` if no row found.

### _row_nb()

- Input: `conn: SnowflakeConnection`, `sf_table: SfTable`
- Output: `int`

Returns `COUNT(*)` from the table.

### _column_nb()

- Input: `conn: SnowflakeConnection`, `sf_table: SfTable`
- Output: `int`

Returns the number of rows from `DESCRIBE TABLE`.

### _pkey_nonunique_nb()

- Input: `conn: SnowflakeConnection`, `sf_table: SfTable`, `asset: Asset`
- Output: `int | None`

When the asset has a primary key, returns the count of non-unique primary key combinations
(`GROUP BY ... HAVING COUNT(*) > 1`). Returns `None` when no pkey is configured.

### _field_increment_min()

- Input: `conn: SnowflakeConnection`, `sf_table: SfTable`, `asset: Asset`
- Output: `str | None`

Returns `MIN({inc_field})::VARCHAR`. Returns `None` when no `inc_field` is configured.

### _field_increment_max()

- Input: `conn: SnowflakeConnection`, `sf_table: SfTable`, `asset: Asset`
- Output: `str | None`

Returns `MAX({inc_field})::VARCHAR`. Returns `None` when no `inc_field` is configured.

## Asset checks

Asset checks are configurable data-quality gates that validate the `AssetMetrics` produced above. They use Dagster's
native asset-check mechanism: each generated asset declares one `dg.AssetCheckSpec(blocking=True)` per configured check
and emits a `dg.AssetCheckResult` (via `MaterializeResult(check_results=...)`) when it materializes. Because the checks
are `blocking`, a failed check fails the run.

Checks are declared per asset in the `CHECKS` column of `_CONFIG.ASSET` (see
[config.md](config.md#snowflake-metadata-tables)), a JSON dict of `{test_name: expected_value}`. A test runs only if its key is
present; an empty/absent dict means no checks. Example: `{"is_row_nb_eq": 123, "is_row_inc_nb_eq": 23,
"is_column_nb_eq": 23}`.

The available tests live in `data_import.defs.elc.checks.CHECK_REGISTRY`, mapping each test name to a `CheckDef`
(`description`, `actual`, `predicate`). Each `predicate` takes the `AssetMetrics` and the configured expected value and
returns a `bool`. **To add a test, add one entry to `CHECK_REGISTRY`** — no change to asset generation is needed.

Configured keys are validated at code-location load by `validate_check_keys()`: an unknown key (e.g. a typo) raises a
`ValueError` so the misconfiguration surfaces immediately rather than being silently skipped.

When `elc()` loads nothing (zero chunks or no table), no `AssetCheckResult` is emitted and the declared checks are
reported as not executed.
