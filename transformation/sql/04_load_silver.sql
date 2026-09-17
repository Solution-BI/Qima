-- ===========================================================================
-- transformation / 04 - Load SILVER from RAW
--
-- RAW_CONTENT -> TAB_LOAD -> PAYROLL_ROW -> FACT_PAYROLL_PAYMENT,
--                                          FACT_PAYROLL_ENTITLEMENT,
--                                          PAYROLL_ATTRIBUTE.
--
-- Plain SQL, no Python. The reconciliation test proved the whole pattern: a
-- cell is located by joining HEADER_MAP on (generation, column index) and
-- reading it with GET(row, index). Nothing here hardcodes a column position,
-- which is what lets one script handle all seven generations - the employee id
-- is at index 0 in 2026 and index 1 in 2024/2025.
--
-- ALWAYS RUN THIS AS A FULL RELOAD. Truncate FACT_PAYROLL_PAYMENT,
-- FACT_PAYROLL_ENTITLEMENT, PAYROLL_ATTRIBUTE, PAYROLL_ROW and TAB_LOAD
-- first - never HEADER_MAP, which loads from CSV and would leave the loader
-- with nothing to interpret columns with.
--
-- Each step does carry a skip-check, but it keys on FILE_LOAD.LOAD_ID, and
-- ingestion writes a new row - and so a new LOAD_ID - on every run, including
-- re-ingestions of a file it has already seen. So after ingestion re-runs, the
-- skip-check does not recognise the same file and a plain re-run loads a
-- second copy of everything rather than skipping it. That is what happened on
-- 7 September: the three source files were re-ingested as 905/906/1001,
-- orphaning a model built on 723/811/813.
--
-- The skip-check is therefore only safe within a single ingestion generation,
-- which is not a condition worth relying on. A rebuild takes seconds.
-- Incremental loading keyed on SHAREPOINT_ITEM_ID plus SHAREPOINT_MODIFIED_AT
-- is possible if volumes ever make it worth it - they do not today.
--
-- Two things to know about the VARIANT data:
--   * an empty spreadsheet cell arrives as a JSON null, which Snowflake reports
--     as NOT NULL - IS_NULL_VALUE is the correct test
--   * GET(array, index) takes a dynamic index, which is what makes the
--     HEADER_MAP join work at all
-- ===========================================================================

use role "SF_APA_SANDBOX-ETL";
use warehouse SANDBOX_WH;
use schema SANDBOX_DB.HR_PAYROLL_QIMA;

-- ---------------------------------------------------------------------------
-- Step 1: TAB_LOAD. One row per tab in every file worth processing.
--
-- Non-year sheets ("Instructions") are recorded as NOT_APPLICABLE rather than
-- skipped, so the sheet inventory of a file is complete and auditable.
-- ---------------------------------------------------------------------------
insert into TAB_LOAD
    (LOAD_ID, TAB_NAME, TAB_YEAR, GENERATION, COLUMN_COUNT,
     HEADER_HASH, HEADER_JSON, TOTAL_ROWS, DATA_ROWS, MAPPING_STATUS)
with sheets as (
    select f.LOAD_ID,
           s.key                                              as TAB_NAME,
           try_to_number(s.key)                               as TAB_YEAR,
           s.value                                            as GRID,
           array_size(s.value)                                as TOTAL_ROWS,
           array_size(s.value[1])                             as COLUMN_COUNT,
           s.key || '-' || array_size(s.value[1]) || 'col'    as GENERATION
    from V_PAYROLL_FILE_CURRENT f,
         lateral flatten(input => f.RAW_CONTENT) s
),
-- Where the employee id lives, per generation. Index 0 in 2026, 1 in 2024/2025.
id_col as (
    select GENERATION, COLUMN_INDEX
    from HEADER_MAP
    where CANONICAL_FIELD = 'EMPLOYEE_SAP_ID'
),
-- Flatten once, then join. A correlated subquery containing its own FLATTEN is
-- rejected by Snowflake with "unsupported subquery type".
flat as (
    select sh.LOAD_ID, sh.TAB_NAME, sh.GENERATION, r.value as RV
    from sheets sh,
         lateral flatten(input => sh.GRID) r
    where r.index >= 2
),
row_counts as (
    select f.LOAD_ID, f.TAB_NAME, count(*) as DATA_ROWS
    from flat f
    join id_col i on i.GENERATION = f.GENERATION
    where not coalesce(is_null_value(get(f.RV, i.COLUMN_INDEX)), true)
      and get(f.RV, i.COLUMN_INDEX)::string <> ''
    group by 1, 2
),
gen_status as (
    select distinct GENERATION, GENERATION_STATUS from HEADER_MAP
)
select sh.LOAD_ID, sh.TAB_NAME, sh.TAB_YEAR, sh.GENERATION, sh.COLUMN_COUNT,
       hash(sh.GRID[1]::string), sh.GRID[1], sh.TOTAL_ROWS,
       coalesce(rc.DATA_ROWS, 0),
       case
           when sh.TAB_YEAR is null           then 'NOT_APPLICABLE'
           when g.GENERATION_STATUS = 'SAMPLE'  then 'SAMPLE'
           when g.GENERATION is not null        then 'MAPPED'
           else 'UNMAPPED'
       end
from sheets sh
left join row_counts rc on rc.LOAD_ID = sh.LOAD_ID and rc.TAB_NAME = sh.TAB_NAME
left join gen_status g   on g.GENERATION = sh.GENERATION
left join TAB_LOAD sl  on sl.LOAD_ID = sh.LOAD_ID and sl.TAB_NAME = sh.TAB_NAME
where sl.TAB_LOAD_ID is null;

-- ---------------------------------------------------------------------------
-- Step 2: PAYROLL_ROW. One row per employee line on a mapped sheet.
--
-- Every attribute is located through CANONICAL_FIELD, never by position.
-- EMPLOYMENT_KEY is the meeting's rule - id alone collides where an employee
-- holds two contracts or transferred subsidiary mid-year.
-- ---------------------------------------------------------------------------
insert into PAYROLL_ROW
    (TAB_LOAD_ID, ROW_INDEX, REPORT_YEAR, EMPLOYEE_SAP_ID, EMPLOYMENT_KEY,
     SUBSIDIARY_CODE, SUBSIDIARY_RAW, EMPLOYEE_NAME, JOIN_DATE, LEAVE_DATE,
     IS_BLANK, ROW_DATA)
with grid as (
    select sl.TAB_LOAD_ID, sl.GENERATION, sl.TAB_YEAR,
           r.index as ROW_INDEX, r.value as RV
    from TAB_LOAD sl
    join V_PAYROLL_FILE_CURRENT f on f.LOAD_ID = sl.LOAD_ID,
         lateral flatten(input => get(f.RAW_CONTENT, sl.TAB_NAME)) r
    where sl.MAPPING_STATUS = 'MAPPED'
      and r.index >= 2
      and not exists (select 1 from PAYROLL_ROW pr
                      where pr.TAB_LOAD_ID = sl.TAB_LOAD_ID)
),
-- One row per (sheet row, wanted field). Pivoted below.
fields as (
    select g.TAB_LOAD_ID, g.TAB_YEAR, g.ROW_INDEX, g.RV,
           m.CANONICAL_FIELD,
           nullif(trim(replace(get(g.RV, m.COLUMN_INDEX)::string, ' ', ' ')), '') as VAL
    from grid g
    join HEADER_MAP m
      on  m.GENERATION = g.GENERATION
      and m.CANONICAL_FIELD in
          ('EMPLOYEE_SAP_ID','EMPLOYEE_NAME','JOIN_DATE','LEAVE_DATE','SUBSIDIARY')
),
pivoted as (
    select TAB_LOAD_ID, TAB_YEAR, ROW_INDEX, any_value(RV) as RV,
           max(iff(CANONICAL_FIELD = 'EMPLOYEE_SAP_ID', VAL, null)) as EMPLOYEE_SAP_ID,
           max(iff(CANONICAL_FIELD = 'EMPLOYEE_NAME',   VAL, null)) as EMPLOYEE_NAME,
           max(iff(CANONICAL_FIELD = 'JOIN_DATE',       VAL, null)) as JOIN_RAW,
           max(iff(CANONICAL_FIELD = 'LEAVE_DATE',      VAL, null)) as LEAVE_RAW,
           max(iff(CANONICAL_FIELD = 'SUBSIDIARY',      VAL, null)) as SUBSIDIARY_RAW
    from fields
    group by 1, 2, 3
)
select TAB_LOAD_ID, ROW_INDEX, TAB_YEAR,
       EMPLOYEE_SAP_ID,
       EMPLOYEE_SAP_ID || '|' || coalesce(JOIN_RAW, '~') || '|' || coalesce(LEAVE_RAW, '~'),
       -- "BR02 - QIMA BRASIL LTDA." -> BR02. CPQUALI/CPHOSP carry no prefix,
       -- so they stay null here and resolve from the folder map instead.
       case when SUBSIDIARY_RAW like '% - %'
            then trim(split_part(SUBSIDIARY_RAW, ' - ', 1)) end,
       SUBSIDIARY_RAW,
       EMPLOYEE_NAME,
       try_to_date(try_to_timestamp_ntz(JOIN_RAW)::string),
       try_to_date(try_to_timestamp_ntz(LEAVE_RAW)::string),
       (EMPLOYEE_SAP_ID is null),
       RV
from pivoted;

-- ---------------------------------------------------------------------------
-- Step 3: resolve every cell once, then land it in the table that fits.
--
-- Storage is split three ways as of 11 September - paid, contractual, and
-- descriptive - but the work of finding a cell and deciding its currency is
-- identical for all three. That work lives in this view so there are not three
-- copies of the currency rule to keep in step.
--
-- The currency rule from the meeting: an amount takes its own component's
-- (Currency) column where the generation has one, and falls back to the
-- contractual currency otherwise. Salary is in local currency while bonus is
-- usually USD, so this cannot default to one currency per row.
--
-- Above both, from 17 September: a column whose header states USD is USD. The
-- currency cell describes the block, not that column, and where the two
-- disagree the header is the one written by whoever designed the template
-- rather than by whoever filled the row in.
--
-- This view also applies COMPONENT_OVERRIDE, which is where a subsidiary uses
-- a shared column for a different scheme than the template names.
-- ---------------------------------------------------------------------------
create or replace view V_PAYROLL_CELL
    comment = 'Every mapped cell of every employee row, with its currency resolved. The loader reads this; nothing downstream should.'
as
with ccy as (
    select pr.PAYROLL_ROW_ID, m.COMPONENT_NAME,
           nullif(trim(get(pr.ROW_DATA, m.COLUMN_INDEX)::string), '') as CURRENCY_CODE
    from PAYROLL_ROW pr
    join TAB_LOAD   sl on sl.TAB_LOAD_ID = pr.TAB_LOAD_ID
    join HEADER_MAP m  on m.GENERATION   = sl.GENERATION
    where m.MEASURE_BASIS = 'CURRENCY' and not pr.IS_BLANK
),
contract_ccy as (
    select pr.PAYROLL_ROW_ID,
           nullif(trim(get(pr.ROW_DATA, m.COLUMN_INDEX)::string), '') as CURRENCY_CODE
    from PAYROLL_ROW pr
    join TAB_LOAD   sl on sl.TAB_LOAD_ID = pr.TAB_LOAD_ID
    join HEADER_MAP m  on m.GENERATION   = sl.GENERATION
    where m.CANONICAL_FIELD = 'CONTRACT_CURRENCY' and not pr.IS_BLANK
)
select pr.PAYROLL_ROW_ID, pr.TAB_LOAD_ID, pr.EMPLOYEE_SAP_ID,
       pr.EMPLOYMENT_KEY, pr.SUBSIDIARY_CODE, pr.REPORT_YEAR,
       m.COMPONENT_GROUP,
       -- COMPONENT_OVERRIDE is empty for all but one subsidiary, so this is
       -- m.COMPONENT_NAME everywhere except Bangladesh's two 2025 blocks.
       coalesce(ov.COMPONENT_NAME_TO, m.COMPONENT_NAME) as COMPONENT_NAME,
       m.MEASURE_BASIS,
       m.PERIOD_TYPE, m.PERIOD_KEY, m.CURRENCY_SCOPE,
       m.CANONICAL_FIELD, m.SOURCE_HEADER, m.COLUMN_INDEX,
       nullif(trim(replace(get(pr.ROW_DATA, m.COLUMN_INDEX)::string, ' ', ' ')), '')                          as RAW_VALUE,
       -- A column whose own header states USD is denominated in USD, whatever
       -- the row's currency cell says. Bangladesh is why this is explicit: all
       -- 23 of its 2025 rows put the March Eid bonus in the column headed
       -- "Actual Paid amount in Dec 2025 (USD)" while the block's currency cell
       -- reads BDT, and the amounts - 79 to 191 - are only sane as dollars.
       -- Trusting the cell would have published USD figures labelled BDT once
       -- those rows started reaching GOLD.
       iff(m.CURRENCY_SCOPE = 'USD', 'USD',
           coalesce(cc.CURRENCY_CODE, kc.CURRENCY_CODE)) as CURRENCY_CODE
from PAYROLL_ROW pr
join TAB_LOAD   sl on sl.TAB_LOAD_ID = pr.TAB_LOAD_ID
join HEADER_MAP m  on m.GENERATION   = sl.GENERATION
left join COMPONENT_OVERRIDE ov
       on  ov.GENERATION          = sl.GENERATION
       and ov.COMPONENT_NAME_FROM = m.COMPONENT_NAME
       and ov.SUBSIDIARY_CODE     = pr.SUBSIDIARY_CODE
left join ccy          cc on cc.PAYROLL_ROW_ID = pr.PAYROLL_ROW_ID
                         and cc.COMPONENT_NAME = m.COMPONENT_NAME
left join contract_ccy kc on kc.PAYROLL_ROW_ID = pr.PAYROLL_ROW_ID
where not pr.IS_BLANK;

-- ---------------------------------------------------------------------------
-- Step 3a: FACT_PAYROLL_PAYMENT. Money that moved.
--
-- An empty cell is not a measurement, which is why RAW_VALUE must be present.
-- A value that should be a number but is not is kept in TEXT_VALUE per the
-- contract's "salary entered as text" case, rather than silently dropped.
-- ---------------------------------------------------------------------------
insert into FACT_PAYROLL_PAYMENT
    (PAYROLL_ROW_ID, TAB_LOAD_ID, EMPLOYEE_SAP_ID, EMPLOYMENT_KEY,
     SUBSIDIARY_CODE, REPORT_YEAR, COMPONENT_GROUP, COMPONENT_NAME,
     MEASURE_BASIS, PERIOD_TYPE, PERIOD_KEY, CURRENCY_SCOPE,
     AMOUNT, CURRENCY_CODE, TEXT_VALUE)
select c.PAYROLL_ROW_ID, c.TAB_LOAD_ID, c.EMPLOYEE_SAP_ID, c.EMPLOYMENT_KEY,
       c.SUBSIDIARY_CODE, c.REPORT_YEAR, c.COMPONENT_GROUP, c.COMPONENT_NAME,
       c.MEASURE_BASIS, c.PERIOD_TYPE, c.PERIOD_KEY, c.CURRENCY_SCOPE,
       try_to_number(c.RAW_VALUE, 18, 2),
       c.CURRENCY_CODE,
       iff(try_to_number(c.RAW_VALUE, 18, 2) is null, c.RAW_VALUE, null)
from V_PAYROLL_CELL c
where c.MEASURE_BASIS = 'PAYMENT'
  and c.RAW_VALUE is not null
  and not exists (select 1 from FACT_PAYROLL_PAYMENT t
                  where t.TAB_LOAD_ID = c.TAB_LOAD_ID);

-- ---------------------------------------------------------------------------
-- Step 3b: FACT_PAYROLL_ENTITLEMENT. What the contract says.
--
-- RATE and LIMIT carry an amount and a currency - what the contract says, and
-- the ceiling finance budgets against. ELIGIBILITY carries neither: it is a
-- Yes/No cell, and writing an AMOUNT or a CURRENCY_CODE on it would invite
-- exactly the mis-totalling the split exists to prevent.
-- ---------------------------------------------------------------------------
insert into FACT_PAYROLL_ENTITLEMENT
    (PAYROLL_ROW_ID, TAB_LOAD_ID, EMPLOYEE_SAP_ID, EMPLOYMENT_KEY,
     SUBSIDIARY_CODE, REPORT_YEAR, COMPONENT_GROUP, COMPONENT_NAME,
     MEASURE_BASIS, PERIOD_TYPE, PERIOD_KEY, CURRENCY_SCOPE,
     AMOUNT, CURRENCY_CODE, IS_ELIGIBLE, TEXT_VALUE)
select c.PAYROLL_ROW_ID, c.TAB_LOAD_ID, c.EMPLOYEE_SAP_ID, c.EMPLOYMENT_KEY,
       c.SUBSIDIARY_CODE, c.REPORT_YEAR, c.COMPONENT_GROUP, c.COMPONENT_NAME,
       c.MEASURE_BASIS, c.PERIOD_TYPE, c.PERIOD_KEY, c.CURRENCY_SCOPE,
       iff(c.MEASURE_BASIS <> 'ELIGIBILITY', try_to_number(c.RAW_VALUE, 18, 2), null),
       iff(c.MEASURE_BASIS =  'ELIGIBILITY', null, c.CURRENCY_CODE),
       iff(c.MEASURE_BASIS =  'ELIGIBILITY',
           case when upper(c.RAW_VALUE) in ('Y','YES','TRUE','1')  then true
                when upper(c.RAW_VALUE) in ('N','NO','FALSE','0') then false end, null),
       iff(c.MEASURE_BASIS <> 'ELIGIBILITY'
           and try_to_number(c.RAW_VALUE, 18, 2) is null, c.RAW_VALUE, null)
from V_PAYROLL_CELL c
where c.MEASURE_BASIS in ('RATE','LIMIT','ELIGIBILITY')
  and c.RAW_VALUE is not null
  and not exists (select 1 from FACT_PAYROLL_ENTITLEMENT t
                  where t.TAB_LOAD_ID = c.TAB_LOAD_ID);

-- ---------------------------------------------------------------------------
-- Step 3c: PAYROLL_ATTRIBUTE. External headcount and remarks.
--
-- These columns were mapped from the start but had no table to land in, which
-- is why Greg saw them missing from the 2026 extract on 11 September.
--
-- EMPLOYEE attributes are deliberately not here - name, id and the two dates
-- already sit on PAYROLL_ROW, and duplicating them would create a second place
-- to correct them.
--
-- ATTRIBUTE_NAME prefers CANONICAL_FIELD so a name is stable across template
-- generations. The fallbacks matter for 2025-95col, whose four extra External
-- HC columns have no canonical field, and for the 2024 sheets, which carry
-- three Remark columns with no header at all.
-- ---------------------------------------------------------------------------
insert into PAYROLL_ATTRIBUTE
    (PAYROLL_ROW_ID, TAB_LOAD_ID, EMPLOYEE_SAP_ID, EMPLOYMENT_KEY,
     SUBSIDIARY_CODE, REPORT_YEAR, ATTRIBUTE_GROUP, ATTRIBUTE_NAME,
     SOURCE_HEADER, TEXT_VALUE, AMOUNT, CURRENCY_CODE)
select c.PAYROLL_ROW_ID, c.TAB_LOAD_ID, c.EMPLOYEE_SAP_ID, c.EMPLOYMENT_KEY,
       c.SUBSIDIARY_CODE, c.REPORT_YEAR,
       c.COMPONENT_GROUP,
       coalesce(c.CANONICAL_FIELD,
                nullif(upper(regexp_replace(trim(c.SOURCE_HEADER), '[^A-Za-z0-9]+', '_')), ''),
                c.COMPONENT_NAME || '_COL' || c.COLUMN_INDEX),
       c.SOURCE_HEADER,
       -- A fee that parses lives in AMOUNT only. Writing its text as well would
       -- hold the same figure in two columns, which the fact tables never do -
       -- they set TEXT_VALUE only when a number fails to parse. A fee typed as
       -- text ("TBC") still keeps it, so nothing submitted is lost.
       iff(c.MEASURE_BASIS = 'FEE' and try_to_number(c.RAW_VALUE, 18, 2) is not null,
           null, c.RAW_VALUE),
       iff(c.MEASURE_BASIS = 'FEE', try_to_number(c.RAW_VALUE, 18, 2), null),
       iff(c.MEASURE_BASIS = 'FEE', c.CURRENCY_CODE, null)
from V_PAYROLL_CELL c
where c.COMPONENT_GROUP in ('EXTERNAL','OTHER','ADHOC')
  and c.MEASURE_BASIS in ('ATTRIBUTE','FEE')
  and c.RAW_VALUE is not null
  and not exists (select 1 from PAYROLL_ATTRIBUTE t
                  where t.TAB_LOAD_ID = c.TAB_LOAD_ID);
