-- ===========================================================================
-- transformation / 05 - Populate DQ_FLAG
--
-- Runs after 04_load_silver.sql. Full reload, same discipline as the model:
-- these are derived findings, not an append log, and Snowflake does not
-- enforce keys, so appending would duplicate every finding on a second run.
--
-- The class decides downstream treatment, per input data contract section 6:
--
--   STRUCTURAL  rejects the file or sheet
--   IDENTITY    loads, but is held out of GOLD until resolved
--   VALUE       loads and stays in GOLD, with the flag visible
--   CONVENTION  auto-resolved where possible, logged for a HEADER_MAP update
--
-- Every rule here is derived from what is already in the model - none of them
-- need a new source. Rules that need FOLDER_SUBSIDIARY_MAP are absent because
-- that seed has never been deployed; see the transformation design doc s.6.5.
--
-- RAW_VALUE on this table carries MP_PAYROLL_AMOUNT_TEXT, so a flagged salary
-- is masked here exactly as it is on the fact table.
-- ===========================================================================

use role "SF_APA_SANDBOX-ETL";
use warehouse SANDBOX_WH;
use schema SANDBOX_DB.HR_PAYROLL_QIMA;

truncate table DQ_FLAG;


-- ---------------------------------------------------------------------------
-- STRUCTURAL - a sheet whose template version is not recognised.
--
-- Zero today. It fires when Qima sends a layout HEADER_MAP has never seen,
-- which is the case this table exists to make visible rather than silent.
-- ---------------------------------------------------------------------------
insert into DQ_FLAG (LOAD_ID, TAB_LOAD_ID, DQ_CLASS, RULE_NAME, MESSAGE)
select sl.LOAD_ID,
       sl.TAB_LOAD_ID,
       'STRUCTURAL',
       'UNMAPPED_GENERATION',
       'Sheet ' || sl.TAB_NAME || ' resolved to generation ' ||
       coalesce(sl.GENERATION, '(none)') || ', which is not in HEADER_MAP. ' ||
       'The sheet did not load. Map the generation and re-run.'
from TAB_LOAD sl
where sl.MAPPING_STATUS = 'UNMAPPED';


-- ---------------------------------------------------------------------------
-- STRUCTURAL - a sample workbook reached the model.
--
-- Zero today because both known samples are excluded at file level. This is
-- the backstop for one that is not.
-- ---------------------------------------------------------------------------
insert into DQ_FLAG (LOAD_ID, TAB_LOAD_ID, DQ_CLASS, RULE_NAME, MESSAGE)
select sl.LOAD_ID,
       sl.TAB_LOAD_ID,
       'STRUCTURAL',
       'SAMPLE_FILE_INGESTED',
       'Sheet ' || sl.TAB_NAME || ' matched generation ' || sl.GENERATION ||
       ', which is flagged SAMPLE in HEADER_MAP. It reached the model despite ' ||
       'the filename rule in V_PAYROLL_FILE_CURRENT, so that rule needs widening.'
from TAB_LOAD sl
where sl.MAPPING_STATUS = 'SAMPLE';


-- ---------------------------------------------------------------------------
-- IDENTITY - the same employee id on two sheets of the same reporting year.
--
-- Zero today. Held out of GOLD if it fires, because it is not knowable which
-- submission is authoritative without asking.
-- ---------------------------------------------------------------------------
insert into DQ_FLAG (PAYROLL_ROW_ID, TAB_LOAD_ID, DQ_CLASS, RULE_NAME, MESSAGE)
select pr.PAYROLL_ROW_ID,
       pr.TAB_LOAD_ID,
       'IDENTITY',
       'DUPLICATE_SAP_ID_ACROSS_FILES',
       'Employee id appears on more than one sheet for ' ||
       pr.REPORT_YEAR::string || '. Which submission is authoritative needs ' ||
       'confirming before these values can be reported on.'
from PAYROLL_ROW pr
where not pr.IS_BLANK
  and exists (
      select 1 from PAYROLL_ROW o
      where o.EMPLOYEE_SAP_ID = pr.EMPLOYEE_SAP_ID
        and o.REPORT_YEAR     = pr.REPORT_YEAR
        and o.TAB_LOAD_ID  <> pr.TAB_LOAD_ID
        and not o.IS_BLANK);


-- ---------------------------------------------------------------------------
-- VALUE - a salary entered as text rather than a number.
--
-- The contract's named case. The value is kept in TEXT_VALUE rather than
-- dropped, and flagged here so a consumer can see it did not parse.
-- ---------------------------------------------------------------------------
insert into DQ_FLAG (TAB_LOAD_ID, PAYROLL_ROW_ID, MEASURE_ID, DQ_CLASS,
                     RULE_NAME, RAW_VALUE, MESSAGE)
select m.TAB_LOAD_ID, m.PAYROLL_ROW_ID, m.MEASURE_ID,
       'VALUE',
       'SALARY_AS_TEXT',
       m.TEXT_VALUE,
       m.COMPONENT_NAME || ' (' || m.MEASURE_BASIS || ') did not parse as a ' ||
       'number. The submitted value is kept in TEXT_VALUE rather than dropped.'
from FACT_PAYROLL_COMPONENT m
where m.TEXT_VALUE is not null;


-- ---------------------------------------------------------------------------
-- VALUE - a payment with an amount but no currency.
--
-- Neither the component's own (Currency) column nor the contractual currency
-- resolved, so the figure cannot be interpreted.
-- ---------------------------------------------------------------------------
insert into DQ_FLAG (TAB_LOAD_ID, PAYROLL_ROW_ID, MEASURE_ID, DQ_CLASS,
                     RULE_NAME, MESSAGE)
select m.TAB_LOAD_ID, m.PAYROLL_ROW_ID, m.MEASURE_ID,
       'VALUE',
       'MISSING_CURRENCY',
       m.COMPONENT_NAME || ' carries an amount but no currency - neither the ' ||
       'component currency column nor the contractual currency resolved.'
from FACT_PAYROLL_COMPONENT m
where m.MEASURE_BASIS = 'PAYMENT'
  and m.AMOUNT        is not null
  and m.CURRENCY_CODE is null;


-- ---------------------------------------------------------------------------
-- VALUE - the currency cell holds something that is not a currency code.
--
-- 191 rows today, all commission in 2026: a number was typed into the currency
-- cell in the source workbook. The column classification is correct - most
-- employees carry a valid code in it - so this is data entry, not mapping.
-- ---------------------------------------------------------------------------
insert into DQ_FLAG (TAB_LOAD_ID, PAYROLL_ROW_ID, MEASURE_ID, DQ_CLASS,
                     RULE_NAME, RAW_VALUE, MESSAGE)
select m.TAB_LOAD_ID, m.PAYROLL_ROW_ID, m.MEASURE_ID,
       'VALUE',
       'INVALID_CURRENCY_CODE',
       m.CURRENCY_CODE,
       'Currency for ' || m.COMPONENT_NAME || ' is ' || m.CURRENCY_CODE ||
       ', which is not a currency code. Likely an amount typed into the ' ||
       'currency cell.'
from FACT_PAYROLL_COMPONENT m
where m.CURRENCY_CODE is not null
  and not regexp_like(m.CURRENCY_CODE, '^[A-Za-z]{2,5}$');


-- ---------------------------------------------------------------------------
-- VALUE - monthly salary present, but the file's own annual total is blank.
--
-- 24 rows today. These are recent joiners the spreadsheet formula was never
-- extended to. Not a mapping failure, but it is why the reconciliation
-- reports 2,784 matches against 2,808 employments rather than all of them.
--
-- Restricted to generations that actually carry an annual total column. Only
-- the 2026 templates do - the 2024 and 2025 layouts have no such column at
-- all, so a missing total there is the template's shape, not a defect, and
-- flagging it would raise 5,000 findings that mean nothing.
-- ---------------------------------------------------------------------------
insert into DQ_FLAG (TAB_LOAD_ID, PAYROLL_ROW_ID, DQ_CLASS, RULE_NAME, MESSAGE)
select m.TAB_LOAD_ID,
       m.PAYROLL_ROW_ID,
       'VALUE',
       'MISSING_ANNUAL_TOTAL',
       'Monthly salary is present for ' || m.REPORT_YEAR::string ||
       ' but the annual total cell is blank, so this row cannot be ' ||
       'reconciled against the file''s own checksum.'
from (select distinct f.TAB_LOAD_ID, f.PAYROLL_ROW_ID, f.REPORT_YEAR
      from FACT_PAYROLL_COMPONENT f
      join TAB_LOAD sl on sl.TAB_LOAD_ID = f.TAB_LOAD_ID
      where f.COMPONENT_NAME = 'MONTHLY_SALARY' and f.MEASURE_BASIS = 'PAYMENT'
        and f.PERIOD_TYPE = 'MONTH' and f.CURRENCY_SCOPE = 'LOCAL'
        and exists (select 1 from HEADER_MAP h
                    where h.GENERATION     = sl.GENERATION
                      and h.COMPONENT_NAME = 'MONTHLY_SALARY'
                      and h.MEASURE_BASIS  = 'PAYMENT'
                      and h.PERIOD_TYPE    = 'FY'
                      and h.CURRENCY_SCOPE = 'LOCAL')) m
where not exists (
    select 1 from FACT_PAYROLL_COMPONENT r
    where r.PAYROLL_ROW_ID = m.PAYROLL_ROW_ID
      and r.COMPONENT_NAME = 'MONTHLY_SALARY' and r.MEASURE_BASIS = 'PAYMENT'
      and r.PERIOD_TYPE = 'FY' and r.CURRENCY_SCOPE = 'LOCAL');


-- ---------------------------------------------------------------------------
-- CONVENTION - retired.
--
-- This rule flagged values sourced from a column HEADER_MAP marks NEEDS_REVIEW.
-- It matched the fact row back to its column with SOURCE_COLUMN_INDEX, which
-- has been dropped from the fact table, so the link no longer exists. The four
-- NEEDS_REVIEW columns produced no values anyway, so nothing is lost today -
-- but a future unreviewed column will now load unflagged.
-- ---------------------------------------------------------------------------



-- ---------------------------------------------------------------------------
-- VALUE - an employee on Qima's roster who does not appear in our payroll data.
--
-- This answers "are we getting all the current employees?" rather than "is this
-- employee valid?". It is a completeness check, and it looks for absence, so
-- there is no fact row to attach it to - LOAD_ID, TAB_LOAD_ID, PAYROLL_ROW_ID
-- and MEASURE_ID are all null by design.
--
-- Scoped to the subsidiaries we actually hold files for. Comparing against the
-- full roster would flag every employee of the 45 subsidiaries nobody has sent
-- us, which is a scope fact rather than a data quality finding.
--
-- Scoped to the current year for the same reason the reporting views are: the
-- roster is a 2026 snapshot, and 970 of our all-years employees are pre-2026
-- leavers who are legitimately absent from it.
--
-- VALUE class is the least wrong of the four. It is not a defect in a loaded
-- value, but it is a finding that should be visible without withholding
-- anything from reporting.
--
-- Depends on STG_CONSOLIDATED_2026, which sits outside the model deliberately.
-- If that table is absent this rule simply inserts nothing.
-- ---------------------------------------------------------------------------
insert into DQ_FLAG (DQ_CLASS, RULE_NAME, MESSAGE)
select 'VALUE',
       'EMPLOYEE_MISSING_FROM_ROSTER',
       'Employee ' || t.EMPLOYEE_SAP_ID || ' is on the roster for subsidiary ' ||
       t.S || iff(t.LEAVE_DATE is null, ' and is still active', ' (has left)') ||
       ', but has no payroll row for the current reporting year.'
from (select trim(split_part(SUBSIDIARY, ' - ', 1)) as S,
             EMPLOYEE_SAP_ID, LEAVE_DATE
      from STG_CONSOLIDATED_2026) t
where t.S in (select distinct SUBSIDIARY_CODE from PAYROLL_ROW
              where not IS_BLANK and SUBSIDIARY_CODE is not null
                and REPORT_YEAR = (select max(REPORT_YEAR) from FACT_PAYROLL_COMPONENT
                                   where REPORT_YEAR <= year(current_date())))
  and not exists (select 1 from PAYROLL_ROW p
                  where p.EMPLOYEE_SAP_ID = t.EMPLOYEE_SAP_ID
                    and not p.IS_BLANK
                    and p.REPORT_YEAR = (select max(REPORT_YEAR) from FACT_PAYROLL_COMPONENT
                                         where REPORT_YEAR <= year(current_date())));


-- ---------------------------------------------------------------------------
-- Summary.
-- ---------------------------------------------------------------------------
select DQ_CLASS, RULE_NAME, count(*) as FINDINGS
from DQ_FLAG
group by 1, 2
order by 1, 3 desc;

-- Nothing IDENTITY-class means nothing is being withheld from GOLD.
select count(*) as IDENTITY_FLAGS_WITHHOLDING_FROM_GOLD
from DQ_FLAG where DQ_CLASS = 'IDENTITY';
