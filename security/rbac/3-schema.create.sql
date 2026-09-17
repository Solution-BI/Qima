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
-- As at 18 Sep 2026 on HR_PAYROLL, everything below is already in place for
-- RAW, SILVER and GOLD except the block marked MISSING. That block is what
-- blocks deployment of the payroll model and its masking policies.
--
-- If a statement rejects IDENTIFIER($schema_cd), substitute the literal schema
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
-- MISSING as at 18 Sep 2026 - the three privileges O does not have.
--
--   create sequence            SEQ_MEASURE_ID, which both fact tables draw
--                              MEASURE_ID from. Without it 02_silver_model
--                              fails on the first statement.
--   create masking policy      security/masking/ cannot deploy at all.
--   create row access policy   blocks the row access work agreed on 20 Aug.
--
-- A owns the schema, and F_HR_PAYROLL_DBA holds A, so this needs no account
-- administrator.
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

grant ownership on future tables     in schema identifier($schema_cd) to database role HR_PAYROLL.O;
grant ownership on future views      in schema identifier($schema_cd) to database role HR_PAYROLL.O;
grant ownership on future stages     in schema identifier($schema_cd) to database role HR_PAYROLL.O;
grant ownership on future tasks      in schema identifier($schema_cd) to database role HR_PAYROLL.O;
grant ownership on future procedures in schema identifier($schema_cd) to database role HR_PAYROLL.O;
grant ownership on future functions  in schema identifier($schema_cd) to database role HR_PAYROLL.O;
grant ownership on future streams    in schema identifier($schema_cd) to database role HR_PAYROLL.O;
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
-- [x] O can create sequence, masking policy and row access policy
-- [x] future tables select to R, DML to W, ownership to O

-- ---------------------------------------------------------------------------
-- Undo, for reference.
-- ---------------------------------------------------------------------------
-- revoke create masking policy    on schema identifier($schema_cd) from database role HR_PAYROLL.O;
-- revoke create row access policy on schema identifier($schema_cd) from database role HR_PAYROLL.O;
-- revoke create sequence          on schema identifier($schema_cd) from database role HR_PAYROLL.O;
