# Known gaps - read before exposing any of this to users

The transformation layer loads and reconciles correctly. It is **not** safe to
expose to a wide audience yet, for the reasons below.

## 1. No masking. Every amount is readable in the clear.

`README.md` and `CLAUDE.md` both specify a `security/` stage with `rbac/`,
`masking/` and `row_access/`. **None of it is built** - there is no `security/`
folder on any branch.

Today, anyone holding `SF_APA_SANDBOX-ETL` can run:

```sql
select * from V_GOLD_ANNUAL_COMPENSATION;
```

and read every salary and bonus in the company, named by SAP ID. The GOLD views
filter for *correctness* - local currency only, mapped generations only - not
for *confidentiality*. Nothing in `transformation/` restricts who sees what.

**This is not an oversight in the transformation design; it is the next epic.**
But it is also blocked, and the blockers are business decisions rather than
engineering ones. From `README.md`, open since June:

- Masking format for hidden values - NULL or a token?
- **Whether all amount fields are treated identically for masking.**

The second one has to be answered before a policy can be written at all, since
masking policies attach per column. "Is a bonus treated like a salary?" is not
something the platform can decide for Tess/HR.

A Row Access Policy is also required, and specifically a real one - the 20
August pre-kickoff confirmed a comma-separated ID list containment check
against an ID + parent entitlement table, **replicated inside the isolated
payroll database** rather than shared with the general platform's mechanism.

### What that means in practice

- Do not grant read on this schema to anyone outside the payroll domain.
- Do not point a BI tool or Snowflake Intelligence at the GOLD views yet.
  `README.md` flags an aggregation / minimum-group-size requirement for
  Snowflake Intelligence specifically, also still open.
- Treat `V_GOLD_*` as "correct", not as "safe to share".

## 2. Wrong home

Everything is in `SANDBOX_DB.HR_PAYROLL_QIMA`, a shared sandbox. The design
calls for an isolated payroll database owned by `F_PAYROLL_DBA` with the
`PAYROLL.A/.O/.W/.R` access-role ladder, isolated by never granting `F_DE` the
PAYROLL domain's roles. Until that exists, isolation is not structural - it is
just the fact that nobody has looked.

## 3. `DQ_FLAG` is empty

The table and the four data-contract classes exist; the loader does not write
to it. The findings are known and reproducible in SQL - 24 employments with no
annual total, 11 employees from subsidiaries no folder declares, 5 blank
currencies - but they are not recorded as rows, so nothing downstream can
filter on them. `V_GOLD_PAYROLL_COMPONENT` already excludes IDENTITY-class
flags; that exclusion currently matches nothing because there is nothing to
match.

## 4. The data model design doc was never available

`README.md` line 106 references
`transformation/docs/Qima_Payroll_Data_Model_Design.md` - "the full reasoning
and the several rounds of redesign it went through". **That file does not exist
on any branch**, so this build was made without it.

The model converged on what `README.md` describes - a single
`FACT_PAYROLL_COMPONENT` driven by HEADER_MAP, no hardcoded component list -
and the table has been renamed to match. But column names, and the names of
`SHEET_LOAD` / `PAYROLL_ROW` / `DQ_FLAG`, were invented here rather than taken
from that document. **If it turns up, reconcile the names against it before
anyone builds on this.**

## 5. Still open, inherited from the contract

- Restatement policy: each monthly file restates the year to date. Which
  submission wins is unresolved (contract section 8).
- `BR09 + BR12 + BR13` names three codes for two legal names; the mapping to
  CPQUALI / CPHOSP is a guess.
- Ad hoc bonuses are recorded horizontally, unlike every other component. The
  model can hold them; the loader has no branch for that shape. No data
  currently exercises it.
