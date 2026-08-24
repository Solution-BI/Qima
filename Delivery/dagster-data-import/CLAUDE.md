# Data Import

## Tech Stack

- **Python**: 3.13, managed with `uv`
- **Config**: pydantic-settings (`data_import.config.settings`), env vars in `.env`
- **Orchestration**: Dagster 1.12 — assets, groups, MaterializeResult with metadata
- **Direct-load drivers**: mysql-connector-python (MySQL), pymssql (MSSQL), oracledb thin mode (Oracle), psutil (memory
  monitoring), httpx (Tarq HTTP API, async)
- **Type checking**: Pyright strict mode
- **Destination**: Snowflake (private key auth) via `data_import.config.snowflake`

## Project Structure

```
src/data_import/
├── definitions.py          # Dagster definitions entry point (static + dynamic merge)
├── config/                 # Centralized configuration (loaded from Snowflake + env)
│   ├── settings.py         # pydantic-settings: env vars + .env
│   ├── snowflake.py        # Snowflake connection context manager (private key auth)
│   ├── config.py           # Aggregated Config: assets + connections snapshot
│   ├── obj/
│   │   ├── asset.py        # Asset dataclass + loader from _CONFIG.ASSET
│   │   ├── connection.py   # Connection dataclass + loader from _CONFIG.CONNECTION
│   │   ├── job.py          # Job dataclass + loader from _CONFIG.JOB
│   │   └── run.py          # Run dataclass (execution metadata)
│   ├── secret.py           # Secret resolution from environment variables
│   └── ssh.py              # SSH tunnel context manager
├── util/
│   └── logging.py          # ElcLogger: DagsterLogManager wrapper with pipe-separated metadata
└── defs/                   # One subdirectory per data source
    ├── elc/                # Production ELC pipeline (Extract, Load, Check)
    ├── quickstart/         # CSV loading + pandas processing example
    └── tutorial/           # Dagster tutorial: jaffle-shop data in DuckDB
test/
    └── data_import/
        ├── config/                     # Config unit + integration tests (pytest marks)
        └── defs/elc/                   # ELC pipeline tests (extract, load, check)
```

## Documentation

Detailed docs live in `docs/`, following the conventions in `.claude/rules/docs.md`:

- [docs/config.md](docs/config.md) — config layers, types (Config, Asset, Job, Connection), and functions
- [docs/defs.md](docs/defs.md) — overview of all Dagster definition groups
- [docs/defs-elc.md](docs/defs-elc.md) — ELC pipeline: data steps, types, and transformations
  - [docs/defs-elc-extract.md](docs/defs-elc-extract.md) — extract step
  - [docs/defs-elc-load.md](docs/defs-elc-load.md) — load step
  - [docs/defs-elc-check.md](docs/defs-elc-check.md) — check step
- [docs/defs-alerts.md](docs/defs-alerts.md) — email alerting on run failure
- [docs/glossary.md](docs/glossary.md) — project-specific terms and abbreviations

## Conventions

- An asset's `cd` is a composite Dagster asset key of exactly three `/`-separated terms
  (e.g., `QIMAONE/QIMAONE_INSPECTION/PUBLIC_USERS`); see `Asset.cd_key`. The Dagster group is the first two
  terms joined with `__` (`Asset.cd_group`, e.g. `QIMAONE__QIMAONE_INSPECTION`).
- Python coding and testing conventions are in `.claude/rules/`.

## Common Commands

```bash
uv sync                                    # Install dependencies
uv run dg dev                              # Start Dagster UI (localhost:3000)
uv run dg list defs                        # List all assets
uv run dg launch --assets "asset_name"     # Run a specific asset
uv run python -m pytest -m int              # Run integration tests
uv run ruff check && uv run ruff format    # Lint and format
uv run pyright                             # Type check (strict mode)
```

## Snowflake Connection

Use `snowflake.connector.connect()` with private key auth — see `config/snowflake.py` for the
context manager implementation.