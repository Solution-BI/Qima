# Payroll Ingestion — Method Options

**For:** QIMA review · **Prepared by:** SBI
**Purpose:** factual comparison of the candidate methods for ingesting the 32 monthly payroll
Excel files from SharePoint into Snowflake. Pros and cons only — the decision is QIMA's.

**Context that applies to every option:** the source is a 67-column `.xlsx` template with a
two-row header (row 1 = merged group headers, row 2 = column names, data from row 3), one annual
sheet (`2026`) plus an `Instructions` sheet, ~1 MB per file, 32 files per month.

---

## Option 1 — Snowflake-Native: Microsoft Graph API + Python Stored Procedure

**How it works:** a Python stored procedure inside the payroll database calls the Microsoft Graph
API (via a Snowflake `EXTERNAL ACCESS INTEGRATION`), downloads each workbook into an internal
stage, parses it with `openpyxl`, and loads the staging table. A Snowflake `TASK` schedules the
monthly run. The SharePoint service-principal credential is stored in a Snowflake `SECRET`.

**Pros**
- Entire pipeline — files, credential, code, schedule — lives inside the dedicated payroll
  database. No external components.
- Credential sits in a Snowflake `SECRET`; every access to it is recorded in `ACCESS_HISTORY`,
  so the credential-access audit alert works natively.
- The pipeline role can be kept minimal: INSERT on staging + read on the secret.
- Handles the two-row merged header and can read Excel cell comments.
- No standing infrastructure or subscription — costs only when the monthly task runs.
- Handover is SQL plus one Python procedure, version-controlled like existing scripts.

**Cons**
- Requires security approval for outbound calls from Snowflake to `graph.microsoft.com`.
- One-off `ACCOUNTADMIN` action to create the network rule, secret, and integration.
- Custom code: a failure is a debugging session, not a vendor support ticket.
- Orchestration is basic (`TASK`): retries and failure alerting are hand-built.

---

## Option 2 — Snowflake-Native: Openflow (managed Apache NiFi)

**How it works:** Openflow is Snowflake's managed data-integration service based on Apache NiFi.
A custom flow reads the files from SharePoint and lands them in the payroll database; NiFi's
`ExcelReader` (with its *Starting Row* setting) handles the two-row header. The prebuilt
SharePoint connector is designed for unstructured-document / AI use cases, so a custom flow is
required for this template.

**Pros**
- Managed by Snowflake — no self-hosted infrastructure.
- Visual, low-code flow builder with built-in monitoring and retry handling.
- Destination is configurable, so data can land inside the payroll database.
- No custom Python code to maintain.

**Cons**
- Connector credentials are managed inside Openflow's own configuration, **not** in a Snowflake
  `SECRET` — credential access is therefore not visible in `ACCESS_HISTORY`, and the
  credential-access audit alert cannot be built as specified.
- Requires a `SERVICE`-type user, key-pair auth, and a connector admin role — a wider access
  grant than the pipeline otherwise needs.
- The Openflow management control pool runs and incurs cost continuously, even when no flow is
  running.
- QIMA takes on operating a new platform (NiFi) not currently in its stack, including creating
  and maintaining the runtime.
- Cannot read Excel cell comments.

---

## Option 3 — Fivetran (managed SaaS connector)

**How it works:** Fivetran's SharePoint connector reads worksheets directly from the document
library and syncs them into Snowflake on a schedule.

**Pros**
- Fully managed, no-code: setup in hours, with scheduling, retries, and monitoring included.
- Well-established vendor with broad connector coverage for future sources.

**Cons**
- **Incompatible with the current template:** the connector uses the first worksheet row as
  column names, has no skip-rows setting, and does not support ranges containing merged cells
  (it skips them). Against this file it produces unusable columns and dropped data. It becomes
  viable only if the template is flattened to a single header row across all 32 subsidiaries.
- Cannot read Excel cell comments.
- Payroll data and the SharePoint credential are processed and held by a third-party SaaS —
  a new vendor contract and DPA for GDPR-scoped compensation data.
- Credential lives with Fivetran, outside Snowflake's `SECRET` / `ACCESS_HISTORY` audit surface.
- Subscription cost.

---

## Option 4 — Snowpipe + Azure Blob Storage

**How it works:** the files are copied from SharePoint into an Azure Blob / ADLS container (by a
Power Automate flow or script); Snowflake reads the container as an external stage, and Snowpipe
auto-loads files as they arrive.

**Pros**
- Event-driven: files load automatically on arrival, no schedule needed.
- Standard, well-documented Snowflake pattern for file ingestion.
- Blob storage accepts any file type as a landing/archive zone.
- No outbound network calls from Snowflake.

**Cons**
- **Snowpipe cannot parse Excel.** It runs `COPY INTO`, which supports only CSV, JSON, Parquet,
  Avro, ORC, and XML — not `.xlsx` (or PDF). A Python parser (as in Option 1) is still required;
  Snowpipe changes only where files land, not how they are read. (Alternatively, every
  subsidiary's file would have to be converted to CSV upstream.)
- Payroll files are stored in an Azure container **outside** the dedicated payroll database —
  outside its isolation boundary and outside `ACCESS_HISTORY` visibility.
- Still needs a separate component to move files SharePoint → Blob, with its own credential.
- Additional credentials to govern (storage SAS token / storage integration) beyond the
  Snowflake `SECRET` model.
- An Azure storage account to provision, secure, and pay for, plus Snowpipe credits.

---

## Side-by-side summary

| | 1 · Graph API + Proc | 2 · Openflow | 3 · Fivetran | 4 · Snowpipe + Blob |
|---|:---:|:---:|:---:|:---:|
| Handles the current template as-is | ✅ | ✅ | ❌ needs template flattened | ⚠️ still needs the Python parser |
| Reads Excel cell comments | ✅ | ❌ | ❌ | ✅ (via the same parser) |
| All data stays inside the payroll DB | ✅ | ✅ | ✅ | ❌ copy in Azure container |
| Credential in Snowflake `SECRET` (auditable in `ACCESS_HISTORY`) | ✅ | ❌ | ❌ | ⚠️ partially |
| Standing cost | none | control pool always-on | subscription | storage account + Snowpipe credits |
| New platform for QIMA to operate | no | yes (NiFi) | yes (SaaS) | yes (storage + mover flow) |
| Custom code to maintain | Python proc | NiFi flow | none | Python proc + mover |
| Key prerequisite | outbound access to `graph.microsoft.com` | Openflow runtime + admin role | vendor contract + DPA + template change | Azure storage account + mover flow |

**Questions that influence the choice:** whether security permits outbound Snowflake →
`graph.microsoft.com`; whether cell comments carry business meaning that must be captured;
whether the 67-column two-row-header template can or should change.
