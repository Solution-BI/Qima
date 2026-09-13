USE DATABASE SANDBOX_DB;
USE SCHEMA HR_PAYROLL_QIMA;

CREATE OR REPLACE PROCEDURE SP_CONNECT_SHAREPOINT(
    TENANT_ID   VARCHAR,
    CLIENT_ID   VARCHAR,
    SITE_ID     VARCHAR,
    DRIVE_ID    VARCHAR,
    FOLDER_PATH VARCHAR
)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'requests')
HANDLER = 'run'
EXTERNAL_ACCESS_INTEGRATIONS = (SHAREPOINT_HR_PAYROLL_EAI)
SECRETS = ('cred' = SHAREPOINT_HR_PAYROLL_CLIENT_SECRET)
EXECUTE AS CALLER
AS $$
import requests
import _snowflake

# ── Constants ────────────────────────────────────────────────────────

TOKEN_BASE = 'https://login.microsoftonline.com'
SCOPE      = 'https://graph.microsoft.com/.default'


# ── Main entry point ─────────────────────────────────────────────────
def run(session, tenant_id, client_id, site_id, drive_id, folder_path):
    # 1. Request OAuth2 token via client credentials grant
    resp = requests.post(
        f'{TOKEN_BASE}/{tenant_id}/oauth2/v2.0/token',
        data={
            'client_id':     client_id,
            'client_secret': _snowflake.get_generic_secret_string('cred'),
            'scope':         SCOPE,
            'grant_type':    'client_credentials',
        },
        timeout=30,
    )

    # 2. Validate response
    if resp.status_code != 200:
        raise RuntimeError(f'Token request failed: HTTP {resp.status_code}')

    # 3. Return connection bundle
    return {
        'access_token': resp.json()['access_token'],
        'site_id':      site_id,
        'drive_id':     drive_id,
        'folder_path':  folder_path,
    }
$$;

CALL SP_CONNECT_SHAREPOINT(
'77fc8d6c-15ec-4aea-9bd6-cf77b407a763',
'f1343367-3e3a-4ab0-8438-e72f261a6994', 
'learnfabricsbi.sharepoint.com,5cfbd818-9daa-43e7-9676-7e69ccdbd7a0,859f7104-aaf6-4d0b-8cd3-30a1bc521983',
'b!GNj7XKqd50OWdn5pzNvXoARxn4X2qgtNjNMwobxSGYOsH0CrHyfVRYKr4I5Z_tXk',
'Payroll files'
)