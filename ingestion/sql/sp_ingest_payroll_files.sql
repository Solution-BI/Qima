-- SP_INGEST_PAYROLL_FILES: loads payroll .xlsx files from SharePoint into FILE_LOAD.
--
-- Follows the QIMA ETL framework (watermark, clear, insert, duplicate check,
-- COMMIT or ROLLBACK). Python instead of LANGUAGE SQL because the SharePoint
-- download and stage PUT need external access.
--
-- Holds no environment values: database, schema and SharePoint identifiers are
-- passed in by the caller (T_PAYROLL_INGEST, defined in deploy_<env>.sql).
-- Deploy with the target database and schema set as the session context.
-- Depends on SP_CONNECT_SHAREPOINT, LIST_SHAREPOINT_FILES and PARSE_XLSX_TO_JSON.

CREATE OR REPLACE PROCEDURE SP_INGEST_PAYROLL_FILES(
    DATABASE_NAME  VARCHAR,
    SCHEMA_NAME    VARCHAR,
    TENANT_ID      VARCHAR,
    CLIENT_ID      VARCHAR,
    SITE_ID        VARCHAR,
    DRIVE_ID       VARCHAR,
    FOLDER_PATH    VARCHAR,
    OFFSET_MINUTES NUMBER DEFAULT 1
)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'requests')
HANDLER = 'run'
EXTERNAL_ACCESS_INTEGRATIONS = (SHAREPOINT_HR_PAYROLL_EAI)
EXECUTE AS CALLER
AS $$
import io
import json
import uuid
import requests

# DECLARE
GRAPH            = 'https://graph.microsoft.com/v1.0'
DATA_DUPLICATION = '-20001: Duplicate records detected in FILE_LOAD on keys: SHAREPOINT_ITEM_ID (IS_CURRENT = TRUE)'


def run(session, database_name, schema_name, tenant_id, client_id, site_id, drive_id, folder_path, offset_minutes):
    run_id = str(uuid.uuid4())
    schema = f'{database_name}.{schema_name}'
    target = f'{schema}.FILE_LOAD'
    stage  = f'{schema}.TEMP_PAYROLL_STAGE'
    insert_file_load = f"""
        INSERT INTO {target} (
            RUN_ID, FILE_NAME, FILE_PATH, SHAREPOINT_ITEM_ID,
            SHAREPOINT_MODIFIED_AT, SHAREPOINT_MODIFIED_BY,
            SHAREPOINT_CREATED_AT, SHAREPOINT_CREATED_BY,
            FILE_SIZE_BYTES, INGESTED_AT, INGEST_STATUS,
            ERROR_MESSAGE, IS_CURRENT
        )
        SELECT :1, :2, :3, :4, :5, :6, :7, :8, :9,
               CURRENT_TIMESTAMP(), :10, :11, :12::BOOLEAN
    """

    try:
        # ==========================================================================
        # STEP 1: Connect to SharePoint
        # Authenticates via OAuth2 client credentials and returns a bearer token.
        # Delegated to SP_CONNECT_SHAREPOINT so this procedure never touches
        # the client secret directly (secret binding lives there, not here).
        # ==========================================================================
        creds = session.sql(
            f'CALL {schema}.SP_CONNECT_SHAREPOINT(:1, :2, :3, :4, :5)',
            params=[tenant_id, client_id, site_id, drive_id, folder_path],
        ).collect()[0][0]
        if isinstance(creds, str):
            creds = json.loads(creds)
        if isinstance(creds, str):
            creds = json.loads(creds)
        hdr = {'Authorization': f"Bearer {creds['access_token']}"}

        # ==========================================================================
        # STEP 2: Collect candidate files modified since the watermark
        # LIST_SHAREPOINT_FILES walks the full folder tree and returns every
        # file. We then read the high-water mark (HWM) from FILE_LOAD -- the
        # most recent successful INGESTED_AT -- and keep only files modified
        # between HWM and (now - OFFSET_MINUTES). The offset prevents ingesting
        # a file that is still being written to on SharePoint.
        # ==========================================================================
        all_files = [row.as_dict() for row in session.sql(
            f'SELECT * FROM TABLE({schema}.LIST_SHAREPOINT_FILES(:1, :2, :3, :4))',
            params=[tenant_id, client_id, drive_id, folder_path],
        ).collect()]
        from_ts, to_ts = session.sql(f"""
            SELECT COALESCE(MAX(INGESTED_AT), '2024-01-01'::TIMESTAMP_TZ),
                   TIMESTAMPADD('MINUTE', -{int(offset_minutes)}, CONVERT_TIMEZONE('UTC', CURRENT_TIMESTAMP()))
            FROM {target}
            WHERE INGEST_STATUS = 'SUCCESS'
        """).collect()[0]
        candidates = [item for item in all_files if from_ts < item['SHAREPOINT_MODIFIED_AT'] < to_ts]

        # ==========================================================================
        # STEP 3: Prepare stage
        # Creates a transient stage to hold downloaded .xlsx files until they
        # are parsed by PARSE_XLSX_TO_JSON in Step 8. The stage is dropped in
        # the finally block to guarantee no raw payroll files persist beyond
        # this run. CREATE TEMPORARY STAGE is rejected inside stored procedures,
        # so a regular stage with a manual DROP serves the same purpose.
        # ==========================================================================
        session.sql(f'DROP STAGE IF EXISTS {stage}').collect()
        session.sql(f'CREATE STAGE {stage}').collect()

        for item in candidates:
            # ==========================================================================
            # STEP 4: Download and stage the file
            # Downloads the file bytes from SharePoint via Graph API, then PUTs
            # them to the temporary stage. Unsupported formats (.csv, .xls, etc.)
            # are rejected before download. Any failure at download or PUT is
            # recorded as a FAILED row in FILE_LOAD for audit, and the loop
            # continues to the next file -- one bad file does not abort the run.
            # ==========================================================================
            file_values = [
                run_id,
                item['FILE_NAME'],
                item['FILE_PATH'],
                item['SHAREPOINT_ITEM_ID'],
                item['SHAREPOINT_MODIFIED_AT'].isoformat(),
                item['SHAREPOINT_MODIFIED_BY'],
                item['SHAREPOINT_CREATED_AT'].isoformat() if item['SHAREPOINT_CREATED_AT'] else None,
                item['SHAREPOINT_CREATED_BY'],
                item['FILE_SIZE_BYTES'],
            ]
            error = None
            if not item['FILE_NAME'].endswith('.xlsx'):
                error = f"Unsupported file format: {item['FILE_NAME'].rsplit('.', 1)[-1].upper()}. Only .xlsx files are accepted."
            else:
                try:
                    dl = requests.get(f"{GRAPH}/drives/{drive_id}/items/{item['SHAREPOINT_ITEM_ID']}/content",
                                      headers=hdr, timeout=120)
                    if dl.status_code != 200:
                        raise RuntimeError(f'HTTP {dl.status_code}')
                except Exception as e:
                    error = f'Download failed: {e}'
                else:
                    try:
                        session.file.put_stream(io.BytesIO(dl.content), f"@{stage}/{item['SHAREPOINT_ITEM_ID']}.xlsx",
                                                auto_compress=False, overwrite=True)
                    except Exception as e:
                        error = f'Stage PUT failed: {e}'

            if error:
                session.sql(insert_file_load, params=[*file_values, 'FAILED', error, 'FALSE']).collect()
                continue

            session.sql('START TRANSACTION').collect()
            try:
                # ==========================================================================
                # STEP 5: Clear rows to be refreshed
                # Retires the previous version of this file by setting IS_CURRENT
                # = FALSE. This runs inside a per-file transaction so the old row
                # and the new row are atomically swapped: if the INSERT in Step 6
                # fails, the ROLLBACK restores IS_CURRENT = TRUE on the old row.
                # ==========================================================================
                session.sql(f"""
                    UPDATE {target} SET IS_CURRENT = FALSE
                    WHERE SHAREPOINT_ITEM_ID = :1 AND IS_CURRENT = TRUE
                """, params=[item['SHAREPOINT_ITEM_ID']]).collect()

                # ==========================================================================
                # STEP 6: Insert the new file version
                # Inserts the new FILE_LOAD row with IS_CURRENT = TRUE and
                # INGEST_STATUS = SUCCESS. At this point the file is staged but
                # not yet parsed -- EXTRACT_STATUS stays at NOT_ATTEMPTED until
                # Step 8 runs the UDF.
                # ==========================================================================
                session.sql(insert_file_load, params=[*file_values, 'SUCCESS', None, 'TRUE']).collect()

                # ==========================================================================
                # STEP 7: Duplicate check on business keys
                # Verifies that exactly one IS_CURRENT = TRUE row exists for this
                # SHAREPOINT_ITEM_ID. If the UPDATE in Step 5 missed an edge case
                # and two current versions coexist, the transaction is rolled back
                # and the run is aborted with a data_duplication error. The check
                # is scoped to this file's key -- other files are checked on their
                # own iteration.
                # ==========================================================================
                v_nb_records = session.sql(f"""
                    SELECT COUNT(*)
                    FROM (
                        SELECT SHAREPOINT_ITEM_ID
                        FROM {target}
                        WHERE SHAREPOINT_ITEM_ID = :1 AND IS_CURRENT = TRUE
                        GROUP BY SHAREPOINT_ITEM_ID
                        HAVING COUNT(*) > 1
                    )
                """, params=[item['SHAREPOINT_ITEM_ID']]).collect()[0][0]
            except Exception as e:
                session.sql('ROLLBACK').collect()
                session.sql(insert_file_load, params=[*file_values, 'FAILED', f'INSERT failed: {e}', 'FALSE']).collect()
                continue

            if v_nb_records > 0:
                session.sql('ROLLBACK').collect()
                raise RuntimeError(DATA_DUPLICATION)
            else:
                session.sql('COMMIT').collect()

        # ==========================================================================
        # STEP 8: Extract staged files into RAW_CONTENT
        # Calls PARSE_XLSX_TO_JSON on every successfully staged file. The UDF
        # reads the .xlsx from the temporary stage, walks every sheet cell by
        # cell, and returns a VARIANT. On success the parsed content goes into
        # RAW_CONTENT; on failure the UDF returns {"_error": "..."} which is
        # stored in ERROR_MESSAGE. Extraction is non-fatal: a corrupt file does
        # not roll back the other files' ingestion.
        # ==========================================================================
        session.sql(f"""
            UPDATE {target} t
            SET RAW_CONTENT    = IFF(s.PARSED:"_error" IS NULL, s.PARSED, NULL),
                EXTRACT_STATUS = IFF(s.PARSED:"_error" IS NULL, 'SUCCESS', 'FAILED'),
                EXTRACTED_AT   = CURRENT_TIMESTAMP(),
                ERROR_MESSAGE  = s.PARSED:"_error"::VARCHAR
            FROM (
                SELECT LOAD_ID,
                       {schema}.PARSE_XLSX_TO_JSON(
                           BUILD_SCOPED_FILE_URL(@{stage}, SHAREPOINT_ITEM_ID || '.xlsx')
                       ) AS PARSED
                FROM {target}
                WHERE RUN_ID = :1
                  AND INGEST_STATUS  = 'SUCCESS'
                  AND EXTRACT_STATUS = 'NOT_ATTEMPTED'
            ) s
            WHERE t.LOAD_ID = s.LOAD_ID
        """, params=[run_id]).collect()

        # ==========================================================================
        # STEP 9: Retire rows for files deleted from SharePoint
        # Compares the full file listing from Step 2 against IS_CURRENT = TRUE
        # rows in FILE_LOAD. Any row whose SHAREPOINT_ITEM_ID no longer appears
        # in SharePoint is set to IS_CURRENT = FALSE. This runs even when there
        # are zero candidates -- a file can be deleted during a quiet period.
        # ==========================================================================
        session.sql(f"""
            UPDATE {target} SET IS_CURRENT = FALSE
            WHERE IS_CURRENT = TRUE
              AND SHAREPOINT_ITEM_ID IS NOT NULL
              AND SHAREPOINT_ITEM_ID NOT IN (
                  SELECT VALUE::VARCHAR FROM TABLE(FLATTEN(INPUT => PARSE_JSON(:1)))
              )
        """, params=[json.dumps([item['SHAREPOINT_ITEM_ID'] for item in all_files])]).collect()

        return {
            'status':     'Success',
            'run_id':     run_id,
            'from_ts':    str(from_ts),
            'to_ts':      str(to_ts),
            'candidates': len(candidates),
        }

    except Exception:
        session.sql('ROLLBACK').collect()
        raise

    finally:
        session.sql(f'DROP STAGE IF EXISTS {stage}').collect()
$$;
-- Deploying this file only creates the procedure. To run it manually:
  CALL SP_INGEST_PAYROLL_FILES(
      DATABASE_NAME  => 'SANDBOX_DB',
      SCHEMA_NAME    => 'HR_PAYROLL_QIMA',
      TENANT_ID      => '77fc8d6c-15ec-4aea-9bd6-cf77b407a763',
      CLIENT_ID      => 'f1343367-3e3a-4ab0-8438-e72f261a6994',
      SITE_ID        => 'learnfabricsbi.sharepoint.com,5cfbd818-9daa-43e7-9676-7e69ccdbd7a0,859f7104-aaf6-4d0b-8cd3-30a1bc521983',
      DRIVE_ID       => 'b!GNj7XKqd50OWdn5pzNvXoARxn4X2qgtNjNMwobxSGYOsH0CrHyfVRYKr4I5Z_tXk',
      FOLDER_PATH    => 'Payroll files',
      OFFSET_MINUTES => 1
  );
