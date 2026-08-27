"""Local harness entry point.

Reads credentials from .env, connects to SharePoint and Snowflake,
runs the ingestion pipeline, and prints a per-file summary.

Usage: python entry/main.py
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

# Ensure project root is on sys.path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from dotenv import load_dotenv
import snowflake.connector

from src.payroll.graph import get_token
from src.payroll.ingest import run


def main() -> int:
    load_dotenv()

    # --- Graph credentials ---
    tenant_id = os.environ["GRAPH_TENANT_ID"]
    client_id = os.environ["GRAPH_CLIENT_ID"]
    client_secret = os.environ["GRAPH_CLIENT_SECRET"]
    site_id = os.environ["SP_SITE_ID"]
    drive_id = os.environ["SP_DRIVE_ID"]
    folder_path = os.environ["SP_FOLDER_PATH"]
    sheet_name = os.environ.get("PAYROLL_SHEET_YEAR", "2026")

    # --- Snowflake connection ---
    conn = snowflake.connector.connect(
        account=os.environ["SNOWFLAKE_ACCOUNT"],
        user=os.environ["SNOWFLAKE_USER"],
        password=os.environ["SNOWFLAKE_PASSWORD"],
        warehouse=os.environ["SNOWFLAKE_WAREHOUSE"],
        database=os.environ["SNOWFLAKE_DATABASE"],
        schema=os.environ["SNOWFLAKE_SCHEMA"],
        role=os.environ.get("SNOWFLAKE_ROLE"),
    )

    try:
        # --- Acquire Graph token ---
        print("Acquiring Microsoft Graph token...")
        token = get_token(tenant_id, client_id, client_secret)
        print("Token acquired.")

        # --- Run pipeline ---
        print(f"Processing files from: {folder_path}")
        result = run(conn, token, site_id, drive_id, folder_path, sheet_name)

        # --- Print summary ---
        print("\n" + "=" * 60)
        print("INGESTION SUMMARY")
        print("=" * 60)

        if result["success"]:
            print(f"\nSucceeded ({len(result['success'])} files):")
            for item in result["success"]:
                print(f"  {item['file']:<50} {item['rows']:>5} rows")

        if result["skipped"]:
            print(f"\nSkipped — unchanged since last load ({len(result['skipped'])} files):")
            for item in result["skipped"]:
                print(f"  {item['file']:<50} modified {item['modified']}")

        if result["failed"]:
            print(f"\nFailed ({len(result['failed'])} files):")
            for item in result["failed"]:
                print(f"  {item['file']:<50} {item['error']}")

        print(f"\nTotal rows inserted: {result['total_rows']}")
        print("=" * 60)

        return 1 if result["failed"] else 0

    finally:
        conn.close()


if __name__ == "__main__":
    sys.exit(main())
