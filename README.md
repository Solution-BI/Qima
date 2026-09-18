# Qima Repository
HR Payroll Data Pipeline

## Structure

- `Delivery/` – reference material received from Qima (existing Dagster setup,
  existing RBAC conventions, architecture docs). Untouched, read-only reference.
- `config/` – external integration enablement and per-environment settings.
- `ingestion/` – SharePoint into RAW, as opaque JSON. See `ingestion/docs/`.
- `transformation/` – RAW into SILVER/GOLD. See `transformation/docs/`.
- `security/` – masking policies are built; RBAC and row access are designed but
  not yet written.

Auditability (Epic 5) has no code yet.

See `CLAUDE.md` for conventions, the model as built, and the run order.

## Where the build actually is

Transformation is the part that exists end to end. Files are read tab by tab into
`PAYROLL_ROW`, every cell is resolved against `HEADER_MAP`, and values land in
`FACT_PAYROLL_PAYMENT`, `FACT_PAYROLL_ENTITLEMENT` or `PAYROLL_ATTRIBUTE` depending
on what the column means. `DQ_FLAG` records findings, the `V_GOLD_*` views are the
reporting layer, and every table and view carries column descriptions so a Qima user
browsing the schema can read what a column means without asking.

It runs today against three real workbooks covering 2024, 2025 and 2026, eight
distinct column layouts, and roughly 8,000 employee lines. Ingestion from SharePoint
is a skeleton waiting on the External Access Integration, so files currently arrive
by hand.

---

## Project context

This section is the full background for anyone picking up this repo cold: why
the project exists, what's changed since it was scoped, and what's still open.

### 1. Who this is for and why it exists

Qima is a ~20-year-old Testing, Inspection & Certification (TIC) company operating
32 subsidiaries, with its data function centred in APAC (Shenzhen). In early 2025
Qima's CIO/CPTO launched a data transformation programme with Snowflake as the
single platform for BI, analytics and AI. SBI became Qima's Snowflake reseller in
April 2026 ($100K, 24-month contract). This payroll project is SBI's **first
professional services engagement** with Qima – deliberately scoped small,
bounded, and low-dependency on Qima's own team capacity, functioning as a
trust-building MVP that gates whether SBI gets Phase 2 and ongoing managed
services work.

**The business problem, as scoped in June 2026:** payroll data from 32
subsidiaries is filled manually into a standardised Excel template by local HR
teams, dropped into a SharePoint folder, and consolidated by one HR team member
running a Python script on a personal laptop, feeding Tableau. There is no
access control, no audit trail, no error handling, and no recovery path.
Anyone with SharePoint access can see all compensation data for all employees
in all jurisdictions. That is a governance and regulatory liability (GDPR
exposure across European entities), not just an inconvenience – and it's the
real reason this project exists, not the manual effort itself.

### 2. Stakeholders

**Qima side:**
- **Antoine Chapelet** – Head of Data Platform. Primary technical counterpart,
  day-to-day contact, defines requirements and validates delivery. Owns the
  isolation requirement that shapes the whole architecture (see section 4).
- **Tess Boorsma** – Total Rewards / HRIS. Owns the business rules behind the
  payroll file, and the most detailed source of what the template actually
  means and where it falls short.
- **Deepanjali Bhatt** – HR Data Analyst. Runs today's manual consolidation
  script; the most direct source on data quality patterns in the current file.
- **Greg Anzel** – CIO/CPTO, sponsor. Not in day-to-day delivery conversations.

**SBI side:**
- **Greg Wolszczak** – project lead and primary point of contact (not just
  solution engineer – see the 27 Aug kickoff where this was made explicit).
- **Chhoraseth "Raseth" Chhort** – data engineering, owns ingestion.
- **Gerard Avena** – modelling and transformation.

### 3. Timeline: what was originally scoped vs. what actually happened

The original proposal (RUD + Solution Design, dated 22 June 2026) targeted a
**4-phase, 7-week delivery starting July 2026**: Discovery & Design (2wk),
Build (3wk), Security & Governance (1wk), Validation & Handover (1wk), costed
at 47 days / $12,540. That didn't hold – the formal kickoff didn't happen
until **27 August 2026**, roughly two months later than planned. No record in
this repo of exactly why the slip happened; treat the July timeline as
historical context, not a still-live commitment.

The plan actually being worked to now is the **5 one-week sprint plan** agreed
going into the 27 August kickoff (S1: 27 Aug – 2 Sep, through S5: 24–30 Sep),
organised around Epics 1–6 (Planning & Design, Ingestion, Modelling &
Transformation, Security & Access, Audit & Monitoring, Deployment &
Handover) rather than the original 4-phase structure. The epic/sprint mapping
and full backlog live outside this repo, in the SBI Presales workspace
(`Qima_Payroll_Delivery_Backlog.md`) and in Notion.

### 4. What changed between the June proposal and what's actually being built

Worth being explicit about this rather than letting stale assumptions from the
original scoping docs quietly persist. Several things moved once real files
and real conversations with Antoine and Tess replaced assumption:

- **Orchestration.** The June proposal assumed Qima's "existing Python
  orchestration framework" would run the pipeline (implicitly Dagster – see
  `Delivery/dagster-data-import`). That's now explicitly rejected: Antoine
  requires the general data team, including himself, to have zero visibility
  into payroll data, even at infrastructure level. Routing payroll through the
  shared Dagster setup would break that. Ingestion here is Snowflake-native
  instead – Snowpark + Task, isolated database, isolated RBAC domain. See
  `CLAUDE.md` and `ingestion/docs/`.

- **Template structure.** The proposal assumed one uniform 67-column template
  across all 32 subsidiaries, confirmed by Antoine. Actual analysis of three
  real files found **eight distinct column layouts** (64 to 96 columns,
  spanning 2024–2026), seven of which are loaded – see
  `transformation/reference_data/header_map/`. Not a contradiction of what
  Antoine said (subsidiary templates probably are standardised), but the three
  files available cover 19 subsidiary codes, not 32-plus. Still open – see
  section 6.

- **Data model.** The proposal's model was two fixed fact tables
  (`PAYROLL_MONTHLY_FACT`, `PAYROLL_BONUS_FACT`) with a hardcoded bonus-type
  enum. What's built instead is a long fact driven by HEADER_MAP, with no
  hardcoded component list – because the real files showed components being
  added, merged and restructured across template generations in ways a fixed
  enum can't absorb. It was a single `FACT_PAYROLL_COMPONENT` until 14
  September, when it was split into `FACT_PAYROLL_PAYMENT` and
  `FACT_PAYROLL_ENTITLEMENT` on `MEASURE_BASIS` – a closed set, unlike the
  component list – with `PAYROLL_ATTRIBUTE` for values that aren't measures at
  all. `FACT_PAYROLL_COMPONENT` remains as a view over both. See
  `transformation/docs/Qima_Payroll_Transformation_Design.md` for the full
  reasoning and the rounds of redesign it went through.

- **Employee identity.** The proposal treated SAP ID, name, join/leave date,
  and subsidiary as a block of unmasked "dimension" columns from the payroll
  file itself. Confirmed directly by Antoine and Tess on 27 August: **SAP ID
  is the only field trusted from this file.** Everything else about an
  employee resolves from Qima's HR system, except subsidiary, which Antoine
  confirmed must be captured as a point-in-time fact tied to the payment
  (monthly snapshot), not resolved live – because of mid-year transfers.
  Qima's own data quality review, received 16 September, independently reaches
  the same conclusion from the other direction: their HR extract is pulled at a
  single date, so org data on older payroll rows shows where an employee sits
  today rather than where they sat that month.

- **Row-level security.** The proposal assumed a simple reuse of an existing
  RLS control table already live on Qima's employee table. The 20 August
  pre-kickoff session confirmed it's a genuine Row Access Policy pattern
  (comma-separated ID list containment check against an ID + parent
  entitlement table) – and because of the isolation requirement, this gets
  *replicated inside the isolated payroll database*, not shared with the
  general platform's mechanism.

### 5. Design principles carried through the whole build

- **Ingestion and extraction are deliberately dumb.** Ingestion only moves
  bytes. Extraction only converts a sheet's grid to JSON, cell by cell. Both
  built this way so neither can break when the template changes – all
  structural interpretation lives in transformation, driven by HEADER_MAP.
- **Raw files are never persisted beyond the moment it takes to read them.**
  A session-scoped temporary stage, not a durable landing zone.
- **Full history is kept at RAW** (every extraction, append-only) so nothing
  is lost even if a later submission corrects an earlier one – but what a
  business user sees as "current" is a separate, still-open question (the
  replacement policy, section 6).
- **Nothing is enforced that can't be proven.** Snowflake doesn't enforce
  primary keys, uniqueness or foreign keys, so each of those guarantees has a
  query behind it in `transformation/tests/`.
- **Isolation is structural, not procedural.** Payroll is a new domain in the
  same RBAC model Qima already uses (`Delivery/snowflake-RBAC`), and isolation
  is expressed the same way everything else in that model is isolated: the
  general `F_DE` role is simply never granted the PAYROLL domain's access
  roles.

### 6. Open items – current as of 17 September 2026

Qima answered a long list of interpretation questions on 15 and 16 September, so
this section is shorter than it was. What follows is what remains.

**Settled since the June list:** transformation tooling is plain SQL, not dbt.
Masking format was agreed verbally on 15 September but still needs writing down.
The recurring error-case list from the current consolidation script arrived on 16
September as Qima's own data quality framework.

**Commercial / scope, needs Qima in writing:**
- FX normalisation. Flagged out of scope in June, but Qima's September answers
  assume conversion to USD at finance's monthly rate, so this needs settling
  rather than assuming. Nothing about deferring it is expensive later – every
  amount is stored in its source currency.
- GDPR compliance implementation out of scope – still not formally confirmed.
- Historical data backfill out of scope – same status.
- Parallel-run scope and comparison ownership vs. the existing Python script.

**Business rules, needs Tess / HR:**
- Two columns sit under a band that contradicts their own header – whether our
  reading of each is right.
- Whether the ad hoc and auditor bonus columns are unused or simply unfilled.
- Whether an agency fee should take the employee's contract currency.
- Finance category per pay component, and which components are fixed versus
  variable. Not derivable – a Max column appears on the fixed schemes too.
- Aggregation requirement / minimum group size.

**Platform / technical, needs Antoine:**
- A dedicated payroll warehouse, the functional roles that get granted to people,
  and the service account the scheduled task runs as. All three need account-level
  rights we do not hold — see `security/rbac/`.
- When their Asia consolidated file and a dedicated entity file both contain the
  same employee, which one we load. Their own review flags this as undecided; if
  both are loaded, salary double counts.
- Whether their HR extract can be delivered as a monthly snapshot rather than a
  single-date pull, so org data on historical rows is correct.
- Alerting mechanism Qima's audit alerts should plug into.
- Monthly expected file count, for completeness checking.
- Folder-to-owner contact list, for error alerting.
- Whether eight observed column layouts across three workbooks are representative
  of all subsidiaries.
- Change-management process for template changes – currently nonexistent
  (see `ingestion/docs/Qima_Payroll_Input_Data_Contract.md` section 7).

**Build-level, ours to decide but not yet decided:**
- Replacement policy: does a corrected resubmission overwrite silently, or
  surface as a visible restatement.
- Whether extraction fails an entire file or allows partial (sheet-level)
  success.
- Whether SharePoint deletion/move detection is worth building (requires
  switching from a filtered "changed since X" check to a full-listing diff) –
  see `ingestion/docs/Qima_Payroll_Ingestion_Design.md`.

### 7. Where the detail actually lives

This section is the orientation, not the source of truth for any one decision.
For the real detail:
- `ingestion/docs/` – ingestion/extraction design, input data contract.
- `transformation/docs/Qima_Payroll_Transformation_Design.md` – the model, the
  reasoning behind the split, and the decisions taken with Qima along the way.
- `transformation/reference_data/header_map/header_map_review.md` – how the
  column layouts were derived from the real files.
- `transformation/tests/` – the reconciliation and proof queries, and the
  recorded results.
- `Delivery/` – what Qima gave us: their existing Dagster setup, their RBAC
  conventions, architecture docs. Reference only, not edited.
