-- SP_INGEST_PAYROLL_FILES: main ingestion procedure for the payroll pipeline.
--
-- Does everything the notebook does in one CALL:
--   1. Authenticates to SharePoint via OAuth2 client credentials
--   2. Walks the payroll folder tree, finds candidates in the HWM time window
--   3. Downloads and stages each file (one at a time, not batch)
--   4. Inserts FILE_LOAD rows with real per-file transactions
--   5. Runs MERGE with PARSE_XLSX_TO_JSON UDF for extraction
--   6. Reconciles deleted files (IS_CURRENT = FALSE)
--   7. Returns a VARIANT run manifest
--
-- Scheduled via T_PAYROLL_INGEST task. See plan_stored_procedure_migration_2026-09-10.md.

USE DATABASE {{ database }};
USE SCHEMA {{ schema_raw }};

CREATE OR REPLACE PROCEDURE {{ database }}.{{ schema_raw }}.SP_INGEST_PAYROLL_FILES(
    OFFSET_MINUTES NUMBER DEFAULT 1
)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'requests')
HANDLER = 'run'
EXTERNAL_ACCESS_INTEGRATIONS = (SHAREPOINT_HR_PAYROLL_EAI)
SECRETS = ('cred' = {{ database }}.{{ schema_raw }}.SHAREPOINT_HR_PAYROLL_CLIENT_SECRET)
EXECUTE AS CALLER
AS $$
import io
import json
import uuid
import requests
from datetime import datetime, timezone
from urllib.parse import quote
import _snowflake

# ── SharePoint constants ──────────────────────────────────────────────

TENANT_ID   = '{{ sharepoint_tenant_id }}'
CLIENT_ID   = '{{ sharepoint_client_id }}'
SITE_ID     = '{{ sharepoint_site_id }}'
DRIVE_ID    = '{{ sharepoint_drive_id }}'
FOLDER_PATH = '{{ sharepoint_folder_path }}'

GRAPH       = 'https://graph.microsoft.com/v1.0'
TOKEN_URL   = f'https://login.microsoftonline.com/{TENANT_ID}/oauth2/v2.0/token'
STAGE_NAME  = '{{ database }}.{{ schema_raw }}.TEMP_PAYROLL_STAGE'


# ── Auth ──────────────────────────────────────────────────────────────
def get_token():
    secret = _snowflake.get_generic_secret_string('cred')
    resp = requests.post(TOKEN_URL, data={
        'client_id':     CLIENT_ID,
        'client_secret': secret,
        'scope':         'https://graph.microsoft.com/.default',
        'grant_type':    'client_credentials',
    }, timeout=30)
    if resp.status_code != 200:
        raise RuntimeError(f'Token request failed: HTTP {resp.status_code}')
    return resp.json()['access_token']


# ── Graph helpers ─────────────────────────────────────────────────────
def list_children(url, hdr):
    items = []
    while url:
        r = requests.get(url, headers=hdr, timeout=60)
        if r.status_code != 200:
            raise RuntimeError(f'Graph list failed: HTTP {r.status_code} - {r.text[:300]}')
        data = r.json()
        items.extend(data.get('value', []))
        url = data.get('@odata.nextLink')
    return items


def walk_folder(folder_id, hdr, depth=0, max_depth=5):
    if depth > max_depth:
        return []
    files = []
    for item in list_children(f'{GRAPH}/drives/{DRIVE_ID}/items/{folder_id}/children', hdr):
        if 'folder' in item:
            files.extend(walk_folder(item['id'], hdr, depth + 1, max_depth))
        else:
            files.append(item)
    return files


def list_candidates(session, all_files, offset_minutes):
    row = session.sql("""
        SELECT COALESCE(
            MAX(INGESTED_AT),
            '2024-01-01'::TIMESTAMP_TZ
        ) AS HWM
        FROM {{ database }}.{{ schema_raw }}.FILE_LOAD
        WHERE INGEST_STATUS = 'SUCCESS'
    """).collect()
    from_ts = row[0]['HWM']
    to_ts = session.sql(f"""
        SELECT TIMESTAMPADD('MINUTE', -{offset_minutes}, CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP()))
    """).collect()[0][0]

    matched = []
    for item in all_files:
        mod = datetime.fromisoformat(item['lastModifiedDateTime'].replace('Z', '+00:00'))
        if from_ts < mod < to_ts:
            is_supported = item.get('name', '').endswith('.xlsx')
            matched.append({
                'id':          item['id'],
                'name':        item['name'],
                'path':        item.get('parentReference', {}).get('path', ''),
                'modified_at': item['lastModifiedDateTime'],
                'modified_by': item.get('lastModifiedBy', {}).get('user', {}).get('displayName'),
                'created_at':  item.get('createdDateTime'),
                'created_by':  item.get('createdBy', {}).get('user', {}).get('displayName'),
                'size_bytes':  item.get('size'),
                'supported':   is_supported,
            })
    return matched, from_ts, to_ts


# ── Main entry point ─────────────────────────────────────────────────
def run(session, offset_minutes):
    run_id = str(uuid.uuid4())
    file_results = []

    # 1. Auth
    hdr = {'Authorization': f'Bearer {get_token()}'}

    # 2. Walk SharePoint and find candidates
    folder = quote(FOLDER_PATH, safe='/')
    r = requests.get(f'{GRAPH}/sites/{SITE_ID}/drives/{DRIVE_ID}/root:/{folder}',
                     headers=hdr, timeout=60)
    if r.status_code != 200:
        return {'run_id': run_id, 'error': f'Folder lookup failed: HTTP {r.status_code}'}

    all_files = walk_folder(r.json()['id'], hdr)
    candidates, from_ts, to_ts = list_candidates(session, all_files, offset_minutes)

    # 3. Stage setup.
    # CREATE TEMPORARY STAGE is rejected inside a stored procedure
    # ("Unsupported statement type 'temporary STAGE'"), so this is a regular
    # stage dropped in the finally block below. Same retention guarantee,
    # enforced by code rather than by Snowflake's session scoping.
    # The leading DROP clears an orphan left by a prior run that died before
    # reaching its finally block.
    session.sql(f"DROP STAGE IF EXISTS {STAGE_NAME}").collect()
    session.sql(f"CREATE STAGE {STAGE_NAME}").collect()

    staged_count = 0
    failed_count = 0

    try:
        # 4. Per-file: download -> PUT -> INSERT (with real transactions)
        for c in candidates:
            file_result = {
                'id': c['id'],
                'name': c['name'],
                'ingest_status': None,
                'extract_status': 'NOT_ATTEMPTED',
                'error': None,
            }

            # Determine ingest status before DB operations
            if not c.get('supported', True):
                file_result['ingest_status'] = 'FAILED'
                file_result['error'] = f"Unsupported file format: {c['name'].rsplit('.', 1)[-1].upper()}. Only .xlsx files are accepted."
                # Still insert a FILE_LOAD row for audit trail
                _insert_file_load(session, run_id, c, file_result)
                failed_count += 1
                file_results.append(file_result)
                continue

            # Download
            try:
                dl = requests.get(f"{GRAPH}/drives/{DRIVE_ID}/items/{c['id']}/content",
                                  headers=hdr, timeout=120)
                if dl.status_code != 200:
                    raise RuntimeError(f'HTTP {dl.status_code}')
            except Exception as e:
                file_result['ingest_status'] = 'FAILED'
                file_result['error'] = f'Download failed: {e}'
                _insert_file_load(session, run_id, c, file_result)
                failed_count += 1
                file_results.append(file_result)
                continue

            # PUT to stage
            try:
                stage_filename = f"{c['id']}.xlsx"
                session.file.put_stream(
                    io.BytesIO(dl.content),
                    f"@{STAGE_NAME}/{stage_filename}",
                    auto_compress=False,
                    overwrite=True,
                )
            except Exception as e:
                file_result['ingest_status'] = 'FAILED'
                file_result['error'] = f'Stage PUT failed: {e}'
                _insert_file_load(session, run_id, c, file_result)
                failed_count += 1
                file_results.append(file_result)
                continue

            # INSERT with real transaction (fixes the rollback bug in the notebook)
            file_result['ingest_status'] = 'SUCCESS'
            try:
                session.sql("BEGIN").collect()

                session.sql("""
                    UPDATE {{ database }}.{{ schema_raw }}.FILE_LOAD SET IS_CURRENT = FALSE
                    WHERE SHAREPOINT_ITEM_ID = :1 AND IS_CURRENT = TRUE
                """, params=[c['id']]).collect()

                session.sql("""
                    INSERT INTO {{ database }}.{{ schema_raw }}.FILE_LOAD (
                        RUN_ID, FILE_NAME, FILE_PATH, SHAREPOINT_ITEM_ID,
                        SHAREPOINT_MODIFIED_AT, SHAREPOINT_MODIFIED_BY,
                        SHAREPOINT_CREATED_AT, SHAREPOINT_CREATED_BY,
                        FILE_SIZE_BYTES, INGESTED_AT, INGEST_STATUS,
                        ERROR_MESSAGE, IS_CURRENT
                    )
                    SELECT :1, :2, :3, :4, :5, :6, :7, :8, :9,
                           CURRENT_TIMESTAMP(), :10, :11, TRUE
                """, params=[
                    run_id,
                    c['name'],
                    c.get('path'),
                    c['id'],
                    c['modified_at'],
                    c.get('modified_by'),
                    c.get('created_at'),
                    c.get('created_by'),
                    c.get('size_bytes'),
                    file_result['ingest_status'],
                    file_result['error'],
                ]).collect()

                session.sql("COMMIT").collect()
                staged_count += 1
            except Exception as e:
                session.sql("ROLLBACK").collect()
                file_result['ingest_status'] = 'FAILED'
                file_result['error'] = f'INSERT failed: {e}'
                failed_count += 1

            file_results.append(file_result)

        # 5. Extraction via MERGE with PARSE_XLSX_TO_JSON UDF
        try:
            session.sql(f"""
                MERGE INTO {{ database }}.{{ schema_raw }}.FILE_LOAD t
                USING (
                    SELECT LOAD_ID,
                           {{ database }}.{{ schema_raw }}.PARSE_XLSX_TO_JSON(
                               BUILD_SCOPED_FILE_URL(@{STAGE_NAME}, SHAREPOINT_ITEM_ID || '.xlsx')
                           ) AS PARSED
                    FROM {{ database }}.{{ schema_raw }}.FILE_LOAD
                    WHERE RUN_ID = :1
                      AND INGEST_STATUS  = 'SUCCESS'
                      AND EXTRACT_STATUS = 'NOT_ATTEMPTED'
                ) s ON t.LOAD_ID = s.LOAD_ID
                WHEN MATCHED THEN UPDATE SET
                    t.RAW_CONTENT    = IFF(s.PARSED:"_error" IS NULL, s.PARSED, NULL),
                    t.EXTRACT_STATUS = IFF(s.PARSED:"_error" IS NULL, 'SUCCESS', 'FAILED'),
                    t.EXTRACTED_AT   = CURRENT_TIMESTAMP(),
                    t.ERROR_MESSAGE  = s.PARSED:"_error"::VARCHAR
            """, params=[run_id]).collect()
        except Exception as e:
            # MERGE failure is non-fatal to the run -- files are still ingested
            for fr in file_results:
                if fr['ingest_status'] == 'SUCCESS':
                    fr['extract_status'] = 'MERGE_FAILED'
                    fr['error'] = str(e)

        # 6. Reconciliation -- flag deleted files as IS_CURRENT = FALSE
        sharepoint_ids = {item['id'] for item in all_files}
        current_rows = session.sql("""
            SELECT LOAD_ID, SHAREPOINT_ITEM_ID
            FROM {{ database }}.{{ schema_raw }}.FILE_LOAD
            WHERE IS_CURRENT = TRUE
              AND SHAREPOINT_ITEM_ID IS NOT NULL
        """).collect()

        deleted_count = 0
        for row in current_rows:
            if row['SHAREPOINT_ITEM_ID'] not in sharepoint_ids:
                session.sql("""
                    UPDATE {{ database }}.{{ schema_raw }}.FILE_LOAD SET IS_CURRENT = FALSE
                    WHERE LOAD_ID = :1
                """, params=[row['LOAD_ID']]).collect()
                deleted_count += 1

    finally:
        # 7. Drop stage -- the retention guarantee
        session.sql(f"DROP STAGE IF EXISTS {STAGE_NAME}").collect()

    # 8. Build return manifest from what FILE_LOAD actually recorded
    extract_rows = session.sql("""
        SELECT LOAD_ID, FILE_NAME, SHAREPOINT_ITEM_ID,
               INGEST_STATUS, EXTRACT_STATUS, ERROR_MESSAGE
        FROM {{ database }}.{{ schema_raw }}.FILE_LOAD
        WHERE RUN_ID = :1
    """, params=[run_id]).collect()

    manifest_files = []
    for row in extract_rows:
        manifest_files.append({
            'id':             row['SHAREPOINT_ITEM_ID'],
            'name':           row['FILE_NAME'],
            'ingest_status':  row['INGEST_STATUS'],
            'extract_status': row['EXTRACT_STATUS'],
            'error':          row['ERROR_MESSAGE'],
        })

    extracted_count = sum(1 for f in manifest_files if f['extract_status'] == 'SUCCESS')

    return {
        'run_id':     run_id,
        'from_ts':    str(from_ts),
        'to_ts':      str(to_ts),
        'candidates': len(candidates),
        'staged':     staged_count,
        'extracted':  extracted_count,
        'failed':     failed_count,
        'deleted':    deleted_count,
        'files':      manifest_files,
    }


def _insert_file_load(session, run_id, candidate, result):
    """Insert a FILE_LOAD row for a file that failed before staging (unsupported format, download error)."""
    session.sql("""
        INSERT INTO {{ database }}.{{ schema_raw }}.FILE_LOAD (
            RUN_ID, FILE_NAME, FILE_PATH, SHAREPOINT_ITEM_ID,
            SHAREPOINT_MODIFIED_AT, SHAREPOINT_MODIFIED_BY,
            SHAREPOINT_CREATED_AT, SHAREPOINT_CREATED_BY,
            FILE_SIZE_BYTES, INGESTED_AT, INGEST_STATUS,
            ERROR_MESSAGE, IS_CURRENT
        )
        SELECT :1, :2, :3, :4, :5, :6, :7, :8, :9,
               CURRENT_TIMESTAMP(), :10, :11, FALSE
    """, params=[
        run_id,
        candidate['name'],
        candidate.get('path'),
        candidate['id'],
        candidate['modified_at'],
        candidate.get('modified_by'),
        candidate.get('created_at'),
        candidate.get('created_by'),
        candidate.get('size_bytes'),
        result['ingest_status'],
        result['error'],
    ]).collect()
$$;

-- Deploying this file only creates the procedure. To run it manually:
--   CALL {{ database }}.{{ schema_raw }}.SP_INGEST_PAYROLL_FILES(1);