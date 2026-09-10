-- ===========================================================================
-- transformation / 03 - Which files the loader processes
--
-- Replaces the former FILE_EXCLUSION table. The rule now lives in one view
-- instead of a table plus a join, which is one fewer object in the flow.
--
-- WHY A FILENAME PATTERN RATHER THAN THE SHAREPOINT ITEM ID
--
-- The exclusion table keyed on SHAREPOINT_ITEM_ID, on the reasoning that a
-- rename cannot defeat an id. That reasoning was sound but incomplete: an item
-- id survives a rename, and does not survive a delete and re-upload. The BR02
-- sample workbook has been through three item ids for that reason, and the
-- list had stopped matching the live one - it was reaching the loader on
-- 10 September and was stopped only by its column width happening to match a
-- generation already flagged SAMPLE.
--
-- A filename pattern catches every upload of that file, past and future, with
-- nothing to maintain.
--
-- THE TRADE-OFF, STATED PLAINLY
--
-- A genuine submission named "..._Sample..." would be skipped. That has never
-- happened in the files received, and it would be visible rather than silent:
-- the tab is still recorded in TAB_LOAD, and a missing subsidiary shows up in
-- reporting. The previous mechanism's failure mode was silence, which is worse.
--
-- The record of why each known file was judged a non-submission is kept in
-- reference_data/file_exclusion/excluded_files.csv. It is no longer loaded.
-- ===========================================================================

use role "SF_APA_SANDBOX-ETL";
use warehouse SANDBOX_WH;
use schema SANDBOX_DB.HR_PAYROLL_QIMA;


-- ---------------------------------------------------------------------------
-- Every file, annotated with whether it will be processed and why not.
-- Nothing is deleted, so a decision to leave a file out stays visible.
-- ---------------------------------------------------------------------------
create or replace view V_PAYROLL_FILE as
select f.*,
       case
           when not f.IS_CURRENT                    then 'SUPERSEDED'
           when f.INGEST_STATUS  <> 'SUCCESS'       then 'INGEST_FAILED'
           when f.EXTRACT_STATUS <> 'SUCCESS'       then 'EXTRACT_FAILED'
           when f.FILE_NAME ilike '%sample%'        then 'SAMPLE'
           when f.FILE_NAME ilike '%dummy%'         then 'NOT_PAYROLL'
           when f.FILE_NAME ilike '%test%'          then 'TEST'
       end                                          as SKIP_REASON
from FILE_LOAD f;


-- ---------------------------------------------------------------------------
-- The single place the loader asks "which files do I process?".
-- ---------------------------------------------------------------------------
create or replace view V_PAYROLL_FILE_CURRENT as
select * from V_PAYROLL_FILE
where SKIP_REASON is null;


-- ---------------------------------------------------------------------------
-- Checks.
-- ---------------------------------------------------------------------------
-- Expect the three real submissions and nothing else.
select LOAD_ID, FILE_NAME, SHAREPOINT_MODIFIED_AT
from V_PAYROLL_FILE_CURRENT
order by LOAD_ID;

-- Everything skipped, with the reason. Useful when someone asks why a file
-- they uploaded has not appeared.
select SKIP_REASON, count(*) as FILES, listagg(distinct FILE_NAME, ', ')
    within group (order by FILE_NAME) as WHICH
from V_PAYROLL_FILE
where SKIP_REASON is not null
group by 1
order by 2 desc;
