# Transformation – Test Scenarios and Results

**Layer under test:** RAW (`FILE_LOAD`) → SILVER (`PAYROLL_ROW`, `FACT_PAYROLL_COMPONENT`) → GOLD (`V_GOLD_*`).

**Environment:** `SANDBOX_DB.HR_PAYROLL_QIMA`, warehouse `SANDBOX_WH`, role `SF_APA_SANDBOX-ETL`.
Not Qima's account – see design doc §10, "Environment".

**Last executed:** 7 September 2026. Every result below is from that run, not
transcribed from an earlier one. Re-running the SQL named in each scenario
reproduces it.

**Data under test:** three subsidiary submissions, seven template generations,
668 `HEADER_MAP` rows, 21,811 `PAYROLL_ROW` rows, 216,101 `FACT_PAYROLL_COMPONENT` rows.

---

## Summary

| | Scenarios | Result |
|---|---|---|
| Covered by an executable test | 7 | 7 pass, 0 fail |
| Structural checks, 11 September rebuild | 40 | 40 pass, 0 fail |
| Findings now written to `DQ_FLAG` | 5 rules | 1,704 findings |
| Not covered – no test, and in most cases no data that would exercise one | 7 | listed below |

No test currently fails. The honest caveat is what is **not** tested: the
coverage below validates salary mapping and loader fidelity, and does **not**
validate the bonus scheme classification, because nothing in the source files
cross-checks it.

**11 September rebuild.** The model was rebuilt after `SHEET_LOAD` became
`TAB_LOAD`, four columns were dropped from the fact, `FILE_EXCLUSION` was
replaced by a filename rule, and reporting gained a current-year default. It
was verified with 40 checks across two passes:

- row counts and value distribution identical to before the change
- the 2,784 / 0 reconciliation unchanged
- a second full reload reproduces an **identical content hash**, so the build
  is deterministic
- both loaders are idempotent – running them twice gives the same result
- no deployed view references a dropped object
- the `EMPLOYEE_MISSING_FROM_ROSTER` count recomputed independently and matched

---

## 1. Scenarios covered

### T1 – Only current, non-excluded files are processed

**Why:** ingestion keeps every version of every file. Processing a superseded
version, or the sample workbook parked in a live submission folder, would
duplicate genuine payroll.

**How:** `select * from V_PAYROLL_FILE where IS_CURRENT` (view defined in `sql/02_silver_model.sql`).

| File | Current | Excluded | Reason |
|---|---|---|---|
| AE01 + BD01 + IN01 + VN01 + SA01 + HK2-4-6 + CN2.xlsx | yes | no | – |
| BR02 – QIMA BRASIL LTDA.xlsx | yes | no | – |
| BR09 – CP_QUALI QIMA Payroll reporting template – Copiar.xlsx | yes | no | – |
| BR05_Payroll_Sample.xlsx | yes | **yes** | SAMPLE |

**Result: pass.** 8 rows in `FILE_LOAD`, 4 current, 3 processed. The exclusion is
keyed on SharePoint item id, not file name – that sample has already been renamed
once while keeping its id, so a name-based rule would have failed silently.

### T2 – HEADER_MAP resolves every supported generation

**Why:** the employee ID sits at a different column position in 2026 than in
2024/2025, and the subsidiary column was renamed. Hardcoded positions would need
a loader per generation.

**How:** `tests/demo_walkthrough.sql` §2–3.

**Result: pass.** Seven generations marked SUPPORTED, 668 mapped columns, 15–17
component schemes per generation. Adding a generation is an INSERT, not a code change.

### T3 – Column mapping is correct, tested against RAW

**Why:** the 2026 template carries its own checksum – twelve monthly salary
columns and a thirteenth reporting their total. If HEADER_MAP identified the
right twelve, summing them must reproduce the thirteenth. No column position is
hardcoded in the test; every column is located through HEADER_MAP, exactly as
the loader does it.

**How:** `tests/reconcile_monthly_vs_total.sql`, run straight against `RAW_CONTENT`.

| File | Employees | Month cols found | Matches | **Mismatches** | Total missing |
|---|---|---|---|---|---|
| AE01 + BD01 + IN01 + VN01 + SA01 + HK2-4-6 + CN2 | 2,341 | 12–12 | 2,337 | **0** | 0 |
| BR02 – QIMA BRASIL LTDA | 303 | 12–12 | 283 | **0** | 14 |
| BR09 – CP_QUALI | 168 | 12–12 | 164 | **0** | 0 |
| **Total** | **2,812** | | **2,784** | **0** | 14 |

**Result: pass.** Zero disagreements across three files and three template versions.

### T4 – The loader preserves that mapping into SILVER

**Why:** T3 proves HEADER_MAP is right. It does not prove the loader wrote what
HEADER_MAP said. This runs the same checksum against the loaded table.

**How:** `tests/reconcile_silver.sql`.

| Employments checked | Matches | **Mismatches** | No total in source |
|---|---|---|---|
| 2,808 | 2,784 | **0** | 24 |

**Result: pass.** Matches T3's 2,784 exactly.

Two numbers here look inconsistent with T3 and are not:

- **2,808 vs 2,812.** Four employments carry no monthly salary rows at all, so
  they never enter the comparison on the SILVER side.
- **24 vs 14 "missing".** Different definitions, deliberately. T3 counts only rows
  where months were entered but the total cell was left blank; T4 counts every
  blank total. Both describe recent joiners the spreadsheet formula was never
  extended down to – not a mapping failure.

### T5 – Employment key is unique where SAP ID is not

**Why:** SAP ID is the only field trusted from this file (contract §5), and it
repeats. The key is ID + join date + leave date.

**How:** distinct-count on `PAYROLL_ROW`, per report year.

| Report year | Rows | Distinct SAP ID | Distinct employment key |
|---|---|---|---|
| 2026 | 2,812 | 2,810 | **2,812** |

Duplicate keys within a year: **0**.

**Result: pass.** Both collisions are legitimate – one employee transferred
subsidiary mid-year, one holds two overlapping contracts at the same entity.
Keys repeat *across* years by design: the same employment appears on the 2024,
2025 and 2026 sheets.

### T6 – Currency belongs to the component, not the employee

**Why:** salary is paid locally, bonuses largely in USD. If currency were taken
from the employee row, bonus amounts would be mislabelled.

**How:** `tests/demo_walkthrough.sql` §8.

| Group | Currency | Values |
|---|---|---|
| BONUS | USD | 1,862 |
| SALARY | RMB | 10,410 |
| SALARY | BRL | 3,507 |
| SALARY | USD | 2,257 |
| SALARY | INR | 1,071 |
| SALARY | HKD | 906 |
| SALARY | BDT | 497 |

**Result: pass.** Bonus denomination is clearly independent of salary
denomination. This is why the GOLD layer never sums salary and bonus into one
figure – FX normalisation is out of scope per contract §3, so doing so would be
arithmetic across units.

### T7 – Masking covers every path to an amount

**Why:** the same figure is reachable four ways. Masking `AMOUNT` alone would
leak through the others.

**How:** `information_schema.policy_references`, `tests/demo_walkthrough.sql` §10.

| Object | Column | Policy |
|---|---|---|
| FACT_PAYROLL_COMPONENT | AMOUNT | MP_PAYROLL_AMOUNT |
| FACT_PAYROLL_COMPONENT | TEXT_VALUE | MP_PAYROLL_AMOUNT_TEXT |
| DQ_FLAG | RAW_VALUE | MP_PAYROLL_AMOUNT_TEXT |
| PAYROLL_ROW | ROW_DATA | MP_PAYROLL_ROW_VARIANT |

`FACT_PAYROLL_COMPONENT.RAW_VALUE` was a fifth masked column until it was
dropped on 11 September, which removed a path to the figure rather than opening
one.

**Result: pass**, with a caveat on how it was verified. GOLD views inherit the
policy from the column they select, so they need none of their own. The
unentitled path cannot be exercised by switching roles – the account has
secondary roles enabled, so `SF_APA_SANDBOX-ETL` stays active whatever primary
role is selected, and it is entitled. It was verified by temporarily narrowing
the policy body (walkthrough §10a–10c): amounts returned NULL, row count and
every other column unchanged, then the policy was restored.

**This does not test the real entitlement model**, which does not exist yet –
see "not covered" below.

---

## 2. Known findings – now written to `DQ_FLAG`

`05_load_dq_flags.sql` populates the table. **1,704 findings across five active
rules**, all `VALUE` class, so nothing is withheld from reporting.

| Rule | Class | Findings | Origin |
|---|---|---|---|
| `EMPLOYEE_MISSING_FROM_ROSTER` | VALUE | 1,187 | open question |
| `SALARY_AS_TEXT` | VALUE | 274 | source data |
| `INVALID_CURRENCY_CODE` | VALUE | 191 | source data |
| `MISSING_CURRENCY` | VALUE | 28 | source data |
| `MISSING_ANNUAL_TOTAL` | VALUE | 24 | source data, benign |
| `UNMAPPED_GENERATION` | STRUCTURAL | 0 | fires on an unknown template |
| `SAMPLE_FILE_INGESTED` | STRUCTURAL | 0 | backstop for the filename rule |
| `DUPLICATE_SAP_ID_ACROSS_FILES` | IDENTITY | 0 | would withhold from GOLD |

Three rules report zero, which is the correct result rather than an untested
one – they exist so that an unrecognised template, a sample reaching the model,
or the same employee on two submissions becomes visible instead of silent.

`UNRESOLVED_COLUMN_CLASSIFICATION` was retired when `SOURCE_COLUMN_INDEX` was
dropped from the fact: it matched a value back to its spreadsheet column, and
that link no longer exists. It found nothing at the time, but a future
unreviewed column will now load unflagged.

The original findings, for reference:

| Finding | Count | Class per contract §6 |
|---|---|---|
| Employments with monthly salary but a blank annual total | 24 | VALUE |
| Payment values with no currency | 28 values across 5 employments (2024: 1, 2025: 3, 2026: 1) | VALUE |
| HEADER_MAP columns still needing review | 4 | CONVENTION |

**Blocked, and worth raising:** the design doc records "11 employees from
undeclared subsidiaries". That check **cannot currently be re-run** –
`FOLDER_SUBSIDIARY_MAP` exists as a CSV in
`reference_data/subsidiary/folder_subsidiary_map.csv` but was never deployed to
the schema. Loading it is a prerequisite for that test and for the
`SUBSIDIARY_NOT_DECLARED_BY_FOLDER` rule.

---

## 3. Not covered

Listed so the state of the layer is not overstated.

| Scenario | Why not | Blocked on |
|---|---|---|
| **Ad hoc bonuses** (recorded horizontally, unlike every other component) | The model can hold them; the loader has no branch for that shape and no current data exercises it | Real submission containing one |
| **A new or unmapped template generation** | No test asserts what happens when a generation is absent from HEADER_MAP | Decide the treatment – reject sheet, or load and flag CONVENTION |
| **Resubmission / restatement** | Each monthly file restates the year to date. No test covers reloading a changed file over an earlier one | Contract §8 – correction policy still undecided |
| **File deleted from SharePoint** (Greg's ruling: preserve the row, set `IS_CURRENT = 0`) | Untested, but should need no change here – the loader already reads through `V_PAYROLL_FILE_CURRENT`, so a flagged-off file drops out on the next run | Ingestion implementing the flag flip; then re-run T1 |
| **Salary entered as text** (VALUE class, confirmed pattern per Deepanjali) | `TEXT_VALUE` holds it, `DQ_FLAG` is never written | DQ_FLAG population |
| **Row access policy** | Not built. Mechanism agreed 20 August: table of id and parent, comma-separated permitted ids, containment check on the querying identity, replicated inside the payroll database rather than reused | Build |
| **Real RBAC entitlement** | T7 verified masking mechanically, not against the roles that will actually exist | Base role structure from Qima |

---

## 4. Re-running

If `HEADER_MAP` changed, reload the seed first:

```
python transformation/reference_data/header_map/load_seed.py
```

Then, in Snowsight against `SANDBOX_DB.HR_PAYROLL_QIMA`:

| Scenario | File |
|---|---|
| T3 | `tests/reconcile_monthly_vs_total.sql` |
| T4 | `tests/reconcile_silver.sql` |
| T1, T2, T6, T7 | `tests/demo_walkthrough.sql` (§6, §2–3, §8, §10) |

`demo_walkthrough.sql` is read-only except §10a–10c, which alters a masking
policy and restores it. §10c is not optional.
