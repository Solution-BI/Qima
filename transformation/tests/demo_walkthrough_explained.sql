-- ===========================================================================
--  QIMA PAYROLL - TRANSFORMATION
--
--  Walkthrough of the RAW -> SILVER -> GOLD layer. Each section states the
--  reasoning behind the query, not just what it returns.
--
--  Environment: SANDBOX_DB.HR_PAYROLL_QIMA, an SBI sandbox - not Qima's
--  account. Read-only throughout, except section 10a-10c which alters a
--  masking policy and restores it.
-- ===========================================================================

use role "SF_APA_SANDBOX-ETL";
use warehouse SANDBOX_WH;
use schema SANDBOX_DB.HR_PAYROLL_QIMA;


-- ===========================================================================
-- 1. THE PROBLEM
--
-- One row per file, with the entire workbook - every sheet, every cell - held
-- as a single opaque JSON value. RAW_PREVIEW is unreadable, and that is the
-- design rather than a limitation.
--
-- Ingestion moves bytes; extraction converts a sheet's grid to JSON cell by
-- cell. Neither knows what a column means, which is what stops them breaking
-- when Qima edits the template. The cost is that RAW cannot be queried as
-- payroll, and every section below is paying that cost off.
--
-- IS_CURRENT is the second thing to note: ingestion retains every version of
-- every file rather than overwriting, so a resubmission never destroys what
-- came before.
-- ===========================================================================
select FILE_NAME,
       SHAREPOINT_MODIFIED_AT,
       IS_CURRENT,
       substr(RAW_CONTENT::string, 1, 90) as RAW_PREVIEW
from FILE_LOAD
order by LOAD_ID;


-- ===========================================================================
-- 2. WHY IT IS HARD - the template changed seven times
--
-- The June proposal assumed one uniform 67-column template across all 32
-- subsidiaries. The real files hold seven distinct layouts, 64 to 96 columns,
-- spanning 2024-2026.
--
-- The changes are structural, not cosmetic:
--
--     Employee SAP ID      col B (2024, 2025)  ->  col A (2026)
--     Subsidiary           col H "Company Code" (2024)
--                          col H "Subsidiary"   (2025)
--                          col E "Subsidiary"   (2026)
--     Contract currency    col S -> col T -> col J, renamed along the way
--
-- Both naive approaches fail against this. Reading by POSITION gets the wrong
-- cell for two generations in three. Reading by HEADER NAME misses "Company
-- Code" entirely, because the same field was renamed. Either one needs a
-- separate branch per generation, and a new branch every time the spreadsheet
-- is edited.
-- ===========================================================================
select GENERATION,
       max(case when CANONICAL_FIELD = 'EMPLOYEE_SAP_ID' then COLUMN_LETTER end)  as EMPLOYEE_ID_AT,
       max(case when CANONICAL_FIELD = 'EMPLOYEE_SAP_ID' then SOURCE_HEADER end)  as CALLED,
       max(case when CANONICAL_FIELD = 'SUBSIDIARY'      then COLUMN_LETTER end)  as SUBSIDIARY_AT,
       max(case when CANONICAL_FIELD = 'SUBSIDIARY'      then SOURCE_HEADER end)  as CALLED_2
from HEADER_MAP
where GENERATION_STATUS = 'SUPPORTED'
group by GENERATION
order by GENERATION;


-- ===========================================================================
-- 3. THE ANSWER - HEADER_MAP
--
-- 668 rows, one per column per template generation, each stating what that
-- column means. The grain is (GENERATION, COLUMN_INDEX) - the primary key.
--
-- The loader never assumes a position. It derives the generation from the
-- sheet's own shape (sheet name + column count), joins this table, and reads
-- the cell with a dynamic GET(row, index). Adding a new template generation
-- is an INSERT here, not a code change - that is the single property this
-- whole design exists to provide.
--
-- USD_DUPLICATE_COLUMNS is worth pointing at. The 2024 and 2025 generations
-- carry a second copy of most amounts, pre-converted to USD at unknown FX
-- rates. They load, but CURRENCY_SCOPE keeps them distinguishable so they are
-- excluded from reporting rather than silently summed alongside local values.
-- FX normalisation is out of scope per the data contract.
-- ===========================================================================
select GENERATION,
       count(*)                                          as COLUMNS_MAPPED,
       count(distinct COMPONENT_NAME)                    as SCHEMES,
       count_if(MEASURE_BASIS = 'PAYMENT')               as PAYMENT_COLUMNS,
       count_if(CURRENCY_SCOPE = 'USD')                  as USD_DUPLICATE_COLUMNS
from HEADER_MAP
where GENERATION_STATUS = 'SUPPORTED'
group by GENERATION
order by GENERATION;


-- ---------------------------------------------------------------------------
-- What a mapping actually looks like, if asked.
--
-- One bonus scheme occupies four columns: whether the employee is eligible,
-- in what currency, the contractual maximum, and what was actually paid.
-- Those are four different KINDS of fact about one scheme, which is why
-- MEASURE_BASIS exists as an axis separate from COMPONENT_NAME.
-- ---------------------------------------------------------------------------
select COLUMN_LETTER, SOURCE_HEADER, COMPONENT_NAME, MEASURE_BASIS, PERIOD_TYPE
from HEADER_MAP
where GENERATION = '2026-75col' and COMPONENT_NAME = 'YEAR_END'
order by COLUMN_INDEX;


-- ===========================================================================
-- 4. THE RESULT
--
-- The fact is long, not wide - one row per cell that carries a value, rather
-- than one row per employee with a column per field. This is the structure
-- Antoine specified on 20 August: unpivot both the monthly periods and the
-- bonus components, with no hardcoded component list.
--
-- The reason is that the component set differs per generation. The Eid
-- festival blocks exist in only one, the USD columns in two, ad hoc bonuses
-- only from 2026. A wide table needs a DDL change for each of those; a long
-- table absorbs them as data.
--
-- Every component name in this result was discovered from the data, by way of
-- HEADER_MAP. Nothing in the loader enumerates them.
-- ===========================================================================
select COMPONENT_GROUP,
       COMPONENT_NAME,
       MEASURE_BASIS,
       count(*)      as VALUES_LOADED
from FACT_PAYROLL_COMPONENT
where REPORT_YEAR = 2026
group by 1, 2, 3
order by VALUES_LOADED desc
limit 12;


-- ---------------------------------------------------------------------------
-- One employee, end to end.
--
-- Twelve monthly salary rows plus the bonus rows for one person. The salary
-- and the bonus carry DIFFERENT currency codes - salary paid locally, bonus
-- in USD. Section 8 is the consequence of that.
--
-- The employee id below is hardcoded. Re-run this before presenting: a reload
-- can change what that id holds.
-- ---------------------------------------------------------------------------
select COMPONENT_NAME, MEASURE_BASIS, PERIOD_KEY, AMOUNT, CURRENCY_CODE
from FACT_PAYROLL_COMPONENT
where EMPLOYEE_SAP_ID = '10000343'
  and REPORT_YEAR = 2026
  and AMOUNT is not null
order by COMPONENT_GROUP, PERIOD_KEY;


-- ===========================================================================
-- 5. PROOF THAT THE MAPPING IS RIGHT
--
-- The template contains its own checksum: twelve monthly salary columns and a
-- thirteenth reporting their total. If HEADER_MAP identified the right
-- twelve, summing them must reproduce the thirteenth.
--
-- This is stronger than a conventional unit test for two reasons. The check is
-- against Qima's own arithmetic, not against an expectation written by the
-- same person who wrote the mapping. And no column position is hardcoded here
-- - every column is located through HEADER_MAP, exactly as the loader does it,
-- so the test exercises the real mechanism rather than a reimplementation.
--
-- It also ran BEFORE the loader was written. The mapping was proven correct
-- against real data first; the loader was then built on a pattern already
-- demonstrated to work.
--
-- DISAGREEMENTS is the number that matters: 0.
-- NO_TOTAL_IN_FILE counts the 24 rows where the annual total cell was left
-- blank in the source - recent joiners the formula was never extended to.
-- A gap in the source file, not a mapping failure.
-- ===========================================================================
with monthly as (
    select PAYROLL_ROW_ID, sum(AMOUNT) as SUM_OF_MONTHS
    from FACT_PAYROLL_COMPONENT
    where REPORT_YEAR = 2026 and COMPONENT_NAME = 'MONTHLY_SALARY'
      and MEASURE_BASIS = 'PAYMENT' and PERIOD_TYPE = 'MONTH'
      and CURRENCY_SCOPE = 'LOCAL'
    group by 1
),
reported as (
    select PAYROLL_ROW_ID, AMOUNT as TOTAL_REPORTED
    from FACT_PAYROLL_COMPONENT
    where REPORT_YEAR = 2026 and COMPONENT_NAME = 'MONTHLY_SALARY'
      and MEASURE_BASIS = 'PAYMENT' and PERIOD_TYPE = 'FY'
      and CURRENCY_SCOPE = 'LOCAL'
)
select count(*)                                                       as EMPLOYMENTS_CHECKED,
       count_if(r.TOTAL_REPORTED is not null
                and abs(m.SUM_OF_MONTHS - r.TOTAL_REPORTED) <= 0.01)  as MATCHES,
       count_if(r.TOTAL_REPORTED is not null
                and abs(m.SUM_OF_MONTHS - r.TOTAL_REPORTED)  > 0.01)  as DISAGREEMENTS,
       count_if(r.TOTAL_REPORTED is null)                             as NO_TOTAL_IN_FILE
from monthly m
left join reported r on r.PAYROLL_ROW_ID = m.PAYROLL_ROW_ID;


-- ===========================================================================
-- 6. RULE ONE - only current, non-excluded files
--
-- IS_CURRENT alone is not sufficient. It returns four files, and one of them
-- is a sample workbook: a four-row extract whose employee ids and salaries all
-- match rows in the real BR02 file. Loading it would duplicate genuine
-- payroll.
--
-- Three design decisions sit in this one view.
--
--   * Exclusion is keyed on SHAREPOINT_ITEM_ID, never on filename. The sample
--     has already been renamed once while keeping the same item id; a
--     name-based rule would have silently stopped working at that rename.
--
--   * Nothing is deleted. FILE_EXCLUSION is a separate table joined with a
--     LEFT JOIN, so an excluded file keeps its FILE_LOAD row and its full
--     RAW_CONTENT. The decision stays auditable and is reversed by deleting
--     one row.
--
--   * Every exclusion carries stated evidence. Excluding payroll data needs a
--     reason on the record, not a preference - hence REASON and EVIDENCE, and
--     the size comparison visible in this result.
--
-- This view is also what makes the agreed deletion behaviour free: when
-- ingestion sets IS_CURRENT = 0 on a file that has disappeared, it drops out
-- here on the next run with no change to the transformation layer.
-- ===========================================================================
select FILE_NAME,
       IS_CURRENT,
       IS_EXCLUDED,
       EXCLUSION_REASON,
       FILE_SIZE_BYTES
from V_PAYROLL_FILE
where IS_CURRENT
order by IS_EXCLUDED, FILE_NAME;


-- ===========================================================================
-- 7. RULE TWO - the employee id is not unique
--
-- The data contract makes SAP ID the only field trusted from this file. It is
-- also not unique - and both duplicates in the data are legitimate, not
-- errors.
--
-- One employee transferred between subsidiaries mid-year. The other holds two
-- overlapping contracts at the same entity. Aggregating on SAP ID alone would
-- merge each pair into one person and sum both salaries as a single job.
--
-- So the grain is EMPLOYMENT_KEY = SAP_ID | JOIN_DATE | LEAVE_DATE, with a
-- sentinel standing in for a null leave date so a missing value cannot
-- collapse two keys into one. That gives 2,812 distinct keys against 2,810
-- SAP IDs - the difference is exactly these two cases.
--
-- This is also why subsidiary is frozen onto every payment rather than
-- resolved live. When someone transfers, their earlier payments must stay
-- attributed to the entity that actually paid them; resolving the current
-- subsidiary at query time would move a year of cost from one entity to
-- another without anyone noticing.
-- ===========================================================================
select EMPLOYEE_SAP_ID,
       JOIN_DATE,
       LEAVE_DATE,
       SUBSIDIARY_RAW,
       EMPLOYMENT_KEY
from PAYROLL_ROW
where REPORT_YEAR = 2026
  and not IS_BLANK
  and EMPLOYEE_SAP_ID in (
        select EMPLOYEE_SAP_ID
        from PAYROLL_ROW
        where REPORT_YEAR = 2026 and not IS_BLANK
        group by 1 having count(*) > 1)
order by EMPLOYEE_SAP_ID, JOIN_DATE;


-- ===========================================================================
-- 8. RULE THREE - currency belongs to the component, not the employee
--
-- Salary is paid in local currency; bonuses are largely paid in USD. An
-- employee therefore cannot be assigned a single currency - each amount has to
-- carry its own.
--
-- This is not an edge case. 1,988 of 2,812 rows carry a year-end bonus
-- currency that differs from the contract currency, the largest single
-- pattern being local salary against a USD bonus.
--
-- The loader resolves it with a two-step fallback: an amount takes the
-- currency from its OWN component's (Currency) column where the generation has
-- one, and falls back to the contractual currency otherwise. A single per-row
-- currency would be wrong for most of the data.
--
-- The consequence is deliberate: the reporting layer never adds salary and
-- bonus into one total, because that is arithmetic on mixed units. GOLD totals
-- per currency, and a separate view identifies which employments report a
-- single currency throughout and can therefore be totalled safely.
-- ===========================================================================
select COMPONENT_GROUP,
       CURRENCY_CODE,
       count(*) as VALUES_
from FACT_PAYROLL_COMPONENT
where REPORT_YEAR = 2026
  and MEASURE_BASIS = 'PAYMENT'
  and CURRENCY_SCOPE = 'LOCAL'
  and COMPONENT_GROUP in ('SALARY', 'BONUS')
group by 1, 2
having count(*) > 400
order by COMPONENT_GROUP, VALUES_ desc;


-- ===========================================================================
-- 9. THE REPORTING LAYER
--
-- The layer a BI tool connects to. Four exclusions are applied on the way in,
-- each traceable to a decision rather than a preference:
--
--     CURRENCY_SCOPE = 'LOCAL'   FX normalisation out of scope, contract s.3
--     MAPPING_STATUS = 'MAPPED'  sample sheets are not submissions
--     NEEDS_REVIEW   = FALSE     an undecided mapping must not reach reporting
--     no IDENTITY flag           contract s.6 - load, flag, exclude until
--                                resolved
--
-- Currency is in the grain, and EXTERNAL is excluded because agency fees are
-- an external headcount cost rather than employee compensation.
--
-- The grain is EMPLOYMENT_KEY, not EMPLOYEE_SAP_ID, for the reason in
-- section 7.
-- ===========================================================================
select SUBSIDIARY_CODE,
       COMPONENT_GROUP,
       CURRENCY_CODE,
       count(distinct EMPLOYMENT_KEY) as EMPLOYEES,
       round(sum(AMOUNT_PAID), 0)     as TOTAL_PAID
from V_GOLD_ANNUAL_COMPENSATION
where REPORT_YEAR = 2026
group by 1, 2, 3
order by EMPLOYEES desc
limit 12;


-- ===========================================================================
-- 10. SECURITY - amounts are masked, rows are not
--
-- The requirement confirmed on 20 August was amount columns only, all rows
-- visible: the data lead can see that a payment exists without seeing its
-- value.
--
-- Masking covers five columns across three policies, not one, and the reason
-- matters - the figure is reachable by more than one route. It appears as the
-- parsed AMOUNT, as the verbatim RAW_VALUE, as TEXT_VALUE where a salary was
-- typed as text, in the flag table's captured value, and inside
-- PAYROLL_ROW.ROW_DATA, which holds the entire original spreadsheet row.
-- Masking only AMOUNT would have left four open paths to the same number.
--
-- GOLD views need no policies of their own - a view inherits the policy from
-- the column it selects.
-- ===========================================================================
select REF_ENTITY_NAME as TABLE_NAME,
       REF_COLUMN_NAME as MASKED_COLUMN,
       POLICY_NAME
from table(information_schema.policy_references(policy_name => 'MP_PAYROLL_AMOUNT'))
union all
select REF_ENTITY_NAME, REF_COLUMN_NAME, POLICY_NAME
from table(information_schema.policy_references(policy_name => 'MP_PAYROLL_AMOUNT_TEXT'))
union all
select REF_ENTITY_NAME, REF_COLUMN_NAME, POLICY_NAME
from table(information_schema.policy_references(policy_name => 'MP_PAYROLL_ROW_VARIANT'))
order by 1, 2;


-- ---------------------------------------------------------------------------
-- OPTIONAL LIVE MASKING DEMO
--
-- Amounts display in this session because the role held is entitled. The
-- unentitled path cannot be shown by switching roles: the account has
-- secondary roles enabled, so SF_APA_SANDBOX-ETL stays active whatever primary
-- role is selected, and it is entitled.
--
-- The workaround is to narrow the policy body temporarily so nothing in the
-- session matches, then restore it. That demonstrates the real mechanism
-- rather than a mock.
--
-- Run 10a, 10b and 10c in order. If you start the sequence, finish it -
-- skipping the demo entirely is safer than abandoning it halfway.
-- ---------------------------------------------------------------------------

-- 10a. Remove the entitlement this session relies on.
alter masking policy MP_PAYROLL_AMOUNT set body ->
    case when is_role_in_session('PAYROLL_AMOUNT_READER') then val else null end;

-- 10b. The same query as before. Amounts return NULL; the row count and every
--      other column are unchanged. That is precisely the requirement - the
--      rows stay visible, the money does not.
select EMPLOYEE_SAP_ID, SUBSIDIARY_CODE, PERIOD_KEY, AMOUNT
from FACT_PAYROLL_COMPONENT
where COMPONENT_NAME = 'MONTHLY_SALARY' and MEASURE_BASIS = 'PAYMENT'
  and REPORT_YEAR = 2026
order by MEASURE_ID
limit 5;

-- 10c. RESTORE. This step is not optional.
alter masking policy MP_PAYROLL_AMOUNT set body ->
    case when is_role_in_session('SF_APA_SANDBOX-ETL')    then val
         when is_role_in_session('PAYROLL_AMOUNT_READER') then val
         else null end;

-- Confirm the restore worked before moving on.
select EMPLOYEE_SAP_ID, PERIOD_KEY, AMOUNT
from FACT_PAYROLL_COMPONENT
where COMPONENT_NAME = 'MONTHLY_SALARY' and MEASURE_BASIS = 'PAYMENT'
  and REPORT_YEAR = 2026
order by MEASURE_ID
limit 3;


-- ===========================================================================
-- 11. WHAT IS NOT BUILT
--
-- Stated before it is asked, because each item is a known gap with a known
-- cause rather than an oversight.
--
--   * DQ_FLAG holds 0 rows. The table and its four contract classes exist and
--     the GOLD views already read identity flags - but nothing writes a flag,
--     so that filter can never fire. The rules are specified and the data is
--     present: salary-as-text is a populated TEXT_VALUE, missing currency is a
--     null currency code on a payment. What is missing is the INSERT
--     statements, not the design.
--
--   * 4 of 668 HEADER_MAP columns need review. All are blank headers in the
--     source template - the classifier correctly refused to guess, and
--     unreviewed mappings are excluded from GOLD.
--
--   * Row access policy is designed, not built. The mechanism was agreed on
--     20 August; it needs Qima's base role structure before it can be.
--
--   * RAW_CONTENT is not masked. This is the significant one. The
--     transformation layer masks five columns, but the ingestion table holds
--     every one of those figures unmasked - anyone who can read it can read
--     every salary. Closing that is not a transformation change; it needs a
--     decision from whoever owns ingestion.
-- ===========================================================================
select 'DQ_FLAG'                as ITEM,
       count(*)                 as ROWS_,
       'table built, loader does not populate it yet' as STATUS
from DQ_FLAG
union all
select 'HEADER_MAP needs review', count(*), 'columns the classifier could not decide - all blank columns'
from HEADER_MAP where NEEDS_REVIEW
union all
select 'Employments with no annual total', 24, 'blank in the source file, not a mapping error'
union all
select 'Row access policy', 0, 'mechanism agreed 20 Aug, not built'
union all
select 'RAW_CONTENT masking', 0, 'holds every amount, owned by ingestion - needs a decision';
