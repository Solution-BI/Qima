USE DATABASE SANDBOX_DB;
USE SCHEMA HR_PAYROLL_QIMA;


CREATE OR REPLACE PROCEDURE SP_LIST_SHAREPOINT_FILES(
    P_FROM_TS TIMESTAMP_TZ,
    P_TO_TS   TIMESTAMP_TZ
)
RETURNS VARCHAR
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'requests')
HANDLER = 'main'
EXTERNAL_ACCESS_INTEGRATIONS = (SHAREPOINT_HR_PAYROLL_EAI)
SECRETS = ('sharepoint_cred' = SHAREPOINT_HR_PAYROLL_CLIENT_SECRET)
EXECUTE AS OWNER
AS
$$
import _snowflake
import requests
import json
from urllib.parse import quote
from datetime import datetime, timezone

GRAPH       = 'https://graph.microsoft.com/v1.0'
TENANT_ID   = '77fc8d6c-15ec-4aea-9bd6-cf77b407a763'
CLIENT_ID   = 'f1343367-3e3a-4ab0-8438-e72f261a6994'
TOKEN_URL   = f'https://login.microsoftonline.com/{TENANT_ID}/oauth2/v2.0/token'

SITE_ID     = 'learnfabricsbi.sharepoint.com,5cfbd818-9daa-43e7-9676-7e69ccdbd7a0,859f7104-aaf6-4d0b-8cd3-30a1bc521983'
DRIVE_ID    = 'b!GNj7XKqd50OWdn5pzNvXoARxn4X2qgtNjNMwobxSGYOsH0CrHyfVRYKr4I5Z_tXk'
FOLDER_PATH = 'Payroll files'


def get_token() -> str:
    secret = _snowflake.get_generic_secret_string('sharepoint_cred')
    resp = requests.post(TOKEN_URL, data={
        'client_id':     CLIENT_ID,
        'client_secret': secret,
        'scope':         'https://graph.microsoft.com/.default',
        'grant_type':    'client_credentials',
    }, timeout=30)
    if resp.status_code != 200:
        raise RuntimeError(f'Token request failed: HTTP {resp.status_code}')
    return resp.json()['access_token']


def list_children(url, hdr):
    items = []
    while url:
        r = requests.get(url, headers=hdr, timeout=60)
        if r.status_code != 200:
            raise RuntimeError(f'Graph list failed: HTTP {r.status_code} — {r.text[:300]}')
        data = r.json()
        items.extend(data.get('value', []))
        url = data.get('@odata.nextLink')
    return items


def walk_folder(folder_id, hdr, depth=0, max_depth=5):
    if depth > max_depth:
        return []
    url = f'{GRAPH}/drives/{DRIVE_ID}/items/{folder_id}/children'
    items = list_children(url, hdr)
    files = []
    for item in items:
        if 'folder' in item:
            files.extend(walk_folder(item['id'], hdr, depth + 1, max_depth))
        else:
            files.append(item)
    return files


def main(session, p_from_ts, p_to_ts) -> str:
    token = get_token()
    hdr = {'Authorization': f'Bearer {token}'}

    from_ts = p_from_ts.replace(tzinfo=timezone.utc) if p_from_ts.tzinfo is None else p_from_ts
    to_ts   = p_to_ts.replace(tzinfo=timezone.utc)   if p_to_ts.tzinfo is None   else p_to_ts

    folder = quote(FOLDER_PATH, safe='/')
    url = f'{GRAPH}/sites/{SITE_ID}/drives/{DRIVE_ID}/root:/{folder}'
    r = requests.get(url, headers=hdr, timeout=60)
    if r.status_code != 200:
        raise RuntimeError(f'Folder lookup failed: HTTP {r.status_code} — {r.text[:300]}')
    root_folder_id = r.json()['id']

    all_files = walk_folder(root_folder_id, hdr)

    candidates = []
    for item in all_files:
        if not item.get('name', '').endswith('.xlsx'):
            continue
        mod_str = item.get('lastModifiedDateTime', '')
        mod = datetime.fromisoformat(mod_str.replace('Z', '+00:00'))
        if from_ts <= mod < to_ts:
            candidates.append({
                'id':          item['id'],
                'name':        item['name'],
                'path':        item.get('parentReference', {}).get('path', ''),
                'modified_at': mod_str,
                'size_bytes':  item.get('size'),
            })

    return json.dumps(candidates, default=str)
$$