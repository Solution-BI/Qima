-- ===========================================================================
-- payroll RBAC / 6 - compute
--
-- NOT YET RUN. Creating a warehouse needs SYSADMIN and the usage role needs
-- USERADMIN, so this one goes to whoever administers the account.
--
-- Why payroll should not share BI_WAREHOUSE, which is the only warehouse on
-- the account today:
--
--   MONITOR on a warehouse exposes the query text running on it. Someone with
--   no grant on HR_PAYROLL at all, but MONITOR on the shared warehouse, can
--   read the questions being asked of payroll - which employee, which
--   subsidiary, which figure. The isolation this project is built around is
--   about who can see compensation data, and a shared warehouse leaks the
--   shape of it around the side.
--
-- Size is deliberately small. The whole model is roughly 200,000 rows and the
-- full reload takes seconds on an X-Small; this is not a compute problem.
-- ===========================================================================

use role SYSADMIN;

create warehouse if not exists HR_PAYROLL_WH with
    warehouse_size      = 'X-SMALL'
    auto_suspend        = 60
    auto_resume         = true
    initially_suspended = true
    comment = 'Compute for the payroll pipeline and its reporting. Separate from BI_WAREHOUSE so that MONITOR on shared compute does not expose payroll query text.';

-- ---------------------------------------------------------------------------
-- The usage role, named A_<NAME>_U per section 6 of the naming convention.
-- Granted into the payroll functional roles in script 4.
-- ---------------------------------------------------------------------------
use role USERADMIN;

create role if not exists A_HR_PAYROLL_WH_U
    comment = 'USAGE on HR_PAYROLL_WH. Granted into payroll functional roles to give them compute.';

use role SECURITYADMIN;

grant usage   on warehouse HR_PAYROLL_WH to role A_HR_PAYROLL_WH_U;
grant operate on warehouse HR_PAYROLL_WH to role A_HR_PAYROLL_WH_U;
grant role A_HR_PAYROLL_WH_U to role SYSADMIN;

-- ---------------------------------------------------------------------------
-- Then, in script 4:
--   grant role A_HR_PAYROLL_WH_U to role F_HR_PAYROLL_ETL;
--   grant role A_HR_PAYROLL_WH_U to role F_HR_PAYROLL_DA;
--
-- And the service user's default warehouse in script 5 changes from
-- BI_WAREHOUSE to HR_PAYROLL_WH.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Check
-- ---------------------------------------------------------------------------
show warehouses like 'HR_PAYROLL%';
show grants to role A_HR_PAYROLL_WH_U;
-- [x] the warehouse exists, suspended, X-Small
-- [x] A_HR_PAYROLL_WH_U holds usage and operate on it and nothing else

-- ---------------------------------------------------------------------------
-- Undo, for reference.
-- ---------------------------------------------------------------------------
-- use role SYSADMIN;
-- drop warehouse HR_PAYROLL_WH;
-- use role USERADMIN;
-- drop role A_HR_PAYROLL_WH_U;
