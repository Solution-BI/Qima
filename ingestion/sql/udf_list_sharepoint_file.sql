-- LIST_SHAREPOINT_FILES: every file under the payroll folder as a VARIANT array.
--
-- Walks all subfolders (each subsidiary files into its own, up to 5 levels deep)
-- and returns a VARIANT array of objects with SharePoint metadata named after the
-- FILE_LOAD columns. Returns every file, not a time window: the caller filters,
-- and SP_INGEST_PAYROLL_FILES needs the full list to detect deleted files.
--
-- Deploy with the target database and schema set as the session context.
--
-- Usage:
--   SELECT LIST_SHAREPOINT_FILES('<tenant_id>', '<client_id>', '<drive_id>', '<folder_path>');
--   -- Returns: [{"SHAREPOINT_ITEM_ID": "...", "FILE_NAME": "...", ...}, ...]

USE DATABASE SANDBOX_DB;
USE SCHEMA HR_PAYROLL_QIMA;

CREATE OR REPLACE FUNCTION LIST_SHAREPOINT_FILES(
    TENANT_ID   VARCHAR,
    CLIENT_ID   VARCHAR,
    DRIVE_ID    VARCHAR,
    FOLDER_PATH VARCHAR
)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('requests')
HANDLER = 'run'
EXTERNAL_ACCESS_INTEGRATIONS = (SHAREPOINT_HR_PAYROLL_EAI)
SECRETS = ('cred' = SHAREPOINT_HR_PAYROLL_CLIENT_SECRET)
AS $$
import requests
import _snowflake
from urllib.parse import quote

# DECLARE
GRAPH      = 'https://graph.microsoft.com/v1.0'
TOKEN_BASE = 'https://login.microsoftonline.com'
SCOPE      = 'https://graph.microsoft.com/.default'
MAX_DEPTH  = 5


def run(tenant_id, client_id, drive_id, folder_path):
    # ==========================================================================
    # STEP 1: Request OAuth2 token via client credentials grant
    # ==========================================================================
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
    if resp.status_code != 200:
        raise RuntimeError(f'Token request failed: HTTP {resp.status_code}')
    hdr = {'Authorization': f"Bearer {resp.json()['access_token']}"}

    # ==========================================================================
    # STEP 2: Walk the folder tree, following pagination
    # ==========================================================================
    files = []
    folders = [(f"{GRAPH}/drives/{drive_id}/root:/{quote(folder_path, safe='/')}:/children", 0)]
    while folders:
        url, depth = folders.pop()
        while url:
            r = requests.get(url, headers=hdr, timeout=60)
            if r.status_code != 200:
                raise RuntimeError(f'Graph list failed: HTTP {r.status_code} - {r.text[:300]}')
            data = r.json()
            for item in data.get('value', []):
                if 'folder' in item:
                    if depth < MAX_DEPTH:
                        folders.append((f"{GRAPH}/drives/{drive_id}/items/{item['id']}/children", depth + 1))
                    continue

                # ==============================================================
                # STEP 3: Collect file metadata into the result array
                # ==============================================================
                created = item.get('createdDateTime')
                files.append({
                    'SHAREPOINT_ITEM_ID':     item['id'],
                    'FILE_NAME':              item['name'],
                    'FILE_PATH':              item.get('parentReference', {}).get('path', ''),
                    'FILE_SIZE_BYTES':        item.get('size'),
                    'SHAREPOINT_MODIFIED_AT': item['lastModifiedDateTime'],
                    'SHAREPOINT_MODIFIED_BY': item.get('lastModifiedBy', {}).get('user', {}).get('displayName'),
                    'SHAREPOINT_CREATED_AT':  created,
                    'SHAREPOINT_CREATED_BY':  item.get('createdBy', {}).get('user', {}).get('displayName'),
                })
            url = data.get('@odata.nextLink')

    return files
$$;
