# transformation/lib

Shared Python used by the scripts under `transformation/reference_data/`.
Nothing here runs inside Snowflake - these are local developer scripts that
connect to it.

| File | Purpose |
|---|---|
| `snowflake_helper.py` | Opens a connection using a Programmatic Access Token from `.env` at the repo root. |

It lives inside `transformation/` rather than a top-level `tools/` because
CLAUDE.md organises this repo by pipeline stage, and a helper used only by the
transformation scripts is not a stage of its own.

## Setup

`.env` at the repo root (gitignored - never commit it):

```
SF_ACCOUNT=SBI-SBI_SINGAPORE
SF_USER=<your login>
SF_TOKEN=<programmatic access token>
SF_ROLE=SF_APA_SANDBOX-ETL
SF_WAREHOUSE=SANDBOX_WH
```

Tokens come from
<https://app.snowflake.com/sbi/sbi_singapore/settings/authentication>.

Two details that are easy to get wrong: the token goes in the **password**
field (this account rejects the `PROGRAMMATIC_ACCESS_TOKEN` authenticator), and
`SF_ROLE` is written unquoted - the helper adds the double quotes Snowflake
needs for a role name containing a hyphen.

```bash
python -m pip install snowflake-connector-python python-dotenv
python transformation/lib/snowflake_helper.py    # connection smoke test
```
