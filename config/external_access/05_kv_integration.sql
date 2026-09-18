-- AZURE_KV_INTEGRATION: lets Snowflake read secrets from Azure Key Vault without storing
-- any client secret in Snowflake (workload identity federation).
--
-- Snowflake gets its own identity (issuer + subject). The Entra app trusts that identity
-- through a federated credential, so Snowflake logs in as the app with no password.
-- The SharePoint credentials (clientID, tenantID, clientSecret) live only in Key Vault.
-- See ingestion/docs/plan_keyvault_wif_integration_2026-09-18.md.
--
-- Preview feature (Snowflake, Sep 2026). Confirm with Qima before production use.

USE ROLE ACCOUNTADMIN;   -- integrations are account-level; USE DATABASE/SCHEMA has no effect on them

-- Never CREATE OR REPLACE: it changes the subject and breaks the federated credential.
-- Change settings with ALTER SECURITY INTEGRATION instead.
CREATE SECURITY INTEGRATION AZURE_KV_INTEGRATION
  TYPE = API_AUTHENTICATION
  AUTH_TYPE = WORKLOAD_IDENTITY_FEDERATION
  API_PROVIDER = AZURE_KEY_VAULT
  AZURE_TENANT_ID = '77fc8d6c-15ec-4aea-9bd6-cf77b407a763'          -- Entra tenant of the app and the vault
  AZURE_AD_APPLICATION_ID = 'f1343367-3e3a-4ab0-8438-e72f261a6994'  -- app Snowflake logs in as; needs Key Vault Secrets User on qimakv
  AZURE_KEY_VAULT_URI = 'https://qimakv.vault.azure.net'             -- vault holding clientID, tenantID, clientSecret
  ENABLED = TRUE;

-- Copy WORKLOAD_IDENTITY_FEDERATION_ISSUER and WORKLOAD_IDENTITY_FEDERATION_SUBJECT into
-- Entra ID -> app -> Certificates & secrets -> Federated credentials -> Other issuer,
-- audience api://AzureADTokenExchange.
DESCRIBE SECURITY INTEGRATION AZURE_KV_INTEGRATION;

-- USAGE covers every secret the app can read in the vault (no per-secret privileges),
-- so grant it to the ingestion role only.
GRANT USAGE ON INTEGRATION AZURE_KV_INTEGRATION TO ROLE "SF_APA_SANDBOX-ETL";   -- double quotes: role name contains '-'

-- Check:
--   SHOW GRANTS ON INTEGRATION AZURE_KV_INTEGRATION;   -- [x] only the ingestion role has USAGE
