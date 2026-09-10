# Qima HR Payroll -- Transformation Design

**Scope:** SILVER and GOLD layers -- turning the raw JSON in `FILE_LOAD` into a
queryable payroll model. Everything upstream of `RAW_CONTENT` is covered by
`Qima_Payroll_Ingestion_Design.md`.

**Status:** Built and loaded in `SANDBOX_DB.HR_PAYROLL_QIMA`, reconciling
against the three current subsidiary submissions. Amount masking applied. Row
access policy, RBAC and scheduling not yet built -- see section 10.

**This is the only documentation file for the transformation layer.** Design
notes, data dictionary, business rules and open items all live here, so an
update means editing one file.

---

## 1. Design principle

Ingestion and extraction are deliberately dumb, so **all structural
interpretation happens here**. That interpretation is held as *data*, not code.

Qima's payroll template has seven distinct versions across the files received,
and the differences are structural rather than cosmetic -- the employee ID sits
at a different column position in 2026 than in 2024/2025, and the subsidiary
column was renamed from `Company Code` to `Subsidiary` along the way. Antoine
confirmed on 20 August that the wide template is deliberate and that further
column additions are expected, since every new bonus type becomes a new column
for every subsidiary even where it applies to a handful of employees in one
country.

Hardcoding column positions would therefore mean a separate loader per version,
and a new one each time the template changes. Instead:

- **`HEADER_MAP`** records what every column means in every template version.
- **The loader** resolves positions by querying that table.
- **Adding a template version is an `INSERT`**, not a code change.

Per the input data contract, a column that maps to nothing is a
convention-class issue to log -- never a reason to reject a file.

---

## 2. Data flow

```
                          FILE_EXCLUSION          HEADER_MAP
                        (not real payroll)   (what each column means)
                                 |                     |
                                 v                     |
   FILE_LOAD  ------->  V_PAYROLL_FILE_CURRENT         |
   (RAW, JSON)          three submissions              |
                                 |                     |
                                 v                     |
                          SHEET_LOAD  <----------------+
                          one row per sheet            |
                                 |                     |
                                 v                     |
                          PAYROLL_ROW  <---------------+
                          one row per employee         |
                                 |                     |
                                 v                     |
                     FACT_PAYROLL_COMPONENT  <---------+
                          one row per value
                                 |
                                 v
                            V_GOLD_*
                     reporting, amounts masked
```

Solid path carries data. `HEADER_MAP` carries meaning -- it tells each step
where to find a column, which is what lets the same three queries handle all
seven template versions.

**Current volumes:** 3 files, 11 sheets, 21,811 employee rows (8,137 carrying
data, the rest formatted-but-empty padding), 216,101 individual values.

---

## 3. Load steps

All four steps are plain SQL in `transformation/sql/`, followed by
`05_load_dq_flags.sql`. No Python runs in the pipeline; the scripts under
`reference_data/` exist only to regenerate `HEADER_MAP` when a new template
version appears.

**Always run the loader as a full reload** -- truncate the three model tables
first. Each step does carry a skip-check, but it keys on `FILE_LOAD.LOAD_ID`,
and ingestion writes a new row, and so a new `LOAD_ID`, on every run --
including a re-ingestion of a file it has already seen. After ingestion
re-runs, the skip-check therefore does not recognise the same file, and a plain
re-run loads a second copy of everything.

That is not hypothetical. The three source files were re-ingested on
7 September as `LOAD_ID` 905/906/1001, orphaning a model built on 723/811/813
and leaving lineage back to `FILE_LOAD` broken until it was reloaded.
Incremental loading keyed on `SHAREPOINT_ITEM_ID` plus `SHAREPOINT_MODIFIED_AT`
is possible if volumes ever justify it; a rebuild currently takes seconds, so
they do not.

### Step 1 -- Select the files to process

`V_PAYROLL_FILE_CURRENT` filters `FILE_LOAD` to rows that are `IS_CURRENT`,
successfully ingested and extracted, and not present in `FILE_EXCLUSION`.

`IS_CURRENT` alone is not sufficient. It returns four files, one of which is a
sample workbook parked inside a live submission folder -- a four-row extract
whose employee IDs and salaries all match the real BR02 file. Loading it would
duplicate genuine payroll.

### Step 2 -- Resolve each sheet's template version

Populates `SHEET_LOAD`. A workbook is not one dataset: each holds several year
sheets plus `Instructions`, and the year sheets are different template versions
from one another -- BR02's 2024 sheet is `2024-91col` while its 2026 sheet is
`2026-67col`.

The version is derived as `<sheet name>-<column count>col` and matched against
`HEADER_MAP`. Matching on column count rather than a header hash is deliberate:
a single corrected typo in one header would change a hash and orphan the file,
whereas the column count survives such edits.

Non-year sheets are recorded as `NOT_APPLICABLE` rather than skipped, so a
file's sheet inventory is complete and auditable.

### Step 3 -- One row per employee

Populates `PAYROLL_ROW` from sheets whose version is mapped. Every attribute is
located by asking `HEADER_MAP` for it by `CANONICAL_FIELD`, never by position.

Blank rows are flagged rather than discarded -- two of the three workbooks are
roughly 96% formatted-but-empty padding, and the count needs to stay auditable.

`ROW_DATA` retains the full cell array so a `HEADER_MAP` correction can be
replayed without re-downloading from SharePoint.

### Step 4 -- One row per value

Populates `FACT_PAYROLL_COMPONENT`. Every cell that `HEADER_MAP` says carries a
value becomes a row, classified by component, measure basis, period and
currency scope.

Currency is resolved per component: an amount takes its own component's
`(Currency)` column where the template provides one, falling back to the
contractual currency otherwise. Section 6.3 explains why.

---

## 4. Reference data

Reference data is versioned as CSV in the repository and loaded into Snowflake,
so a change is a reviewable diff rather than an untraceable table edit.

### Table: HEADER_MAP

The single place where structural interpretation lives. One row per column per
template version -- 668 rows covering seven supported versions plus one sample.

Loaded from `transformation/reference_data/header_map/header_map_seed.csv`.

```sql
CREATE TABLE HEADER_MAP (
    GENERATION          VARCHAR      NOT NULL,
    COLUMN_INDEX        NUMBER(38,0) NOT NULL,
    COLUMN_LETTER       VARCHAR,
    SHEET_YEAR          NUMBER(4,0)  NOT NULL,
    GENERATION_STATUS   VARCHAR      NOT NULL DEFAULT 'SUPPORTED',
    GROUP_HEADER        VARCHAR,
    SOURCE_HEADER       VARCHAR,
    COMPONENT_GROUP     VARCHAR      NOT NULL,
    COMPONENT_NAME      VARCHAR      NOT NULL,
    MEASURE_BASIS       VARCHAR      NOT NULL,
    CANONICAL_FIELD     VARCHAR,
    PERIOD_TYPE         VARCHAR,
    PERIOD_KEY          VARCHAR,
    CURRENCY_SCOPE      VARCHAR      NOT NULL DEFAULT 'LOCAL',
    NEEDS_REVIEW        BOOLEAN      NOT NULL DEFAULT FALSE,
    REVIEW_REASON       VARCHAR,
    RESOLUTION_NOTE     VARCHAR,
    CREATED_AT          TIMESTAMP_TZ NOT NULL DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT PK_HEADER_MAP PRIMARY KEY (GENERATION, COLUMN_INDEX)
);
```

| Column | Description |
|---|---|
| GENERATION | Template version, `<sheet year>-<column count>col`, e.g. `2026-75col`. |
| COLUMN_INDEX | Zero-based position in the sheet's row array. What the loader reads with. |
| COLUMN_LETTER | Excel reference (A, B, ... BM). For discussing a specific column with Qima. |
| SHEET_YEAR | The year the sheet reports on. |
| GENERATION_STATUS | `SUPPORTED` = a real Qima template. `SAMPLE` = a test artefact that must never load as payroll. |
| GROUP_HEADER | Row 0 merged band label, forward-filled across the columns it spans. Identifies the scheme. |
| SOURCE_HEADER | Row 1 header text, verbatim -- embedded newlines and trailing spaces preserved. |
| COMPONENT_GROUP | `SALARY`, `BONUS`, `COMMISSION`, `EXTERNAL`, `ADHOC` per the data contract, plus `EMPLOYEE` and `OTHER` for non-payment columns. |
| COMPONENT_NAME | The specific scheme: `MONTHLY_SALARY`, `YEAR_END`, `CCLAB`, `EID_FESTIVAL_FEB` and so on. |
| MEASURE_BASIS | `PAYMENT` (money paid), `RATE` (a contractual position or ceiling), `FEE` (external headcount cost), plus `ELIGIBILITY`, `CURRENCY` and `ATTRIBUTE` for columns that qualify a payment rather than being one. |
| CANONICAL_FIELD | Which specific field this column is, where the loader needs it by name -- `EMPLOYEE_SAP_ID`, `SUBSIDIARY`, `JOIN_DATE`, `LEAVE_DATE`, `CONTRACT_CURRENCY`. Populated for 138 of 668 columns; the rest are measurements handled in bulk. |
| PERIOD_TYPE | `MONTH`, `QUARTER` or `FY`. Null for eligibility, currency and attribute columns. |
| PERIOD_KEY | `YYYY-MM`, `YYYY-Qn` or `YYYY`. Null where PERIOD_TYPE is null. |
| CURRENCY_SCOPE | `LOCAL`, `USD` or `NA`. The 2024/2025 templates carry a second copy of most amounts converted to USD at unknown rates -- 154 of 668 columns. |
| NEEDS_REVIEW | True where the classification could not be decided. Loads anyway, excluded from GOLD. |
| REVIEW_REASON | Why it could not be decided. |
| RESOLUTION_NOTE | Set where a band/header conflict was resolved deliberately -- see section 6.4. |
| CREATED_AT | When the row was loaded. |

**Why `CANONICAL_FIELD` is separate from `COMPONENT_NAME`.** `COMPONENT_NAME`
says which scheme a column belongs to; it does not say which *field* it is. All
88 employee columns classify identically as `EMPLOYEE_ATTR`, so without
`CANONICAL_FIELD` the loader cannot find the employee ID. Position cannot be
assumed either -- the ID is at index 0 in 2026 and index 1 in 2024/2025.

### Table: FILE_EXCLUSION

SharePoint items that are not genuine payroll submissions.

| Column | Description |
|---|---|
| SHAREPOINT_ITEM_ID | Primary key. The stable SharePoint item id. |
| KNOWN_AS | Every file name this item has been seen under. Informational -- never join on it. |
| REASON | `SAMPLE`, `TEST`, `DUPLICATE`, `WITHDRAWN` or `NOT_PAYROLL`. |
| EVIDENCE | Why this was judged not a submission. Excluding payroll data requires a stated reason. |
| EXCLUDED_ON | Date of the decision. |
| EXCLUDED_BY | Who made it. |

**Why the item id and not the file name.** The one excluded workbook has
already been renamed once while keeping the same item id. A name-based rule
would have stopped working at that rename, silently, with no error to notice.

---

## 5. Model tables

### Table: SHEET_LOAD

One row per sheet inside an ingested workbook, with its resolved template
version. Makes template drift visible before anything tries to parse it.

| Column | Description |
|---|---|
| SHEET_LOAD_ID | Surrogate key. |
| LOAD_ID | FK to `FILE_LOAD`. |
| SHEET_NAME | Key from `RAW_CONTENT`, e.g. `2026` or `Instructions`. |
| SHEET_YEAR | Parsed from SHEET_NAME when it is a four-digit year; null otherwise. |
| GENERATION | FK to `HEADER_MAP.GENERATION`. Null when unmatched. |
| COLUMN_COUNT | Width of the header row. Part of how the version is identified. |
| HEADER_HASH | Fingerprint of the header row. Not the join key -- a corrected typo changes it -- but a change here on a known version is worth alerting on. |
| HEADER_JSON | The header row verbatim, so a new version can be mapped without reopening the workbook. |
| TOTAL_ROWS | Rows in the sheet, including trailing blanks. |
| DATA_ROWS | Rows carrying an employee id. Some sheets are over 95% padding. |
| MAPPING_STATUS | `MAPPED`, `UNMAPPED`, `SAMPLE` or `NOT_APPLICABLE`. Only `MAPPED` proceeds. |
| CREATED_AT | When the row was written. |

### Table: PAYROLL_ROW

One row per employee line on a mapped sheet.

Per the data contract, `EMPLOYEE_SAP_ID` is the only field trusted from this
file. Name and dates are informative and resolve from Qima's HR system
downstream. Subsidiary is the deliberate exception -- Antoine confirmed it must
be a point-in-time fact tied to the payment, because an employee who transfers
must not have historic payments re-attributed to the new entity.

| Column | Description |
|---|---|
| PAYROLL_ROW_ID | Surrogate key. |
| SHEET_LOAD_ID | FK to `SHEET_LOAD`. |
| ROW_INDEX | Index in the sheet array. Row 0 is the merged band, row 1 the headers, data starts at 2. |
| REPORT_YEAR | The year this row reports on. |
| EMPLOYEE_SAP_ID | Authoritative. Held as text, not numeric -- a non-numeric id must not be silently dropped. |
| SUBSIDIARY_CODE | Parsed from SUBSIDIARY_RAW as the part before the first ` - `. Point-in-time. |
| SUBSIDIARY_RAW | The cell verbatim. Not every label carries a code prefix. |
| EMPLOYEE_NAME | Informative only. |
| JOIN_DATE | Informative, but load-bearing for EMPLOYMENT_KEY. |
| LEAVE_DATE | Informative, but load-bearing for EMPLOYMENT_KEY. |
| EMPLOYMENT_KEY | `EMPLOYEE_SAP_ID \| JOIN_DATE \| LEAVE_DATE`. The grain of an employment, not of a person -- see section 6.2. |
| IS_BLANK | True for a formatted-but-empty row. Flagged rather than discarded so counts stay auditable. |
| ROW_DATA | The full cell array, retained so a mapping fix can be replayed without re-ingesting. |
| LOADED_AT | When the row was written. |

### Table: FACT_PAYROLL_COMPONENT

The target model. One row per cell that carries a value.

**Grain:** `PAYROLL_ROW` x `COMPONENT_NAME` x `MEASURE_BASIS` x `PERIOD_KEY` x
`CURRENCY_SCOPE`.

Long rather than wide, because the set of components differs per template
version -- the Eid festival blocks exist in only one, the USD columns in two,
ad hoc bonuses only from 2026. Wide columns would mean a DDL change per
version; long absorbs them as data. This is the structure Antoine specified on
20 August: unpivot both the monthly periods and the bonus components, with no
hardcoded component list.

| Column | Description |
|---|---|
| MEASURE_ID | Surrogate key. |
| PAYROLL_ROW_ID | FK to `PAYROLL_ROW`. Lineage back to the original cell array. |
| SHEET_LOAD_ID | FK to `SHEET_LOAD`. |
| EMPLOYEE_SAP_ID | Copied from PAYROLL_ROW. |
| EMPLOYMENT_KEY | Copied from PAYROLL_ROW. Aggregating on SAP ID alone would merge two contracts into one person. |
| JOIN_DATE | Copied, so GOLD can group without joining back. |
| LEAVE_DATE | Copied. |
| SUBSIDIARY_CODE | Point-in-time, copied from PAYROLL_ROW. Do not resolve this live. |
| REPORT_YEAR | The year this value reports on. |
| COMPONENT_GROUP | From HEADER_MAP. |
| COMPONENT_NAME | From HEADER_MAP. |
| MEASURE_BASIS | From HEADER_MAP. |
| PERIOD_TYPE | `MONTH`, `QUARTER`, `FY`. |
| PERIOD_KEY | `YYYY-MM`, `YYYY-Qn`, `YYYY`. |
| CURRENCY_SCOPE | `LOCAL` or `USD`. Only `LOCAL` reaches GOLD. |
| AMOUNT | Set where MEASURE_BASIS is PAYMENT, RATE or FEE and the cell parsed as a number. **Masked.** |
| CURRENCY_CODE | The component's own currency where the template has one, otherwise the contractual currency. Files use `RMB` where ISO is `CNY`. |
| IS_ELIGIBLE | Set where MEASURE_BASIS is ELIGIBILITY, from the Y/N dropdown. |
| TEXT_VALUE | Set where a value that should be numeric is not -- the contract's "salary entered as text" case. Kept, not dropped. **Masked.** |
| RAW_VALUE | The cell exactly as extracted, always populated, for dispute resolution. **Masked.** |
| SOURCE_COLUMN_INDEX | Which column this value came from. Lineage back to HEADER_MAP. |
| LOADED_AT | When the row was written. |

### Table: DQ_FLAG

Data quality findings, classified per the input data contract. **The table and
its four classes exist; the loader does not yet write to it.**

| Column | Description |
|---|---|
| FLAG_ID | Surrogate key. |
| LOAD_ID / SHEET_LOAD_ID / PAYROLL_ROW_ID / MEASURE_ID | Whichever level the finding applies to. |
| DQ_CLASS | `STRUCTURAL` rejects the file or sheet. `IDENTITY` loads but is excluded from GOLD until resolved. `VALUE` loads and stays in GOLD with the flag visible. `CONVENTION` is auto-resolved where possible and logged for a HEADER_MAP update. |
| RULE_NAME | e.g. `UNMAPPED_GENERATION`, `SALARY_AS_TEXT`, `MISSING_CURRENCY`, `SUBSIDIARY_NOT_DECLARED_BY_FOLDER`, `TOTAL_MISMATCH`. |
| COLUMN_INDEX / SOURCE_HEADER / RAW_VALUE | Where and what. RAW_VALUE is **masked**. |
| MESSAGE | Human-readable detail. |
| CREATED_AT | When the finding was raised. |

### Views

| View | Purpose |
|---|---|
| `V_PAYROLL_FILE` | Every file with whether it is excluded and why. |
| `V_PAYROLL_FILE_CURRENT` | The files the loader processes. The single place that rule lives. |
| `V_SHEET_GENERATION` | Resolves a sheet to its template version, and whether it is mapped or a sample. |
| `V_GOLD_PAYROLL_COMPONENT` | Values safe for reporting: local currency, mapped versions, no identity-class flags. |
| `V_GOLD_ANNUAL_COMPENSATION` | Totals per employment, per component group, **per currency**. Deliberately no cross-component total. |
| `V_GOLD_SINGLE_CURRENCY_EMPLOYMENT` | A single total, only for employments reporting one currency throughout. |

---

## 6. Business rules and the reasoning behind them

### 6.1 Process only what is current

Ingestion retains every version of every file and marks superseded ones
`IS_CURRENT = FALSE`, keyed on the SharePoint item id. The transformation rule
is to process only what is current -- **and not excluded**.

Both halves are needed. `IS_CURRENT` returns four files; one is a sample
workbook. `V_PAYROLL_FILE_CURRENT` applies both conditions plus a check that
ingest and extract both succeeded.

### 6.2 Employee identity where the ID repeats

`EMPLOYEE_SAP_ID` is the only field trusted from this file, and it is not
unique. Across 2,812 current employee rows there are 2,810 distinct IDs.

| Key | Distinct values | Verdict |
|---|---|---|
| `EMPLOYEE_SAP_ID` | 2,810 | collides |
| `+ JOIN_DATE + LEAVE_DATE` | **2,812** | unique |
| `+ SUBSIDIARY` | 2,812 | adds nothing |

Both collisions are legitimate. One employee left one subsidiary and rejoined
another mid-year -- a transfer, and exactly the case that makes point-in-time
subsidiary necessary. The other holds two overlapping contracts at the same
entity with different salaries.

The composite is stored as `EMPLOYMENT_KEY` and is the grain of the GOLD views.
Grouping on `EMPLOYEE_SAP_ID` alone would merge two contracts into one person.

**Note:** contract type cannot form part of the key, though it was originally
proposed. No 2026 template has a contract column -- `Contract` exists only in
the 2025 versions and `Full Time / Part time` only in 2024. It is also
unnecessary, since ID plus join plus leave is already unique.

### 6.3 Currency belongs to the component, not the employee

Salary is paid in local currency; bonuses are largely denominated in USD.
Comparing the contractual currency against the year-end bonus currency on the
same row:

| | Rows |
|---|---|
| Bonus currency **differs** from contract currency | 1,988 |
| Same | 431 |
| Bonus currency absent | 393 |

The largest single pattern is RMB salary against USD bonus, at 1,480 rows.

Each amount therefore takes its own component's currency where the template
provides one, falling back to the contractual currency otherwise.

**Consequence:** the reporting layer never sums salary and bonus into a single
figure. FX normalisation is out of scope per the data contract, so doing so
would be arithmetic across units presented as a total.
`V_GOLD_ANNUAL_COMPENSATION` carries currency in its grain;
`V_GOLD_SINGLE_CURRENCY_EMPLOYMENT` provides a safe total only where one
currency applies throughout.

The 2024 and 2025 templates additionally carry a USD copy of most amounts,
converted at rates the contract describes as inconsistent and unknown. Those
load tagged `CURRENCY_SCOPE = 'USD'` and never reach GOLD.

### 6.4 Two template defects, resolved in opposite directions

Both are Qima-side and persist across versions. Neither can be a blanket rule,
which is why the classification flags conflicts rather than guessing.

1. **`Eligible for Holiday Bonus` under the Profit sharing band**, in all five
   2024/2025 versions. The column is profit-sharing eligibility; the header text
   was copy-pasted from the block above and never corrected. **The band wins.**
2. **`Commission (Currency)` under the Auditor Bonus band**, in both 2026
   versions. Here the header is right -- the merged band runs one column too
   wide. **The header wins.**

Both belong in the change-notification conversation the data contract flags as
its largest open gap, rather than being absorbed silently.

### 6.5 Subsidiaries declared versus subsidiaries present

The three SharePoint folder names declare 16 subsidiary codes. The data does
not match:

- One declared code has zero employees in the 2026 sheet.
- Seven subsidiaries appear that no folder declares -- 11 employees in total,
  all inside the multi-subsidiary file.

Those same rows carry most of the currency anomalies. The pattern suggests
stragglers appended to whichever workbook was open rather than deliberate
submissions. `SUBSIDIARY_NOT_DECLARED_BY_FOLDER` is the DQ rule for this.

**Both figures above are from the original analysis and cannot be re-run as
things stand.** `FOLDER_SUBSIDIARY_MAP` lives as a CSV in
`reference_data/subsidiary/` and was never deployed to the schema, so nothing in
the database currently knows which subsidiaries a folder declares. Deploying it
is the prerequisite for reproducing these counts and for implementing the rule.

The folder names are also the only source for the CPQUALI / CPHOSP codes, since
those cells carry no code prefix. One folder names three codes for two legal
names, so which maps to which is unconfirmed.

### 6.6 Restatement -- lock the year, not the month

Every monthly file restates the year to date, so a correction to an
already-reported month arrives inside an ordinary submission. The treatment was
open until Greg ruled on it in the 7 September call:

> Previous **years** are locked. Within the current year, a change to a past
> month is kept and flows through.

Locking per month was considered and rejected as impractical. The reasoning is
accounting rather than technical: payroll has to reconcile to the books for
salaries and benefits, and the books close around day plus 10 (Antoine, same
call, salary slightly earlier). An adjustment for December therefore gets booked
in January, so a month-level lock in this platform would disagree with finance
either way. Mathieu flagged that finance still needs to sign the treatment off.

Two consequences:

- **A year-locking mechanism does not exist yet.** See section 10.
- Tess noted the rest is a communications matter for the payroll owners rather
  than a platform control: do not rename the year tab, and be aware that editing
  a previous month will be reflected.

### 6.7 Paid date versus period covered -- phase two

Tess confirmed in the same call that **date paid is not captured today** in any
template generation, and described the target logic: each pay component should
record both the date it was paid and the period it covers. Salary paid on
31 January covering January is the ordinary case; the value of the pair is the
exception, where a correction paid on 31 January is actually *for* December.

Half of this already exists. `PERIOD_TYPE` and `PERIOD_KEY` on
`FACT_PAYROLL_COMPONENT` are the period covered. What is missing is the paid
date, which no source column supplies -- the only dates in any generation are
join and leave.

**Explicitly deferred: Tess placed this in a second phase, not the current
scope.** It is recorded here so the eventual shape is not re-derived from
scratch, and because it is the mechanism that makes a restatement auditable
rather than merely permitted.

---

## 7. Security

Requirement, confirmed 20 August: **amount columns only, all rows visible.**
Employee attributes stay unmasked deliberately -- that data is already exposed
in other tables, so masking it here achieves nothing while it remains readable
elsewhere.

Masking is the primary control for the data team, layered on top of database
access. The concern it mitigates is someone granting themselves a full view for
a short window; a policy attached to the column holds even then.

### Policies

| Policy | Applies to |
|---|---|
| `MP_PAYROLL_AMOUNT` | `FACT_PAYROLL_COMPONENT.AMOUNT` |
| `MP_PAYROLL_AMOUNT_TEXT` | `FACT_PAYROLL_COMPONENT.RAW_VALUE`, `.TEXT_VALUE`, `DQ_FLAG.RAW_VALUE` |
| `MP_PAYROLL_ROW_VARIANT` | `PAYROLL_ROW.ROW_DATA` |

**Masking `AMOUNT` alone would leak.** The same figure is reachable through the
verbatim raw value, the text value where a salary was typed as text, and
`ROW_DATA`, which holds an entire spreadsheet line. Views inherit a policy from
the column they select, so the GOLD views are covered without policies of their
own.

### Masked value

`NULL` (hidden), agreed as the working choice. `AMOUNT` is `NUMBER(18,2)` and a
policy must return the column's type -- a string mask is accepted at policy
creation and then fails at query time. A sentinel such as `0` is worse than
null, because sums over zeros return confident, plausible, wrong totals.

Whether the final form is hidden, anonymised or a fixed value is still open
with HR. Changing it is one `ALTER MASKING POLICY ... SET BODY` per policy; the
shape does not change. Note that `CREATE OR REPLACE` is rejected once a policy
is attached.

### Entitlement

The policy grants on `IS_ROLE_IN_SESSION`, so entitlement follows the grant
rather than the selected role. `CURRENT_ROLE` would demonstrate more
convincingly but is weaker -- anyone entitled could unmask by switching primary
role back. The control is the grant: a user who should not see amounts is
simply never granted the role.

`PAYROLL_AMOUNT_READER` is a placeholder that maps to the real access-role
ladder on migration.

---

## 8. Verification

The 2026 template contains its own checksum: twelve monthly salary columns and
a thirteenth reporting their total. If `HEADER_MAP` has identified the right
twelve, summing them must reproduce the thirteenth.

Locating every column through `HEADER_MAP` -- no hardcoded positions:

| | Result |
|---|---|
| Employments checked | 2,808 |
| Match | **2,784** |
| Disagree | **0** |
| No total in the source file | 24 |

The 24 have monthly salary but an empty annual total -- recent joiners the
spreadsheet formula was never extended to, not a mapping failure.

This validates the salary mapping and the loader across three files and three
template versions. **It does not validate the bonus schemes** -- nothing in the
file cross-checks those, and the classification has not been reviewed by Qima.

The query is `transformation/tests/reconcile_silver.sql`. An annotated
walkthrough of the whole layer is `transformation/tests/demo_walkthrough.sql`.
Every scenario tested, its result, and what is deliberately not covered is
recorded in `transformation/tests/test_results.md`.

---

## 9. Maintenance

### When Qima changes the template

1. Run `reference_data/header_map/extract_headers.py` -- reads `FILE_LOAD` and
   writes `headers_observed.csv`.
2. Run `reference_data/header_map/build_header_map.py` -- classifies them into
   `header_map_seed.csv` and lists anything it could not decide in
   `header_map_review.md`.
3. Review and correct the seed by hand.
4. Run `reference_data/header_map/load_seed.py` -- truncates and reloads.

No SQL changes. A sheet whose version is unrecognised loads as `UNMAPPED` and
raises a flag rather than failing.

### Reloading the model

```sql
TRUNCATE TABLE FACT_PAYROLL_COMPONENT;
TRUNCATE TABLE PAYROLL_ROW;
TRUNCATE TABLE SHEET_LOAD;
```

then re-run `transformation/sql/04_load_silver.sql` followed by
`05_load_dq_flags.sql`. Rebuild takes seconds.

This is the only supported way to run the loader -- see section 3.

**Do not truncate `HEADER_MAP` alongside these.** It loads from CSV rather than
from `FILE_LOAD`, so emptying it leaves the loader with no way to interpret any
column -- it will run and insert nothing.

### File layout

```
transformation/
    sql/          01_header_map, 02_silver_model, 03_file_exclusion,
                  04_load_silver, 05_load_dq_flags,
                  90_staging_consolidated (outside the model)
    reference_data/  header_map/, subsidiary/, file_exclusion/
    tests/        reconcile_silver.sql, reconcile_monthly_vs_total.sql,
                  demo_walkthrough.sql
    lib/          connection helper for the reference-data scripts
    docs/         this file
security/
    masking/      01_amount_masking_policies.sql
```

Run order for a fresh deployment: `01`, `03`, `02`, `04`, then the seeds, then
masking. `03` precedes `02` because the silver views reference the exclusion
view.

---

## 10. Open items

### Closed by the 9 September review

Seventeen integrity checks were run against the loaded model; thirteen passed
and four did not. Note that **Snowflake does not enforce primary key, unique or
foreign key constraints** -- they are metadata only -- which is why each was
tested by query, and how the first two below went unnoticed.

- **Fact grain was not unique.** 8,120 duplicate keys. Four distinct
  contractual columns -- gross salary, allowance, employer social charges, and
  their total -- all classified as `CONTRACT_SALARY` / `RATE` with a null
  period, so they collided. The fourth is the sum of the other three, so
  summing the group double-counted. `CANONICAL_FIELD` already held the correct
  four names; they were promoted into `COMPONENT_NAME`. Fixed.
- **The model was built from superseded loads.** See section 3. Fixed by a full
  reload.
- **Sample files were being skipped by coincidence** rather than by rule --
  caught only because their column count happened to match a generation flagged
  `SAMPLE`. Three explicit exclusions added, including the current item id for
  the BR02 sample: a SharePoint item id survives a rename but **not** a delete
  and re-upload, so the original exclusion had silently stopped matching
  anything.
- **`DQ_FLAG` is now populated** by `05_load_dq_flags.sql` -- 517 findings, all
  `VALUE` class, so nothing is withheld from GOLD.

### Not built

- **`SUBSIDIARY_NOT_DECLARED_BY_FOLDER`.** The one data-quality rule that
  cannot be written yet. `FOLDER_SUBSIDIARY_MAP` exists as a CSV in
  `reference_data/subsidiary/` but was never deployed to the schema, so nothing
  in the database knows which subsidiaries a folder declares. Deploying it is
  the prerequisite for both this rule and for reproducing the "11 employees
  from undeclared subsidiaries" figure in section 6.5.
- **Year locking.** Required by the restatement rule in section 6.6: previous
  years locked, current year open to correction. No mechanism exists.
- **Row access policy.** Mechanism confirmed 20 August: a table of ID and
  parent, a comma-separated list of permitted IDs, and a policy checking
  containment of the querying identity, applied directly on the main table. To
  be **replicated inside the payroll database, not reused** from the shared
  mechanism.
- **RBAC roles.** Awaiting the base role structure from Qima.
- **Scheduling.** The loader runs manually. A Snowflake Task is the intended
  mechanism; note that account-level roles are required for tasks, while
  database roles are preferred for objects.
- **Ad hoc bonuses** are recorded horizontally, unlike every other component.
  The model can hold them; the loader has no branch for that shape, and no
  current data exercises it.

### Needs a decision

- **`FILE_LOAD.RAW_CONTENT` is not masked.** It holds every amount in every
  workbook, so masking downstream does not protect anyone who can read that
  table. It belongs to the ingestion stage. The likely answer is that RAW is
  not granted to the roles this defends against -- worth confirming rather than
  assuming.
- **Masked value format** -- hidden, anonymised or fixed. Currently null.
- **HEADER_MAP review.** The classification is a draft. Nothing in the source
  file cross-checks the bonus schemes, so a review by Tess is the only way to
  confirm them.
- **Finance sign-off on the restatement rule.** The treatment itself is decided
  (section 6.6); Mathieu flagged in the 7 September call that finance has not
  confirmed it reconciles with how the books actually close.

### Deferred to a later phase

- **`DATE_PAID` on each component.** Paid date separate from period covered --
  see section 6.7. Placed out of current scope by Tess on 7 September, recorded
  so the target shape is not lost.

### Environment

Everything currently sits in `SANDBOX_DB.HR_PAYROLL_QIMA` -- one flat schema in
SBI's sandbox, not Qima's account. The target is a dedicated `HR_PAYROLL`
database plus `HR_PAYROLL_DEV`, carrying separate RAW, SILVER and GOLD schemas.
On migration: `FILE_LOAD` to RAW, reference and model tables to SILVER, the
`V_GOLD_*` views to GOLD.

---

## 11. Plain-language description (for Qima)

The payroll spreadsheets arrive as raw data -- every sheet, every cell, exactly
as submitted, with nothing yet understood about what any of it means. This step
turns that into a structured model that can be reported on.

The difficulty is that the payroll template has changed several times over the
years, and columns have moved and been renamed between versions. Rather than
building something that assumes a fixed layout -- which would break the next
time the template changes -- the platform keeps a reference table describing
what every column means in every version of the template. When a new column is
added, that reference is updated. No rebuilding is required.

Each value is stored individually rather than as a fixed set of columns, so new
bonus types are absorbed automatically as they appear. Every payment records
the subsidiary it came from at the time it was paid, so an employee who moves
between entities does not have their earlier payments reassigned.

Amounts are hidden from anyone not specifically entitled to see them, while
every row remains visible -- so the data can be worked with and audited without
compensation figures being exposed.

Because salaries are paid in local currencies and bonuses are often paid in US
dollars, the platform deliberately never adds the two together into a single
figure. Converting between currencies is outside the agreed scope, and a
combined total would be misleading.

The model can be checked against the spreadsheets themselves: the template
totals its own monthly salary columns, and the platform reproduces that total
for every employee where the file provides it, with no discrepancies.
