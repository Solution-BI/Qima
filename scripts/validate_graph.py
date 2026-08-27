"""
Usage:
  pip install requests python-dotenv
  python scripts/validate_graph.py
"""

import os
import sys

from dotenv import load_dotenv

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

from payroll.graph import get_token, list_files, download, GraphAuthError, GraphAPIError

import requests

load_dotenv()

TENANT_ID = os.environ["GRAPH_TENANT_ID"]
CLIENT_ID = os.environ["GRAPH_CLIENT_ID"]
CLIENT_SECRET = os.environ["GRAPH_CLIENT_SECRET"]
SITE_URL = "learnfabricsbi.sharepoint.com:/sites/PROJAPAQIMASharePoint-to-Snowflakedataingestion"
FOLDER_PATH = os.environ.get("SP_FOLDER_PATH", "QIMA_APA_HR-Payroll-Data-Platform-2026")


def step(n: int, description: str):
    print(f"\n{'='*60}")
    print(f"  Step {n}: {description}")
    print(f"{'='*60}")


def main():
    # --- Step 1: Token ---
    step(1, "Acquire access token")
    try:
        token = get_token(TENANT_ID, CLIENT_ID, CLIENT_SECRET)
        print(f"  OK - Token acquired (first 20 chars): {token[:20]}...")
    except GraphAuthError as e:
        print(f"  FAILED - {e}")
        print("\n  Check: client_id, client_secret, tenant_id are correct.")
        return

    headers = {"Authorization": f"Bearer {token}"}

    # --- Step 2: Discover site ID ---
    step(2, "Discover site ID")
    site_url = f"https://graph.microsoft.com/v1.0/sites/{SITE_URL}"
    resp = requests.get(site_url, headers=headers)
    if resp.status_code != 200:
        print(f"  FAILED ({resp.status_code}): {resp.text}")
        print("\n  Check: Sites.Selected is consented AND the app is scoped to this site.")
        print("  The admin must POST /sites/{{site_id}}/permissions to scope the app.")
        return

    site_data = resp.json()
    site_id = site_data["id"]
    print(f"  OK - Site: {site_data.get('displayName', 'unknown')}")
    print(f"  Site ID: {site_id}")
    print(f"\n  --> Add to .env: SP_SITE_ID={site_id}")

    # --- Step 3: Discover drive ID ---
    step(3, "Discover drive ID (Documents library)")
    drives_url = f"https://graph.microsoft.com/v1.0/sites/{site_id}/drives"
    resp = requests.get(drives_url, headers=headers)
    if resp.status_code != 200:
        print(f"  FAILED ({resp.status_code}): {resp.text}")
        return

    drives = resp.json()["value"]
    print(f"  Found {len(drives)} drive(s):")
    # ponytail: name match only - every library reports driveType=documentLibrary
    drive_id = next((d["id"] for d in drives if d["name"] == "Documents"), None)
    for d in drives:
        marker = "  <-- THIS ONE" if d["id"] == drive_id else ""
        print(f"    - {d['name']} (id: {d['id']}){marker}")

    if not drive_id:
        drive_id = drives[0]["id"]
        print(f"\n  No 'Documents' library found, using first drive: {drive_id}")

    print(f"\n  --> Add to .env: SP_DRIVE_ID={drive_id}")

    # --- Step 4: List files ---
    step(4, f"List .xlsx files in '{FOLDER_PATH}'")
    try:
        files = list_files(token, site_id, drive_id, FOLDER_PATH)
        print(f"  OK - Found {len(files)} .xlsx file(s):")
        for f in files:
            print(f"    - {f['name']} ({f.get('size', '?')} bytes)")
    except GraphAPIError as e:
        print(f"  FAILED - {e}")
        print(f"\n  Check: Does the folder '{FOLDER_PATH}' exist and contain .xlsx files?")
        print("  You may need to upload test files first.")
        return

    # --- Step 5: Download first file ---
    step(5, f"Download '{files[0]['name']}'")
    try:
        content = download(token, drive_id, files[0]["id"])
        magic = content[:4]
        if magic == b"PK\x03\x04":
            print(f"  OK - Downloaded {len(content)} bytes (valid .xlsx/zip)")
        else:
            print(f"  WARNING - Downloaded {len(content)} bytes but magic bytes are {magic!r}, not PK\\x03\\x04")
    except GraphAPIError as e:
        print(f"  FAILED - {e}")
        return

    # --- Summary ---
    print(f"\n{'='*60}")
    print("  ALL STEPS PASSED - SharePoint access is configured correctly.")
    print(f"{'='*60}")
    print(f"\n  Add these to your .env:")
    print(f"    SP_SITE_ID={site_id}")
    print(f"    SP_DRIVE_ID={drive_id}")
    print(f"    SP_FOLDER_PATH={FOLDER_PATH}")


if __name__ == "__main__":
    main()
