-- Stores the Azure AD client secret used by the ingestion notebook to authenticate
-- against the Microsoft Graph API (OAuth2 client-credentials flow).
--
-- GENERIC_STRING because we do the token exchange manually in Python (POST to the
-- /oauth2/v2.0/token endpoint with client_id + client_secret). Snowflake's built-in
-- OAUTH2 secret type is for the authorization-code flow, which doesn't apply here --
-- this is a headless service principal, not a user login.
--
-- Requires a role with CREATE SECRET on the target schema.

USE ROLE ACCOUNTADMIN;
USE DATABASE {{ database }};
USE SCHEMA {{ schema_raw }};

CREATE OR REPLACE SECRET SHAREPOINT_HR_PAYROLL_CLIENT_SECRET
    TYPE          = GENERIC_STRING
    SECRET_STRING = '{{ sharepoint_client_secret }}'
    COMMENT       = 'Azure AD client secret for the payroll SharePoint app registration.';
