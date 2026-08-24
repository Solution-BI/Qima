# Defs - ELC (Extract, Load, Check) - extract()

## Overview

This module extracts data from a source (database or HTTP API) and stages it in Snowflake. The public entry point is `extract()`,
which resolves the asset and connection from config, then delegates to the inner orchestrator `_read_to_tmp()`.
`_read_to_tmp()` reads data from the source in chunks, compresses each chunk to gzip, uploads it to a Snowflake table
stage, and cleans up temp files after each upload.

CSV files must conform to the `_CONFIG.CSV_IMPORT` Snowflake file format
([CSV_IMPORT.sql](../scripts/DST/RAW/_CONFIG/FILE_FORMAT/CSV_IMPORT.sql)): comma-delimited, `"` quoting,
header row (`PARSE_HEADER = TRUE`), UTF-8, GZIP compression, timestamps as `YYYY-MM-DD"T"HH24:MI:SS.FFTZHTZM`.

## Operations

1. `extract()` receives `Asset` and `Connection` from `elc()`. If `run.extract_mode` is `none`, it reads nothing
   from the source and returns an empty list immediately (no SSH tunnel, no reader); otherwise it calls
   `_read_to_tmp()`.
2. If `run.extract_mode` is `inc`, call `_resolve_inc_bounds()` to get the incremental min/max bounds.
3. Open an SSH tunnel via the shared `ssh_tunnel()` helper, which yields `(host, port)` — either
   `("127.0.0.1", local_bind_port)` when a tunnel is active, or `(connection.host, connection.port)` when no SSH is
   configured.
4. Extract the asset data to Snowflake stage, processing one chunk at a time:
   - `_read_source_to_csv()` yields `TempChunkCsv` chunks via the appropriate reader. Each SQL reader pins its
     session to UTC (Oracle/MySQL/Snowflake `ALTER SESSION`/`SET`, PostgreSQL `timezone=UTC`; SQL Server has no
     session timezone) and passes the typed incremental bound as a bind parameter, so the watermark comparison
     stays in a single UTC frame and the driver formats the value natively.
   - For each chunk: `_compress_csv_to_csvgz()` compresses it, then `_move_temp_to_stage()` uploads it.
   - Both `.csv` and `.csv.gz` temp files are deleted after each successful upload.
5. Return `list[SfStageChunkCsvGz]` — the manifest of all uploaded stage chunks.

## Types

### Run

- Detailed documentation: [Run](defs-elc.md#run)

### Asset

- Detailed documentation: [Asset](config.md#asset)

### Connection

- Detailed documentation: [Connection](config.md#connection)

### Config

- Detailed documentation: [Config](config.md#config)

### Job

- Detailed documentation: [Job](config.md#job)

### IncrementalFieldBounds

`data_import.defs.elc.step.extract_types.IncrementalFieldBounds` — incremental extraction bounds. Frozen dataclass.
Values are typed (a `datetime` watermark or a monotonic `int`) and passed to the source query as **bind
parameters**, so each driver formats them natively — no manual literal formatting or NLS coercion. Datetime values
are normalized to naive UTC by `_resolve_inc_bounds` before reaching here (see [Operations](#operations)).

| Key       | Type                   | Description                       |
|-----------|------------------------|-----------------------------------|
| field     | `str`                  | The column used for incremental loading |
| value_min | `datetime \| int \| None` | Lower bound value (exclusive `>`) |
| value_max | `datetime \| int \| None` | Upper bound value (inclusive `<=`) |

### ExtractQuery

`data_import.defs.elc.step.extract_types.ExtractQuery` — a source SELECT statement and its incremental bound
values. Frozen dataclass returned by `build_select_query()`; readers pass it to the driver as
`cursor.execute(query.sql, query.params)`. `sql` carries driver-specific bind placeholders (`:value_min` for
oracledb's `named` style, `%(value_min)s` for the `pyformat` drivers); the `params` property derives the bind
mapping from the bound fields, keyed by the same placeholder names so its keys always match the placeholders
present in `sql`. The incremental field's column name is a SQL identifier, not a bind value, so it never appears
in `params`.

| Key       | Type                      | Description                                                      |
|-----------|---------------------------|------------------------------------------------------------------|
| sql       | `str`                     | SELECT statement with bind placeholders for the present bounds   |
| value_min | `datetime \| int \| None` | Lower-bound value (exclusive `>`), or `None`                     |
| value_max | `datetime \| int \| None` | Upper-bound value (inclusive `<=`), or `None`                    |
| params    | `dict[str, datetime \| int]` | Property: bind mapping keyed by placeholder name; omits absent bounds |

### TempChunkCsv

`data_import.defs.elc.step.extract_types.TempChunkCsv` — a CSV chunk file in the local temp directory. Frozen
dataclass.

| Key      | Type   | Description                                                                          |
|----------|--------|--------------------------------------------------------------------------------------|
| id       | `int`  | The chunk id                                                                         |
| asset_cd | `str`  | The code of the Asset                                                                |
| run_cd   | `str`  | The code of the Run                                                                  |
| path     | `Path` | Property: `/tmp/data-import/{asset_cd}/{run_cd}/{id:08d}.csv`                        |

### TempChunkCsvGz

`data_import.defs.elc.step.extract_types.TempChunkCsvGz` — a gzip-compressed CSV chunk file in the local temp
directory. Frozen dataclass.

| Key      | Type   | Description                                                                          |
|----------|--------|--------------------------------------------------------------------------------------|
| id       | `int`  | The chunk id                                                                         |
| asset_cd | `str`  | The code of the Asset                                                                |
| run_cd   | `str`  | The code of the Run                                                                  |
| path     | `Path` | Property: `/tmp/data-import/{asset_cd}/{run_cd}/{id:08d}.csv.gz`                     |

### SfStageChunkCsvGz

- Detailed documentation: [SfStageChunkCsvGz](defs-elc.md#sfstagechunkcsvgz)

## Functions

### extract()

- Input: `context: dg.AssetExecutionContext`, `run: Run`, `asset: Asset`, `connection: Connection`
- Output: `list[SfStageChunkCsvGz]`
- Public entry point. Receives asset and connection directly from `elc()`, delegates to `_read_to_tmp()`.
  Returns an empty list without reading the source when `run.extract_mode` is `none`.

### _read_to_tmp()

- Input: `elc_logger: ElcLogger`, `asset: Asset`, `connection: Connection`, `run: Run`
- Output: `list[SfStageChunkCsvGz]`
- Inner orchestrator: resolves incremental bounds, opens SSH tunnel, reads/compresses/uploads chunks, cleans up.

### _resolve_inc_bounds()

- Input: `asset: Asset`
- Output: `IncrementalFieldBounds | None`
- Resolves incremental extraction bounds:
    - **inc_min** (lower bound, exclusive `>`):
        1. Query `MAX(inc_field)` from the Snowflake destination table via `_query_value_min_from_dest()`.
        2. If the query fails or returns NULL, fall back to `asset.inc_min` (manual override).
        3. If both are `None`, no lower bound.
    - **inc_max** (upper bound, inclusive `<=`):
        1. If `asset.inc_max` is set, use it directly (manual cap).
        2. Otherwise `None` (no upper bound).
- Both the destination value and the config strings (`inc_min`/`inc_max`) are coerced to a typed watermark via
  `_coerce_bound()`: a monotonic `int` or a naive-UTC `datetime` (tz-aware values are converted to UTC and
  stripped of tzinfo). This keeps the watermark in the same UTC frame as the source sessions, which the readers
  pin to UTC.

### _coerce_bound()

- Input: `value: object` (a driver result or a config string)
- Output: `datetime | int | None`
- Coerces a raw watermark to a typed bound: `datetime` → naive UTC; `date` → midnight `datetime`; `int`/`Decimal`
  → `int`; `str` → `int` if it parses as one, else a naive-UTC `datetime` via `datetime.fromisoformat`. Raises
  `TypeError` for an unsupported type (e.g. `bool`).

### _query_value_min_from_dest()

- Input: `asset: Asset`
- Output: `datetime | int | None`
- Queries `SELECT MAX(inc_field) FROM {dest_table}` to find the current watermark value, coerced via
  `_coerce_bound()`. Returns `None` if the query fails or returns NULL.

### _read_source_to_csv()

- Input: `asset: Asset`, `connection: Connection`, `run_cd: str`, `local_host: str`, `local_port: int`,
  `inc_bounds: IncrementalFieldBounds | None`
- Output: `Iterator[TempChunkCsv]`
- Dispatches to the appropriate reader based on `asset.reader`:

| asset.reader | Reader function            | Details                                                      |
|--------------|----------------------------|--------------------------------------------------------------|
| postgresql   | read_postgresql_to_csv()   | Server-side cursor (psycopg2)                                |
| oracle       | read_oracle_to_csv()       | oracledb thin mode with prefetch tuning                      |
| mssql        | read_mssql_to_csv()        | pymssql cursor with fetchmany                                |
| mysql        | read_mysql_to_csv()        | mysql-connector-python with fetchmany                        |
| tarq         | read_tarq_to_csv()         | HTTP API reader (httpx async, semaphore=3); does not use local_host/local_port |
| epicor       | read_epicor_to_csv()       | PLH Fashion Epicor ERP HTTP API reader (httpx async, Basic Auth, self-signed cert); does not use local_host/local_port |
| snowflake    | read_snowflake_to_csv()    | Reads the destination Snowflake account via shared private-key connection; does not use local_host/local_port |

#### read_postgresql_to_csv()

- Reads data from a PostgreSQL database using a named (server-side) cursor for memory-efficient streaming.
- Fetches `asset.chunk_size` rows at a time, writes each batch to a CSV with header.

#### read_oracle_to_csv()

- Reads data from an Oracle database using oracledb in thin mode (no Oracle client required).
- Uses `prefetchrows` and `arraysize` tuning for chunk-sized fetches.

#### read_mssql_to_csv()

- Reads data from a MSSQL database using pymssql.
- Fetches `asset.chunk_size` rows at a time, writes each batch to a CSV with header.

#### read_mysql_to_csv()

- Reads data from a MySQL database using mysql-connector-python.
- Fetches `asset.chunk_size` rows at a time, writes each batch to a CSV with header.

#### read_tarq_to_csv()

- Input: `asset: Asset`, `connection: Connection`, `run_cd: str`, `inc_bounds: IncrementalFieldBounds | None`
- Output: `Iterator[TempChunkCsv]`
- Reads farm detail records from the Tarq HTTP API using `httpx` async with a semaphore of 3 concurrent requests.
- Authenticates via `POST /api/v1/auth/login` using `connection.username` / `connection.password`; sets a Bearer token for all subsequent requests.
- Paginates `asset.source` endpoint (100 items per page) to collect farm summaries.
- When `inc_bounds.value_min` is set, filters farms by `updated_at > value_min` before fetching details.
- Fetches farm details in async batches of `asset.chunk_size`: for each farm, `GET /api/v1/external/farms/{farm_id}` and paginated `GET /api/v1/external/farms/{farm_id}/status`; merges status_changes into the detail payload.
- Retries up to 3 times on 429/5xx; respects the `Retry-After` header on 429 responses.
- Yields one CSV chunk per batch. Columns: `id`, `updated_at`, `raw_json`.
- Does not use `local_host` or `local_port` (no SSH tunnel for HTTP API sources).
- See [_read_source_to_csv()](#_read_source_to_csv) for dispatch details.

#### read_epicor_to_csv()

- Input: `asset: Asset`, `connection: Connection`, `run_cd: str`, `inc_bounds: IncrementalFieldBounds | None`
  (unused — see below)
- Output: `Iterator[TempChunkCsv]`
- Reads PLH Fashion Epicor ERP REST API data (`Erp.BO.CustomerSvc`, `Erp.BO.VendorSvc`, `Erp.BO.SalesOrderSvc`) using
  `httpx` async with Basic Auth (`connection.username`/`connection.password`) and `verify=False` (the host presents a
  self-signed certificate).
- Ignores the framework-computed `inc_bounds` (which is a single global bound) and instead resolves a **per-company**
  watermark by querying `SELECT "COMPANY", MAX(inc_field) FROM {asset.dest_fqn} GROUP BY 1` directly, since PLH01 and
  PLH03 have independent `SysRevID` ranges. Every request sets a `CallSettings: {'Company': ...}` header (Python
  dict-repr, matching the format the live Epicor instance already accepts) to scope the request to one company.
- Paginates each endpoint via OData `$skip`/`$top` until a page returns fewer rows than `$top`.
- `PLH_ORDER_D` and `PLH_ORDER_R` can only be read from Epicor per-parent-order (nested URLs) — there is no
  cross-asset dependency mechanism in this pipeline, so each dependent table's reader is self-contained: it reads
  `Company`/`OrderNum`(`/OrderLine`) directly from the sibling destination table in Snowflake (`PLH_ORDER_H` /
  `PLH_ORDER_D` respectively) for rows past its own last-processed watermark, then stamps a bookkeeping column
  (`SRC_HDR_SYSREVID` / `SRC_DTL_SYSREVID`, not native to Epicor) on each fetched child row with the parent's own
  `SysRevID`. That bookkeeping column is the dependent table's own `inc_field`, so incrementality is race-free
  regardless of whether the parent table's job has already run this cycle.
- Retries up to 3 times on 429/5xx; respects the `Retry-After` header on 429 responses.
- Yields one CSV chunk per `asset.chunk_size` rows, across all companies. Columns are the asset's `$select` field
  list (Customers/Vendors have no `$select`, so columns are the union of keys seen across fetched rows).
- Does not use `local_host` or `local_port` (no SSH tunnel for HTTP API sources).
- See [_read_source_to_csv()](#_read_source_to_csv) for dispatch details.

#### read_snowflake_to_csv()

- Input: `asset: Asset`, `connection: Connection`, `run_cd: str`, `inc_bounds: IncrementalFieldBounds | None`
- Output: `Iterator[TempChunkCsv]`
- Reads from the destination Snowflake account via the shared `snowflake_connection()` context manager
  (private-key auth from `DESTINATION_SNOWFLAKE_*`), so it does not use `connection.username` / `connection.password`.
- Used with the ad-hoc `BI__SNOWFLAKE` connection (see [Connection](config.md#connection)) to copy a Snowflake table
  into another Snowflake table (Snowflake → Snowflake reflow).
- Builds an [ExtractQuery](#extractquery) via `build_select_query()` (`asset.source` should be a schema- or
  fully-qualified Snowflake table), then fetches `asset.chunk_size` rows at a time, writing each batch to a CSV
  with header.
- Does not use `local_host` or `local_port` (no SSH tunnel, like `tarq`).
- See [_read_source_to_csv()](#_read_source_to_csv) for dispatch details.

### _compress_csv_to_csvgz()

- Input: `TempChunkCsv`
- Output: `TempChunkCsvGz`
- Compresses the CSV file using gzip via `shutil.copyfileobj`.

### _move_temp_to_stage()

- Input: `TempChunkCsvGz`, `Asset`
- Output: `SfStageChunkCsvGz`
- Uploads the compressed CSV to a Snowflake table stage using `PUT` with `AUTO_COMPRESS=FALSE OVERWRITE=TRUE`.
