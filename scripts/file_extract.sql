USE DATABASE SANDBOX_DB;
USE SCHEMA HR_PAYROLL_QIMA;

CREATE OR REPLACE PROCEDURE EXTRACT_PAYROLL_FILES()
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'openpyxl')
HANDLER = 'main'
EXECUTE AS CALLER
AS
$$
import json
import re
from datetime import date, datetime, time, timezone
from io import BytesIO

import openpyxl

STAGE_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_$]*(\.[A-Za-z_][A-Za-z0-9_$]*){0,2}$")


def sheet_grid(ws):
    rows = [
        [str(v) if isinstance(v, (datetime, date, time)) else v for v in row]
        for row in ws.iter_rows(values_only=True)
    ]

    while rows and all(v is None for v in rows[-1]):
        rows.pop()
    return rows


def workbook_to_dict(file_bytes):
    wb = openpyxl.load_workbook(BytesIO(file_bytes), read_only=True, data_only=True)
    try:
        return {name: sheet_grid(wb[name]) for name in wb.sheetnames}
    finally:
        wb.close()


def scoped_url(session, path):
    stage, _, relative = path.lstrip("@").partition("/")
    if not STAGE_RE.match(stage) or not relative:
        raise ValueError(f"cannot split a stage and relative path out of {path!r}")
    return session.sql(
        f"SELECT BUILD_SCOPED_FILE_URL(@{stage}, ?)", params=[relative]
    ).collect()[0][0]


def read_stage_file(session, path):
    attempts = []
    try:
        from snowflake.snowpark.files import SnowflakeFile

        with SnowflakeFile.open(scoped_url(session, path), "rb") as fh:
            return fh.read()
    except Exception as e:
        attempts.append(f"scoped-url: {e!r}")

    try:
        with session.file.get_stream(path) as fh:
            return fh.read()
    except Exception as e:
        attempts.append(f"get_stream: {e!r}")

    raise RuntimeError(" | ".join(attempts))


def pending_rows(session):
    return session.sql(
        "SELECT LOAD_ID, FILE_PATH FROM FILE_LOAD "
        "WHERE INGEST_STATUS = 'SUCCESS' AND EXTRACT_STATUS = 'NOT_ATTEMPTED' "
        "ORDER BY LOAD_ID"
    ).collect()


def update_row(session, load_id, extract_status, content, error):
    if extract_status == "SUCCESS":
        session.sql(
            "UPDATE FILE_LOAD SET EXTRACT_STATUS = ?, EXTRACTED_AT = ?, "
            "RAW_CONTENT = PARSE_JSON(?), ERROR_MESSAGE = NULL WHERE LOAD_ID = ?",
            params=[
                extract_status,
                datetime.now(timezone.utc),
                json.dumps(content, default=str),
                load_id,
            ],
        ).collect()
    else:
        session.sql(
            "UPDATE FILE_LOAD SET EXTRACT_STATUS = ?, EXTRACTED_AT = ?, "
            "RAW_CONTENT = NULL, ERROR_MESSAGE = ? WHERE LOAD_ID = ?",
            params=[
                extract_status,
                datetime.now(timezone.utc),
                str(error),
                load_id,
            ],
        ).collect()


def main(session):
    results = []
    for row in pending_rows(session):
        load_id, path = row["LOAD_ID"], row["FILE_PATH"]
        content, error, extract_status = None, None, "FAILED"

        try:
            content = workbook_to_dict(read_stage_file(session, path))
            extract_status = "SUCCESS"
        except Exception as e:
            error = str(e)


        write_error = None
        try:
            update_row(session, load_id, extract_status, content, error)
        except Exception as e:
            write_error = str(e)

        results.append({
            "load_id": load_id,
            "file": path.rsplit("/", 1)[-1],
            "extract_status": "NOT_WRITTEN" if write_error else extract_status,
            "sheets": None if content is None else {s: len(g) for s, g in content.items()},
            "error": write_error or error,
        })

    return {
        "processed": len(results),
        "succeeded": sum(1 for r in results if r["extract_status"] == "SUCCESS"),
        "failed": sum(1 for r in results if r["extract_status"] == "FAILED"),
        "not_written": sum(1 for r in results if r["extract_status"] == "NOT_WRITTEN"),
        "files": results,
    }
$$;
