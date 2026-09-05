-- ===========================================================================
-- transformation / 03 - Which files are real payroll
--
-- Implements the processing rule: only current files, and never a known
-- non-submission.
--
-- FILE_LOAD.IS_CURRENT alone is not sufficient. It returns four files today
-- and one of them is a sample workbook parked in the live BR02 folder.
-- ===========================================================================

use role "SF_APA_SANDBOX-ETL";
use warehouse SANDBOX_WH;
use schema SANDBOX_DB.HR_PAYROLL_QIMA;

-- ---------------------------------------------------------------------------
-- Keyed on SHAREPOINT_ITEM_ID, not file name, deliberately.
--
-- The known sample has already been renamed once - BR02_Payroll_Sample.xlsx to
-- BR05_Payroll_Sample.xlsx - while keeping the same item id. A name-based
-- exclusion would have silently stopped working at that rename. The item id is
-- what SharePoint keeps stable.
--
-- Seeded from reference_data/file_exclusion/excluded_files.csv.
-- ---------------------------------------------------------------------------
create table if not exists FILE_EXCLUSION (
    SHAREPOINT_ITEM_ID  varchar        not null,
    KNOWN_AS            varchar
        comment 'Every file name this item has been seen under. Informational - never join on it.',
    REASON              varchar        not null,
    EVIDENCE            varchar
        comment 'Why this was judged a non-submission. Excluding payroll data needs a stated reason, not a preference.',
    EXCLUDED_ON         date           not null default current_date(),
    EXCLUDED_BY         varchar        not null default current_user(),
    constraint PK_FILE_EXCLUSION primary key (SHAREPOINT_ITEM_ID),
    constraint CHK_EXCLUSION_REASON check (REASON in ('SAMPLE','TEST','DUPLICATE','WITHDRAWN','NOT_PAYROLL'))
) comment = 'SharePoint items that are not genuine payroll submissions. Keyed on item id so a rename cannot defeat it.';

-- ---------------------------------------------------------------------------
-- The single place the loader asks "which files do I process?".
--
-- Nothing is deleted - an excluded file keeps its FILE_LOAD row and its
-- RAW_CONTENT, so the decision stays auditable and reversible by deleting one
-- row from FILE_EXCLUSION.
-- ---------------------------------------------------------------------------
create or replace view V_PAYROLL_FILE as
select f.*,
       (x.SHAREPOINT_ITEM_ID is not null) as IS_EXCLUDED,
       x.REASON                           as EXCLUSION_REASON
from FILE_LOAD f
left join FILE_EXCLUSION x
       on x.SHAREPOINT_ITEM_ID = f.SHAREPOINT_ITEM_ID;

create or replace view V_PAYROLL_FILE_CURRENT as
select * from V_PAYROLL_FILE
where IS_CURRENT
  and not IS_EXCLUDED
  and INGEST_STATUS  = 'SUCCESS'
  and EXTRACT_STATUS = 'SUCCESS';

-- Sanity check: should return the three real submissions and nothing else.
select LOAD_ID, FILE_NAME, SHAREPOINT_MODIFIED_AT from V_PAYROLL_FILE_CURRENT order by LOAD_ID;
