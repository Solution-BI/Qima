-- Run after 01-03 have created all objects as ACCOUNTADMIN.
-- Transfers ownership where appropriate and grants usage to the ingestion role.
--
-- Must be run by ACCOUNTADMIN or SECURITYADMIN.

USE ROLE ACCOUNTADMIN;

-- Transfer secret ownership to the ingestion role (only role that should access it).
GRANT OWNERSHIP ON SECRET {{ database }}.{{ schema_raw }}.SHAREPOINT_HR_PAYROLL_CLIENT_SECRET
    TO ROLE {{ role_ingestion }} REVOKE CURRENT GRANTS;

-- Grant usage on the integration and network rule (account-level objects, can't transfer ownership).
GRANT USAGE ON INTEGRATION SHAREPOINT_HR_PAYROLL_EAI
    TO ROLE {{ role_ingestion }};

GRANT USAGE ON NETWORK RULE {{ database }}.{{ schema_raw }}.SHAREPOINT_HR_PAYROLL_NETWORK_RULE
    TO ROLE {{ role_ingestion }};
