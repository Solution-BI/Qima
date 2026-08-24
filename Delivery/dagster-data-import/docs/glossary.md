# Glossary

| Term                 | Definition                                                                                  |
|----------------------|---------------------------------------------------------------------------------------------|
| ELC                  | Extract, Load, Check — the main production pipeline                                        |
| Asset                | A Dagster asset representing a single data extraction/load unit, configured in `_CONFIG.ASSET` |
| Connection           | A source database endpoint definition, configured in `_CONFIG.CONNECTION`                   |
| Config               | Immutable snapshot of all connections and assets loaded from Snowflake                      |
| Reader               | The method used to read data from a source (e.g. `postgresql`, `mysql`, `mssql`, `oracle`, `tarq`, `snowflake`), configured in `_CONFIG.ASSET.READER` |
| Job                  | A scheduling and execution unit configured in `_CONFIG.JOB`, referenced by assets via `FULL_JOB`/`INC_JOB` |
| Incremental load     | A partial extraction using a watermark column (`inc_field`) to fetch only new/changed rows  |
| inc_min              | Manual lower bound (exclusive `>`) for incremental extraction, overrides the Snowflake MAX query |
| inc_max              | Manual upper bound (inclusive `<=`) for incremental extraction                               |
| Full load            | A complete extraction of all rows from the source table                                     |
| Chunk                | A batch of rows extracted and written as a single CSV file                                  |
| Stage                | A Snowflake internal stage used for temporary file storage before COPY INTO                 |
| dest_db              | The target Snowflake database, derived from `ENVIRONMENT` (`RAW` or `RAW_DEV`)             |