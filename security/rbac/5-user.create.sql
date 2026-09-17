-- ===========================================================================
-- payroll RBAC / 5 - users
--
-- Users receive F_* functional roles only. Never an access role, never a
-- system role.
--
-- NOT YET RUN on the account. Needs USERADMIN and SECURITYADMIN.
--
-- Service accounts are named S_<PURPOSE> per section 7 of the naming
-- convention. People are FIRSTNAME_LASTNAME.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- The service account the scheduled task runs as.
--
-- TYPE = SERVICE so it cannot log into Snowsight and has no password. It
-- authenticates with a key pair, which unlike a programmatic access token does
-- not depend on a network policy being attached.
-- ---------------------------------------------------------------------------
use role USERADMIN;

create user if not exists S_HR_PAYROLL
    type            = SERVICE
    comment         = 'Runs the payroll ingestion and transformation task. Owned by the payroll build, not a person.'
    default_role      = F_HR_PAYROLL_ETL
    default_warehouse = BI_WAREHOUSE;         -- 👈 replace once a payroll warehouse exists

-- Key pair, once the public key is generated:
-- alter user S_HR_PAYROLL set rsa_public_key = '<public key>';

use role SECURITYADMIN;
grant role F_HR_PAYROLL_ETL to user S_HR_PAYROLL;

-- ---------------------------------------------------------------------------
-- People
--
-- The build team currently reaches payroll through F_SBI_DE, which holds
-- HR_PAYROLL.A. That works but is broad: F_SBI_DE is a default role, so it
-- carries payroll admin into every session whether or not payroll is what the
-- person is doing. Granting F_HR_PAYROLL_DBA to named individuals instead, and
-- revoking A from F_SBI_DE, would narrow it without slowing anyone down.
--
-- Not done unilaterally - it changes who can reach compensation data, and that
-- is a decision for the project lead rather than a tidy-up.
-- ---------------------------------------------------------------------------
-- grant role F_HR_PAYROLL_DBA to user GERARD_AVENA;
-- grant role F_HR_PAYROLL_DBA to user CHHORASETH_CHHORT;
-- use role SECURITYADMIN;
-- revoke database role HR_PAYROLL.A from role F_SBI_DE;

-- ---------------------------------------------------------------------------
-- Check
-- ---------------------------------------------------------------------------
show grants to user S_HR_PAYROLL;
desc user S_HR_PAYROLL;
-- [x] S_HR_PAYROLL holds F_HR_PAYROLL_ETL and nothing else
-- [x] TYPE is SERVICE, HAS_PASSWORD is false

-- ---------------------------------------------------------------------------
-- Undo, for reference.
-- ---------------------------------------------------------------------------
-- use role USERADMIN;
-- drop user S_HR_PAYROLL;
