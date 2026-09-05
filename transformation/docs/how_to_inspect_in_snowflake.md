# How to look at this in Snowflake

Written for someone new to Snowflake. Everything below is read-only.

## Getting in

1. <https://app.snowflake.com/sbi/sbi_singapore/>
2. Top left, **Projects -> Worksheets**, then **+ Worksheet**.
3. Above the editor set the context - this matters, queries fail without it:
   - **Role**: `SF_APA_SANDBOX-ETL`
   - **Warehouse**: `SANDBOX_WH` (the compute; it wakes on demand and sleeps after 60s)
   - **Database**: `SANDBOX_DB`, **Schema**: `HR_PAYROLL_QIMA`

Or paste this as the first line of any worksheet:

```sql
use role "SF_APA_SANDBOX-ETL";  use warehouse SANDBOX_WH;
use schema SANDBOX_DB.HR_PAYROLL_QIMA;
```

The quotes around the role are required - the hyphen in `SF_APA_SANDBOX-ETL`
would otherwise be read as a minus sign.

## The vocabulary

| Term | What it is |
|---|---|
| **Warehouse** | Compute. Costs credits only while running. Nothing to do with a "data warehouse". |
| **Database / Schema** | `SANDBOX_DB` is the database, `HR_PAYROLL_QIMA` the folder inside it. |
| **Role** | Your permissions. Same login, different role, different visibility. |
| **VARIANT** | A column holding JSON. `FILE_LOAD.RAW_CONTENT` is one. |
| **View** | A saved query, not stored data. Reading one re-runs it. |

## What we built, in plain terms

The spreadsheets arrive as JSON blobs - one `RAW_CONTENT` per file, holding
every sheet, every row, every cell, uninterpreted. Useless to query directly:
`RAW_CONTENT:"2026"[5][12]` means nothing to a human.

The job is turning that into rows you can query. The problem is that Qima's
template has changed seven times, so column 4 is *Subsidiary* in the 2026 files
but *Leave Date* in 2025, and the employee id moves from column 0 to column 1.
Hardcoding positions would need seven separate loaders.

So instead there is a lookup table, `HEADER_MAP`: 668 rows, one per column per
template version, saying what that column means. The loader reads it and works
out where everything is. **A new template version is a few new rows in
`HEADER_MAP` - not a code change.**

```
FILE_LOAD          the raw JSON, one row per file           (Greg's pipeline)
   |
   v   guided by HEADER_MAP
SHEET_LOAD         one row per sheet, with its template version
PAYROLL_ROW        one row per employee line
PAYROLL_MEASURE    one row per value - a salary, a bonus, a currency
   |
   v
V_GOLD_*           the clean views for reporting
```

## Queries to try

**What's in the schema:**
```sql
show tables in schema SANDBOX_DB.HR_PAYROLL_QIMA;
show views  in schema SANDBOX_DB.HR_PAYROLL_QIMA;
```

**Which files we process, and why the fourth is skipped:**
```sql
select LOAD_ID, FILE_NAME, IS_CURRENT, IS_EXCLUDED, EXCLUSION_REASON
from V_PAYROLL_FILE  order by LOAD_ID;
```

**What HEADER_MAP knows about one column** - the same header, four template
versions, four different positions:
```sql
select GENERATION, COLUMN_INDEX, COLUMN_LETTER, SOURCE_HEADER
from HEADER_MAP where CANONICAL_FIELD = 'EMPLOYEE_SAP_ID' order by GENERATION;
```

**One employee, everything we hold about them:**
```sql
select COMPONENT_GROUP, COMPONENT_NAME, MEASURE_BASIS,
       PERIOD_KEY, AMOUNT, CURRENCY_CODE
from PAYROLL_MEASURE
where EMPLOYEE_SAP_ID = '10000343' and REPORT_YEAR = 2026
order by COMPONENT_GROUP, PERIOD_KEY;
```

**Why salary and bonus can't simply be added** - salary in local currency,
bonus in USD:
```sql
select COMPONENT_GROUP, CURRENCY_CODE, count(*) as N
from PAYROLL_MEASURE
where REPORT_YEAR = 2026 and MEASURE_BASIS = 'PAYMENT'
  and COMPONENT_GROUP in ('SALARY','BONUS')
group by 1,2 having count(*) > 500 order by 1, 3 desc;
```

**Headcount by subsidiary:**
```sql
select SUBSIDIARY_CODE, count(distinct EMPLOYMENT_KEY) as EMPLOYEES
from PAYROLL_ROW where REPORT_YEAR = 2026 and not IS_BLANK
group by 1 order by 2 desc;
```

**Does the data agree with itself?** The template has twelve monthly salary
columns and its own annual total, so the twelve should reproduce the
thirteenth. Run `transformation/tests/reconcile_silver.sql` - currently 2,784
match, 0 disagree, 24 have no total filled in.

## Safe to run, and not

Everything above only reads. `select`, `show` and `desc` cannot change
anything.

Avoid `drop`, `delete`, `truncate`, `update` and `insert` unless you mean them.
Snowflake has no undo prompt - though a dropped table can be recovered within
24 hours with `undrop table <name>`.

To reload from scratch, the safe sequence is:

```sql
truncate table PAYROLL_MEASURE;  truncate table PAYROLL_ROW;
truncate table SHEET_LOAD;
```

then re-run `transformation/sql/04_load_silver.sql`. The loader skips sheets it
has already loaded, so running it twice does not duplicate anything.
