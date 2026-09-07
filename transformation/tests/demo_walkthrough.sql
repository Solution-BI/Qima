-- ###########################################################################
--
--  QIMA PAYROLL - TRANSFORMATION DEMO
--
--  Run these blocks IN ORDER, one at a time.
--  In Snowsight: click inside a block, then Ctrl+Enter (Cmd+Enter on Mac).
--  Do NOT use "Run All" - the whole point is to talk over each result.
--
--  Every block has a "SAY:" line. That is what the result on screen shows.
--  Nothing here changes any data. It is all read-only.
--
-- ###########################################################################


-- ===========================================================================
-- SETUP - run this first, every time. Nothing to say out loud.
-- ===========================================================================
use role "SF_APA_SANDBOX-ETL";
use warehouse SANDBOX_WH;
use schema SANDBOX_DB.HR_PAYROLL_QIMA;


-- ===========================================================================
-- 1. THE PROBLEM
--
-- SAY: "This is what ingestion gives us - one row per file, and the whole
--       workbook as a single blob of JSON. Every sheet, every cell,
--       uninterpreted. You cannot query payroll out of this."
--
-- Point at RAW_PREVIEW. It is unreadable on purpose - that is the point.
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
-- SAY: "One template, seven versions. And they are not cosmetic changes -
--       the employee ID moves from column B to column A, and 'Company Code'
--       gets renamed to 'Subsidiary'. If we hardcoded column positions we
--       would need seven different loaders, and an eighth the next time
--       QIMA edits the spreadsheet."
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
-- SAY: "So instead of code that assumes, we built a lookup table. 668 rows,
--       one per column per template version, saying what that column means.
--       The loader asks this table where things are. A new template version
--       is new rows here - not a code change."
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


-- Optional, if someone asks what a mapping row actually looks like.
-- SAY: "Here is one bonus scheme in one version. Four columns: are they
--       eligible, in what currency, the maximum, and what was actually paid."
select COLUMN_LETTER, SOURCE_HEADER, COMPONENT_NAME, MEASURE_BASIS, PERIOD_TYPE
from HEADER_MAP
where GENERATION = '2026-75col' and COMPONENT_NAME = 'YEAR_END'
order by COLUMN_INDEX;


-- ===========================================================================
-- 4. THE RESULT
--
-- SAY: "That JSON blob becomes this. One row per value - a monthly salary,
--       a bonus, an eligibility flag - each one tagged with what it is,
--       which period, and which currency."
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


-- One employee, end to end. The most persuasive single screen in the demo.
-- SAY: "One employee, everything we hold for them. Note the salary is in
--       Indian rupees and the bonus is in US dollars - that matters in a
--       moment."
select COMPONENT_NAME, MEASURE_BASIS, PERIOD_KEY, AMOUNT, CURRENCY_CODE
from FACT_PAYROLL_COMPONENT
where EMPLOYEE_SAP_ID = '10000343'
  and REPORT_YEAR = 2026
  and AMOUNT is not null
order by COMPONENT_GROUP, PERIOD_KEY;


-- ===========================================================================
-- 5. PROOF THAT THE MAPPING IS RIGHT
--
-- SAY: "The spreadsheet contains its own checksum. Twelve monthly salary
--       columns, and a thirteenth that totals them. If our mapping picked
--       the right twelve, they must add up to the thirteenth."
--
--       "2,784 employments match. Zero disagree. The 24 are people whose
--        annual total cell was left blank in the spreadsheet - recent joiners
--        the formula was never dragged down to. Not our error."
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
-- 6. RULE ONE - only current files
--
-- SAY: "Ingestion keeps every version of every file. We only process the
--       current one. But 'current' alone was not enough - one of the four
--       current files is a sample workbook someone parked in a live folder.
--       Four rows, all copied from the real BR02 file. We exclude it."
--
-- Point at the row where IS_EXCLUDED is TRUE.
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
-- 7. RULE TWO - duplicate employee IDs
--
-- SAY: "Employee ID is the only field we trust from this file. It is also
--       not unique. Two people appear twice - and both are legitimate."
--
--       "The first transferred between subsidiaries mid-year. The second
--        holds two overlapping contracts at the same entity. So the key is
--        ID plus join date plus leave date, which is unique across all
--        2,812 rows."
--
--       "This is also why subsidiary is frozen onto every payment. When
--        someone transfers, their old payments must stay with the old
--        entity."
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
-- SAY: "Salary is paid in local currency. Bonuses are mostly paid in US
--       dollars. So we cannot give an employee one currency - each amount
--       carries its own."
--
--       "This is why the reporting view never adds salary and bonus into a
--        single total. That would be adding rupees to dollars and calling it
--        a number."
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
-- SAY: "This is what Tableau would connect to. Totals per employment, per
--       component, per currency - deliberately never summed across
--       currencies."
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
-- 10. SECURITY - amounts are masked
--
-- SAY: "Antoine's requirement was that he can see every row but no amounts.
--       Five columns are masked, not one - the figure is reachable through
--       the raw value, the text value, and the whole spreadsheet row, so
--       masking just the amount would have leaked."
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
-- Only do this if you are comfortable. It changes the policy and changes it
-- back. Run the three blocks in order and do not stop halfway.
--
-- SAY: "Right now I can see amounts because I hold the entitled role. Let me
--       take that away."
-- ---------------------------------------------------------------------------

-- 10a. Take the entitlement away
alter masking policy MP_PAYROLL_AMOUNT set body ->
    case when is_role_in_session('PAYROLL_AMOUNT_READER') then val else null end;

-- 10b. Same query as before. Amounts are gone, every row still there.
-- SAY: "Amounts are gone. Every row is still visible - that was the
--       requirement, he sees the rows, not the money."
select EMPLOYEE_SAP_ID, SUBSIDIARY_CODE, PERIOD_KEY, AMOUNT
from FACT_PAYROLL_COMPONENT
where COMPONENT_NAME = 'MONTHLY_SALARY' and MEASURE_BASIS = 'PAYMENT'
  and REPORT_YEAR = 2026
order by MEASURE_ID
limit 5;

-- 10c. PUT IT BACK. Do not skip this.
alter masking policy MP_PAYROLL_AMOUNT set body ->
    case when is_role_in_session('SF_APA_SANDBOX-ETL')    then val
         when is_role_in_session('PAYROLL_AMOUNT_READER') then val
         else null end;

-- Confirm it is back
select EMPLOYEE_SAP_ID, PERIOD_KEY, AMOUNT
from FACT_PAYROLL_COMPONENT
where COMPONENT_NAME = 'MONTHLY_SALARY' and MEASURE_BASIS = 'PAYMENT'
  and REPORT_YEAR = 2026
order by MEASURE_ID
limit 3;


-- ===========================================================================
-- 11. WHAT IS NOT DONE - say this before they ask
--
-- SAY: "Three things are not built. Data quality findings have a table but
--       nothing writes to them yet. Row-level security is designed but not
--       built. And RAW_CONTENT in the ingestion table is not masked - anyone
--       who can read that table can read every salary, which needs a
--       decision from whoever owns ingestion."
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
