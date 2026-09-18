-- ===========================================================================
-- payroll RBAC / 3b - schema-scoped read roles
--
-- Section 4a of the naming convention: where someone should read one schema
-- rather than the whole database, create a narrower database role named
-- <SCHEMA>_R and grant it into the domain's R role.
--
-- For payroll this is not a nicety. HR_PAYROLL.R carries read on RAW, and RAW
-- holds each submitted workbook as extracted JSON - every amount for every
-- employee, in the clear, before any masking policy applies. A reporting
-- consumer given R to look at published figures can also read the source
-- spreadsheets.
--
-- GOLD_R gives them the reporting layer and nothing else.
--
-- NOT YET RUN. The role creation and grants below are ours to run; granting
-- GOLD_R to a functional role is in script 4 and needs SECURITYADMIN.
-- ===========================================================================

use role F_HR_PAYROLL_DBA;

-- ---------------------------------------------------------------------------
-- The role
-- ---------------------------------------------------------------------------
create database role if not exists HR_PAYROLL.GOLD_R
    comment = 'Read role on the GOLD schema of [HR_PAYROLL] only. Scope: Schema (not Database, not Account). For reporting consumers who must not reach RAW or SILVER.';

-- ---------------------------------------------------------------------------
-- What it can reach
--
-- Views only, deliberately. Everything a consumer needs in GOLD is a view, and
-- granting select on tables as well would hand them anything later created
-- there as a table without a second thought.
-- ---------------------------------------------------------------------------
grant usage  on database HR_PAYROLL          to database role HR_PAYROLL.GOLD_R;
grant usage  on schema   HR_PAYROLL.GOLD     to database role HR_PAYROLL.GOLD_R;
grant select on all views    in schema HR_PAYROLL.GOLD to database role HR_PAYROLL.GOLD_R;
grant select on future views in schema HR_PAYROLL.GOLD to database role HR_PAYROLL.GOLD_R;

-- ---------------------------------------------------------------------------
-- Folded into the domain read role, per section 4a.
--
-- So anyone holding R keeps everything they had: R now reaches GOLD through
-- this role as well as directly. The point of GOLD_R is what it can be granted
-- to on its own, not what it takes away.
-- ---------------------------------------------------------------------------
grant database role HR_PAYROLL.GOLD_R to database role HR_PAYROLL.R;

-- ---------------------------------------------------------------------------
-- Check
-- ---------------------------------------------------------------------------
show database roles in database HR_PAYROLL;
show grants to database role HR_PAYROLL.GOLD_R;
-- [x] GOLD_R reaches HR_PAYROLL.GOLD and nothing else
-- [x] no grant on RAW or SILVER appears against it

-- ---------------------------------------------------------------------------
-- Undo, for reference.
-- ---------------------------------------------------------------------------
-- use role F_HR_PAYROLL_DBA;
-- drop database role HR_PAYROLL.GOLD_R;
