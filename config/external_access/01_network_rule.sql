-- Whitelists the external hosts the ingestion notebook needs to reach.
-- Requires a role with CREATE NETWORK RULE on the target schema.
--
-- Four hosts:
--   graph.microsoft.com       -- Microsoft Graph API (list/download SharePoint files)
--   login.microsoftonline.com -- Azure AD token endpoint (OAuth2 client-credentials grant).
--                                Issues the Key Vault token as well as the Graph token, so
--                                one entry covers both -- no separate auth rule is needed.
--   {{ sharepoint_domain }}   -- download URLs sometimes redirect to the tenant's SharePoint domain
--   {{ keyvault_host }}       -- Key Vault holding the SharePoint connection

USE ROLE ACCOUNTADMIN;
USE DATABASE {{ database }};
USE SCHEMA {{ schema_raw }};

CREATE OR REPLACE NETWORK RULE SHAREPOINT_HR_PAYROLL_NETWORK_RULE
    MODE       = EGRESS
    TYPE       = HOST_PORT
    VALUE_LIST = (
        'graph.microsoft.com',
        'login.microsoftonline.com',
        'learnfabricsbi.sharepoint.com',
        'qimakv.vault.azure.net'
    );
