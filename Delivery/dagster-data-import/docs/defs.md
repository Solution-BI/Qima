# Definitions

## Overview

The `src/data_import/defs/` directory contains Dagster asset definitions. Each subdirectory defines a group of assets
with its own generation logic.

## Operations

### elc

The main production pipeline — ELC (Extract, Load, Check). Generates Dagster assets dynamically from Snowflake config
tables.

- Source: `src/data_import/defs/elc/`
- Detailed documentation:
  - [defs-elc.md](defs-elc.md) — overview
  - [defs-elc-extract.md](defs-elc-extract.md) — Step 1: extract data from sources
  - [defs-elc-load.md](defs-elc-load.md) — Step 2: load data into Snowflake
  - [defs-elc-check.md](defs-elc-check.md) — Step 3: check data integrity

### alerts

Email alerting on Dagster run failure. Generates a run-failure sensor (prod only) that emails a
static recipient list.

- Source: `src/data_import/defs/alerts/`
- Detailed documentation: [defs-alerts.md](defs-alerts.md)

### quickstart

CSV loading + pandas processing example from the Dagster documentation. Not important for this project.

- Source: `src/data_import/defs/quickstart/`

### tutorial

Dagster tutorial: jaffle-shop data in DuckDB. Not important for this project.

- Source: `src/data_import/defs/tutorial/`