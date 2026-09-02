# Plan: SharePoint External Access Integration

## Context

The ingestion notebook (cells 4-5) needs to call the Microsoft Graph API to list and download payroll files from SharePoint. This requires a Snowflake External Access Integration, which is composed of three objects: a network rule, a secret, and the integration itself.

Per the Snowflake docs, the chain is:
1. **Network Rule** -- whitelists the external hosts (EGRESS)
2. **Secret** -- holds the Azure AD client secret for OAuth2 client-credentials flow
3. **External Access Integration** -- aggregates the rule + secret into a reusable reference that procedures/notebooks can use

## Objects to create

All SQL files go under `config/external_access/`, numbered for execution order. All use Jinja-style `{{ var }}` placeholders that map to the environment YAML configs.

### 1. Environment config updates

Add to each of `config/environments/{sandbox,dev,prod}.yml`:

```yaml
# SharePoint / Microsoft Graph API credentials
sharepoint_tenant_id: TBD          # Azure AD tenant ID
sharepoint_client_id: TBD          # App registration client ID
sharepoint_client_secret: TBD      # App registration client secret
sharepoint_domain: qima.sharepoint.com
```

Database name updated from `TBD` to `PAYROLL_DB`.

### 2. Network Rule (`01_network_rule.sql`)

```sql
CREATE OR REPLACE NETWORK RULE PAYROLL_DB.RAW.SHAREPOINT_NETWORK_RULE
    MODE  = EGRESS
    TYPE  = HOST_PORT
    VALUE_LIST = (
        'graph.microsoft.com',
        'login.microsoftonline.com',
        '{{ sharepoint_domain }}'
    );
```

Three hosts needed:
- `graph.microsoft.com` -- the Graph API for listing/downloading files
- `login.microsoftonline.com` -- Azure AD token endpoint (OAuth2 client-credentials grant)
- `qima.sharepoint.com` -- download URLs sometimes redirect to the SharePoint domain directly

### 3. Secret (`02_secret.sql`)

```sql
CREATE OR REPLACE SECRET PAYROLL_DB.RAW.SHAREPOINT_CLIENT_SECRET
    TYPE          = GENERIC_STRING
    SECRET_STRING = '{{ sharepoint_client_secret }}';
```

Using `GENERIC_STRING` because we're doing a manual OAuth2 client-credentials flow in Python (POST to the token endpoint with client_id + client_secret), not Snowflake's built-in OAuth2 integration (which requires a security integration for the authorization-code flow -- not applicable here since this is a headless service principal, not a user login).

### 4. External Access Integration (`03_external_access_integration.sql`)

```sql
CREATE OR REPLACE EXTERNAL ACCESS INTEGRATION SHAREPOINT_PAYROLL_EAI
    ALLOWED_NETWORK_RULES            = (PAYROLL_DB.RAW.SHAREPOINT_NETWORK_RULE)
    ALLOWED_AUTHENTICATION_SECRETS   = (PAYROLL_DB.RAW.SHAREPOINT_CLIENT_SECRET)
    ENABLED = TRUE
    COMMENT = 'Allows the payroll ingestion notebook to call Microsoft Graph API for SharePoint file listing and download.';
```

This is an account-level object (integrations are not schema-scoped). Requires `ACCOUNTADMIN` or a role with `CREATE INTEGRATION`.

### 5. RBAC grants (`04_grants.sql`)

Following the RBAC convention from `CLAUDE.md` (F_PAYROLL_DBA owns the domain):

```sql
GRANT USAGE ON INTEGRATION SHAREPOINT_PAYROLL_EAI TO ROLE F_PAYROLL_DBA;
GRANT READ ON SECRET PAYROLL_DB.RAW.SHAREPOINT_CLIENT_SECRET TO ROLE F_PAYROLL_DBA;
GRANT USAGE ON NETWORK RULE PAYROLL_DB.RAW.SHAREPOINT_NETWORK_RULE TO ROLE F_PAYROLL_DBA;
```

### 6. Notebook skeleton update

Update cells 4-5 comments to reference `SHAREPOINT_PAYROLL_EAI` and `SHAREPOINT_CLIENT_SECRET` by name so the dependency is explicit.

## Execution notes

- Steps 1-4 must be run by `ACCOUNTADMIN` (or a role with `CREATE INTEGRATION`).
- Step 5 must be run by a role that can grant on the integration (typically `ACCOUNTADMIN` or `SECURITYADMIN`).
- The `{{ }}` placeholders are for documentation clarity -- the actual values come from the environment configs when deploying.

## What this does NOT do

- Does not write the Python handler code for cells 4-5 (that's a separate task once the EAI exists and can be tested).
- Does not create the `RAW.FILE_LOAD` table (separate from this task).
- Does not register the Azure AD app in Entra ID -- that's Qima's action item on the Azure side.
