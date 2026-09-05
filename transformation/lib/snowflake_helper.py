"""Snowflake connection helper for the QIMA project.

Authenticates with a Programmatic Access Token (PAT) read from .env.
Snowflake accepts a PAT in the password field, so no key pair or browser
round-trip is needed.

    from snowflake_helper import get_connection, query

    with get_connection() as conn:
        rows = query(conn, "select current_role()")

Run it directly for a connection smoke test:

    python src/snowflake_helper.py
"""

from __future__ import annotations

import os
import sys
from contextlib import contextmanager
from io import StringIO
from pathlib import Path
from typing import Any, Iterable, Sequence

import snowflake.connector
from dotenv import load_dotenv
from snowflake.connector import DictCursor
from snowflake.connector.util_text import split_statements

def _find_env() -> Path:
    """Locate .env by walking up from this file to the repo root.

    Searching rather than hardcoding a depth: this module has already moved
    once (tools/ -> transformation/lib/) and a fixed number of .parent calls
    silently starts resolving to the wrong directory when it moves again.
    """
    here = Path(__file__).resolve()
    for folder in [here.parent, *here.parents]:
        if (folder / ".env").is_file():
            return folder / ".env"
        if (folder / ".git").exists():           # repo root, .env not created yet
            return folder / ".env"
    return here.parent / ".env"


ENV_PATH = _find_env()
PROJECT_ROOT = ENV_PATH.parent

# Identifiers Snowflake will not accept unquoted (hyphens, leading digits, ...).
_NEEDS_QUOTING = set("-. +")


def load_env(env_path: Path | str | None = None) -> None:
    """Load .env into os.environ. Existing env vars win, so CI can override."""
    load_dotenv(Path(env_path) if env_path else ENV_PATH, override=False)


def quote_identifier(name: str) -> str:
    """Double-quote an identifier when Snowflake needs it.

    ``SF_APA_SANDBOX-ETL`` has a hyphen and must be passed as
    ``"SF_APA_SANDBOX-ETL"`` or Snowflake parses it as a subtraction.
    """
    if not name:
        return name
    if name.startswith('"') and name.endswith('"'):
        return name
    if any(c in _NEEDS_QUOTING for c in name) or not name[0].isalpha():
        return '"' + name.replace('"', '""') + '"'
    return name


def connection_params(**overrides: Any) -> dict[str, Any]:
    """Build connector kwargs from the environment, with optional overrides."""
    load_env()

    account = os.getenv("SF_ACCOUNT")
    user = os.getenv("SF_USER")
    token = os.getenv("SF_TOKEN")

    missing = [k for k, v in (("SF_ACCOUNT", account), ("SF_USER", user), ("SF_TOKEN", token)) if not v]
    if missing:
        raise RuntimeError(
            f"Missing required setting(s) {', '.join(missing)}. "
            f"Copy .env.example to .env and fill it in ({ENV_PATH})."
        )

    params: dict[str, Any] = {
        "account": account,
        "user": user,
        # A PAT is presented as the password. Do NOT set authenticator here:
        # 'PROGRAMMATIC_ACCESS_TOKEN' is rejected by this account's config.
        "password": token,
        "client_session_keep_alive": True,
        "login_timeout": int(os.getenv("SF_LOGIN_TIMEOUT", "30")),
        "session_parameters": {"QUERY_TAG": os.getenv("SF_QUERY_TAG", "qima-project")},
    }

    for key, env_var in (
        ("role", "SF_ROLE"),
        ("warehouse", "SF_WAREHOUSE"),
        ("database", "SF_DATABASE"),
        ("schema", "SF_SCHEMA"),
    ):
        value = os.getenv(env_var)
        if value:
            params[key] = quote_identifier(value) if key == "role" else value

    params.update(overrides)
    return params


def get_connection(**overrides: Any) -> snowflake.connector.SnowflakeConnection:
    """Open a Snowflake connection using .env settings."""
    return snowflake.connector.connect(**connection_params(**overrides))


@contextmanager
def connect(**overrides: Any):
    """Context-managed connection that always closes."""
    conn = get_connection(**overrides)
    try:
        yield conn
    finally:
        conn.close()


def query(
    conn: snowflake.connector.SnowflakeConnection,
    sql: str,
    params: Sequence[Any] | dict[str, Any] | None = None,
    as_dict: bool = True,
) -> list[Any]:
    """Run one statement and return all rows."""
    cur = conn.cursor(DictCursor) if as_dict else conn.cursor()
    try:
        cur.execute(sql, params)
        return cur.fetchall()
    finally:
        cur.close()


def split_sql(text: str) -> list[str]:
    """Split a script into statements.

    Uses the connector's own splitter rather than text.split(';') - several
    COMMENT strings in sql/01_core_tables.sql contain semicolons, and a naive
    split cuts those statements in half.
    """
    with StringIO(text) as buf:
        return [stmt for stmt, _ in split_statements(buf, remove_comments=False) if stmt.strip()]


def execute_many(conn: snowflake.connector.SnowflakeConnection, statements: Iterable[str]) -> None:
    """Run a series of statements, skipping blanks and comment-only chunks."""
    cur = conn.cursor()
    try:
        for stmt in statements:
            stmt = stmt.strip()
            if not stmt or all(line.strip().startswith("--") or not line.strip() for line in stmt.splitlines()):
                continue
            cur.execute(stmt)
    finally:
        cur.close()


def run_sql_file(conn: snowflake.connector.SnowflakeConnection, path: Path | str) -> None:
    """Execute every statement in a .sql file."""
    execute_many(conn, split_sql(Path(path).read_text(encoding="utf-8")))


def whoami(conn: snowflake.connector.SnowflakeConnection) -> dict[str, Any]:
    """Current session context - handy for debugging grants."""
    return query(
        conn,
        """
        select current_user()      as user,
               current_role()      as role,
               current_warehouse() as warehouse,
               current_database()  as database,
               current_schema()    as schema,
               current_account()   as account,
               current_region()    as region,
               current_version()   as version
        """,
    )[0]


def main() -> int:
    try:
        with connect() as conn:
            ctx = whoami(conn)
            print("Connected to Snowflake\n")
            for key, value in ctx.items():
                print(f"  {key.lower():<10} {value}")
            roles = query(conn, "select current_available_roles() as r", as_dict=False)[0][0]
            print(f"\n  available  {roles}")
    except Exception as exc:  # noqa: BLE001 - surface the real cause to the user
        print(f"Connection failed: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
