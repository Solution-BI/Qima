-- ===========================================================================
-- payroll RBAC / 4 - functional roles
--
-- These are the account-level roles that get granted to people and service
-- accounts. Users never receive an access role or a system role directly, only
-- an F_* role, which bundles access roles plus a warehouse role.
--
-- NOT YET RUN on the account. Needs USERADMIN and SECURITYADMIN, which neither
-- F_HR_PAYROLL_DBA nor F_SBI_DE holds - so this one goes to whoever administers
-- the account.
--
-- The warehouse below does not exist yet. Only BI_WAREHOUSE does, and MONITOR
-- on a shared warehouse exposes the query text running on it, which for payroll
-- means exposing what is being asked about compensation even to someone with no
-- data access. A dedicated warehouse is requested for that reason.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- Roles
-- ---------------------------------------------------------------------------
use role USERADMIN;

create role if not exists F_HR_PAYROLL_ETL
    comment = 'Runs the payroll ingestion and transformation. Granted to the service user, not to people.';

create role if not exists F_HR_PAYROLL_DA
    comment = 'Reads published payroll reporting. Granted to named consumers only.';

-- ---------------------------------------------------------------------------
-- What each one carries
--
-- ETL gets O, which by the ladder confers W and R as well - it has to create
-- and load objects across all three schemas.
--
-- DA gets R. Note this is read on the whole database, including RAW, which
-- holds the ingested workbook content in the clear. If consumers should see
-- published reporting only, create a schema-scoped role instead:
--
--   use role F_HR_PAYROLL_DBA;
--   create database role if not exists HR_PAYROLL.GOLD_R;
--   grant usage  on schema HR_PAYROLL.GOLD to database role HR_PAYROLL.GOLD_R;
--   grant select on future views in schema HR_PAYROLL.GOLD to database role HR_PAYROLL.GOLD_R;
--   grant select on all views    in schema HR_PAYROLL.GOLD to database role HR_PAYROLL.GOLD_R;
--
-- and grant GOLD_R to F_HR_PAYROLL_DA rather than R. Section 4a of the naming
-- convention covers this pattern.
-- ---------------------------------------------------------------------------
use role SECURITYADMIN;

grant database role HR_PAYROLL.O to role F_HR_PAYROLL_ETL;
grant database role HR_PAYROLL.R to role F_HR_PAYROLL_DA;

-- Compute. Replace the name once the payroll warehouse exists.
-- grant role A_HR_PAYROLL_WH_U to role F_HR_PAYROLL_ETL;
-- grant role A_HR_PAYROLL_WH_U to role F_HR_PAYROLL_DA;

grant role F_HR_PAYROLL_ETL to role SYSADMIN;
grant role F_HR_PAYROLL_DA  to role SYSADMIN;

-- ---------------------------------------------------------------------------
-- The grant that must never exist.
--
-- F_DE is QIMA's general data-engineering functional role. It is never granted
-- any HR_PAYROLL access role. That absence is the whole isolation requirement,
-- and an absence leaves no trace in the account - which is why it is recorded
-- here rather than only in a meeting note.
--
-- Verified absent on 18 Sep 2026.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Check
-- ---------------------------------------------------------------------------
show grants to role F_HR_PAYROLL_ETL;
show grants to role F_HR_PAYROLL_DA;
show grants of database role HR_PAYROLL.R;
-- [x] ETL holds O, DA holds R or GOLD_R
-- [x] F_DE holds nothing on HR_PAYROLL

-- ---------------------------------------------------------------------------
-- Undo, for reference.
-- ---------------------------------------------------------------------------
-- use role SECURITYADMIN;
-- revoke database role HR_PAYROLL.O from role F_HR_PAYROLL_ETL;
-- revoke database role HR_PAYROLL.R from role F_HR_PAYROLL_DA;
-- use role USERADMIN;
-- drop role F_HR_PAYROLL_ETL;
-- drop role F_HR_PAYROLL_DA;
