-- ###########################################################################
--
--  QIMA PAYROLL - TRANSFORMATION WALKTHROUGH
--
--  An annotated tour of the transformation layer, ordered as an argument
--  rather than an inventory: what the raw data looks like, why it is awkward,
--  how HEADER_MAP resolves it, what comes out, and how we know it is right.
--
--  Run one block at a time (Ctrl+Enter in Snowsight). Read-only throughout,
--  except the clearly marked masking demonstration near the end.
--
--  Every query here has been executed against the loaded data.
--
-- ###########################################################################


-- ===========================================================================
-- SETUP
-- ===========================================================================
use role "SF_APA_SANDBOX-ETL";
use warehouse SANDBOX_WH;
use schema SANDBOX_DB.HR_PAYROLL_QIMA;


-- ===========================================================================
-- 1. What ingestion hands us
--
-- FILE_LOAD is the ingestion pipeline's table: one row per file per attempt,
-- with the entire workbook held in RAW_CONTENT as a single JSON object keyed
-- by sheet name. Every sheet, every cell, uninterpreted.
--
-- This is deliberate. Ingestion and extraction are kept "dumb" so they cannot
-- break when QIMA changes the template - all structural interpretation is
-- transformation's job. The consequence is that nothing here is queryable as
-- payroll until we interpret it.
--
-- RAW_PREVIEW below is the first 90 characters of that JSON.
-- ===========================================================================
select FILE_NAME,
       SHAREPOINT_MODIFIED_AT,
       IS_CURRENT,
       substr(RAW_CONTENT::string, 1, 90) as RAW_PREVIEW
from FILE_LOAD
order by LOAD_ID;


-- ===========================================================================
-- 2. Why interpretation is not trivial
--
-- Seven distinct template versions appear across the files received. The
-- differences are structural, not cosmetic: the employee ID sits at a
-- different column position in the 2026 files than in 2024/2025, and the
-- subsidiary column was renamed from "Company Code" to "Subsidiary" along
-- the way.
--
-- Hardcoding column positions would therefore require a separate loader per
-- version, and a new one each time the template changes again - which Antoine
-- confirmed on 20 August is expected, since every new bonus type becomes a new
-- column for everyone.
-- ===========================================================================
select GENERATION,
       max(case when CANONICAL_FIELD = 'EMPLOYEE_SAP_ID' then COLUMN_LETTER end)  as EMPLOYEE_ID_AT,
       max(case when CANONICAL_FIELD = 'EMPLOYEE_SAP_ID' then SOURCE_HEADER end)  as ID_HEADER,
       max(case when CANONICAL_FIELD = 'SUBSIDIARY'      then COLUMN_LETTER end)  as SUBSIDIARY_AT,
       max(case when CANONICAL_FIELD = 'SUBSIDIARY'      then SOURCE_HEADER end)  as SUBSIDIARY_HEADER
from HEADER_MAP
where GENERATION_STATUS = 'SUPPORTED'
group by GENERATION
order by GENERATION;


-- ===========================================================================
-- 3. HEADER_MAP - where the interpretation lives
--
-- One row per column per template version, recording what that column means:
-- which component it belongs to, whether it is a payment or a contractual
-- rate, which period it covers, and whether it is a local-currency figure or
-- one of the USD duplicates the 2024/2025 templates carry.
--
-- The loader resolves column positions by querying this table, so adding a
-- template version is an INSERT rather than a code change. This is the
-- requirement in CLAUDE.md that all structural interpretation lives in
-- HEADER_MAP.
-- ===========================================================================
select GENERATION,
       count(*)                             as COLUMNS_MAPPED,
       count(distinct COMPONENT_NAME)       as SCHEMES,
       count_if(MEASURE_BASIS = 'PAYMENT')  as PAYMENT_COLUMNS,
       count_if(CURRENCY_SCOPE = 'USD')     as USD_DUPLICATE_COLUMNS
from HEADER_MAP
where GENERATION_STATUS = 'SUPPORTED'
group by GENERATION
order by GENERATION;


-- A single bonus scheme in one template version, to show the shape of a
-- mapping. Each scheme occupies a repeating four-column block: eligibility,
-- currency, the maximum entitlement, and the amount actually paid.
select COLUMN_LETTER, SOURCE_HEADER, COMPONENT_NAME, MEASURE_BASIS, PERIOD_TYPE
from HEADER_MAP
where GENERATION = '2026-75col' and COMPONENT_NAME = 'YEAR_END'
order by COLUMN_INDEX;


-- ===========================================================================
-- 4. What comes out
--
-- FACT_PAYROLL_COMPONENT holds one row per value rather than one row per
-- employee with a column per field. Both the monthly periods and the bonus
-- components are unpivoted, which is the model Antoine specified on 20 August
-- and the structure README.md names.
--
-- The reason is that the set of components differs per template version - the
-- Eid festival blocks exist in only one, the USD columns in two, ad hoc
-- bonuses only from 2026. A wide table would need a DDL change for each.
-- ===========================================================================
select COMPONENT_GROUP,
       COMPONENT_NAME,
       MEASURE_BASIS,
       count(*) as VALUES_LOADED
from FACT_PAYROLL_COMPONENT
where REPORT_YEAR = 2026
group by 1, 2, 3
order by VALUES_LOADED desc
limit 12;


-- Everything held for a single employment, picked at random rather than
-- hardcoded. Note that the monthly salary and the bonus carry different
-- currency codes - salary is paid locally, bonuses largely in USD. Section 8
-- covers why that matters.
with one_employment as (
    select EMPLOYMENT_KEY
    from FACT_PAYROLL_COMPONENT
    where REPORT_YEAR = 2026 and COMPONENT_GROUP = 'BONUS'
      and MEASURE_BASIS = 'PAYMENT' and AMOUNT > 0
    limit 1
)
select f.COMPONENT_NAME, f.MEASURE_BASIS, f.PERIOD_KEY, f.AMOUNT, f.CURRENCY_CODE
from FACT_PAYROLL_COMPONENT f
join one_employment e on e.EMPLOYMENT_KEY = f.EMPLOYMENT_KEY
where f.REPORT_YEAR = 2026 and f.AMOUNT is not null
order by f.COMPONENT_GROUP, f.PERIOD_KEY;


-- ===========================================================================
-- 5. Evidence that the mapping is correct
--
-- The template contains its own checksum: twelve monthly salary columns and a
-- thirteenth reporting their total. If HEADER_MAP has identified the right
-- twelve, summing them must reproduce the thirteenth.
--
-- No column position is hardcoded in this query - every column is located
-- through HEADER_MAP, exactly as the loader does it.
--
-- DISAGREEMENTS is the number that matters. NO_TOTAL_IN_FILE counts rows where
-- the total cell was left blank in the source workbook - recent joiners the
-- formula was never extended to, not a mapping failure.
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
-- 6. Selecting which files to process
--
-- Ingestion retains every version of every file and marks superseded ones
-- IS_CURRENT = FALSE, keyed on the SharePoint item id. The requirement is to
-- process only what is current.
--
-- IS_CURRENT alone proved insufficient: one of the current files is a sample
-- workbook parked inside a live submission folder, holding rows copied from
-- the real BR02 file. Loading it would have duplicated genuine payroll.
--
-- This was a FILE_EXCLUSION table keyed on SHAREPOINT_ITEM_ID, on the
-- reasoning that a rename cannot defeat an id. That held for a rename and not
-- for a delete and re-upload, which issues a new id - the BR02 sample has been
-- through three, and by 10 September the list matched none of them.
--
-- The rule is now a filename pattern inside V_PAYROLL_FILE_CURRENT, which
-- catches every upload of that file with nothing to maintain. SKIP_REASON
-- says why anything left out was left out.
-- ===========================================================================
select FILE_NAME,
       IS_CURRENT,
       INGEST_STATUS,
       coalesce(SKIP_REASON, 'processed') as OUTCOME,
       FILE_SIZE_BYTES
from V_PAYROLL_FILE
order by OUTCOME, FILE_NAME;


-- ===========================================================================
-- 7. Employee identity where the ID repeats
--
-- Employee SAP ID is the only field trusted from this file, confirmed with
-- Tess and Antoine on 27 August. It is not unique: across 2,812 current rows
-- there are 2,810 distinct IDs.
--
-- Both collisions are legitimate rather than errors. One employee transferred
-- between subsidiaries mid-year; another holds two overlapping contracts at
-- the same entity with different salaries. The key is therefore ID plus join
-- date plus leave date, which is unique across all 2,812 rows.
--
-- The transfer case is also why SUBSIDIARY_CODE is frozen onto every payment
-- rather than resolved live - Antoine's point-in-time requirement, so earlier
-- payments stay attributed to the entity that made them.
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
-- 8. Currency is a property of the component, not the employee
--
-- Salary is paid in local currency; bonuses are largely denominated in USD.
-- Comparing the two on the same row, 1,988 of 2,812 records carry a bonus
-- currency that differs from the contractual currency, RMB salary against USD
-- bonus being the largest single pattern.
--
-- Each amount therefore takes its own component's currency column where the
-- template provides one, falling back to the contractual currency otherwise.
--
-- The consequence is that the reporting layer never sums salary and bonus into
-- a single figure. FX normalisation is out of scope per the data contract, so
-- doing so would be arithmetic across units.
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
-- 9. The reporting layer
--
-- V_GOLD_ANNUAL_COMPENSATION is what Tableau would connect to. Its grain is
-- employment, component group and currency - deliberately with no
-- cross-component total, for the reason in section 8.
--
-- Three exclusions are applied, each traceable to a decision: local currency
-- only, mapped template versions only, and no rows carrying an identity-class
-- data quality flag.
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
-- 10. Amount masking
--
-- The requirement from 20 August is that the amounts are hidden while every
-- row stays visible. Employee attributes are deliberately left unmasked, since
-- that data is already exposed in other tables.
--
-- Five columns are masked rather than one. The same figure is reachable
-- through the parsed amount, the verbatim raw value, the text value where a
-- salary was typed as text, and PAYROLL_ROW.ROW_DATA, which holds an entire
-- spreadsheet line. Masking only AMOUNT would have leaked through the others.
--
-- Views inherit a policy from the column they select, so the GOLD views are
-- covered without policies of their own.
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
-- 10a-10c. Demonstrating the policy - THIS SECTION WRITES
--
-- The policy body is narrowed so no role in this session qualifies, queried,
-- then restored. This is the only way to exercise the unentitled path here:
-- the account has secondary roles enabled, so SF_APA_SANDBOX-ETL stays active
-- whatever primary role is selected, and it is entitled.
--
-- Run all three blocks in sequence. 10c is not optional.
-- ---------------------------------------------------------------------------

-- 10a. Narrow the policy so nothing in this session matches.
alter masking policy MP_PAYROLL_AMOUNT set body ->
    case when is_role_in_session('PAYROLL_AMOUNT_READER') then val else null end;

-- 10b. Amounts return NULL. Row count and every other column are unaffected,
--      which is the requirement: rows visible, amounts not.
select EMPLOYEE_SAP_ID, SUBSIDIARY_CODE, PERIOD_KEY, AMOUNT
from FACT_PAYROLL_COMPONENT
where COMPONENT_NAME = 'MONTHLY_SALARY' and MEASURE_BASIS = 'PAYMENT'
  and REPORT_YEAR = 2026
order by MEASURE_ID
limit 5;

-- 10c. Restore. Do not skip.
alter masking policy MP_PAYROLL_AMOUNT set body ->
    case when is_role_in_session('SF_APA_SANDBOX-ETL')    then val
         when is_role_in_session('PAYROLL_AMOUNT_READER') then val
         else null end;

-- Confirm amounts are back.
select EMPLOYEE_SAP_ID, PERIOD_KEY, AMOUNT
from FACT_PAYROLL_COMPONENT
where COMPONENT_NAME = 'MONTHLY_SALARY' and MEASURE_BASIS = 'PAYMENT'
  and REPORT_YEAR = 2026
order by MEASURE_ID
limit 3;


-- ===========================================================================
-- 11. Known gaps
--
-- Recorded here so the state of the layer is not overstated. Detail in
-- transformation/docs/Qima_Payroll_Transformation_Design.md section 10, and
-- what is and is not tested in transformation/tests/test_results.md.
--
-- The RAW_CONTENT item is the one with live consequence: it holds every amount
-- in every workbook and is not masked, so masking downstream does not protect
-- anyone who can read that table. It belongs to the ingestion stage.
-- ===========================================================================
select 'DQ_FLAG rows'                     as ITEM,
       count(*)                           as VALUE_,
       'table and its four contract classes exist; loader does not write to it' as STATUS
from DQ_FLAG
union all
select 'HEADER_MAP columns needing review', count(*),
       'blank columns in the 2024 template; everything else classified'
from HEADER_MAP where NEEDS_REVIEW
union all
select 'Row access policy', 0, 'mechanism agreed 20 August, not built'
union all
select 'RBAC roles', 0, 'awaiting the base role structure'
union all
select 'FILE_LOAD.RAW_CONTENT masking', 0,
       'holds every amount unmasked; owned by ingestion, needs a decision';
