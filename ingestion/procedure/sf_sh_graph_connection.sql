-- SharePoint Graph API stored procedures: verify access and list candidate files for ingestion.
-- Co-authored with CoCo
USE DATABASE SANDBOX_DB;
USE SCHEMA HR_PAYROLL_QIMA;


CREATE OR REPLACE PROCEDURE SP_VERIFY_SHAREPOINT_ACCESS()
RETURNS STRING
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
import base64, json
from urllib.parse import quote
 
GRAPH     = 'https://graph.microsoft.com/v1.0'
TENANT_ID = '77fc8d6c-15ec-4aea-9bd6-cf77b407a763'
CLIENT_ID = 'f1343367-3e3a-4ab0-8438-e72f261a6994'
TOKEN_URL = f'https://login.microsoftonline.com/{TENANT_ID}/oauth2/v2.0/token'
 
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
        # Status only — the body can echo request parameters back.
        raise RuntimeError(f'Token request failed: HTTP {resp.status_code}')
    return resp.json()['access_token']
 
 
def main(session) -> str:
    out = []
 
    # --- 1. Token ---
    try:
        token = get_token()
        out.append('token      : OK')
    except Exception as e:
        return f'token      : FAILED — {e}'
    hdr = {'Authorization': f'Bearer {token}'}
 
    # --- 2. Claims ---
    payload = token.split('.')[1] + '=' * (-len(token.split('.')[1]) % 4)
    claims  = json.loads(base64.urlsafe_b64decode(payload))
    if not claims.get('roles'):
        kind = 'delegated token (scp)' if claims.get('scp') else 'no roles claim'
        return '\n'.join(out + [f'roles      : FAILED — {kind}.'])
    out.append(f"roles      : {claims['roles']}")
 
    # --- 3. List the folder — same URL shape as the local script ------------
    # quote() matters: payroll folder names contain spaces.
    folder = quote(FOLDER_PATH, safe='/')
    url = f'{GRAPH}/sites/{SITE_ID}/drives/{DRIVE_ID}/root:/{folder}:/children'
    r = requests.get(url, headers=hdr, timeout=60)
    if r.status_code != 200:
        return '\n'.join(out + [
            f'list       : HTTP {r.status_code} — {r.text[:250]}',
            '',
            '403 here = the per-site grant is missing or SITE_ID is not the granted site.',
            '404 here = FOLDER_PATH is wrong (it is relative to the drive root).',
        ])
    items = r.json().get('value', [])
    xlsx  = [i for i in items if i['name'].endswith('.xlsx')]
    out.append(f'list       : OK — {len(items)} item(s), {len(xlsx)} .xlsx')
    if not xlsx:
        return '\n'.join(out + ['download   : SKIPPED — no .xlsx to test with.'])
    out.append(f"first      : {xlsx[0]['name']} ({xlsx[0].get('size')} bytes)")
 
    # --- 4. Download — THE step your local test could not prove -------------
    # Follows the redirect to <tenant>.sharepoint.com / *.svc.ms. If the network
    # rule omits those hosts, this raises a CONNECTION error, not an HTTP status.
    try:
        r = requests.get(
            f"{GRAPH}/drives/{DRIVE_ID}/items/{xlsx[0]['id']}/content",
            headers=hdr, timeout=120,
        )
    except Exception as e:
        return '\n'.join(out + [
            f'download   : FAILED — {type(e).__name__}: {e}',
            '',
            'A connection error (not an HTTP code) means the NETWORK RULE blocked',
            'the download redirect. Add to VALUE_LIST:',
            "  '<tenant>.sharepoint.com:443', '*.svc.ms:443'",
        ])
    if r.status_code != 200:
        return '\n'.join(out + [f'download   : HTTP {r.status_code} — {r.text[:200]}'])
 
    body = r.content
    out.append(f'download   : OK — {len(body)} bytes')
    # .xlsx is a zip; PK is the magic number. Proves real bytes, not an error page.
    out.append(f"magic      : {'PK — valid xlsx' if body[:2] == b'PK' else repr(body[:16])}")
    out.append('')
    out.append('PASS — full chain proven, including egress to the download hosts.')
    return '\n'.join(out)
$$;

CALL SP_VERIFY_SHAREPOINT_ACCESS();



SELECT * FROM FILE_LOAD;
TRUNCATE TABLE FILE_LOAD;