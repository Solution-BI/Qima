# QIMA Payroll Ingestion 

**Project:** QIMA HR Payroll Data Platform — Phase 1 (Ingestion)  
**Last updated:** 27 Aug 2026  
**Author:** Chhoraseth CHHORT

---

## What was built

A pipeline that downloads payroll Excel workbooks from SharePoint and loads them into Snowflake. Two execution modes — same core logic, different entry points:

| Mode | Runs where | Status |
|---|---|---|
| **Local harness** (`entry/main.py`) | Developer machine | Working end-to-end |
| **Stored procedure** (`sql/PAYROLL_INGEST_DEPLOY.sql`) | Inside Snowflake | Written, blocked on EAI (trial limitation) |

### What the pipeline does

1. Authenticates to SharePoint via Microsoft Graph API (OAuth2 client credentials)
2. Lists all `.xlsx` files in the configured folder
3. For each file:
   - Downloads raw bytes
   - Stages the `.xlsx` in `@PAYROLL_STAGE` (audit trail)
   - Parses the 67-column template (sheet "2026")
   - Inserts rows into `PAYROLL_STAGING` (all VARCHAR, no type casting)




---

## Repository structure

```
src/payroll/
├── __init__.py
├── columns.py        # Frozen 67-column definitions (single source of truth)
├── graph.py          # Microsoft Graph API transport (token, list, download)
├── parse.py          # Pure Excel parser (no network, no Snowflake)
├── staging.py        # Snowflake boundary (PUT + INSERT with transactions)
└── ingest.py         # Orchestrator (ties all modules together)

entry/
└── main.py           # Local harness CLI entry point

sql/
└── PAYROLL_INGEST_DEPLOY.sql # Full Ingestion script (OAuth + procedure)

scripts/
├── validate_graph.py   # Step-by-step SharePoint access validation

```

## How to run (locally)

### Prerequisites

1. Python 3.12+ with dependencies:
   ```
   pip install -r requirements.txt
   ```

2. `.env` file (copy from `.env.example`, fill in values):
   



### Run

```bash
python entry/main.py
```



---

## Environments

### SBI SharePoint (test — fully working)

| Item | Value |
|---|---|
| Tenant | `77fc8d6c-15ec-4aea-9bd6-cf77b407a763` (SBI Learning) |
| App ID | `f1343367-3e3a-4ab0-8438-e72f261a6994` |
| Permission | `Sites.Selected` (read) — granted and tested |
| Site | `learnfabricsbi.sharepoint.com` |
| Folder | `QIMA_APA_HR-Payroll-Data-Platform-2026` |

### QIMA SharePoint (client — pending site grant)

| Item | Status |
|---|---|
| App credentials (AppID, TenantID, Secret) | Received |
| Token acquisition | Works |
| Site-level access (`Sites.Selected` grant) | **Pending** — QIMA admin needs to grant the app permission to the specific site |

### Snowflake trial

| Item | Value |
|---|---|
| Account | `A6368006907271-SBI_SINGAPORE` |
| Database | `HR_PAYROLL_DEV` |
| Schema | `RAW` |
| Table | `PAYROLL_STAGING` (4 metadata + 67 source columns) |
| Stage | `@PAYROLL_STAGE` |
| Limitation | `EXTERNAL ACCESS INTEGRATION` blocked on trial |

---

## Example run output 

```
PS C:\...\Qima PayRoll Ingestion> python entry/main.py
Acquiring Microsoft Graph token...
Token acquired.
Processing files from: QIMA_APA_HR-Payroll-Data-Platform-2026

============================================================
INGESTION SUMMARY
============================================================

Succeeded (1 files):
  BR09 - CP_QUALI QIMA Payroll reporting template - Copiar.xlsx   168 rows

Skipped — unchanged since last load (2 files):
  BR02 - QIMA BRASIL LTDA.xlsx                       modified 2026-08-27 02:29:28
  QIMA Payroll - Template.xlsx                       modified 2026-08-26 03:08:46

Total rows inserted: 168
```

- **Succeeded**: file was downloaded, parsed, staged, and inserted
- **Skipped**: file's SharePoint timestamp hasn't changed since last load (no wasted work)
- Re-run the pipeline again and all 3 files will show as "Skipped"

---

## What's pending

| Item | Blocker | Impact |
|---|---|---|
| QIMA site-level permission grant | Waiting on QIMA admin | Cannot test against client's actual payroll files |
| External Access Integration | Snowflake trial limitation | Stored procedure cannot execute; pipeline runs locally only |


---

