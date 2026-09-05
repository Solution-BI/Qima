# Runbook - running the transformation yourself

Written for someone new to Snowflake. Takes about ten minutes.

The model is already built and loaded, so you can start by simply looking at
it. Part 3 wipes and rebuilds it, which is the real test.

**The safety net:** every table we own rebuilds from `FILE_LOAD` in about five
seconds. `FILE_LOAD` is the ingestion pipeline's table and nothing here writes
to it - so there is nothing you can break that a rebuild does not fix.

**The one rule: never `truncate`, `delete from` or `drop` `FILE_LOAD`.** That
is the only irreplaceable table in the schema. Re-creating it would mean
re-running the SharePoint ingestion.

---

## Part 0 - Setup

1. <https://app.snowflake.com/sbi/sbi_singapore/>
2. **Projects -> Worksheets -> + Worksheet**
3. Paste this and run it. Every later step assumes it:

```sql
use role "SF_APA_SANDBOX-ETL";
use warehouse SANDBOX_WH;
use schema SANDBOX_DB.HR_PAYROLL_QIMA;
```

The quotes around the role matter - the hyphen would otherwise be read as a
minus sign. The warehouse takes a few seconds to wake on the first query.

---

## Part 1 - Look at what is there

All read-only. Nothing in this section can change anything.

```sql
select 'FILE_LOAD' as t, count(*) n from FILE_LOAD
union all select 'HEADER_MAP',      count(*) from HEADER_MAP
union all select 'SHEET_LOAD',      count(*) from SHEET_LOAD
union all select 'PAYROLL_ROW',     count(*) from PAYROLL_ROW
union all select 'FACT_PAYROLL_COMPONENT', count(*) from FACT_PAYROLL_COMPONENT;
```

Expect **8 / 668 / 11 / 21,811 / 216,101**.

Which files we process, and why one is skipped:

```sql
select LOAD_ID, FILE_NAME, IS_CURRENT, IS_EXCLUDED, EXCLUSION_REASON
from V_PAYROLL_FILE order by LOAD_ID;
```

Eight rows; three with `IS_EXCLUDED = FALSE` and `IS_CURRENT = TRUE` are the
real submissions.

One employee, everything we hold for them:

```sql
select COMPONENT_GROUP, COMPONENT_NAME, MEASURE_BASIS,
       PERIOD_KEY, AMOUNT, CURRENCY_CODE
from FACT_PAYROLL_COMPONENT
where EMPLOYEE_SAP_ID = '10000343' and REPORT_YEAR = 2026
order by COMPONENT_GROUP, PERIOD_KEY;
```

Note their salary is in INR and their bonus in USD. That is why GOLD never adds
the two together.

---

## Part 2 - Run the test

Still read-only. This is the proof the mapping is right: the spreadsheet has
twelve monthly salary columns and its own annual total, so the twelve should
reproduce the thirteenth.

Open `transformation/tests/reconcile_silver.sql`, paste the whole file, run it.

Expect:

| EMPLOYMENTS | MATCHES | REAL_MISMATCHES | TOTAL_MISSING |
|---|---|---|---|
| 2808 | 2784 | **0** | 24 |

`REAL_MISMATCHES = 0` is the number that matters. The 24 are employees whose
annual total cell was left empty in the spreadsheet - recent joiners the
formula was never filled down to.

---

## Part 3 - Wipe and rebuild

This is the actual test run. It empties the three tables we build and
regenerates them from `FILE_LOAD`.

**Do not add `HEADER_MAP` to this list.** It is loaded from a CSV by a Python
script, not from `FILE_LOAD`, so emptying it means it stays empty until someone
re-runs `load_seed.py`. Without it the loader produces nothing.

```sql
truncate table FACT_PAYROLL_COMPONENT;
truncate table PAYROLL_ROW;
truncate table SHEET_LOAD;
```

Confirm they are empty - all three should be 0:

```sql
select 'SHEET_LOAD' t, count(*) n from SHEET_LOAD
union all select 'PAYROLL_ROW',     count(*) from PAYROLL_ROW
union all select 'FACT_PAYROLL_COMPONENT', count(*) from FACT_PAYROLL_COMPONENT;
```

Now open `transformation/sql/04_load_silver.sql`, paste the whole file, and use
**Run All** (the dropdown beside the Run button). It runs three inserts and
takes around five seconds.

Expect **11**, then **21,811**, then **216,101** rows inserted.

Then re-run Part 2. You should get the same 2808 / 2784 / 0 / 24.

That is the whole thing proven: raw JSON in, reconciled payroll out, no column
position hardcoded anywhere.

### Running it twice

Run `04_load_silver.sql` again without truncating. Every insert reports **0
rows**. The loader skips sheets it has already loaded, so a scheduled re-run
picks up only new files rather than duplicating existing ones.

---

## If something goes wrong

| Symptom | Cause |
|---|---|
| `Object does not exist or not authorized` | Part 0 was not run, or the role is missing its quotes |
| Loader inserts 0 rows on a clean table | `HEADER_MAP` is empty - see the warning in Part 3 |
| `SQL compilation error` on `use role` | The quotes: `use role "SF_APA_SANDBOX-ETL";` |
| Everything returns nothing | Wrong database or schema in the worksheet context |

Dropped a table by accident? `undrop table <name>;` recovers it for 24 hours.
Truncated one of ours? Just redo Part 3.
