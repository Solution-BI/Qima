  # CLAUDE.md

Guidance for working in this repository.

## What this repo is

`data-admin` is a collection of **Snowflake SQL scripts** that provision and manage
access control (RBAC) for a data platform. There is **no application, build step, or
test runner** — the `.sql` files are executed manually by an administrator in a
Snowflake worksheet (or the JetBrains/DataGrip SQL console; note the `.idea/` data
source config). This repo is the version-controlled source of truth for how databases,
schemas, roles, grants, and user assignments are set up.

Because scripts are run by hand, they are written to be **read and executed
statement-by-statement**, not as an idempotent migration. Expect:

- `SET <var> = ...;` lines that are meant to be run one at a time. When the same
  variable is set several times in a row (e.g. every `domain_cd`), the operator
  picks one, runs it, then runs the block below. A `-- 👈` comment marks the value
  currently selected / most recently used.
- `/******* 🔁Repeat for each $domain_cd *******/` markers: the block below is run
  once per domain / subdomain / schema, changing the `SET` at the top each time.
- Frequent `SHOW GRANTS ...`, `DESCRIBE ...`, `SELECT $var` and `-- [x] ...` lines.
  These are **verification checks** the operator eyeballs, not assertions.
- Commented-out `DROP`/`REVOKE` statements kept as an undo/rollback reference.

## RBAC model (essential context)

The whole design is a layered role hierarchy. Read `docs/naming_convention.md` for the
full naming scheme; the short version:

- **Databases = domains** (e.g. `RAW`, `RAW_DEV`, `AUDIT`, `FINANCE`, `PRODUCT`,
  `LAB_TESTING`, `INSPECTION`, `ADMIN`, `SANDBOX`). Some domains have **subdomains**
  (`CP`, `FOOD`, `LS`).
- **Access roles** are Snowflake *database roles*, one set per database (or
  per subdomain), following a strict privilege ladder:
  - `A` = Admin (DCL / manage grants) → `O` = Owner (DDL / owns objects) →
    `W` = Write (DML) → `R` = Read (DQL).
  - Each level is granted the level below it, so `A ⊇ O ⊇ W ⊇ R`. Named
    `<DB>.<LETTER>` or `<DB>.<SUBDOMAIN>_<LETTER>` (e.g. `RAW.R`, `LAB_TESTING.CP_O`).
- **DBA role** `F_<DB>_DBA` is an *account-level* functional role that **owns** the
  database and creates its schemas / access roles.
- **Functional roles** (prefix `F_`) are what get granted **to users**. They bundle
  access roles from many databases plus a warehouse-usage role
  (`A_BI_WAREHOUSE_U`). Named by domain + optional subdomain + persona, e.g.
  `F_LAB_TESTING__CP_DA` (Data Analyst), `F_DE` (Data Engineer), `F_ETL`.
- Users are granted **only** functional roles — never access roles or system roles
  directly.

### Snowflake system-role conventions

Match the built-in role to the action, as the existing scripts do:

- `USE ROLE USERADMIN;` — create/drop roles and users.
- `USE ROLE SECURITYADMIN;` — grant/revoke roles (role → role, role → user).
- `USE ROLE SYSADMIN;` — create databases and warehouses; parent of all functional roles.
- `USE ROLE F_<DB>_DBA;` — create schemas and access roles **inside** that database
  (so `CREATE DATABASE` is never granted to a DBA role).
- `USE ROLE ACCOUNTADMIN;` — only for account-wide `SHOW`/inspection.

## Layout

```
src/
  1-database.create.sql        Create databases + F_<DB>_DBA owner role   (run in order)
  2-role-access.create.sql     Create A/O/W/R database roles per domain
  3a-schema.create.sql         Create schemas + wire A/O/W/R schema grants
  3b-schema.create.extra.sql   Per-schema read roles (<SCHEMA>_R) for RAW/RAW_DEV
  4-role-function.create.sql   Create F_* functional roles + grant access roles
  5-user.create.sql            Grant functional roles to users
  model/ADMIN/PUBLIC/FUNCTION/ UDFs: ROLE_ACCESS_CD, SCHEMA_CD (naming helpers)
  ROLE/F/                      One file per functional role (F_*.sql), current state
  ROLE/A/                      Access-role tweaks (e.g. schema-scoped roles)
  ROLE/F/_TEMPLATE.sql         Starting point for a new functional role
  ROLE/F/[WIP] *.sql           Work-in-progress roles, not yet applied
  old/                         Superseded scripts — reference only, do not run
docs/
  architecture.drawio          Diagram of the RBAC hierarchy
  naming_convention.md         Naming rules (see this before adding anything)
```

The numeric prefix on the top-level `src/` scripts is the **intended execution order**
for standing up the platform from scratch.

### Naming helper UDFs

`ADMIN.PUBLIC.ROLE_ACCESS_CD(domain, subdomain, letter)` and
`ADMIN.PUBLIC.SCHEMA_CD(domain, subdomain, schema)` build the canonical identifiers so
scripts don't hard-code names. Use them when generating role/schema names in new
scripts:

- `ROLE_ACCESS_CD('LAB_TESTING','CP','R')` → `LAB_TESTING.CP_R`
- `SCHEMA_CD('LAB_TESTING','CP','GOLD')` → `LAB_TESTING.CP__GOLD`
- With `subdomain = NULL`: `ROLE_ACCESS_CD('RAW',NULL,'R')` → `RAW.R`.

## Working conventions

- **Follow `docs/naming_convention.md` exactly** when adding a database, schema, role,
  or grant. Consistency is the entire point of this repo.
- To add a new functional role, copy `src/ROLE/F/_TEMPLATE.sql` to
  `src/ROLE/F/<ROLE_NAME>.sql` and keep the `Create → Grant access roles → Grant to
  users → Check` section structure.
- Keep each `src/ROLE/F/*.sql` file reflecting the **current desired grants** for that
  role (files here read like declarative state, unlike the numbered setup scripts).
- Preserve the commented `DROP`/`REVOKE` lines and the `SHOW GRANTS` / `-- [x]` checks;
  they are the operator's safety net.
- Prefer `IDENTIFIER($var)` with `SET` variables over hard-coded names, matching the
  existing scripts — it keeps a block reusable across domains.
- `[WIP]` filename prefix and inline `TODO:` comments mark things not yet applied in
  Snowflake. Don't assume a script has been run against the account.
- This repo does not run itself. **Do not attempt to execute SQL against Snowflake** —
  there are no credentials here and changes are applied manually. Produce/modify the
  scripts and let the operator run them.

## Git

- Commit messages in history are short and imperative (e.g. "GRANT RAW.R TO F_DE_DEV",
  "new role set-up"). Match that style.
- Only commit or push when asked. Branch off `main` first if asked to commit.
