

from __future__ import annotations

import requests


class GraphAuthError(Exception):
    """Raised when token acquisition fails."""


class GraphAPIError(Exception):
    """Raised when a Graph API call returns a non-success status."""


def get_token(tenant_id: str, client_id: str, client_secret: str) -> str:
  
    url = f"https://login.microsoftonline.com/{tenant_id}/oauth2/v2.0/token"
    resp = requests.post(url, data={
        "client_id": client_id,
        "client_secret": client_secret,
        "scope": "https://graph.microsoft.com/.default",
        "grant_type": "client_credentials",
    })
    if resp.status_code != 200:
        raise GraphAuthError(
            f"Token request failed ({resp.status_code}): {resp.text}"
        )
    return resp.json()["access_token"]


def list_files(
    token: str, site_id: str, drive_id: str, folder_path: str
) -> list[dict]:
    url = (
        f"https://graph.microsoft.com/v1.0/sites/{site_id}"
        f"/drives/{drive_id}"
        f"/root:/{folder_path}:/children"
    )
    resp = requests.get(url, headers={"Authorization": f"Bearer {token}"})
    if resp.status_code != 200:
        raise GraphAPIError(
            f"list_files failed ({resp.status_code}): {resp.text}"
        )
    items = resp.json().get("value", [])
    xlsx_files = [item for item in items if item["name"].endswith(".xlsx")]

    if not xlsx_files:
        raise GraphAPIError(
            f"No .xlsx files found in '{folder_path}'. "
            "Expected payroll workbooks -- check folder path and site scoping."
        )
    return xlsx_files


def download(token: str, drive_id: str, item_id: str) -> bytes:
    """Download a file's content by item ID. Returns raw bytes."""
    url = (
        f"https://graph.microsoft.com/v1.0/drives/{drive_id}"
        f"/items/{item_id}/content"
    )
    resp = requests.get(url, headers={"Authorization": f"Bearer {token}"})
    if resp.status_code != 200:
        raise GraphAPIError(
            f"download failed ({resp.status_code}): {resp.text}"
        )
    return resp.content
