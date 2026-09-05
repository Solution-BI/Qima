# Transformation - RAW to SILVER/GOLD

Turns `FILE_LOAD.RAW_CONTENT` into a queryable payroll model. All structural
interpretation lives here, driven by `HEADER_MAP` - ingestion and extraction
stay dumb by design (see `ingestion/docs/`).

Built as plain SQL + Snowpark, matching the Snowflake-native approach the
payroll isolation decision requires. No dbt.

## Layout

```
reference_data/header_map/
    headers_observed.csv     every column of every generation, extracted from FILE_LOAD
    build_header_map.py      drafts the seed below from the above
    header_map_seed.csv      the draft mapping, for human review
    header_map_review.md     what the classifier could not decide
sql/
    01_header_map.sql        HEADER_MAP table + generation-resolution view
    02_silver_model.sql      SHEET_LOAD, PAYROLL_ROW, PAYROLL_MEASURE, DQ_FLAG, GOLD views
docs/
    README.md                this file
```

## Why the fact is long, not wide

The contract defines every value as component group x measure basis x period.
The set of components differs per generation: the two Eid festival blocks exist
only in `2026-75col`, the USD columns only in 2024/2025, ad hoc bonuses only
from 2026. A wide table means a DDL change per generation. `PAYROLL_MEASURE`
absorbs them as data.

## Template generations

Eight observed in `FILE_LOAD`. The contract lists seven:

| Generation | In contract | Source |
|---|---|---|
| 2024-89col | yes | AE01+BD01+IN01+VN01+SA01+HK+CN |
| 2024-91col | yes | BR02 |
| 2025-91col | yes | BR09 |
| 2025-95col | yes | BR02 |
| 2025-96col | yes | AE01+... |
| 2026-64col | **no** | `BR05_Payroll_Sample.xlsx` / `BR02_Payroll_Sample.xlsx` |
| 2026-67col | yes | BR02, BR09 |
| 2026-75col | yes | AE01+... |

`2026-64col` comes only from two files that share one SharePoint item ID (the
same file, renamed) sitting inside the live `BR02 - QIMA BRASIL LTDA - Payroll
Reporting` folder, with 4 data rows. That reads as a sample file parked in a
submission folder rather than a real generation - **open question: filter these
at ingestion, or map the generation.**

The contract's own table lists 88 columns for both `2024-89col` and
`2024-91col`; measured, they are 89 and 91, matching the generation names.

## Two template defects, resolved in opposite directions

Both are Qima-side, both persist across generations, and neither can be a
blanket rule - which is why the classifier flags conflicts rather than guessing:

1. **"Eligible for Holiday Bonus" under the Profit sharing band**, in all five
   2024/2025 generations. The column is profit-sharing eligibility; the header
   text was copy-pasted from the Holiday block above. **The band wins.**
2. **"Commission (Currency)" under the Auditor Bonus band**, in both 2026
   generations. Here the header is right - the merged band runs one column too
   wide. **The header wins.**

Both belong in the change-management conversation the contract flags as its
biggest open gap (section 7), rather than being absorbed silently forever.

## Currency scope

2024 and 2025 report most amounts twice: once in local currency, once converted
to USD at rates the contract describes as inconsistent and unknown. FX
normalisation is out of scope, so `CURRENCY_SCOPE` is part of the
`PAYROLL_MEASURE` grain. Both load; **only `LOCAL` reaches GOLD.** Summing
across scopes would double-count.

## Rebuilding the mapping

```bash
python src/extract_headers.py                                     # FILE_LOAD -> headers_observed.csv
python transformation/reference_data/header_map/build_header_map.py  # -> seed + review
```

Then review `header_map_review.md`, correct `header_map_seed.csv` by hand, and
load it per the COPY INTO in `sql/01_header_map.sql`.

## Not yet built

- The Snowpark procedure that walks `RAW_CONTENT` into `PAYROLL_ROW` /
  `PAYROLL_MEASURE` using `HEADER_MAP`.
- Ad hoc bonuses are recorded **horizontally** while every other component is
  vertical (contract section 3). `PAYROLL_MEASURE` can hold them, but the
  loader needs a specific branch for that shape.
- `DIM_SUBSIDIARY`. 21 labels observed; `CPQUALI` and `CPHOSP` carry no code
  prefix, and `BR02 - QIMA BRASIL LTDA.` has a trailing period the filename
  does not.
- Restatement handling. Each monthly submission restates the full year to date
  (contract section 1), so the same employee-year arrives repeatedly. Which
  submission wins is an open contract item (section 8).
