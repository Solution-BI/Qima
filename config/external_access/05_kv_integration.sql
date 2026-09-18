USE ROLE ACCOUNTADMIN; 

CREATE SECURITY IF NOT EXISTS INTEGRATION AZURE_KV_SI
  TYPE = API_AUTHENTICATION
  AUTH_TYPE = WORKLOAD_IDENTITY_FEDERATION
  API_PROVIDER = AZURE_KEY_VAULT
  AZURE_TENANT_ID = {{ sharepoint_tenant_id }}          -- Entra tenant of the app and the vault
  AZURE_AD_APPLICATION_ID = {{ sharepoint_client_id }}  -- app Snowflake logs in as; needs Key Vault Secrets User on qimakv
  AZURE_KEY_VAULT_URI = {{ azure_key_vault }}             -- vault holding clientID, tenantID, clientSecret
  ENABLED = TRUE
COMMENT = 'Allows snowflake read secrets from Azure Key Vault (workload identity federation).'
;