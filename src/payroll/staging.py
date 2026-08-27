from __future__ import annotations

import shutil
import tempfile
from datetime import datetime, timezone
from pathlib import Path

from src.payroll.columns import COLUMNS, METADATA_COLUMNS
from src.payroll.parse import subsidiary_code


def stage_file(conn, file_bytes: bytes, file_name: str) -> None:
    
    tmp_dir = Path(tempfile.mkdtemp())
    try:
        tmp_path = tmp_dir / file_name
        tmp_path.write_bytes(file_bytes)
        conn.cursor().execute(
            f"PUT 'file://{tmp_path.as_posix()}' @PAYROLL_STAGE "
            f"AUTO_COMPRESS=FALSE OVERWRITE=TRUE"
        )
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


def loaded_versions(conn) -> dict[str, datetime]:
    
    cur = conn.cursor()
    try:
        cur.execute(
            "SELECT SOURCE_FILE_NAME, MAX(SOURCE_MODIFIED_DATE) "
            "FROM PAYROLL_STAGING GROUP BY 1"
        )
        return {name: modified for name, modified in cur.fetchall()}
    finally:
        cur.close()


def refresh_stage_directory(conn) -> None:
    
    conn.cursor().execute("ALTER STAGE PAYROLL_STAGE REFRESH")


def insert_rows(
    conn, rows: list[list[str | None]], file_name: str, source_modified: datetime
) -> int:
   
    if not rows:
        return 0

    load_date = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
    modified = source_modified.strftime("%Y-%m-%d %H:%M:%S")

    # Build column list: metadata + source columns
    all_columns = list(METADATA_COLUMNS) + list(COLUMNS)
    col_list = ", ".join(all_columns)
    placeholders = ", ".join(["%s"] * len(all_columns))
    insert_sql = f"INSERT INTO PAYROLL_STAGING ({col_list}) VALUES ({placeholders})"

   
    params = [
        [load_date, file_name, subsidiary_code(row), modified] + row for row in rows
    ]

    cur = conn.cursor()
    try:
        cur.execute("BEGIN")
        cur.executemany(insert_sql, params)
        cur.execute("COMMIT")
        return len(rows)

    except Exception:
        cur.execute("ROLLBACK")
        raise
    finally:
        cur.close()
