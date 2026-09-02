# Qima Repository
HR Payroll Data Pipeline

## Structure

- `Delivery/` – reference material received from Qima (existing Dagster setup,
  existing RBAC conventions, architecture docs). Untouched, read-only reference.
- `config/` – external integration enablement and per-environment settings.
- `ingestion/` – SharePoint into RAW, as opaque JSON. See `ingestion/docs/`.
- `transformation/` – RAW into SILVER/GOLD. See `transformation/docs/`.
- `security/` – RBAC, masking, row access policies.
- `auditability/` – privilege-change detection and alerting.

See `CLAUDE.md` for conventions and guidance on working in this repo.

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
- **Chhoraseth "Rasa" Chhort** – data engineering, owns the build.

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
  real dummy files found **seven distinct column layouts** (67 to 96 columns,
  spanning 2024–2026) – see `transformation/reference_data/header_map/`. Not
  a contradiction of what Antoine said (subsidiary templates probably are
  standardised), but the three files available don't yet prove it across all
  32 subsidiaries. Still open – see section 6.

- **Data model.** The proposal's model was two fixed fact tables
  (`PAYROLL_MONTHLY_FACT`, `PAYROLL_BONUS_FACT`) with a hardcoded bonus-type
  enum. What's actually being built is a single fact table
  (`FACT_PAYROLL_COMPONENT`) driven by the HEADER_MAP reference data, with no
  hardcoded component list – because the real files showed components being
  added, merged, and restructured across template generations in ways a fixed
  enum can't absorb. See `transformation/docs/Qima_Payroll_Data_Model_Design.md`
  for the full reasoning and the several rounds of redesign it went through.

- **Employee identity.** The proposal treated SAP ID, name, join/leave date,
  and subsidiary as a block of unmasked "dimension" columns from the payroll
  file itself. Confirmed directly by Antoine and Tess on 27 August: **SAP ID
  is the only field trusted from this file.** Everything else about an
  employee resolves from Qima's HR system, except subsidiary, which Antoine
  confirmed must be captured as a point-in-time fact tied to the payment
  (monthly snapshot), not resolved live – because of mid-year transfers.

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
- **Isolation is structural, not procedural.** Payroll is a new domain in the
  same RBAC model Qima already uses (`Delivery/snowflake-RBAC`), and isolation
  is expressed the same way everything else in that model is isolated: the
  general `F_DE` role is simply never granted the PAYROLL domain's access
  roles.

### 6. Open items – consolidated, current as of this repo's last update

Several items were flagged back in June and are still unresolved two months
later going into the August kickoff – worth tracking as a pattern, not just a
list, since it suggests these need direct follow-up rather than another round
of async flagging:

**Commercial / scope, needs Qima in writing:**
- FX normalisation out of scope – flagged in June, still not formally confirmed.
- GDPR compliance implementation out of scope – same status.
- Historical data backfill out of scope – same status.
- Parallel-run scope and comparison ownership vs. the existing Python script.

**Business rules, needs Tess/HR:**
- Masking format for hidden values (NULL vs. token) – flagged in June, still open.
- Whether all amount fields are treated identically for masking.
- Aggregation requirement / minimum group size (relevant to Snowflake
  Intelligence risk specifically – see `security/tests/README.md`).
- Recurring error-case list from the current consolidation script.

**Platform / technical, needs Antoine:**
- Snowflake edition (Enterprise or higher) – needed for tag-based
  classification, if that's still pursued; flagged in June, still open.
- Alerting mechanism Qima's audit alerts should plug into.
- Monthly expected file count, for completeness checking.
- Folder-to-owner contact list, for error alerting.
- Whether HEADER_MAP's seven observed generations are representative of all
  32 subsidiaries, or just the three sampled.
- Change-management process for template changes – currently nonexistent
  (see `ingestion/docs/Qima_Payroll_Input_Data_Contract.md` section 7).

**Build-level, ours to decide but not yet decided:**
- dbt vs. plain SQL/Snowpark for transformation.
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
- `transformation/docs/` – data model design, including the discriminating-key
  and subsidiary-as-frozen-fact reasoning.
- `security/*/README.md` – status of RBAC, masking, row access work.
- `Delivery/` – what Qima gave us: their existing Dagster setup, their RBAC
  conventions, architecture docs. Reference only, not edited.
