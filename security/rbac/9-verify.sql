-- ===========================================================================
-- payroll RBAC / 9 - verification
--
-- Reads only. Safe to run at any time, by anyone holding a payroll role.
--
-- Answers four questions in order of how much they matter:
--   1. who can reach payroll data
--   2. does the privilege ladder still hold
--   3. can the model actually be deployed
--   4. what is in the database
--
-- Results as at 18 September 2026 are recorded in README.md.
-- ===========================================================================

use role F_HR_PAYROLL_DBA;

-- ---------------------------------------------------------------------------
-- 1. Who can reach payroll data.
--
-- Expect F_HR_PAYROLL_DBA, and F_SBI_DE while the build is in progress.
-- QIMA's general F_DE must not appear against any of the four. If it does, the
-- isolation requirement has been broken and that is the finding, not a note.
-- ---------------------------------------------------------------------------
show grants of database role HR_PAYROLL.A;
show grants of database role HR_PAYROLL.O;
show grants of database role HR_PAYROLL.W;
show grants of database role HR_PAYROLL.R;

-- ---------------------------------------------------------------------------
-- 2. The ladder.
--
-- Expect R granted into W, W into O, O into A. Any break means a role confers
-- less than its name implies, which fails quietly rather than loudly.
-- ---------------------------------------------------------------------------
show database roles in database HR_PAYROLL;

-- ---------------------------------------------------------------------------
-- 3. Can the model be deployed.
--
-- O needs create sequence, create masking policy and create row access policy
-- alongside the usual table and view privileges. Missing any of the three and
-- the deployment stops partway, having already created some objects.
-- ---------------------------------------------------------------------------
show grants to database role HR_PAYROLL.O;

show future grants in schema HR_PAYROLL.RAW;
show future grants in schema HR_PAYROLL.SILVER;
show future grants in schema HR_PAYROLL.GOLD;

-- ---------------------------------------------------------------------------
-- 4. What is actually there.
-- ---------------------------------------------------------------------------
show schemas in database HR_PAYROLL;

select table_schema, table_type, count(*) as objects
from HR_PAYROLL.information_schema.tables
where table_schema <> 'INFORMATION_SCHEMA'
group by 1, 2
order by 1, 2;

show masking policies in database HR_PAYROLL;
show row access policies in database HR_PAYROLL;
show git repositories in database HR_PAYROLL;

-- Compute. A shared warehouse exposes payroll query text to anyone holding
-- MONITOR on it, so a dedicated one is preferred.
show warehouses;
