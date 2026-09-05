# tools

Developer utilities. Not a pipeline stage - nothing here runs in Snowflake.

CLAUDE.md organises the repo by pipeline stage (`config`, `ingestion`,
`transformation`, `security`, `auditability`). A shared connection helper is
not one of those, so it sits here rather than being duplicated into each stage.
Rename or relocate if the team prefers otherwise.

| File | Purpose |
|---|---|
| `snowflake_helper.py` | Connects to Snowflake with a Programmatic Access Token from `.env`. Used by the scripts under `transformation/reference_data/header_map/`. |

## Setup

Create `.env` in the repo root (gitignored):

```
SF_ACCOUNT=SBI-SBI_SINGAPORE
SF_USER=<your login>
SF_TOKEN=<programmatic access token>
SF_ROLE=SF_APA_SANDBOX-ETL
SF_WAREHOUSE=SANDBOX_WH
```

Tokens are issued at
<https://app.snowflake.com/sbi/sbi_singapore/settings/authentication>.
The token is sent as the password field - the `PROGRAMMATIC_ACCESS_TOKEN`
authenticator is rejected by this account. `SF_ROLE` is written unquoted; the
helper adds the quotes Snowflake needs for a name containing a hyphen.

```bash
python -m pip install snowflake-connector-python python-dotenv
python tools/snowflake_helper.py    # connection smoke test
```
