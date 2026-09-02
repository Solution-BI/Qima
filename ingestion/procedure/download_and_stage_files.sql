CREATE OR REPLACE PROCEDURE SP_DOWNLOAD_AND_STAGE_FILES(
    P_CANDIDATES VARCHAR,
    P_STAGE_NAME VARCHAR
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
import os
import tempfile

GRAPH     = 'https://graph.microsoft.com/v1.0'
TENANT_ID = '77fc8d6c-15ec-4aea-9bd6-cf77b407a763'
CLIENT_ID = 'f1343367-3e3a-4ab0-8438-e72f261a6994'
TOKEN_URL = f'https://login.microsoftonline.com/{TENANT_ID}/oauth2/v2.0/token'
DRIVE_ID  = 'b!GNj7XKqd50OWdn5pzNvXoARxn4X2qgtNjNMwobxSGYOsH0CrHyfVRYKr4I5Z_tXk'


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


def main(session, p_candidates, p_stage_name) -> str:
    candidates = json.loads(p_candidates)
    if not candidates:
        return json.dumps({'status': 'skipped', 'message': 'No candidates', 'files': []})

    token = get_token()
    hdr = {'Authorization': f'Bearer {token}'}
    results = []
    tmp_dir = tempfile.mkdtemp(prefix='payroll_')

    try:
        for c in candidates:
            file_id   = c['id']
            file_name = c['name']
            status    = {'name': file_name, 'id': file_id}

            # Download file content from Graph API
            try:
                url = f'{GRAPH}/drives/{DRIVE_ID}/items/{file_id}/content'
                resp = requests.get(url, headers=hdr, timeout=120, stream=True)
                if resp.status_code != 200:
                    status['result'] = f'DOWNLOAD_FAILED (HTTP {resp.status_code})'
                    results.append(status)
                    continue

                local_path = os.path.join(tmp_dir, file_name)
                with open(local_path, 'wb') as f:
                    for chunk in resp.iter_content(chunk_size=1024 * 256):
                        f.write(chunk)
                status['downloaded_bytes'] = os.path.getsize(local_path)
            except Exception as e:
                status['result'] = f'DOWNLOAD_ERROR: {e}'
                results.append(status)
                continue

            # PUT file to stage using Snowpark file.put API
            try:
                stage_loc = f'@{p_stage_name}'
                session.file.put(
                    local_path,
                    stage_loc,
                    auto_compress=False,
                    overwrite=True
                )
                status['result'] = 'OK'
            except Exception as e:
                status['result'] = f'PUT_FAILED: {e}'

            results.append(status)
    finally:
        for f in os.listdir(tmp_dir):
            try:
                os.remove(os.path.join(tmp_dir, f))
            except OSError:
                pass
        try:
            os.rmdir(tmp_dir)
        except OSError:
            pass

    ok_count = sum(1 for r in results if r.get('result') == 'OK')
    return json.dumps({
        'status': 'done',
        'staged': ok_count,
        'total': len(candidates),
        'files': results
    }, default=str)
$$;