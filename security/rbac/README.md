# Payroll RBAC

Scripts that stand up the access control for the payroll domain, following the naming
convention in `Delivery/snowflake-RBAC/docs/naming_convention.md`.

Written to be **run by hand, statement by statement**, the same way QIMA's own RBAC
repository works. They are not migrations and nothing here runs itself.

## Run order

| Script | Creates | Needs role |
|---|---|---|
| `1-database.create.sql` | database + `F_HR_PAYROLL_DBA` | `SYSADMIN`, `USERADMIN`, `SECURITYADMIN` |
| `2-role-access.create.sql` | `A` / `O` / `W` / `R` and the ladder | `F_HR_PAYROLL_DBA` |
| `3-schema.create.sql` | schemas, grants, future grants | `F_HR_PAYROLL_DBA` |
| `4-role-function.create.sql` | `F_*` roles granted to people | `USERADMIN`, `SECURITYADMIN` |
| `5-user.create.sql` | service user, user grants | `USERADMIN`, `SECURITYADMIN` |
| `9-verify.sql` | reads only — what exists and who can reach it | any |

## State of HR_PAYROLL as at 18 September 2026

Verified by running `9-verify.sql` against the account. Most of this was built on
3 September, before we had access:

- Both databases exist: `HR_PAYROLL`, `HR_PAYROLL_DEV`
- `A`, `O`, `W`, `R` exist with the ladder wired: `A ⊇ O ⊇ W ⊇ R`
- `RAW`, `SILVER`, `GOLD` exist, all `WITH MANAGED ACCESS`, owned by `A`
- Future grants are configured on all three schemas, so anything created later is
  automatically owned by `O`, writable by `W` and readable by `R`

So scripts 1 and 2 are satisfied, and script 3 is satisfied **except** for three
privileges — see below. Scripts 4 and 5 have not been run at all.

`HR_PAYROLL_DEV` has not been inspected: it is owned by `F_HR_PAYROLL_DEV_DBA`, which
we do not hold.

## The gap that blocks deployment

`O` can create tables, views, stages, tasks, procedures and streams, but **not**:

- `CREATE SEQUENCE` — `SEQ_MEASURE_ID` fails, so `02_silver_model.sql` cannot run
- `CREATE MASKING POLICY` — `security/masking/` cannot be deployed
- `CREATE ROW ACCESS POLICY` — blocks the row access work when we reach it

`3-schema.create.sql` grants all three. `A` owns the schemas and `F_HR_PAYROLL_DBA`
holds `A`, so this does not need an account administrator.

## Who holds what today

`HR_PAYROLL.A` is granted to `F_HR_PAYROLL_DBA` and to `F_SBI_DE`, the latter added on
15 September. QIMA's general `F_DE` role holds nothing here, which is the isolation
requirement being met. Note that `F_SBI_DE` is a default role, so anyone at SBI holding
it has administrative access to payroll compensation data without switching role.

## Still outstanding, and not ours to run

- A dedicated warehouse. Only `BI_WAREHOUSE` exists, and `MONITOR` on a shared
  warehouse exposes query text.
- `F_HR_PAYROLL_ETL` and the service user the scheduled task runs as.
- Any functional role for reporting consumers.

All three need `USERADMIN` or `SECURITYADMIN`.
