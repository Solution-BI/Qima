# CLAUDE.md

Guidance for working in this repository.

## What this repo is

The HR Payroll Data Platform build for Qima – Phase 1, Snowflake-native. `Delivery/`
is reference material Qima gave us (their existing Dagster ELT setup, their existing
RBAC repo, architecture docs) – read it for context and convention, don't edit it.
Everything else here is the new payroll build.

## Why this isn't built on Dagster

`Delivery/dagster-data-import` is Qima's existing, general-purpose ELT pipeline.
Payroll is deliberately isolated from it: Antoine (Qima's data lead) requires the
general data team – including himself – to have zero visibility into payroll data,
even at the infrastructure level. Routing payroll through the shared Dagster setup
would put it inside infrastructure the general data team operates. Instead,
ingestion here is Snowflake-native: a Snowpark Python procedure/notebook triggered
by a Task, with its own isolated database and RBAC domain. If you're wondering why
payroll doesn't follow the existing ELT pattern, this is why – it's a deliberate
choice, not an oversight.

## Structure

Organized by pipeline stage, which maps onto the delivery backlog's epics (Epic 2 =
ingestion, Epic 3 = transformation, Epic 4 = security, Epic 5 = auditability):

```
config/           -- external access integration, per-environment settings
ingestion/        -- SharePoint -> RAW, as opaque JSON (docs/, notebooks/)
transformation/   -- RAW -> SILVER/GOLD (docs/, lib/, reference_data/, sql/, tests/)
security/         -- masking/ is built; rbac/ and row_access/ are designed, not written
```

There is no `auditability/` code yet. Each stage folder keeps its own `docs/` and
`tests/`, following the convention `Delivery/dagster-data-import` and
`Delivery/snowflake-RBAC` already use – docs live next to the code they describe,
not centralized.

## Design principle: ingestion and extraction are deliberately dumb

Ingestion only moves bytes (SharePoint to a temporary stage). Extraction only
converts a sheet's grid to JSON, cell by cell – no header detection, no layout
interpretation, no knowledge of template generation. Both are built this way
specifically so they can't break when Qima's Excel template changes. All structural
interpretation lives in transformation, driven by the HEADER_MAP reference data in
`transformation/reference_data/header_map/`. See `ingestion/docs/` for the full
reasoning, including load-bearing detail on why raw files are never persisted
beyond the moment it takes to read them.

## The transformation model, as built

`HEADER_MAP` says what every column of every template generation means. The fact is
long – one row per value, not one row per employee – so a new bonus column in next
year's template is reference data, not a schema change.

- `PAYROLL_ROW` – one row per employee line in a tab. `V_PAYROLL_CELL` resolves each
  cell against `HEADER_MAP`.
- `FACT_PAYROLL_PAYMENT` – what was actually paid.
- `FACT_PAYROLL_ENTITLEMENT` – contractual rates and eligibility flags.
- `PAYROLL_ATTRIBUTE` – remarks, external headcount, anything that isn't a measure.
- `FACT_PAYROLL_COMPONENT` – a view over both fact tables, kept for compatibility
  with anything written against the single-table shape.
- `DQ_FLAG` – findings. Only the `IDENTITY` class withholds a row from reporting.
- `V_GOLD_*` – the reporting layer.

The split is on `MEASURE_BASIS` because that is a closed set. An earlier split by
component was wrong for exactly the reason the model is long in the first place:
components change per template generation. Both fact tables draw `MEASURE_ID` from
`SEQ_MEASURE_ID`, so an id is unique across the pair and `DQ_FLAG.MEASURE_ID` stays
valid whichever table the measure came from.

Snowflake does not enforce primary keys, uniqueness or foreign keys. Every such
guarantee here is proven by a query in `transformation/tests/`, never by the
constraint that declares it.

## Run order

`01_header_map` → `02_silver_model` → `03_file_selection` → `04_load_silver` →
`05_load_dq_flags` → `06_column_descriptions`.

`06` runs last every time, including after a data-only reload: `04` rebuilds
`V_PAYROLL_CELL`, and `CREATE OR REPLACE VIEW` silently drops column comments.
Comments on views need `ALTER VIEW ... ALTER COLUMN ... COMMENT` – `COMMENT ON
COLUMN` is rejected for a view.

Loads are full reloads. Each insert step skips tabs that are already loaded, so a
rerun adds nothing; to rebuild, truncate and run again.

## Masking

Policies attach to base table columns and views inherit them, so a masked amount
stays masked through GOLD. Once a policy is attached, `CREATE OR REPLACE` is
rejected – use `ALTER MASKING POLICY ... SET BODY`. `PAYROLL_ROW.ROW_DATA` and
`DQ_FLAG.RAW_VALUE` are covered because both can carry an amount in the clear.
`RAW_CONTENT` at the ingestion layer is not covered yet.

Masking and row access policies both require Snowflake Enterprise edition.

## RBAC convention

Payroll is a new isolated domain, following the same model as
`Delivery/snowflake-RBAC` (read there for the full naming convention): an
`F_PAYROLL_DBA` account-level role owns the database, `PAYROLL.A/.O/.W/.R` access
roles form the privilege ladder, functional roles are what get granted to users.
Isolation is expressed the same way everything else in that model is isolated –
`F_DE` (the general data-engineering functional role) is simply never granted the
PAYROLL domain's access roles. The scripts for this are not written yet.

## Open items blocking real work

- SharePoint app registration + External Access Integration – needs Qima to act,
  requires ACCOUNTADMIN on their side. See `config/external_access/`.
- Real database, warehouse and role names. `config/environments/` still holds
  placeholders and the SQL still hardcodes sandbox names.
- HEADER_MAP has seen eight column layouts across three workbooks, covering 19
  subsidiary codes out of the sixty-odd on the roster. Not confirmed representative.
- Confirmation that the target account is Enterprise edition.
- When Qima's Asia consolidated file and a dedicated entity file both contain the
  same employee, which one we load. Unresolved on their side; until it is, loading
  both would double count.

Full design detail and everything already confirmed with Qima lives in each stage's
`docs/` folder, not duplicated here. For the fuller engagement story – stakeholders,
what changed since the original June proposal, and the consolidated open-items list
– see `README.md`.
