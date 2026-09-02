# Qima HR Payroll – Ingestion & Extraction Design

**Scope:** RAW layer only – getting a file from SharePoint into Snowflake as unstructured JSON. Nothing in this document touches transformation, modelling, or the SILVER layer.

**Status:** working design, not yet built or confirmed with Qima. A few points are flagged below as assumptions rather than decisions.

---

## 1. Design principle

Ingestion and extraction are deliberately kept "dumb" so they can't break on template change. Ingestion never looks inside a file – it only moves bytes. Extraction never interprets a file – it only converts the grid to JSON, sheet by sheet, cell by cell. Nothing about headers, layout, vertical/horizontal components, or template generation is known at this layer. All of that is transformation's job, downstream of this design.

The corollary: raw payroll files are never persisted in Snowflake beyond the moment it takes to read them. They land in a session-scoped temporary stage, get parsed immediately, and disappear when the session ends. Nothing sensitive sits in the platform for longer than necessary.

---

## 2. Table: RAW.FILE_LOAD

One row per file, per ingestion attempt. Append-only – a file picked up again in a later run gets a new row, nothing is ever overwritten. This is both the ingestion log and the landing point for the extracted content; there's no separate table for the two, since it's always a strict one-to-one relationship between "we attempted this file" and "here's what we got."

```sql
CREATE OR REPLACE TABLE RAW.FILE_LOAD (
    LOAD_ID                 NUMBER IDENTITY START 1 INCREMENT 1,        -- unique per file, per attempt
    RUN_ID                  VARCHAR,                                     -- Snowflake task-graph run id; groups every file from one scheduled execution. Null on a manual/ad hoc run.
    FILE_NAME                VARCHAR NOT NULL,
    FILE_PATH                VARCHAR NOT NULL,                           -- full SharePoint path, incl. owner/subsidiary folder
    SHAREPOINT_MODIFIED_AT   TIMESTAMP_TZ,                                -- last-modified as reported by SharePoint
    FILE_SIZE_BYTES          NUMBER,
    INGESTED_AT              TIMESTAMP_TZ,                                -- when the file was fetched and staged
    INGEST_STATUS            VARCHAR NOT NULL,                            -- SUCCESS / FAILED
    EXTRACTED_AT             TIMESTAMP_TZ,                                -- when parse-to-JSON completed
    EXTRACT_STATUS           VARCHAR NOT NULL DEFAULT 'NOT_ATTEMPTED',    -- SUCCESS / FAILED / NOT_ATTEMPTED
    RAW_CONTENT              VARIANT,                                     -- { "Sheet2024": [[...],[...]], "Sheet2025": [...] } – null unless EXTRACT_STATUS = SUCCESS
    ERROR_MESSAGE            VARCHAR,                                     -- populated on either failure, from whichever stage failed
    CONSTRAINT PK_FILE_LOAD PRIMARY KEY (LOAD_ID),                                                 -- informational only, Snowflake does not enforce this
    CONSTRAINT CHK_INGEST_STATUS  CHECK (INGEST_STATUS  IN ('SUCCESS','FAILED')),                  -- informational only, not enforced
    CONSTRAINT CHK_EXTRACT_STATUS CHECK (EXTRACT_STATUS IN ('SUCCESS','FAILED','NOT_ATTEMPTED'))   -- informational only, not enforced
);
```

### Status values

| INGEST_STATUS | EXTRACT_STATUS | Meaning |
|---|---|---|
| FAILED | NOT_ATTEMPTED | Never made it to the stage – SharePoint fetch or connectivity failure. |
| SUCCESS | NOT_ATTEMPTED | Staged, but the run stopped before parsing reached it – picked up on retry. |
| SUCCESS | FAILED | Staged, but the file couldn't be opened or parsed at all. Structural rejection, needs the file owner notified. |
| SUCCESS | SUCCESS | Complete. RAW_CONTENT is trustworthy. |

`LOAD_ID` is a plain surrogate key, generated per row – deliberately *not* a Snowflake job/query id, since one scheduled run touches several files and a job id can't uniquely identify a single row. `RUN_ID` is where that execution-level traceability lives instead, shared across every file processed in one run.

---

## 3. Notebook structure

Six cells, run start to finish in one continuous session – this matters, because it's what lets the temporary stage work as intended (see cell 3).

**Cell 1 – Context.** Set role, warehouse, database and schema. Nothing project-specific; ensures the notebook runs against the right objects regardless of session defaults.

**Cell 2 – Parameters.** `FROM_TS`, `TO_TS`, `OFFSET_MINUTES`, all overridable manually for backfill or reprocessing a specific range. Defaults: `FROM_TS` = the latest `INGESTED_AT` among rows where `INGEST_STATUS = 'SUCCESS'` in FILE_LOAD (so a failed run's high-water mark never silently advances past a file that needs retrying); `TO_TS` = current time minus `OFFSET_MINUTES`. *Flagging honestly: the intended purpose of the offset – a safety buffer so we don't pick up a file SharePoint is still mid-write on – is my assumption, not something confirmed with you. Worth a quick check before this becomes the working definition.*

**Cell 3 – Create temporary stage.** Session-scoped, dropped automatically when the notebook session ends. This is the deliberate mechanism for never persisting a raw file beyond the run – no manual cleanup step needed, no code path where cleanup gets skipped. This only works because ingestion and extraction share one session; if these were ever split into separate scheduled tasks, this stage wouldn't survive between them and the design would need to change.

**Cell 4 – List candidate files.** Query the SharePoint payroll folder tree, filtering server-side on `lastModifiedDateTime` within `[FROM_TS, TO_TS)`. Returns file name, path, last-modified time and size for anything that qualifies – no content yet.

**Cell 5 – Fetch, stage, and log the ingest outcome.** For each candidate: download the bytes over the External Access Integration and `PUT` onto the temporary stage, then immediately `INSERT` a FILE_LOAD row. Every candidate from cell 4 gets a row here, whatever the outcome – `INGEST_STATUS = 'SUCCESS'` with file metadata if it staged cleanly, or `'FAILED'` with an error message if it didn't. A failed fetch is never silently dropped; it's a durable row that shows up in monitoring and stays inside next run's window for a retry.

**Cell 6 – Extract and update.** For every row just inserted with `INGEST_STATUS = 'SUCCESS'`: open the staged file, walk every worksheet, and build the nested JSON grid – no header detection, no layout interpretation, just the raw cells. `UPDATE` that same row: `EXTRACT_STATUS = 'SUCCESS'`, `EXTRACTED_AT`, and `RAW_CONTENT` on success; `EXTRACT_STATUS = 'FAILED'` plus `ERROR_MESSAGE` if the file can't be opened or parsed at all. Rows where ingest failed are left at `EXTRACT_STATUS = 'NOT_ATTEMPTED'`, since there was nothing to parse.

Nothing further runs after cell 6 – the temporary stage and anything on it disappear when the session closes.

---

## 4. Open points, not yet decided

- **OFFSET_MINUTES purpose** – assumed to be a mid-write safety buffer, needs confirming.
- **RUN_ID source** – Snowflake exposes a task-graph run identifier at runtime (`SYSTEM$TASK_RUNTIME_INFO`); the exact key to use for a *scheduled notebook* specifically needs confirming at build time, not assumed here.
- **Partial extraction failure** – if one worksheet in an otherwise-good file is unreadable, does the whole file fail, or do the good sheets land and the bad one gets flagged separately? Current default assumption is whole-file failure, for consistency with the structural-rejection approach – not yet a firm decision.
- **First-ever run** – `FROM_TS` defaults off `MAX(INGESTED_AT)` in FILE_LOAD, which is undefined before the table has any successful rows. Needs an explicit fallback (e.g. a fixed project-start date) rather than being left to fail silently.

---

## 5. Plain-language description (for Qima)

Every time this step runs, the platform checks the SharePoint payroll folders for anything that has changed since the last time it ran successfully. That window is automatic by default, but can be widened manually if we ever need to reprocess an older period.

Every file it finds is logged – file name, when it changed, when we picked it up, and whether that succeeded – whatever the outcome, so there is a complete and permanent record of everything received. Nothing is ever silently missed.

This step is deliberately generic and fully automatic: it reads and stores whatever is in a file without needing to understand its layout, so it keeps working even as templates change or new columns are added over time. Turning that raw content into a structured, business-ready model is a separate process – transformation – that happens afterwards, not something this step does.

We also keep a full history here: if a file is resubmitted with changes, both the earlier version and the new one are kept, nothing is overwritten. Every version received stays available.

The content of each file is read into a temporary work area that exists only for the moment it takes to process it – this is what guarantees the original spreadsheet itself is never kept in the platform afterwards, consistent with the isolation approach agreed with Antoine.
