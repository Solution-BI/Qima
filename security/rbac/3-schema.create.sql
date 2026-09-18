-- ===========================================================================
-- payroll RBAC / 3 - schemas and the grants that make the four roles mean
--                    something
--
-- 🔁 Repeat the whole file once per schema, changing $schema_cd at the top.
--
-- Schemas are created WITH MANAGED ACCESS so grants are centralised on the
-- schema rather than scattered across whoever owns each object.
--
-- Two kinds of grant here, and both matter:
--   * on the schema      - what a role may create or see now
--   * on FUTURE objects  - what happens to things created later, without
--                          anyone remembering to grant again
--
-- The second is what "specific roles when an object is created" means in
-- practice. No new role per object: a table created next year is owned by O,
-- writable by W and readable by R the moment it exists, because the rule was
-- set here once.
--
-- As at 18 Sep 2026 on HR_PAYROLL, everything below is already in place for
-- RAW, SILVER and GOLD except the block marked MISSING, and the schema
-- descriptions. CREATE SEQUENCE on RAW was granted and verified on 18 Sep.
--
-- IDENTIFIER($schema_cd) follows QIMA's own convention, which prefers it over
-- hard-coded names. If a statement rejects it, substitute the literal schema
-- name - the grant is the point, not the indirection.
-- ===========================================================================

use role F_HR_PAYROLL_DBA;

set schema_cd = 'HR_PAYROLL.RAW';       -- 👈
-- set schema_cd = 'HR_PAYROLL.SILVER';
-- set schema_cd = 'HR_PAYROLL.GOLD';

-- ---------------------------------------------------------------------------
-- The schema, owned by A
-- ---------------------------------------------------------------------------
create schema if not exists identifier($schema_cd) with managed access;

grant ownership on schema identifier($schema_cd)
    to database role HR_PAYROLL.A copy current grants;

-- ---------------------------------------------------------------------------
-- Descriptions.
--
-- Set on the schema itself so anyone browsing the database in Snowsight can
-- see what each layer holds without opening this repository. The model's own
-- tables and columns are described by transformation/sql/06_column_descriptions.
--
-- 👈 run the line matching $schema_cd above.
-- ---------------------------------------------------------------------------
alter schema HR_PAYROLL.RAW set comment =
    'Landing layer. Holds each ingested payroll workbook as extracted JSON, one row per file version, plus the load history. Nothing here is interpreted - structure is applied in SILVER. Raw spreadsheets are never persisted beyond the moment it takes to read them.';

-- alter schema HR_PAYROLL.SILVER set comment =
--     'Modelled layer. One row per payroll value, interpreted through the HEADER_MAP reference data: payments, contractual rates and ceilings, scheme eligibility, and the descriptive attributes. Data quality findings live here too. Read GOLD rather than this layer for reporting.';

-- alter schema HR_PAYROLL.GOLD set comment =
--     'Reporting layer. Views over SILVER that apply the agreed exclusions - sample templates, rows held back by identity findings, and the currency rules - so a consumer does not have to know them. This is the layer to grant to reporting users.';

-- ---------------------------------------------------------------------------
-- MISSING as at 18 Sep 2026 - the three privileges O does not have.
--
--   create sequence            SEQ_MEASURE_ID, which both fact tables draw
--                              MEASURE_ID from. Without it 02_silver_model
--                              fails on the first statement.
--   create masking policy      security/masking/ cannot deploy at all.
--   create row access policy   blocks the row access work agreed on 20 Aug.
--
-- A owns the schema, and F_HR_PAYROLL_DBA holds A, so this needs no account
-- administrator. Proven on RAW on 18 Sep: create sequence granted and verified.
-- ---------------------------------------------------------------------------
grant create sequence          on schema identifier($schema_cd) to database role HR_PAYROLL.O;
grant create masking policy    on schema identifier($schema_cd) to database role HR_PAYROLL.O;
grant create row access policy on schema identifier($schema_cd) to database role HR_PAYROLL.O;

-- ---------------------------------------------------------------------------
-- O - create and own objects
-- ---------------------------------------------------------------------------
grant usage                     on schema identifier($schema_cd) to database role HR_PAYROLL.O;
grant create table              on schema identifier($schema_cd) to database role HR_PAYROLL.O;
grant create view               on schema identifier($schema_cd) to database role HR_PAYROLL.O;
grant create materialized view  on schema identifier($schema_cd) to database role HR_PAYROLL.O;
grant create stage              on schema identifier($schema_cd) to database role HR_PAYROLL.O;
grant create file format        on schema identifier($schema_cd) to database role HR_PAYROLL.O;
grant create stream             on schema identifier($schema_cd) to database role HR_PAYROLL.O;
grant create task               on schema identifier($schema_cd) to database role HR_PAYROLL.O;
grant create procedure          on schema identifier($schema_cd) to database role HR_PAYROLL.O;
grant create function           on schema identifier($schema_cd) to database role HR_PAYROLL.O;
grant create pipe               on schema identifier($schema_cd) to database role HR_PAYROLL.O;

grant ownership on future tables       in schema identifier($schema_cd) to database role HR_PAYROLL.O;
grant ownership on future views        in schema identifier($schema_cd) to database role HR_PAYROLL.O;
grant ownership on future stages       in schema identifier($schema_cd) to database role HR_PAYROLL.O;
grant ownership on future tasks        in schema identifier($schema_cd) to database role HR_PAYROLL.O;
grant ownership on future procedures   in schema identifier($schema_cd) to database role HR_PAYROLL.O;
grant ownership on future functions    in schema identifier($schema_cd) to database role HR_PAYROLL.O;
grant ownership on future streams      in schema identifier($schema_cd) to database role HR_PAYROLL.O;
grant ownership on future file formats in schema identifier($schema_cd) to database role HR_PAYROLL.O;

-- ---------------------------------------------------------------------------
-- W - modify data
-- ---------------------------------------------------------------------------
grant insert, update, delete, truncate, references
    on future tables in schema identifier($schema_cd) to database role HR_PAYROLL.W;
grant insert, update, delete, truncate, references
    on all tables    in schema identifier($schema_cd) to database role HR_PAYROLL.W;
grant read, write on future stages in schema identifier($schema_cd) to database role HR_PAYROLL.W;
grant read, write on all stages    in schema identifier($schema_cd) to database role HR_PAYROLL.W;
grant operate on future tasks in schema identifier($schema_cd) to database role HR_PAYROLL.W;
grant operate on all tasks    in schema identifier($schema_cd) to database role HR_PAYROLL.W;

-- ---------------------------------------------------------------------------
-- R - read
--
-- Note this is read on the whole schema. For a consumer who should see
-- published reporting only, use the schema-scoped role in 3b rather than
-- granting R.
-- ---------------------------------------------------------------------------
grant usage  on schema identifier($schema_cd) to database role HR_PAYROLL.R;
grant select on future tables  in schema identifier($schema_cd) to database role HR_PAYROLL.R;
grant select on all tables     in schema identifier($schema_cd) to database role HR_PAYROLL.R;
grant select on future views   in schema identifier($schema_cd) to database role HR_PAYROLL.R;
grant select on all views      in schema identifier($schema_cd) to database role HR_PAYROLL.R;
grant select on future streams in schema identifier($schema_cd) to database role HR_PAYROLL.R;
grant usage  on future functions  in schema identifier($schema_cd) to database role HR_PAYROLL.R;
grant usage  on future procedures in schema identifier($schema_cd) to database role HR_PAYROLL.R;
grant monitor on future tasks in schema identifier($schema_cd) to database role HR_PAYROLL.R;
grant read   on future stages in schema identifier($schema_cd) to database role HR_PAYROLL.R;

-- ---------------------------------------------------------------------------
-- Check
-- ---------------------------------------------------------------------------
show grants to database role HR_PAYROLL.O;
show future grants in schema identifier($schema_cd);
show schemas in database HR_PAYROLL;
-- [x] O can create sequence, masking policy and row access policy
-- [x] future tables select to R, DML to W, ownership to O
-- [x] the schema carries a description

-- ---------------------------------------------------------------------------
-- Undo, for reference.
-- ---------------------------------------------------------------------------
-- revoke create masking policy    on schema identifier($schema_cd) from database role HR_PAYROLL.O;
-- revoke create row access policy on schema identifier($schema_cd) from database role HR_PAYROLL.O;
-- revoke create sequence          on schema identifier($schema_cd) from database role HR_PAYROLL.O;
