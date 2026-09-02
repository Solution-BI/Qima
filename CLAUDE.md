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
by a Task, with its own isolated database and RBAC domain (see `security/rbac/`).
If you're wondering why payroll doesn't follow the existing ELT pattern, this is why
– it's a deliberate choice, not an oversight.

## Structure

Organized by pipeline stage, which maps directly onto the delivery backlog's epics
(Epic 2 = ingestion, Epic 3 = transformation, Epic 4 = security, Epic 5 =
auditability):

```
config/           -- external access integration, per-environment settings
ingestion/        -- SharePoint -> RAW, as opaque JSON (sql/, python/, notebooks/)
transformation/   -- RAW -> SILVER/GOLD (reference_data/header_map/, dbt/ [TBC], sql/)
security/         -- rbac/, masking/, row_access/
auditability/     -- sql/, alerts/
```

Each stage folder has its own `docs/` and `tests/`, following the same convention
`Delivery/dagster-data-import` and `Delivery/snowflake-RBAC` already use (docs live
next to the code they describe, not centralized).

## Design principle: ingestion and extraction are deliberately dumb

Ingestion only moves bytes (SharePoint to a temporary stage). Extraction only
converts a sheet's grid to JSON, cell by cell – no header detection, no layout
interpretation, no knowledge of template generation. Both are built this way
specifically so they can't break when Qima's Excel template changes. All structural
interpretation lives in transformation, driven by the HEADER_MAP reference data in
`transformation/reference_data/header_map/`. See `ingestion/docs/` for the full
reasoning, including load-bearing detail on why raw files are never persisted
beyond the moment it takes to read them.

## RBAC convention

Payroll is a new isolated domain, following the same model as
`Delivery/snowflake-RBAC` (read there for the full naming convention): an
`F_PAYROLL_DBA` account-level role owns the database, `PAYROLL.A/.O/.W/.R` access
roles form the privilege ladder, functional roles are what get granted to users.
Isolation is expressed the same way everything else in that model is isolated –
`F_DE` (the general data-engineering functional role) is simply never granted the
PAYROLL domain's access roles.

## Open items blocking real work

- SharePoint app registration + External Access Integration – needs Qima to act,
  requires ACCOUNTADMIN on their side. See `config/external_access/`.
- Real database/warehouse names for `config/environments/` – currently placeholders.
- HEADER_MAP has only been validated against three dummy files – not confirmed
  representative of all real subsidiary submissions.
- Transformation tooling (dbt vs plain SQL/Snowpark) – not yet decided.

Full design detail and everything already confirmed with Qima directly lives in
each stage's `docs/` folder, not duplicated here. For the fuller engagement
story – stakeholders, what changed since the original June proposal, and the
consolidated open-items list – see `README.md`.
