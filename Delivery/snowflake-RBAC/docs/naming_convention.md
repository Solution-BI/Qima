# Naming Conventions

Canonical naming rules for all Snowflake objects managed in this repository. The goal is
that a name alone tells you **what** an object is, **which domain** it belongs to, and
**what access** it grants. When in doubt, use the helper UDFs
`ADMIN.PUBLIC.ROLE_ACCESS_CD` and `ADMIN.PUBLIC.SCHEMA_CD` (see the bottom of this doc)
so names are generated the same way everywhere.

All identifiers are **UPPER_SNAKE_CASE**.

---

## 1. Core concepts

| Concept       | Meaning                                                                 | Examples                                  |
|---------------|-------------------------------------------------------------------------|-------------------------------------------|
| **Domain**    | A business/data area. Maps 1:1 to a **database**.                        | `RAW`, `AUDIT`, `FINANCE`, `LAB_TESTING`  |
| **Subdomain** | An optional split *within* a domain. Maps to a prefix on roles/schemas. | `CP`, `FOOD`, `LS`                        |
| **Schema**    | A layer or source system inside a database.                             | `SILVER`, `GOLD`, `QSP__AIPROD__FIMASTER` |
| **Persona**   | The type of human/service consumer a functional role serves.            | `DA`, `DE`, `BA`, `DBA`, `ETL`            |

`<SUBDOMAIN>` below is **optional** — omit it (and its separator) for domains that have
no subdomains.

---

## 2. Databases (domains)

```
<DOMAIN>
```

- One database per domain. Uppercase, singular where natural.
- Development variants use a `_DEV` suffix: `RAW` / `RAW_DEV`.
- Sandbox / proof-of-concept variants use `_SBX`: `LAB_TESTING_SBX`, `COMMON_SBX`.
- Known domains include: `RAW`, `RAW_DEV`, `AUDIT`, `FINANCE`, `PRODUCT`, `INSPECTION`,
  `LAB_TESTING`, `CERTIFICATION`, `CUSTOMER`, `HR`, `ANALYTICS`, `COMMON`, `ADMIN`,
  `SANDBOX`, `TEST`.

`ADMIN` is special: it holds shared platform objects (the naming UDFs live in
`ADMIN.PUBLIC`).

---

## 3. Schemas

```
<SCHEMA_NAME>                       -- domain with no subdomain
<SUBDOMAIN>__<SCHEMA_NAME>          -- domain with a subdomain   (double underscore)
```

Built by `ADMIN.PUBLIC.SCHEMA_CD(domain, subdomain, schema_name)`.

- **Modeled layers** (medallion): `SILVER`, `GOLD`. With a subdomain:
  `LAB_TESTING.CP__GOLD`, `LAB_TESTING.LS__SILVER`.
- **Source-system schemas** in `RAW` / `RAW_DEV` encode the pipeline path with double
  underscores: `<SOURCE>__<SYSTEM>__<OBJECT>`, e.g. `QSP__AIPROD__FIMASTER`,
  `QIMAONE__QIMAONE__QIMAONE`, `WQS__ORION__TARQ`.
- **Internal/config** schemas use a leading underscore: `_CONFIG`.
- **Personal sandbox** schemas (in `SANDBOX`) are named after the user:
  `VICTOR_GRAPPE`, `ANTOINE_CHAPELET`.
- Schemas are created `WITH MANAGED ACCESS` so grants are centralized on the schema.
- The default `PUBLIC` schema is dropped from every database (except `ADMIN`).

> Note the two separators: a subdomain is joined to the schema with `__` (double
> underscore); the pieces of a source-system schema name are also `__`. A single `_`
> is only used inside a compound word (`RAW_DEV`, `_CONFIG`).

---

## 4. Access roles (Snowflake *database roles*)

Scoped to a single database. One set per domain, or per subdomain when the domain is
split. Built by `ADMIN.PUBLIC.ROLE_ACCESS_CD(domain, subdomain, letter)`.

```
<DOMAIN>.<LETTER>                   -- no subdomain
<DOMAIN>.<SUBDOMAIN>_<LETTER>       -- with subdomain            (single underscore)
```

| Letter | Name  | Privilege class            | Grants (roughly)                          |
|:------:|-------|----------------------------|-------------------------------------------|
| `A`    | Admin | DCL — manage access        | Owns schemas; can grant `O`/`W`/`R`       |
| `O`    | Owner | DDL — create/own objects   | `CREATE` + `OWNERSHIP` on objects         |
| `W`    | Write | DML — modify data          | `INSERT/UPDATE/DELETE/TRUNCATE`, stages   |
| `R`    | Read  | DQL — read data            | `USAGE` + `SELECT`, `MONITOR`             |

**Privilege ladder — each role is granted the one below it:**

```
A  ─contains→  O  ─contains→  W  ─contains→  R
```

So granting a functional role `<DB>.O` also confers write and read. All four are also
granted to `SYSADMIN`.

Examples: `RAW.R`, `RAW.O`, `FINANCE.A`, `LAB_TESTING.CP_R`, `AUDIT.FOOD_O`.

### 4a. Schema-scoped read roles

For read access to a *single* schema (rather than the whole database), a narrower
database role is created and granted **to** the domain's `R` role:

```
<SCHEMA_NAME>_R          e.g. QSP__AIPROD__FIMASTER_R  (in database RAW)
```

See `src/3b-schema.create.extra.sql`.

---

## 5. Functional roles (account-level, prefix `F_`)

These are the roles **granted to users and service accounts**. They compose access
roles (from possibly many databases) plus a warehouse-usage role. Users never receive
access or system roles directly — only `F_*` roles.

### 5a. Per-domain data roles

```
F_<DOMAIN>_<PERSONA>                    -- no subdomain
F_<DOMAIN>__<SUBDOMAIN>_<PERSONA>       -- with subdomain   (double underscore before subdomain)
```

Persona suffixes:

| Suffix | Persona                | Typical grants                                    |
|--------|------------------------|---------------------------------------------------|
| `DA`   | Data Analyst           | `O` on own domain + `R` on many domains + warehouse |
| `DE`   | Data Engineer          | broad `O`/`R` for building models                 |
| `BA`   | Business Analyst       | scoped `R`                                          |
| `DBA`  | Database Administrator | owns the database (see 5b)                         |
| `ETL`  | ETL / ingestion        | `O` on `RAW` (write pipeline data)                |

Examples: `F_LAB_TESTING__CP_DA`, `F_AUDIT__FOOD_DA`, `F_FINANCE_DA`, `F_PRODUCT_DA`,
`F_CUSTOMER_DA`, `F_HR_DA`, `F_MARKETING_DA`, `F_QUANTILAB_BA`, `F_SECURITY_BA`.

`_SBX` / `_DEV` on the domain flows through: `F_LAB_TESTING_SBX__CP_DA`, `F_DE_DEV`,
`F_ETL_DEV`.

### 5b. DBA roles

```
F_<DOMAIN>_DBA
```

Account-level role that **owns** the domain's database and creates its schemas and
access roles. Granted to `SYSADMIN`. Examples: `F_RAW_DBA`, `F_LAB_TESTING_DBA`.

### 5c. Cross-cutting / platform functional roles

Named `F_<PURPOSE>` where the purpose is not a single domain: `F_DE`, `F_ETL`,
`F_DA`, `F_DATARAILS`, `F_DATA_IMPORT_DA`, `F_DATA_METRIC_EXECUTE`,
`F_FOOCERT_AUTOALLOC`.

Each such role has its own file at `src/ROLE/F/<ROLE>.sql`.

---

## 6. Warehouse roles

```
A_<NAME>_U        e.g. A_BI_WAREHOUSE_U   (USAGE on a warehouse)
```

`A_` = an account-level access role, `_U` = usage. Granted into functional roles to give
them compute.

---

## 7. Users

- **People:** `FIRSTNAME_LASTNAME` — e.g. `VICTOR_GRAPPE`, `ANTOINE_CHAPELET`.
- **Service accounts:** `S_<PURPOSE>` — e.g. `S_DATA_IMPORT`, `S_BI_SCRIPTS`,
  `S_DATA_TRANSFO`. Dev variants add `_DEV`: `S_DATA_IMPORT_DEV`.

Users are granted only `F_*` functional roles.

---

## 8. Legacy naming (do not extend)

Older roles predating this scheme use `<AREA>_<ROLE>_ROLE` (e.g. `BI_USER_ROLE`,
`BI_ADMIN_ROLE`, `MKT_ADMIN_ROLE`, `WQS_USER_ROLE`, `PRODUCE_USER_ROLE`). They are being
replaced by the `F_*` scheme above — reference only, don't create new ones.

---

## 9. Quick reference — the helper UDFs

Always prefer these over hand-writing names in scripts:

```sql
-- Access role identifier
ADMIN.PUBLIC.ROLE_ACCESS_CD('RAW',         NULL, 'R')  -- 'RAW.R'
ADMIN.PUBLIC.ROLE_ACCESS_CD('LAB_TESTING', 'CP', 'O')  -- 'LAB_TESTING.CP_O'

-- Schema identifier
ADMIN.PUBLIC.SCHEMA_CD('AUDIT',       NULL, 'GOLD')   -- 'AUDIT.GOLD'
ADMIN.PUBLIC.SCHEMA_CD('LAB_TESTING', 'CP', 'SILVER') -- 'LAB_TESTING.CP__SILVER'
```

Both apply the same rule: `NULL` subdomain → no prefix; otherwise the subdomain is
joined with `_` for roles and `__` for schemas.

---

## 10. Cheat sheet

| Object            | Pattern                                          | Example                     |
|-------------------|--------------------------------------------------|-----------------------------|
| Database (domain) | `<DOMAIN>`                                        | `LAB_TESTING`               |
| Dev / sandbox db  | `<DOMAIN>_DEV` / `<DOMAIN>_SBX`                   | `RAW_DEV`, `LAB_TESTING_SBX`|
| Schema            | `<SUBDOMAIN>__<SCHEMA>`                           | `CP__GOLD`                  |
| Access role       | `<DOMAIN>.<SUBDOMAIN>_<LETTER>`                  | `LAB_TESTING.CP_R`          |
| Schema read role  | `<SCHEMA>_R`                                      | `QSP__AIPROD__FIMASTER_R`   |
| Functional role   | `F_<DOMAIN>__<SUBDOMAIN>_<PERSONA>`              | `F_LAB_TESTING__CP_DA`      |
| DBA role          | `F_<DOMAIN>_DBA`                                  | `F_RAW_DBA`                 |
| Warehouse role    | `A_<NAME>_U`                                      | `A_BI_WAREHOUSE_U`          |
| Person user       | `FIRSTNAME_LASTNAME`                             | `VICTOR_GRAPPE`             |
| Service user      | `S_<PURPOSE>`                                     | `S_DATA_IMPORT`             |
