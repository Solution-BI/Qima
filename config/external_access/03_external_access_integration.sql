-- Ties the network rule and secret together into a single integration that the
-- ingestion notebook (or any Snowpark procedure) can reference via
-- EXTERNAL_ACCESS_INTEGRATIONS = (SHAREPOINT_HR_PAYROLL_EAI).
--
-- Account-level object -- requires ACCOUNTADMIN or a role with CREATE INTEGRATION.

USE ROLE ACCOUNTADMIN;

CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION SHAREPOINT_HR_PAYROLL_EAI
    ALLOWED_NETWORK_RULES          = ({{ database }}.{{ schema_raw }}.SHAREPOINT_HR_PAYROLL_NETWORK_RULE)
    ALLOWED_AUTHENTICATION_SECRETS = ({{ database }}.{{ schema_raw }}.SHAREPOINT_HR_PAYROLL_CLIENT_SECRET)
    ENABLED = TRUE
    COMMENT = 'Allows the payroll ingestion notebook to call Microsoft Graph API for SharePoint file listing and download.';
