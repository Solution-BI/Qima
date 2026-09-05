# Meeting notes checked against the data

Four rules from the previous meeting, each tested against the current contents
of `SANDBOX_DB.HR_PAYROLL_QIMA.FILE_LOAD` rather than accepted on face value.
All four hold. One of them found a bug in the model as first written.

Scope for every figure below: `IS_CURRENT` files, sample workbook excluded,
`2026` sheets = **2,812 employee rows**.

---

## 1. "Only process what's current / has latest changes on SharePoint"

**Holds, with one gap.** `FILE_LOAD.IS_CURRENT` already implements this - the
ingestion notebook flips prior versions to `FALSE` keyed on
`SHAREPOINT_ITEM_ID`, so a resubmitted file supersedes its predecessor without
overwriting the history.

The gap: `IS_CURRENT` returns **four** files, and one is
`BR05_Payroll_Sample.xlsx` - a sample workbook, not a subsidiary submission.
Currency alone is not enough to identify real payroll.

**Implemented** as `V_PAYROLL_FILE_CURRENT` in `sql/03_file_exclusion.sql`:
current, successfully extracted, and not in `FILE_EXCLUSION`. Returns the three
real submissions.

`FILE_EXCLUSION` is keyed on `SHAREPOINT_ITEM_ID`, not file name - the sample
has already been renamed once (`BR02_Payroll_Sample.xlsx` to
`BR05_Payroll_Sample.xlsx`) while keeping its item id, so a name-based rule
would have silently stopped working at that rename.

The sample is verified, not assumed: 4 employee rows whose SAP IDs **and gross
salaries** all match the real BR02 file exactly (916 / 850 / 510 / 340);
18,672 bytes against 900,176; one `2026` sheet against four. It is a 4-row
extract of BR02, and it very likely still sits in the BR02 SharePoint folder -
so it will be re-ingested on the next run and must be excluded rather than
presumed gone.

## 2. "If there are duplicate IDs (different contract), use ID + join date + leave date + contract"

**Holds, and the composite key is exactly right.**

| Key | Distinct values across 2,812 rows |
|---|---|
| `EMPLOYEE_SAP_ID` | 2,810 - **collides** |
| `EMPLOYEE_SAP_ID + JOIN_DATE + LEAVE_DATE` | **2,812 - unique** |
| + `SUBSIDIARY` | 2,812 - adds nothing |

Only two duplicate IDs exist in the real files, and they are precisely the two
cases the note anticipated:

| SAP ID | Join | Leave | Subsidiary | Interpretation |
|---|---|---|---|---|
| 10019286 | 2025-12-01 | 2026-02-20 | CPQUALI | **transfer** - left one entity... |
| 10019286 | 2026-06-01 | *(open)* | CPHOSP | ...rejoined another |
| 10022433 | 2026-05-02 | 2026-06-15 | BR02 | **two contracts**, same entity, |
| 10022433 | 2026-05-21 | 2026-06-15 | BR02 | overlapping, different salaries |

10019286 is Antoine's point-in-time subsidiary requirement in live data: the
employee's earlier payments belong to CPQUALI and must not be re-attributed to
CPHOSP.

**One correction to the note:** *contract* cannot be part of the key. No 2026
generation has a contract column - `Contract` exists only in the three 2025
generations and `Full Time / Part time` only in 2024. Fortunately it is not
needed; ID + join + leave is already unique.

**Implemented as** `EMPLOYMENT_KEY` on `PAYROLL_ROW` and `FACT_PAYROLL_COMPONENT`, and
as the grain of the GOLD views. Earlier I reported five cross-file duplicate
IDs - three of those were artefacts of the sample file and are withdrawn.

## 3. "Currency is defined by contract"

**Holds.** Every generation carries a contractual `Currency` column under the
`Contractual salary` band (column J in 2026). It varies per employee, not per
subsidiary - `HK04 - QIMA Limited` alone reports 14 distinct currencies across
553 employees, consistent with it payrolling staff across several countries.

## 4. "Bonus component can have a different currency - separate bonus, contractual"

**Holds, and this is the dominant case, not an edge case.**

Comparing the contractual currency against the year-end bonus currency on the
same row:

| | Rows |
|---|---|
| Bonus currency **differs** from contract currency | **1,988** |
| Same | 431 |
| Bonus currency absent | 393 |

The largest patterns are local salary against USD bonus: RMB→USD (1,480),
INR→USD (162), HKD→USD (123), BDT→USD (69), VND→USD (60).

### This found a bug

The GOLD view as first written did:

```sql
sum(AMOUNT) as TOTAL_PAID ... group by EMPLOYEE_SAP_ID, CURRENCY_CODE
```

which would have added RMB salary to USD bonus for 1,480 employees and labelled
the result with one currency. Arithmetic on mixed units, and FX normalisation is
out of scope per the contract.

**Fixed.** `V_GOLD_ANNUAL_COMPENSATION` now carries `CURRENCY_CODE` in the grain
with no cross-component total. `V_GOLD_SINGLE_CURRENCY_EMPLOYMENT` gives a
safe total only for employments that report one currency throughout, so the
rest are visibly excluded rather than silently mis-added.

**Loader rule:** an amount takes its component's own `(Currency)` column where
the generation has one, and falls back to the contractual currency otherwise.

---

## Confirmed by the 20 August pre-kickoff

- **Vertical remodelling is the agreed target.** Antoine: unpivot both the
  monthly periods and the bonus components, and "it can be 3 tables or whatever,
  it doesn't have to be a single table with everything hardcoded." That is what
  `FACT_PAYROLL_COMPONENT` is.
- **Subsidiary is a frozen fact**, recording where the payment originated, not a
  current attribute - employees change subsidiary and the record must not follow
  them. Carried on every fact row.
- **The employee ID resolves against the main HR table** for all other
  attributes; payroll does not need to carry them. Name, join and leave dates
  are held here as informative only. Join and leave are additionally load-bearing
  for `EMPLOYMENT_KEY`, which is why they are kept rather than dropped.
- **No Tableau-specific design.** Antoine explicitly said sound modelling is the
  priority over designing for the BI tool.
- **Phase 2 removes Excel entirely**, taking data from source systems into this
  same model - so the model is the target for that work too, not a
  spreadsheet-shaped stopgap.

## Open, not answered by these notes

- Which submission wins when a monthly file restates the year to date
  (contract section 8).
- `BR09 + BR12 + BR13` names three codes for two legal names; which maps to
  which is unconfirmed.
- The 11 employees from seven subsidiaries no folder declares.
