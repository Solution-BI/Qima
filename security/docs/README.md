# security

Epic 4. Only masking exists so far.

```
masking/     01_amount_masking_policies.sql   built and applied
rbac/        not built
row_access/  not built
```

## What is in force

Five columns are masked. Rows are never hidden - that is the requirement, not
an omission: Antoine can access the database and see every row, but must not
see the amounts.

| Table | Column | Why |
|---|---|---|
| `FACT_PAYROLL_COMPONENT` | `AMOUNT` | the figure |
| `FACT_PAYROLL_COMPONENT` | `RAW_VALUE` | the same figure verbatim as text |
| `FACT_PAYROLL_COMPONENT` | `TEXT_VALUE` | the figure where it was typed as text |
| `PAYROLL_ROW` | `ROW_DATA` | the entire spreadsheet line, every amount in it |
| `DQ_FLAG` | `RAW_VALUE` | the offending value on a flagged cell |

**Masking `AMOUNT` alone would have leaked.** The other four reach the same
numbers by another route, and `ROW_DATA` exposes an employee's whole row at
once. Views inherit a policy from the column they select, so masking these base
columns covers `V_GOLD_PAYROLL_COMPONENT` and everything downstream - verified,
`V_GOLD_ANNUAL_COMPENSATION.AMOUNT_PAID` returns NULL for an unentitled role.

Employee attributes are deliberately **not** masked. Antoine's reasoning: that
data is already exposed in other tables, so masking it here achieves nothing
while it stays readable elsewhere.

## Tested

Both directions, by switching the policy body and re-querying:

| | AMOUNT | rows visible |
|---|---|---|
| entitled role | 359.00 | 216,101 |
| unentitled role | NULL | 216,101 |

## Not covered, deliberately

**`FILE_LOAD.RAW_CONTENT`** holds every amount in the workbook as JSON. It
belongs to the ingestion pipeline and sits in the RAW layer, so a policy on it
is the ingestion owner's call, not this stage's. **It is a live hole**: anyone
who can read `FILE_LOAD` can read every salary regardless of what is masked
downstream. Raise it with Greg - the likely answer is that RAW is not granted
to the roles this masking is defending against, in which case nothing more is
needed. Worth confirming rather than assuming.

## Still open

- **Display value.** NULL (hidden) is the working choice. Whether the final form
  is hidden, anonymised or a fixed value is HR's decision. Changing it is one
  `ALTER MASKING POLICY ... SET BODY` per policy - the shape does not change.
- **Whether all amount columns take the same policy.** Antoine's view is yes,
  not yet confirmed with HR. Currently they do.
- **The role name.** `PAYROLL_AMOUNT_READER` is a placeholder. On migration it
  maps to the real access-role ladder, and `SF_APA_SANDBOX-ETL` comes out.
- **Row access policy.** Not built. The mechanism was confirmed on 20 August: a
  table of ID and parent, a comma-separated list of permitted IDs, and a policy
  checking containment of the querying identity, applied directly on the main
  table. Decision was to **replicate it inside the payroll database, not reuse**
  the shared one - fewer people able to set attribute rules for payroll, cleaner
  audit position. Qima will share their structure as a reference.
- **Aggregation / minimum group size**, flagged as relevant to Snowflake
  Intelligence specifically. Not addressed.

## Why masking is the primary control

The named concern is someone granting themselves a full view for a short
window. Masking holds even then, because it is attached to the column rather
than to the grant. The entitlement table doubles as an audit source.

Both controls must hold for **Snowflake Intelligence and direct Snowflake
access**, not only Tableau. Tableau uses a live connection with no stored
credentials, so each user authenticates as themselves and the policies apply at
query time.
