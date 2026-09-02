-- Whitelists the external hosts the ingestion notebook needs to reach.
-- Requires a role with CREATE NETWORK RULE on the target schema.
--
-- Three hosts:
--   graph.microsoft.com       -- Microsoft Graph API (list/download SharePoint files)
--   login.microsoftonline.com -- Azure AD token endpoint (OAuth2 client-credentials grant)
--   {{ sharepoint_domain }}   -- download URLs sometimes redirect to the tenant's SharePoint domain

USE ROLE ACCOUNTADMIN;
USE DATABASE {{ database }};
USE SCHEMA {{ schema_raw }};

CREATE OR REPLACE NETWORK RULE SHAREPOINT_HR_PAYROLL_NETWORK_RULE
    MODE       = EGRESS
    TYPE       = HOST_PORT
    VALUE_LIST = (
        'graph.microsoft.com',
        'login.microsoftonline.com',
        '{{ sharepoint_domain }}'
    );
