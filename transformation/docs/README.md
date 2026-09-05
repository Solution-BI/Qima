# Transformation - RAW to SILVER/GOLD

Turns `FILE_LOAD.RAW_CONTENT` into a queryable payroll model. All structural
interpretation lives here, driven by `HEADER_MAP` - ingestion and extraction
stay dumb by design (see `ingestion/docs/`).

Built as plain SQL + Snowpark, matching the Snowflake-native approach the
payroll isolation decision requires. No dbt.

> **Before exposing any of this to users, read [KNOWN_GAPS.md](KNOWN_GAPS.md).**
> There is no masking and no row-level security yet, so every salary and bonus
> is readable in the clear by anyone with access to the schema.

## Layout

```
lib/
    snowflake_helper.py      connects to Snowflake using .env at the repo root
reference_data/header_map/
    headers_observed.csv     every column of every generation, extracted from FILE_LOAD
    build_header_map.py      drafts the seed below from the above
    header_map_seed.csv      the draft mapping, for human review
    header_map_review.md     what the classifier could not decide
sql/
    01_header_map.sql        HEADER_MAP table + generation-resolution view
    02_silver_model.sql      SHEET_LOAD, PAYROLL_ROW, FACT_PAYROLL_COMPONENT, DQ_FLAG, GOLD views
    03_file_exclusion.sql    FILE_EXCLUSION + V_PAYROLL_FILE_CURRENT (what to process)
docs/
    README.md                this file
```

## Why the fact is long, not wide

The contract defines every value as component group x measure basis x period.
The set of components differs per generation: the two Eid festival blocks exist
only in `2026-75col`, the USD columns only in 2024/2025, ad hoc bonuses only
from 2026. A wide table means a DDL change per generation. `FACT_PAYROLL_COMPONENT`
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
| 2026-64col | **no - sample, not a real template** | `BR05_Payroll_Sample.xlsx` / `BR02_Payroll_Sample.xlsx` |
| 2026-67col | yes | BR02, BR09 |
| 2026-75col | yes | AE01+... |

`2026-64col` is **verified not a real generation**. Its 4 employee rows match
the real BR02 file on both SAP ID and gross salary (916 / 850 / 510 / 340); the
file is 18,672 bytes against BR02's 900,176 and carries one `2026` sheet against
four. It is a 4-row extract of BR02, parked in the live BR02 folder, and has
been renamed once while keeping its SharePoint item id.

It is almost certainly still in that folder - the folder listing confirms three
owner folders, not their contents - so it will be re-ingested on the next run.
`FILE_EXCLUSION` (see `sql/03_file_exclusion.sql`) excludes it by item id.

It is still loaded into `HEADER_MAP`, marked `GENERATION_STATUS = 'SAMPLE'`, so
a sheet matching it is *recognised and excluded* rather than silently mapped as
real payroll. `MAPPING_STATUS = 'SAMPLE'` on `SHEET_LOAD` keeps it out of GOLD.

The seven remaining generations match the contract's list exactly. That closes
the open item only for **what is in SharePoint today** - not for the steady
state. On 20 August Antoine put expected volume at **10 to 20 files monthly,
one per subsidiary**, against the three payroll-owner folders that exist now.
He also confirmed the wide template is deliberate and that **further column
additions are expected over time**, since every new bonus type becomes a new
column for everyone even where it applies to five people in one country.

So treat seven generations as the current floor, not a closed list. That is
exactly why a new generation must be rows in `HEADER_MAP` rather than a code
change.

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

## Subsidiaries declared vs subsidiaries present

The three folder names declare 16 subsidiary codes
(`reference_data/subsidiary/folder_subsidiary_map.csv`). The data does not
match them:

- **`HK02` is declared but has zero employees** in the 2026 sheet.
- **Seven subsidiaries appear that no folder declares** - `MX01` (3 employees),
  `PH01` (2), `CL01` (2), `PE01` (1), `MX05` (1), `GB02` (1), `US01` (1). All 11
  arrive inside the `AE01 + ...` file.

Those same 11 rows carry most of the currency anomalies: `GB02` paid in HKD,
`PE01` paid in RMB, `CL01` and `MX05` with no currency at all. The pattern reads
as stragglers appended to whichever file was open rather than deliberate
submissions - worth raising with Tess before they are modelled as real
subsidiary payroll. `SUBSIDIARY_NOT_DECLARED_BY_FOLDER` is the DQ rule for this.

The folder names are also the only source for `CPQUALI` / `CPHOSP` codes, since
those cells carry no code prefix - `BR09 + BR12 + BR13` covers both, but which
of the three maps to which legal name is **not confirmed**.

## Currency scope

2024 and 2025 report most amounts twice: once in local currency, once converted
to USD at rates the contract describes as inconsistent and unknown. FX
normalisation is out of scope, so `CURRENCY_SCOPE` is part of the
`FACT_PAYROLL_COMPONENT` grain. Both load; **only `LOCAL` reaches GOLD.** Summing
across scopes would double-count.

## Rebuilding the mapping

```bash
python transformation/reference_data/header_map/extract_headers.py                                     # FILE_LOAD -> headers_observed.csv
python transformation/reference_data/header_map/build_header_map.py  # -> seed + review
```

Then review `header_map_review.md`, correct `header_map_seed.csv` by hand, and
load it per the COPY INTO in `sql/01_header_map.sql`.

## Not yet built

- The Snowpark procedure that walks `RAW_CONTENT` into `PAYROLL_ROW` /
  `FACT_PAYROLL_COMPONENT` using `HEADER_MAP`.
- Ad hoc bonuses are recorded **horizontally** while every other component is
  vertical (contract section 3). `FACT_PAYROLL_COMPONENT` can hold them, but the
  loader needs a specific branch for that shape.
- `DIM_SUBSIDIARY`. 21 labels observed; `CPQUALI` and `CPHOSP` carry no code
  prefix, and `BR02 - QIMA BRASIL LTDA.` has a trailing period the filename
  does not.
- Restatement handling. Each monthly submission restates the full year to date
  (contract section 1), so the same employee-year arrives repeatedly. Which
  submission wins is an open contract item (section 8).
