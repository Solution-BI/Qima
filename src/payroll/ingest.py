"""Pipeline orchestrator: ties graph transport, parser, and staging together.
"""
from __future__ import annotations

from datetime import datetime

from src.payroll.graph import list_files, download
from src.payroll.parse import parse
from src.payroll.staging import (
    stage_file,
    insert_rows,
    loaded_versions,
    refresh_stage_directory,
)


def _graph_timestamp(value: str) -> datetime:
    """Parse a Graph ISO-8601 UTC timestamp into a naive UTC datetime."""
    return datetime.fromisoformat(value.replace("Z", "+00:00")).replace(tzinfo=None)


def run(
    conn,
    token: str,
    site_id: str,
    drive_id: str,
    folder_path: str,
    sheet_name: str = "2026",
) -> dict:

    files = list_files(token, site_id, drive_id, folder_path)
    already_loaded = loaded_versions(conn)

    success = []
    failed = []
    skipped = []
    total_rows = 0

    for item in files:
        file_name = item["name"]
        item_id = item["id"]

        try:
            modified = _graph_timestamp(item["lastModifiedDateTime"])

            # Qima's existing pattern: re-inject only where the timestamp changed.
            if already_loaded.get(file_name) == modified:
                skipped.append({"file": file_name, "modified": modified})
                continue

            file_bytes = download(token, drive_id, item_id)
            stage_file(conn, file_bytes, file_name)
            rows = parse(file_bytes, sheet_name)
            count = insert_rows(conn, rows, file_name, modified)

            success.append({"file": file_name, "rows": count})
            total_rows += count

        except Exception as e:
            failed.append({"file": file_name, "error": str(e)})

    # Once per run, not per file — the directory table is not updated by PUT.
    refresh_stage_directory(conn)

    return {
        "success": success,
        "failed": failed,
        "skipped": skipped,
        "total_rows": total_rows,
    }
