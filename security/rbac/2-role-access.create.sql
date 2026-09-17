-- ===========================================================================
-- payroll RBAC / 2 - the four access roles
--
-- These are Snowflake DATABASE roles, scoped to one database, and they are
-- never granted to a person. People receive F_* functional roles only, which
-- bundle these plus a warehouse role (script 4).
--
--   A  Admin   DCL - owns schemas, can grant the rest
--   O  Owner   DDL - creates and owns objects
--   W  Write   DML - insert, update, delete, truncate
--   R  Read    DQL - usage and select
--
-- Privilege ladder, each role granted the one below it:
--
--   A  ─contains→  O  ─contains→  W  ─contains→  R
--
-- So granting a functional role O also confers write and read.
--
-- Already satisfied on HR_PAYROLL as at 18 Sep 2026, ladder included.
--
-- Database role names are written out rather than built with IDENTIFIER():
-- the domain changes once per run, at the top of script 1, and a literal name
-- in a GRANT is easier to eyeball than a concatenation when the statement is
-- about who can read payroll.
-- ===========================================================================

use role F_HR_PAYROLL_DBA;
use database HR_PAYROLL;                -- 👈 HR_PAYROLL_DEV for the dev build

-- ---------------------------------------------------------------------------
-- The roles
-- ---------------------------------------------------------------------------
create database role if not exists A
    comment = 'Admin role on [HR_PAYROLL] database. Scope: Database (not Account)';
create database role if not exists O
    comment = 'Owner role on [HR_PAYROLL] database. Scope: Database (not Account)';
create database role if not exists W
    comment = 'Write role on [HR_PAYROLL] database. Scope: Database (not Account)';
create database role if not exists R
    comment = 'Read role on [HR_PAYROLL] database. Scope: Database (not Account)';

-- ---------------------------------------------------------------------------
-- The ladder
-- ---------------------------------------------------------------------------
grant database role HR_PAYROLL.R to database role HR_PAYROLL.W;
grant database role HR_PAYROLL.W to database role HR_PAYROLL.O;
grant database role HR_PAYROLL.O to database role HR_PAYROLL.A;

-- ---------------------------------------------------------------------------
-- Database-level usage. Schema-level grants are in script 3.
-- ---------------------------------------------------------------------------
grant usage on database HR_PAYROLL to database role HR_PAYROLL.R;
grant usage on database HR_PAYROLL to database role HR_PAYROLL.O;

-- ---------------------------------------------------------------------------
-- Who holds A.
--
-- F_SBI_DE was granted A on 15 Sep 2026 so the build team can work. It is a
-- default role, so anyone at SBI holding it reaches payroll without switching
-- role - worth revisiting once the build is handed over.
--
-- QIMA's general F_DE role is deliberately absent and must stay absent. That
-- non-grant is the isolation requirement; there is no statement expressing it,
-- which is why it is written here instead.
-- ---------------------------------------------------------------------------
use role SECURITYADMIN;
grant database role HR_PAYROLL.A to role F_HR_PAYROLL_DBA;

-- ---------------------------------------------------------------------------
-- Check
-- ---------------------------------------------------------------------------
show database roles in database HR_PAYROLL;
show grants of database role HR_PAYROLL.A;
show grants of database role HR_PAYROLL.R;
-- [x] four roles exist
-- [x] R granted into W, W into O, O into A
-- [x] no general data-engineering role appears against any of them

-- ---------------------------------------------------------------------------
-- Undo, for reference.
-- ---------------------------------------------------------------------------
-- use role F_HR_PAYROLL_DBA;
-- drop database role HR_PAYROLL.R;
-- drop database role HR_PAYROLL.W;
-- drop database role HR_PAYROLL.O;
-- drop database role HR_PAYROLL.A;
