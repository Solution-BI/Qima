-- ===========================================================================
-- security / masking - payroll amount masking
--
-- Requirement, confirmed by Antoine at the 20 August pre-kickoff:
--   * AMOUNT columns only. Employee attributes stay unmasked deliberately -
--     that data is already exposed in other tables, so masking it here would
--     achieve nothing while it remains readable elsewhere.
--   * ALL ROWS stay visible. "He can access the database but should not see the
--     amounts, while still seeing all rows." Masking and row access are two
--     separate controls; this file is only the first.
--   * Masking is the primary control for the data team, layered on top of
--     database access.
--
-- Display value: NULL (hidden), agreed as the working choice. Whether the final
-- form is hidden, anonymised or a fixed value is still open with HR - when it
-- is settled, only MASKED_NUMBER / MASKED_TEXT below need to change.
-- ===========================================================================

use role "SF_APA_SANDBOX-ETL";
use warehouse SANDBOX_WH;
use schema SANDBOX_DB.HR_PAYROLL_QIMA;

-- ---------------------------------------------------------------------------
-- Masking AMOUNT alone is not enough. The same figure is reachable through
-- four other columns, so a policy on AMOUNT by itself would leak:
--
--   FACT_PAYROLL_COMPONENT.AMOUNT       the parsed number
--   FACT_PAYROLL_COMPONENT.RAW_VALUE    the same figure, verbatim as text
--   FACT_PAYROLL_COMPONENT.TEXT_VALUE   the figure where it was typed as text
--   PAYROLL_ROW.ROW_DATA                the entire spreadsheet line, VARIANT
--   DQ_FLAG.RAW_VALUE                   the offending value on a flagged cell
--
-- Views inherit a policy from the column they select, so masking these base
-- columns covers V_GOLD_PAYROLL_COMPONENT and everything downstream.
--
-- Deliberately NOT covered here: FILE_LOAD.RAW_CONTENT, which holds every
-- amount in the workbook. It belongs to the ingestion pipeline and sits in the
-- RAW layer - see security/docs/README.md.
-- ---------------------------------------------------------------------------

-- Re-running this file after the policies are attached will fail:
--   "Policy ... cannot be dropped/replaced as it is associated with one or
--    more entities."
-- CREATE OR REPLACE is for first run only. To change the rule afterwards, use
-- ALTER ... SET BODY, which edits in place without detaching:
--
--   alter masking policy MP_PAYROLL_AMOUNT set body ->
--       case when is_role_in_session('PAYROLL_AMOUNT_READER') then val else null end;
--
-- That is also how the display value changes once HR settles hidden vs
-- anonymised vs fixed - one ALTER per policy, no downtime, no re-apply.
--
-- IS_ROLE_IN_SESSION respects role hierarchy, so a role that inherits an
-- authorised role is also authorised. Do not use CURRENT_ROLE here - it sees
-- only the active role and would mask for anyone using an inheriting role.
create or replace masking policy MP_PAYROLL_AMOUNT as (val number) returns number ->
    case
        when is_role_in_session('SF_APA_SANDBOX-ETL')   then val   -- sandbox build role
        when is_role_in_session('PAYROLL_AMOUNT_READER') then val  -- target: maps to the PAYROLL access-role ladder
        else null
    end
    comment = 'Hides payroll amounts from roles not entitled to see them. Rows remain visible.';

create or replace masking policy MP_PAYROLL_AMOUNT_TEXT as (val varchar) returns varchar ->
    case
        when is_role_in_session('SF_APA_SANDBOX-ETL')   then val
        when is_role_in_session('PAYROLL_AMOUNT_READER') then val
        else null
    end
    comment = 'Same rule as MP_PAYROLL_AMOUNT, for amount columns held as text.';

create or replace masking policy MP_PAYROLL_ROW_VARIANT as (val variant) returns variant ->
    case
        when is_role_in_session('SF_APA_SANDBOX-ETL')   then val
        when is_role_in_session('PAYROLL_AMOUNT_READER') then val
        else null
    end
    comment = 'Hides the whole spreadsheet row. ROW_DATA holds every amount for that employee, so it cannot be left readable while AMOUNT is masked.';

-- ---------------------------------------------------------------------------
-- Apply
-- ---------------------------------------------------------------------------
alter table FACT_PAYROLL_COMPONENT modify column AMOUNT      set masking policy MP_PAYROLL_AMOUNT;
alter table FACT_PAYROLL_COMPONENT modify column RAW_VALUE   set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table FACT_PAYROLL_COMPONENT modify column TEXT_VALUE  set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table PAYROLL_ROW            modify column ROW_DATA    set masking policy MP_PAYROLL_ROW_VARIANT;
alter table DQ_FLAG                modify column RAW_VALUE   set masking policy MP_PAYROLL_AMOUNT_TEXT;

-- ---------------------------------------------------------------------------
-- Verify: every masked column, and nothing missed
-- ---------------------------------------------------------------------------
select POLICY_NAME, REF_ENTITY_NAME as TABLE_NAME, REF_COLUMN_NAME as COLUMN_NAME
from table(information_schema.policy_references(policy_name => 'MP_PAYROLL_AMOUNT'))
union all
select POLICY_NAME, REF_ENTITY_NAME, REF_COLUMN_NAME
from table(information_schema.policy_references(policy_name => 'MP_PAYROLL_AMOUNT_TEXT'))
union all
select POLICY_NAME, REF_ENTITY_NAME, REF_COLUMN_NAME
from table(information_schema.policy_references(policy_name => 'MP_PAYROLL_ROW_VARIANT'))
order by 2, 3;
