# Qima HR Payroll -- Ingestion & Extraction Design

**Scope:** RAW layer only -- getting payroll Excel files from SharePoint into
Snowflake as unstructured JSON. Nothing in this document touches
transformation, modelling, or the SILVER/GOLD layers.

**Status:** Built and tested end-to-end in the Snowflake Notebook Workspace.
Running against the live SharePoint payroll folder with real subsidiary files.

---

## 1. Design Principle

Ingestion and extraction are deliberately kept "dumb" so they cannot break
when Qima's Excel template changes.

- **Ingestion** never looks inside a file -- it only moves bytes from
  SharePoint into a temporary Snowflake stage.
- **Extraction** never interprets a file -- it only converts the grid to JSON,
  sheet by sheet, cell by cell. No header detection, no layout interpretation.

All structural interpretation lives in the transformation layer, driven by the
HEADER_MAP reference data.

Raw payroll files are never persisted in Snowflake beyond the moment it takes
to read them. They land in a session-scoped temporary stage, get parsed
immediately, and disappear when the session ends. Nothing sensitive sits in
the platform longer than necessary.

---

## 2. Table: FILE_LOAD

Tracks every payroll Excel file submitted by QIMA subsidiaries via SharePoint.
Each row represents one ingestion attempt of a single file -- capturing who
submitted it, when it was last modified, whether it was successfully downloaded
and parsed, and the raw cell-level content extracted from the workbook. When HR
re-uploads a corrected file, the previous version is retained for audit
purposes and flagged accordingly, ensuring a complete history of every
submission.

```sql
CREATE OR REPLACE TABLE FILE_LOAD (
    -- Identity
    LOAD_ID                NUMBER(38,0)      NOT NULL AUTOINCREMENT START 1 INCREMENT 1 NOORDER,

    -- Pipeline run
    RUN_ID                 VARCHAR,

    -- File metadata (from SharePoint Graph API)
    FILE_NAME              VARCHAR           NOT NULL,
    FILE_PATH              VARCHAR,
    FILE_SIZE_BYTES        NUMBER(38,0),
    SHAREPOINT_MODIFIED_AT TIMESTAMP_TZ(9),
    SHAREPOINT_MODIFIED_BY VARCHAR,
    SHAREPOINT_CREATED_AT  TIMESTAMP_TZ(9),
    SHAREPOINT_CREATED_BY  VARCHAR,

    -- Ingest outcome
    INGESTED_AT            TIMESTAMP_TZ(9),
    INGEST_STATUS          VARCHAR,

    -- Extract outcome
    EXTRACTED_AT           TIMESTAMP_TZ(9),
    EXTRACT_STATUS         VARCHAR           NOT NULL DEFAULT 'NOT_ATTEMPTED',
    RAW_CONTENT            VARIANT,

    -- Error tracking
    ERROR_MESSAGE          VARCHAR,

    -- Versioning
    IS_CURRENT             BOOLEAN           DEFAULT TRUE,

    -- Constraints
    CONSTRAINT PK_FILE_LOAD      PRIMARY KEY (LOAD_ID),
    CONSTRAINT CHK_INGEST_STATUS  CHECK (INGEST_STATUS  IN ('SUCCESS', 'FAILED')),
    CONSTRAINT CHK_EXTRACT_STATUS CHECK (EXTRACT_STATUS IN ('SUCCESS', 'FAILED', 'NOT_ATTEMPTED'))
);
```

### Column reference

| Column | Description |
|---|---|
| LOAD_ID | Auto-incrementing row ID. One per file, per ingest attempt. |
| RUN_ID | UUID grouping all files processed in a single pipeline run. |
| FILE_NAME | Excel file name as it appears on SharePoint. |
| FILE_PATH | SharePoint folder path identifying which subsidiary folder the file came from. |
| FILE_SIZE_BYTES | File size in bytes as reported by the Graph API. |
| SHAREPOINT_MODIFIED_AT | When the file was last saved on SharePoint. Drives the high-water mark window. |
| SHAREPOINT_MODIFIED_BY | Display name of the person who last modified the file. |
| SHAREPOINT_CREATED_AT | When the file was first uploaded to SharePoint. |
| SHAREPOINT_CREATED_BY | Display name of the person who originally uploaded the file. |
| INGESTED_AT | When the pipeline downloaded and staged this file. |
| INGEST_STATUS | `SUCCESS` = file downloaded and staged. `FAILED` = download or staging failed. |
| EXTRACTED_AT | When the raw cell extraction ran against this file. |
| EXTRACT_STATUS | `SUCCESS` = parsed into JSON. `FAILED` = couldn't be opened/parsed. `NOT_ATTEMPTED` = ingest failed, nothing to parse. |
| RAW_CONTENT | Nested JSON grid: `{ "SheetName": [[cell, cell, ...], ...] }`. Raw cells only. |
| ERROR_MESSAGE | Error detail when INGEST_STATUS or EXTRACT_STATUS is FAILED. NULL on success. |
| IS_CURRENT | `TRUE` = latest version of this file. `FALSE` = previous version, superseded by a re-upload. |

### Status combinations

| INGEST_STATUS | EXTRACT_STATUS | Meaning |
|---|---|---|
| FAILED | NOT_ATTEMPTED | SharePoint fetch or connectivity failure. Never made it to the stage. |
| SUCCESS | NOT_ATTEMPTED | Staged, but extraction hasn't run yet -- picked up on retry. |
| SUCCESS | FAILED | Staged, but the file couldn't be opened or parsed. Needs investigation. |
| SUCCESS | SUCCESS | Complete. RAW_CONTENT is populated and trustworthy. |

---

## 3. Notebook structure

The pipeline runs as a Snowflake Notebook in a Workspace service, connected to
SharePoint via an External Access Integration (`SHAREPOINT_HR_PAYROLL_EAI`).
All cells run start to finish in one continuous session -- this is what makes
the temporary stage work (it auto-drops at session end).

### Cell 1 -- Context

SQL cell. Sets the warehouse, database, and schema for the session.

```sql
USE WAREHOUSE SANDBOX_WH;
USE DATABASE SANDBOX_DB;
USE SCHEMA HR_PAYROLL_QIMA;
```

### Cell 2 -- SharePoint config and auth

Defines all SharePoint connection parameters inline -- `TENANT_ID`, `CLIENT_ID`,
`SITE_ID`, `DRIVE_ID`, `FOLDER_PATH`, and `STAGE`. These are reused across all
subsequent cells via session-level variable persistence.

The `get_token()` function reads the client secret from the SPCS-mounted secret
file (`/secrets/sandbox_db/hr_payroll_qima/sharepoint_hr_payroll_client_secret/secret_string`)
and exchanges it for a bearer token via the OAuth2 client-credentials flow.
The token is stored in `HDR` (the auth header dict) for the duration of the run.

### Cell 3 -- Create temporary stage

SQL cell. Creates a session-scoped temporary stage (`TEMP_PAYROLL_STAGE`).
Auto-dropped when the session ends -- no manual cleanup, no path where raw
file bytes persist beyond the run.

### Cell 4 -- list_children()

Defines `list_children(url)` -- a function that fetches the immediate items
(files and folders) at a single Graph API URL, handling Microsoft Graph's
pagination (`@odata.nextLink`). This is the low-level API primitive used by
`walk_folder`.

Verification output: prints the top-level items inside the payroll folder.

### Cell 5 -- walk_folder()

Defines `walk_folder(folder_id)` -- recursively traverses all subfolders under
the payroll root, collecting every file regardless of nesting depth. Each
subsidiary files into its own subfolder (e.g. `Payroll files/Brazil/`), and
this function flattens the entire tree into a single list.

Verification output: prints every file found across all subfolders with name,
size, and modification time.

### Cell 6 -- list_candidates()

Defines `list_candidates(session, all_files, offset_minutes)` -- combines the
parameter computation and file filtering into a single function:

1. **Computes the ingestion window** internally:
   - `FROM_TS` = `MAX(INGESTED_AT)` from FILE_LOAD rows where
     `INGEST_STATUS = 'SUCCESS'`. Falls back to `2024-01-01` on the first run.
   - `TO_TS` = current UTC time minus `offset_minutes` (safety buffer).
2. **Filters** the flat file list from `walk_folder` to only `.xlsx` files
   with `lastModifiedDateTime` strictly within `(FROM_TS, TO_TS)` -- exclusive
   on both sides, so already-ingested files are not re-processed.

Returns a tuple: `(candidates, from_ts, to_ts)`. Each candidate dict contains
`id` (SharePoint item ID), `name`, `path`, `modified_at`, `modified_by`,
`created_at`, `created_by`, and `size_bytes`.

Both timestamps are in UTC for consistency with SharePoint's
`lastModifiedDateTime`.

### Cell 7 -- download_files()

Defines `download_files(candidates)` -- downloads each candidate file from
SharePoint via the Graph API `/content` endpoint. Returns a list of dicts,
each containing the file `name`, download `status` (`OK` or `FAILED`), and
the raw `content` bytes (on success) or an `error` message (on failure).

One bad file does not abort the batch -- each file is handled independently.

### Cell 8 -- stage_files()

Defines `stage_files(downloads, stage_name)` -- PUTs each successfully
downloaded file into the temporary Snowflake stage using
`session.file.put_stream`. Files that failed to download are skipped.

The bytes go straight from memory to the stage -- they never touch local disk.

Verification output: lists all files on the stage with `LIST @STAGE`.

### Cell 9 -- INSERT into FILE_LOAD

For every candidate from Cell 6 (regardless of outcome):

1. **Version management:** Updates any existing FILE_LOAD rows for the same
   file name to `IS_CURRENT = FALSE`.
2. **Insert:** Creates a new row with all SharePoint metadata
   (`SHAREPOINT_MODIFIED_AT`, `SHAREPOINT_MODIFIED_BY`, `SHAREPOINT_CREATED_AT`,
   `SHAREPOINT_CREATED_BY`), the ingest outcome (`SUCCESS` or `FAILED`), and
   `IS_CURRENT = TRUE`.

A failed fetch is never silently dropped -- it gets a durable `FAILED` row
with an error message that shows up in monitoring.

The `RUN_ID` (UUID) groups all files from this pipeline execution for
traceability.

### Cell 10 -- Extract and update

For every row just inserted with `INGEST_STATUS = 'SUCCESS'` and
`EXTRACT_STATUS = 'NOT_ATTEMPTED'`:

1. Opens the staged file from the temporary stage via `session.file.get_stream`.
2. Parses the workbook using `openpyxl` in read-only mode.
3. Walks every worksheet and builds a nested JSON grid:
   `{ "SheetName": [[cell, cell, ...], [cell, cell, ...], ...] }`.
   Dates become ISO strings, numbers stay as-is, everything else becomes a
   string. No header detection, no layout interpretation.
4. Updates the FILE_LOAD row: `EXTRACT_STATUS = 'SUCCESS'`, `EXTRACTED_AT`,
   and `RAW_CONTENT = PARSE_JSON(...)`.
5. On failure: `EXTRACT_STATUS = 'FAILED'` with the error in `ERROR_MESSAGE`.

Rows where ingest failed are untouched -- they stay at
`EXTRACT_STATUS = 'NOT_ATTEMPTED'`.

The cell is idempotent: re-running it only processes rows that are still
`NOT_ATTEMPTED`, so already-extracted rows are never re-processed.

Nothing further runs after this cell -- the temporary stage and anything on
it disappear when the session closes.

---

## 4. HR scenarios

The pipeline handles four scenarios covering the full lifecycle of a subsidiary
payroll submission. Full detail is in `ingestion/docs/QIMA_HR_SCENARIO.md`.

**Scenario 1 -- New file upload.** HR uploads a new payroll Excel file. The
pipeline picks it up based on `lastModifiedDateTime`, downloads it, stages it,
extracts the raw content, and inserts a FILE_LOAD row with `IS_CURRENT = TRUE`.

**Scenario 2 -- File correction.** HR edits an existing file (e.g. fixes a
salary). SharePoint advances `lastModifiedDateTime`, so the file re-enters the
next run's window. The pipeline downloads the latest version, flags the
previous FILE_LOAD row as `IS_CURRENT = FALSE`, and inserts a new row with the
corrected content as `IS_CURRENT = TRUE`. Both versions are preserved for
audit. The timing of the correction does not matter -- hours or weeks later.

**Scenario 3 -- File deletion.** HR deletes a file from SharePoint. The
pipeline simply doesn't see it on the next run. No error, no new row, no
change to FILE_LOAD. The existing row and its RAW_CONTENT are preserved.
Whether deleted-file data should be excluded from reports is a business rule
handled in the transformation layer.

**Scenario 4 -- No activity.** Nothing has changed on SharePoint. The pipeline
runs, finds zero candidates, and finishes cleanly as a no-op.

---

## 5. External access configuration

The notebook runs in a Snowflake Workspace service (SPCS container) with the
following attached:

- **External Access Integration:** `SHAREPOINT_HR_PAYROLL_EAI` -- allows
  outbound HTTPS to Microsoft Graph API and SharePoint download hosts.
- **Secret:** `SANDBOX_DB.HR_PAYROLL_QIMA.SHAREPOINT_HR_PAYROLL_CLIENT_SECRET`
  -- Azure AD client secret, mounted at
  `/secrets/sandbox_db/hr_payroll_qima/sharepoint_hr_payroll_client_secret/secret_string`
  (SPCS mounts secrets as lowercase file paths).
- **Network Rule:** `SHAREPOINT_HR_PAYROLL_NETWORK_RULE` -- allows egress to
  `graph.microsoft.com`, `login.microsoftonline.com`, `*.sharepoint.com`, and
  `*.svc.ms`.

Configuration SQL is in `config/external_access/`.

---

## 6. Open items

- **SHAREPOINT_ITEM_ID column** -- needed so the version management UPDATE
  matches on the stable SharePoint item ID (e.g. `01NLVSOQ3GRS6PUJGWX5...`)
  instead of file name. Without this, a file rename creates an orphaned
  `IS_CURRENT = TRUE` row for the old name. The item ID is already captured
  in `list_candidates` as `c['id']` -- it just needs to be stored in FILE_LOAD
  and used in the UPDATE WHERE clause.
- **Partial extraction failure** -- if one worksheet in an otherwise-good file
  is unreadable, the current implementation fails the whole file. Whether to
  land the good sheets and flag the bad one separately is not yet decided.
- **Task scheduling** -- the pipeline currently runs manually. Scheduled
  execution via a Snowflake Task is planned but not yet implemented.
- **RBAC lockdown** -- production role grants and masking policies are defined
  in `security/` but not yet applied.

---

## 7. Plain-language description (for Qima)

Every time this step runs, the platform checks the SharePoint payroll folders
for anything that has changed since the last time it ran. That window is
automatic by default, but can be widened manually if we ever need to
reprocess an older period.

Every file it finds is logged -- file name, who submitted it, when it changed,
when we picked it up, and whether that succeeded -- whatever the outcome, so
there is a complete and permanent record of everything received. Nothing is
ever silently missed. A failed file stays in the system for automatic retry on
the next run.

If HR corrects a file and re-uploads it, the platform picks up the new version
and keeps both -- the old and the corrected -- for audit purposes. Only the
latest version is marked as current; downstream reports always use the
corrected data.

The content of each file is then read and stored securely inside Snowflake as
raw data. The original spreadsheet itself is only ever held for the brief
moment it takes to read it, and is never kept afterwards -- consistent with the
isolation and minimal-retention approach agreed with Antoine.
