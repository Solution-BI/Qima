# QIMA HR Payroll Ingestion -- Test Scenarios and Results

Documented test runs validating each HR scenario against the live pipeline
in the Snowflake Notebook Workspace, using the real SharePoint payroll folder.

---

## Test 1: Scenario 1 -- New File Upload

**Trigger:** HR uploads a new payroll Excel file to the SharePoint folder




Two files visible in the `BR02 - QIMA BRASIL LTDA - Payroll Reporting` folder:
- `BR02_Payroll_Sample.xlsx` -- modified a few seconds ago by Chhoraseth CHHORT
- `BR02 - QIMA BRASIL LTDA.xlsx` -- modified 2 days ago by Chhoraseth CHHORT

**Files Ingested output (list_candidates):**


```
1 files in window: [LAST_INGESTED_AT: 2026-09-04 02:26:42.796000-07:00, CURRENT_TIMESTAMP: 2026-09-07 06:59:58.301000+00:00)

  [1] BR02_Payroll_Sample.xlsx
      id          : 01NLVSOQZ76BTL3SHM25BYFJPQYQSVD5IQ
      path        : /drives/b!GNj7XKqd5...root:/Payroll files/BR02 - QIMA BRASIL LTDA - Pa
      size_bytes  : 22,129
      modified_at : 07 Sep 2026, 06:58 AM UTC  by Chhoraseth CHHORT
      created_at  : 07 Sep 2026, 06:58 AM UTC  by Chhoraseth CHHORT
      created_by  : Chhoraseth CHHORT
```

- The file's `lastModifiedDateTime` (07 Sep 2026, 06:58 AM UTC) falls within
  the ingestion window `(LAST_INGESTED_AT, CURRENT_TIMESTAMP)`.
- Only the newly uploaded file is listed. The older `BR02 - QIMA BRASIL LTDA.xlsx`
  (modified 2 days ago) is excluded because its modification time is before
  `LAST_INGESTED_AT`.

**FILE_LOAD query result:**

| SHAREPOINT_ITEM_ID | FILE_NAME | IS_CURRENT | INGEST_STATUS | EXTRACT_STATUS | RAW_CONTENT | ERROR_MESSAGE |
|---|---|---|---|---|---|---|
| `01NLVSOQY67ML7PVUOXVHK6V4IUVHJLZZO` | `BR02_Payroll_Sample.xlsx` | `TRUE` | `SUCCESS` | `SUCCESS` | `{ "2026": [ [ "Employee Information (QIMA PEOPLE)", ...` | `null` |

**Result**

- File was detected in the ingestion window.
- Downloaded, staged, and extracted successfully.
- FILE_LOAD row created with `INGEST_STATUS = 'SUCCESS'`, `EXTRACT_STATUS = 'SUCCESS'`,
  `IS_CURRENT = TRUE`.
- `SHAREPOINT_ITEM_ID` captured from the Graph API response.
- `RAW_CONTENT` populated with the nested JSON grid.
- No error message.

---

## Scenario 2: File Correction Scenario

**Trigger:** HR discovers an error (e.g. wrong salary amount) and edits the
file on SharePoint days or weeks after the original submission as well re-naming the file.

**What happens:**

1. HR opens the file, corrects the value, and saves. SharePoint advances the
   file's `lastModifiedDateTime` and creates a new entry in its version history.
2. On the next pipeline run, `FROM_TS` = the last successful ingestion time.
   The corrected file's new `lastModifiedDateTime` is after `FROM_TS`, so it
   enters the window as a candidate.
3. The pipeline downloads the latest version of the file (the Graph API always
   serves the current version, not historical ones).
4. Before inserting, the existing FILE_LOAD row for this file is updated to
   `IS_CURRENT = FALSE`.
5. A new row is inserted with the corrected content, `IS_CURRENT = TRUE`.

**FILE_LOAD query result:**

| SHAREPOINT_ITEM_ID | FILE_NAME | IS_CURRENT | INGEST_STATUS | EXTRACT_STATUS | RAW_CONTENT | ERROR_MESSAGE |
|---|---|---|---|---|---|---|
| `01NLVSOQY67ML7PVUOXVHK6V4IUVHJLZZO` | `BR02_Payroll_Sample.xlsx` | `FALSE` | `SUCCESS` | `SUCCESS` | `{ "2026": [ [ "Employee Information (QIMA PEOPLE)", ...` | `null` |
| `01NLVSOQY67ML7PVUOXVHK6V4IUVHJLZZO` | `BR02_Payroll_Sample.xlsx` | `FALSE` | `SUCCESS` | `SUCCESS` | `{ "2026": [ [ "Employee Information (QIMA PEOPLE)", ...` | `null` |
| `01NLVSOQY67ML7PVUOXVHK6V4IUVHJLZZO` | `BR02_Payroll_Sample.xlsx` | `TRUE` | `SUCCESS` | `SUCCESS` | `{ "2026": [ [ "Employee Information (QIMA PEOPLE)", ...` | `null` |

- All three rows share the same `SHAREPOINT_ITEM_ID`. SharePoint keeps the item
  id stable across edits and renames, so the pipeline correctly treats them as
  three versions of one file rather than three separate files.
- Two corrections produced three rows: the two superseded rows are
  `IS_CURRENT = FALSE`, only the latest is `TRUE`. `RAW_CONTENT` is retained on
  every version, so the full audit trail survives.

**Result:** Both versions are preserved in FILE_LOAD for audit purposes. The
old row is flagged `IS_CURRENT = FALSE`, the new row is `IS_CURRENT = TRUE`.
Downstream queries filter on `IS_CURRENT = TRUE` and always see the corrected
data. The timing of the correction does not matter — whether it happens hours
or weeks later, the pipeline picks it up on the next run.

---

## Scenario 3: File Deletion

**Trigger:** HR deletes a payroll file from the SharePoint folder.

**What happens:**

1. The deleted file no longer appears in the Graph API folder listing, so
   `walk_folder` never returns it and it never enters the candidate list.
2. The reconciliation step (Cell 9) compares every `IS_CURRENT = TRUE` row in
   FILE_LOAD against the current SharePoint file list.
3. Any row whose `SHAREPOINT_ITEM_ID` is no longer present on SharePoint is
   updated to `IS_CURRENT = FALSE`.
4. The rows themselves are preserved — not deleted. `RAW_CONTENT`,
   `INGEST_STATUS`, `EXTRACT_STATUS` and all metadata stay intact.

**FILE_LOAD query result:**

| SHAREPOINT_ITEM_ID | FILE_NAME | IS_CURRENT | INGEST_STATUS | EXTRACT_STATUS | RAW_CONTENT | ERROR_MESSAGE |
|---|---|---|---|---|---|---|
| `01NLVSOQY67ML7PVUOXVHK6V4IUVHJLZZO` | `BR02_Payroll_Sample.xlsx` | `FALSE` | `SUCCESS` | `SUCCESS` | `{ "2026": [ [ "Employee Information (QIMA PEOPLE)", ...` | `null` |
| `01NLVSOQY67ML7PVUOXVHK6V4IUVHJLZZO` | `BR02_Payroll_Sample.xlsx` | `FALSE` | `SUCCESS` | `SUCCESS` | `{ "2026": [ [ "Employee Information (QIMA PEOPLE)", ...` | `null` |
| `01NLVSOQY67ML7PVUOXVHK6V4IUVHJLZZO` | `BR02_Payroll_Sample.xlsx` | `FALSE` | `SUCCESS` | `SUCCESS` | `{ "2026": [ [ "Employee Information (QIMA PEOPLE)", ...` | `null` |

- No row is `IS_CURRENT = TRUE` any more. The row that was current before the
  deletion (the third row in Scenario 2) has been flipped to `FALSE` by
  reconciliation; the two already-superseded rows were untouched.
- Every row is still present with its `RAW_CONTENT` and status columns intact,
  so the file's full submission history remains auditable after deletion.

**Result:** The deleted file's rows stay in FILE_LOAD with full history, but
none is marked as current. Downstream queries filtering on `IS_CURRENT = TRUE`
exclude the file automatically — no downstream process consumes deleted data,
while traceability is fully preserved.

---

## Scenario 4: No Activity

**Trigger:** No files have been created, modified, or deleted on SharePoint
since the last pipeline run.

**What happens:**

1. The pipeline runs and computes the ingestion window as usual.
2. `walk_folder` returns all files in the SharePoint folder, but none of them
   have a `lastModifiedDateTime` within the `(FROM_TS, TO_TS)` window.
3. `list_candidates` returns an empty list — zero candidates.
4. The download, stage, insert, and extract steps all skip cleanly (they
   iterate over an empty list).
5. The pipeline prints "No new/modified files to ingest" and finishes.

**Result:** No rows are inserted into FILE_LOAD. No existing rows are
modified. The high-water mark (`FROM_TS`) stays the same for the next run.
This is a normal, expected outcome — the pipeline is designed to be a no-op
when there is nothing to process.


---

## Scenario 5: Unsupported File Format

**Trigger:** HR uploads a non-`.xlsx` file to the payroll folder — a PDF export,
a CSV, or a legacy `.xls` workbook.

**What happens:**

1. `list_candidates` still picks the file up: the time-window filter is on
   `lastModifiedDateTime` only. It tags the candidate `supported = False`
   (`name.endswith('.xlsx')`) and prints
   `[WARNING: Unsupported file format]` next to it.
2. `download_files` skips the file — status `SKIPPED`, reason
   `unsupported file format`. No bytes are fetched, nothing is staged.
3. Cell 7 still inserts a FILE_LOAD row for it, as it does for every candidate:
   `INGEST_STATUS = 'FAILED'` with
   `ERROR_MESSAGE = 'Unsupported file format: <EXT>. Only .xlsx files are accepted.'`
4. Extraction never runs on it — Cell 8 only selects rows with
   `INGEST_STATUS = 'SUCCESS'` — so `EXTRACT_STATUS` stays `NOT_ATTEMPTED` and
   `RAW_CONTENT` stays `null`.

**FILE_LOAD query result:**

| SHAREPOINT_ITEM_ID | FILE_NAME | IS_CURRENT | INGEST_STATUS | EXTRACT_STATUS | RAW_CONTENT | ERROR_MESSAGE |
|---|---|---|---|---|---|---|
| `01NLVSOQ…` | `BR02_Payroll_Sample.pdf` | `TRUE` | `FAILED` | `NOT_ATTEMPTED` | `null` | `Unsupported file format: PDF. Only .xlsx files are accepted.` |
| `01NLVSOQ…` | `BR02_Payroll_Sample.csv` | `TRUE` | `FAILED` | `NOT_ATTEMPTED` | `null` | `Unsupported file format: CSV. Only .xlsx files are accepted.` |
| `01NLVSOQ…` | `BR02 - QIMA BRASIL LTDA.xls` | `TRUE` | `FAILED` | `NOT_ATTEMPTED` | `null` | `Unsupported file format: XLS. Only .xlsx files are accepted.` |

- The row exists. The rejection is visible in the table, not buried in notebook
  output — this is what makes it alertable to the submitting subsidiary.
- `ERROR_MESSAGE` names the actual extension and the accepted one, so the owner
  can act on it without anyone reading the pipeline logs.
- `RAW_CONTENT` is `null` and `EXTRACT_STATUS = 'NOT_ATTEMPTED'`, which
  distinguishes "we refused this file" from "we parsed it and it was empty".

**Result:** Unsupported files are never silently dropped. Each one lands in
FILE_LOAD as a `FAILED` row with a descriptive message, giving a queryable list
of submissions that need re-uploading in the correct format:

