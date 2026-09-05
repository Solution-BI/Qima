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

The 20 August pre-kickoff narrowed it considerably. Antoine confirmed:

- **Amount columns only.** Employee attributes stay unmasked, because that data
  is already exposed in other tables - masking it here achieves nothing while it
  remains readable elsewhere.
- **All rows stay visible.** The requirement in his words: he can access the
  database but should not see the amounts, while still seeing every row. So
  masking and row access are separate controls, not one mechanism.
- **Masking is the primary control for the data team**, layered on top of
  database access.
- Same policy across all amount columns is **his view, not yet confirmed** with
  HR.

That is now specific enough to draft a policy against `AMOUNT` on
`FACT_PAYROLL_COMPONENT`. One thing still genuinely blocks finishing it: what a
masked value should display - hidden, anonymised, or a fixed value. That is
Tess/HR's call and changes the policy body, not its shape.

Note the audit concern behind this, also Antoine's: "we need to make sure
someone doesn't grant himself a full view for a few minutes." Masking is the
mitigation, with the entitlement table as a second audit source.

A Row Access Policy is also required, and specifically a real one. The
mechanism was confirmed on 20 August: a table of **ID and parent** (parent
defaults to the manager, sometimes driven by dimension), from which a
comma-separated list of permitted IDs is built, with the policy checking
containment of the querying identity. Applied **directly on the main table**.

**Replicate, do not reuse.** The driving table sits inside the payroll database
as its own table rather than the shared one - fewer people able to set
attribute-based rules for payroll, and a cleaner audit position. Qima will share
the existing structure as a reference.

Both controls must hold for **Snowflake Intelligence and direct Snowflake
access**, not only Tableau. Tableau will use a live connection with no stored
credentials so users supply their own, which is precisely what lets masking and
row access apply at query time.

### What that means in practice

- Do not grant read on this schema to anyone outside the payroll domain.
- Do not point a BI tool or Snowflake Intelligence at the GOLD views yet.
  `README.md` flags an aggregation / minimum-group-size requirement for
  Snowflake Intelligence specifically, also still open.
- Treat `V_GOLD_*` as "correct", not as "safe to share".

## 2. Wrong home, and no RAW / SILVER / GOLD split

Everything sits in `SANDBOX_DB.HR_PAYROLL_QIMA` - SBI's sandbox, not Qima's
account. That is expected at this stage, but two structural things differ from
the agreed target and should not be carried across as-is.

**Database.** Antoine confirmed a dedicated **`HR_PAYROLL`** database plus
**`HR_PAYROLL_DEV`**, separate from the existing `HR` domain database, which he
will hand over blank with the base role structure and future grants already
applied. `HR_PAYROLL_DEV` is to hold **files with fabricated amounts** so he can
manipulate them and simulate error conditions himself; production credentials
are switched in afterwards.

**Schemas.** `HR_PAYROLL` carries **RAW, SILVER and GOLD** - a deliberate
exception to Qima's single shared RAW schema across sources, so payroll RAW
stays inside the payroll database. Everything built here is in **one flat
schema**. On migration it should split:

| Here today | Belongs in |
|---|---|
| `FILE_LOAD` | RAW |
| `HEADER_MAP`, `FILE_EXCLUSION` | SILVER (reference data) |
| `SHEET_LOAD`, `PAYROLL_ROW`, `FACT_PAYROLL_COMPONENT`, `DQ_FLAG` | SILVER |
| `V_GOLD_*` | GOLD |

Two role details that bite at migration: **database roles are preferred for
objects, tables and procedures, but account-level roles are required for
tasks** - which matters the moment orchestration is added. And **future grants
may not cover object types Qima does not already use**; secrets were named as
the likely example, so anything unusual has to be flagged for them to add.

Deployment is **manual** - there is no automated framework, and the working
pattern is to clone production for heavier testing then apply changes back.

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
