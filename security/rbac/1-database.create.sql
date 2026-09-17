-- ===========================================================================
-- payroll RBAC / 1 - database and its owner role
--
-- Run by hand, statement by statement. Nothing here is a migration.
--
-- Already satisfied on HR_PAYROLL as at 18 Sep 2026 (built 3 Sep). Kept so the
-- domain is reproducible, and so HR_PAYROLL_DEV can be checked against it.
--
-- SYSADMIN creates the database and hands ownership to the DBA role. The DBA
-- role never holds CREATE DATABASE itself - it owns and builds inside one.
-- ===========================================================================

set domain_cd = 'HR_PAYROLL';          -- 👈
-- set domain_cd = 'HR_PAYROLL_DEV';

-- ---------------------------------------------------------------------------
-- Database
-- ---------------------------------------------------------------------------
use role SYSADMIN;

create database if not exists identifier($domain_cd)
    comment = 'Database for payroll consolidation, processing, and reporting. Consolidates multi-entity payroll data from external feeds and supports downstream reporting, analytics, and compliance workflows. Includes dynamic masking policies on salary/compensation fields and audit logging for financial controls.';

-- Convention: PUBLIC is dropped from every database except ADMIN.
drop schema if exists identifier($domain_cd || '.PUBLIC');

-- ---------------------------------------------------------------------------
-- Owner role
--
-- Named F_<DOMAIN>_DBA per section 5b of the naming convention. HR_PAYROLL_DEV
-- uses F_HR_PAYROLL_DEV_DBA, which already exists and which we do not hold.
-- ---------------------------------------------------------------------------
use role USERADMIN;

create role if not exists F_HR_PAYROLL_DBA
    comment = 'Owns the HR_PAYROLL database and creates its schemas and access roles.';

use role SECURITYADMIN;

grant role F_HR_PAYROLL_DBA to role SYSADMIN;

grant ownership on database identifier($domain_cd)
    to role F_HR_PAYROLL_DBA copy current grants;

-- ---------------------------------------------------------------------------
-- Check
-- ---------------------------------------------------------------------------
show databases like 'HR_PAYROLL%';
-- [x] owner of HR_PAYROLL is F_HR_PAYROLL_DBA
-- [x] no PUBLIC schema

-- ---------------------------------------------------------------------------
-- Undo, for reference. Do not run casually - dropping the database drops
-- every payroll object inside it.
-- ---------------------------------------------------------------------------
-- use role SYSADMIN;
-- drop database identifier($domain_cd);
-- use role USERADMIN;
-- drop role F_HR_PAYROLL_DBA;
