-- ===========================================================================
-- transformation / 06 - Table, view and column descriptions
--
-- What a user sees when browsing the payroll objects in Snowsight, or reading
-- INFORMATION_SCHEMA. Written for the person reading the data rather than the
-- person building it: what each column holds, its values, and how to use it.
-- The design reasoning stays in the SQL comments of 01 to 05.
--
-- RUN THIS LAST, AND AFTER EVERY RUN OF 01 TO 04. CREATE OR REPLACE VIEW
-- discards column descriptions, and 01, 02, 03 and 04 all rebuild views -
-- 04 rebuilds V_PAYROLL_CELL on every data reload. Table descriptions survive
-- a truncate and CREATE TABLE IF NOT EXISTS, but are set here as well so this
-- file is the one place descriptions are maintained.
--
-- Tables take COMMENT ON COLUMN. Views need ALTER VIEW ... ALTER COLUMN
-- ... COMMENT, because COMMENT ON COLUMN rejects a view.
--
-- Not covered: FILE_LOAD, which belongs to ingestion and is described there,
-- and STG_CONSOLIDATED_2026, a staging copy that sits outside the model.
-- ===========================================================================

use role "SF_APA_SANDBOX-ETL";
use warehouse SANDBOX_WH;
use schema SANDBOX_DB.HR_PAYROLL_QIMA;


-- ---------------------------------------------------------------------------
-- TAB_LOAD
-- ---------------------------------------------------------------------------
comment on table TAB_LOAD is 'One row per tab in each ingested payroll workbook, with the template version it matched. Shows why each tab was or was not loaded.';
comment on column TAB_LOAD.TAB_LOAD_ID is 'Unique identifier of the tab.';
comment on column TAB_LOAD.LOAD_ID is 'The ingested file this tab belongs to. Join to FILE_LOAD.';
comment on column TAB_LOAD.TAB_NAME is 'Tab name as it appears in the workbook, such as 2026 or Instructions.';
comment on column TAB_LOAD.TAB_YEAR is 'The tab name read as a year. Empty for tabs that are not a year, such as Instructions.';
comment on column TAB_LOAD.GENERATION is 'Template version, written as tab year and column count, such as 2026-75col. Join to HEADER_MAP.';
comment on column TAB_LOAD.COLUMN_COUNT is 'Number of columns in the header row of the tab.';
comment on column TAB_LOAD.HEADER_HASH is 'Fingerprint of the header row. A change on a known template version means headers were edited.';
comment on column TAB_LOAD.HEADER_JSON is 'The header row exactly as submitted.';
comment on column TAB_LOAD.TOTAL_ROWS is 'Every row in the tab, including the band and header rows and formatted but empty rows.';
comment on column TAB_LOAD.DATA_ROWS is 'Rows that carry an employee identifier.';
comment on column TAB_LOAD.MAPPING_STATUS is 'MAPPED when the template version is known and the tab was loaded. UNMAPPED when the version is unknown, so the tab was not loaded and a finding was raised. SAMPLE for a test template, never loaded. NOT_APPLICABLE for tabs that are not a year.';
comment on column TAB_LOAD.CREATED_AT is 'When the tab was recorded.';

-- ---------------------------------------------------------------------------
-- PAYROLL_ROW
-- ---------------------------------------------------------------------------
comment on table PAYROLL_ROW is 'One row per employee line in each loaded workbook tab, with the employee details and a masked copy of the whole line.';
comment on column PAYROLL_ROW.PAYROLL_ROW_ID is 'Unique identifier of the employee line.';
comment on column PAYROLL_ROW.TAB_LOAD_ID is 'The workbook tab this row came from. Join to TAB_LOAD.';
comment on column PAYROLL_ROW.ROW_INDEX is 'Position of the line in the tab. Row 0 is the band and row 1 the headers, so employee data starts at 2.';
comment on column PAYROLL_ROW.REPORT_YEAR is 'Reporting year of the tab.';
comment on column PAYROLL_ROW.EMPLOYEE_SAP_ID is 'Employee identifier from SAP, as submitted. This is the authoritative employee key. Stored as text so that a non-numeric identifier is never lost.';
comment on column PAYROLL_ROW.SUBSIDIARY_CODE is 'Subsidiary code taken from the subsidiary cell, the part before the first dash, such as BR02. Empty where the cell has no code.';
comment on column PAYROLL_ROW.SUBSIDIARY_RAW is 'The subsidiary cell exactly as submitted.';
comment on column PAYROLL_ROW.EMPLOYEE_NAME is 'Employee name as submitted. For reference only, since the HR system is the source of truth.';
comment on column PAYROLL_ROW.JOIN_DATE is 'Join date as submitted. For reference, and part of EMPLOYMENT_KEY.';
comment on column PAYROLL_ROW.LEAVE_DATE is 'Leave date as submitted, if any. For reference, and part of EMPLOYMENT_KEY.';
comment on column PAYROLL_ROW.EMPLOYMENT_KEY is 'Identifies one employment: SAP ID, join date and leave date, separated by a vertical bar. Group by this rather than by EMPLOYEE_SAP_ID, because one employee can hold two contracts or move between subsidiaries.';
comment on column PAYROLL_ROW.IS_BLANK is 'TRUE for a formatted but empty line with no employee identifier. Kept so row counts reconcile with the file.';
comment on column PAYROLL_ROW.ROW_DATA is 'Every cell of the line as submitted, so a mapping correction can be applied without ingesting the file again. Masked for roles not entitled to see payroll amounts.';
comment on column PAYROLL_ROW.LOADED_AT is 'When this row was loaded.';

-- ---------------------------------------------------------------------------
-- FACT_PAYROLL_PAYMENT
-- ---------------------------------------------------------------------------
comment on table FACT_PAYROLL_PAYMENT is 'Amounts actually paid, one row per paid value per employee line. When totalling salary, leave out MONTHLY_SALARY rows with PERIOD_TYPE FY: they are the template''s annual total and repeat the monthly rows.';
comment on column FACT_PAYROLL_PAYMENT.MEASURE_ID is 'Unique identifier of this value. It is unique across FACT_PAYROLL_PAYMENT and FACT_PAYROLL_ENTITLEMENT together, so it identifies one row in either table.';
comment on column FACT_PAYROLL_PAYMENT.PAYROLL_ROW_ID is 'The employee line in the submitted workbook this row came from. Join to PAYROLL_ROW.';
comment on column FACT_PAYROLL_PAYMENT.TAB_LOAD_ID is 'The workbook tab this row came from. Join to TAB_LOAD.';
comment on column FACT_PAYROLL_PAYMENT.EMPLOYEE_SAP_ID is 'Employee identifier from SAP, as submitted. This is the authoritative employee key. Stored as text so that a non-numeric identifier is never lost.';
comment on column FACT_PAYROLL_PAYMENT.EMPLOYMENT_KEY is 'Identifies one employment: SAP ID, join date and leave date, separated by a vertical bar. Group by this rather than by EMPLOYEE_SAP_ID, because one employee can hold two contracts or move between subsidiaries.';
comment on column FACT_PAYROLL_PAYMENT.SUBSIDIARY_CODE is 'Subsidiary code as recorded on the submission, such as BR02. It stays as it stood at the time, so an employee who later transfers keeps earlier values under the original subsidiary. Empty where the submission gives the entity name without a code.';
comment on column FACT_PAYROLL_PAYMENT.REPORT_YEAR is 'Reporting year of the workbook tab the value came from.';
comment on column FACT_PAYROLL_PAYMENT.COMPONENT_GROUP is 'Pay component family: SALARY, BONUS, COMMISSION or ADHOC.';
comment on column FACT_PAYROLL_PAYMENT.COMPONENT_NAME is 'The specific pay component, such as MONTHLY_SALARY, YEAR_END or THIRTEENTH_MONTH. The list comes from HEADER_MAP, so a new component appears here without any change to the table.';
comment on column FACT_PAYROLL_PAYMENT.MEASURE_BASIS is 'Always PAYMENT: an amount actually paid.';
comment on column FACT_PAYROLL_PAYMENT.PERIOD_TYPE is 'MONTH, QUARTER or FY: the kind of period the payment covers.';
comment on column FACT_PAYROLL_PAYMENT.PERIOD_KEY is 'The period the payment covers: YYYY-MM for a month, YYYY-Qn for a quarter, YYYY for a year.';
comment on column FACT_PAYROLL_PAYMENT.CURRENCY_SCOPE is 'LOCAL for an amount in local currency. USD for a value from the USD columns of the 2024 and 2025 templates, which mostly repeat local amounts converted at an unknown rate. Reporting views use LOCAL.';
comment on column FACT_PAYROLL_PAYMENT.AMOUNT is 'The amount paid, in CURRENCY_CODE. Masked for roles not entitled to see payroll amounts.';
comment on column FACT_PAYROLL_PAYMENT.CURRENCY_CODE is 'Currency of AMOUNT. Taken from the component''s own currency column where the template has one, otherwise from the contract currency, so salary and bonus can differ for the same employee. Codes are as submitted, so Chinese yuan appears as RMB, and invalid codes are flagged in DQ_FLAG.';
comment on column FACT_PAYROLL_PAYMENT.TEXT_VALUE is 'The value as typed, kept only when it could not be read as a number, such as a salary entered as text. Empty whenever AMOUNT is set. Masked for roles not entitled to see payroll amounts.';
comment on column FACT_PAYROLL_PAYMENT.LOADED_AT is 'When this row was loaded.';

-- ---------------------------------------------------------------------------
-- FACT_PAYROLL_ENTITLEMENT
-- ---------------------------------------------------------------------------
comment on table FACT_PAYROLL_ENTITLEMENT is 'The contractual position, one row per value: agreed rates such as gross monthly salary and bonus maximums, and bonus scheme eligibility. Nothing here is money paid, so never add these rows to payments.';
comment on column FACT_PAYROLL_ENTITLEMENT.MEASURE_ID is 'Unique identifier of this value. It is unique across FACT_PAYROLL_PAYMENT and FACT_PAYROLL_ENTITLEMENT together, so it identifies one row in either table.';
comment on column FACT_PAYROLL_ENTITLEMENT.PAYROLL_ROW_ID is 'The employee line in the submitted workbook this row came from. Join to PAYROLL_ROW.';
comment on column FACT_PAYROLL_ENTITLEMENT.TAB_LOAD_ID is 'The workbook tab this row came from. Join to TAB_LOAD.';
comment on column FACT_PAYROLL_ENTITLEMENT.EMPLOYEE_SAP_ID is 'Employee identifier from SAP, as submitted. This is the authoritative employee key. Stored as text so that a non-numeric identifier is never lost.';
comment on column FACT_PAYROLL_ENTITLEMENT.EMPLOYMENT_KEY is 'Identifies one employment: SAP ID, join date and leave date, separated by a vertical bar. Group by this rather than by EMPLOYEE_SAP_ID, because one employee can hold two contracts or move between subsidiaries.';
comment on column FACT_PAYROLL_ENTITLEMENT.SUBSIDIARY_CODE is 'Subsidiary code as recorded on the submission, such as BR02. It stays as it stood at the time, so an employee who later transfers keeps earlier values under the original subsidiary. Empty where the submission gives the entity name without a code.';
comment on column FACT_PAYROLL_ENTITLEMENT.REPORT_YEAR is 'Reporting year of the workbook tab the value came from.';
comment on column FACT_PAYROLL_ENTITLEMENT.COMPONENT_GROUP is 'Pay component family: SALARY, BONUS, COMMISSION or ADHOC.';
comment on column FACT_PAYROLL_ENTITLEMENT.COMPONENT_NAME is 'The specific pay component, such as MONTHLY_SALARY, YEAR_END or THIRTEENTH_MONTH. The list comes from HEADER_MAP, so a new component appears here without any change to the table.';
comment on column FACT_PAYROLL_ENTITLEMENT.MEASURE_BASIS is 'RATE for a contractual figure such as gross monthly salary, allowance or a bonus maximum. ELIGIBILITY for a yes or no bonus scheme flag.';
comment on column FACT_PAYROLL_ENTITLEMENT.PERIOD_TYPE is 'FY on bonus maximums, which the template states per year. Empty on salary rates and eligibility flags, which are standing positions rather than events in a period.';
comment on column FACT_PAYROLL_ENTITLEMENT.PERIOD_KEY is 'The year a bonus maximum applies to. Empty where PERIOD_TYPE is empty.';
comment on column FACT_PAYROLL_ENTITLEMENT.CURRENCY_SCOPE is 'LOCAL or USD on rates, as for payments. NA on eligibility flags, which have no currency.';
comment on column FACT_PAYROLL_ENTITLEMENT.AMOUNT is 'The contractual amount on RATE rows, in CURRENCY_CODE. Empty on eligibility flags. Masked for roles not entitled to see payroll amounts.';
comment on column FACT_PAYROLL_ENTITLEMENT.CURRENCY_CODE is 'Currency of AMOUNT on RATE rows. Taken from the component''s own currency column where the template has one, otherwise from the contract currency. Empty on eligibility flags.';
comment on column FACT_PAYROLL_ENTITLEMENT.IS_ELIGIBLE is 'Set on eligibility flags only: TRUE for yes, FALSE for no, empty if the cell held anything else.';
comment on column FACT_PAYROLL_ENTITLEMENT.TEXT_VALUE is 'A rate as typed, kept only when it could not be read as a number. Empty whenever AMOUNT is set. Masked for roles not entitled to see payroll amounts.';
comment on column FACT_PAYROLL_ENTITLEMENT.LOADED_AT is 'When this row was loaded.';

-- ---------------------------------------------------------------------------
-- PAYROLL_ATTRIBUTE
-- ---------------------------------------------------------------------------
comment on table PAYROLL_ATTRIBUTE is 'Descriptive values that are not pay, one row per attribute per employee line: the External HC block, Agency Name and Agency Fee, and Remarks.';
comment on column PAYROLL_ATTRIBUTE.ATTRIBUTE_ID is 'Unique identifier of the attribute row.';
comment on column PAYROLL_ATTRIBUTE.PAYROLL_ROW_ID is 'The employee line in the submitted workbook this row came from. Join to PAYROLL_ROW.';
comment on column PAYROLL_ATTRIBUTE.TAB_LOAD_ID is 'The workbook tab this row came from. Join to TAB_LOAD.';
comment on column PAYROLL_ATTRIBUTE.EMPLOYEE_SAP_ID is 'Employee identifier from SAP, as submitted. This is the authoritative employee key. Stored as text so that a non-numeric identifier is never lost.';
comment on column PAYROLL_ATTRIBUTE.EMPLOYMENT_KEY is 'Identifies one employment: SAP ID, join date and leave date, separated by a vertical bar. Group by this rather than by EMPLOYEE_SAP_ID, because one employee can hold two contracts or move between subsidiaries.';
comment on column PAYROLL_ATTRIBUTE.SUBSIDIARY_CODE is 'Subsidiary code as recorded on the submission, such as BR02. It stays as it stood at the time, so an employee who later transfers keeps earlier values under the original subsidiary. Empty where the submission gives the entity name without a code.';
comment on column PAYROLL_ATTRIBUTE.REPORT_YEAR is 'Reporting year of the workbook tab the value came from.';
comment on column PAYROLL_ATTRIBUTE.ATTRIBUTE_GROUP is 'EXTERNAL for the External HC block, OTHER for Remarks, ADHOC for the payment type of an ad hoc bonus.';
comment on column PAYROLL_ATTRIBUTE.ATTRIBUTE_NAME is 'What the value is, such as AGENCY_NAME, AGENCY_FEE or REMARK. The name is the same across template versions, so a Remark header and a Remarks header both arrive as REMARK.';
comment on column PAYROLL_ATTRIBUTE.SOURCE_HEADER is 'The column header exactly as it appears in the workbook.';
comment on column PAYROLL_ATTRIBUTE.TEXT_VALUE is 'The value as written. On AGENCY_FEE it is set only when the fee could not be read as a number. Masked for roles not entitled to see payroll amounts.';
comment on column PAYROLL_ATTRIBUTE.AMOUNT is 'The agency fee. Empty on every other attribute. Masked for roles not entitled to see payroll amounts.';
comment on column PAYROLL_ATTRIBUTE.CURRENCY_CODE is 'Currency of the agency fee. The template has no currency cell for the fee, so this is the contract currency of the employee. Empty on every other attribute.';
comment on column PAYROLL_ATTRIBUTE.LOADED_AT is 'When this row was loaded.';

-- ---------------------------------------------------------------------------
-- DQ_FLAG
-- ---------------------------------------------------------------------------
comment on table DQ_FLAG is 'Data quality findings from the latest load, one row per finding. The class decides the effect on reporting: VALUE findings stay visible in reporting, IDENTITY findings are held out until resolved, and STRUCTURAL findings mean a file or tab was not loaded.';
comment on column DQ_FLAG.FLAG_ID is 'Unique identifier of the finding.';
comment on column DQ_FLAG.LOAD_ID is 'The file the finding concerns, where it applies to a whole file. Join to FILE_LOAD.';
comment on column DQ_FLAG.TAB_LOAD_ID is 'The workbook tab the finding concerns. Join to TAB_LOAD.';
comment on column DQ_FLAG.PAYROLL_ROW_ID is 'The employee line the finding concerns. Join to PAYROLL_ROW.';
comment on column DQ_FLAG.MEASURE_ID is 'The value the finding concerns. Join to FACT_PAYROLL_COMPONENT, which covers both payments and entitlements.';
comment on column DQ_FLAG.DQ_CLASS is 'STRUCTURAL: the file or tab was not loaded. IDENTITY: loaded, but held out of reporting until resolved. VALUE: loaded and kept in reporting with the finding visible. CONVENTION: resolved automatically and logged.';
comment on column DQ_FLAG.RULE_NAME is 'The check that raised the finding: SALARY_AS_TEXT, MISSING_CURRENCY, INVALID_CURRENCY_CODE, MISSING_ANNUAL_TOTAL, EMPLOYEE_MISSING_FROM_ROSTER, DUPLICATE_SAP_ID_ACROSS_FILES, UNMAPPED_GENERATION or SAMPLE_FILE_INGESTED.';
comment on column DQ_FLAG.COLUMN_INDEX is 'Reserved for the column position of a finding. No current check fills it.';
comment on column DQ_FLAG.SOURCE_HEADER is 'Reserved for the column header of a finding. No current check fills it.';
comment on column DQ_FLAG.RAW_VALUE is 'The offending value, where the check has one, such as a salary typed as text or an invalid currency code. Masked for roles not entitled to see payroll amounts.';
comment on column DQ_FLAG.MESSAGE is 'Plain-language description of the finding.';
comment on column DQ_FLAG.CREATED_AT is 'When the finding was raised.';

-- ---------------------------------------------------------------------------
-- HEADER_MAP
-- ---------------------------------------------------------------------------
comment on table HEADER_MAP is 'Reference table that gives every column of every known payroll template version its meaning. The loader reads it to interpret each workbook, so a new template version is added here rather than in code.';
comment on column HEADER_MAP.GENERATION is 'Template version: tab year and column count, such as 2026-75col.';
comment on column HEADER_MAP.COLUMN_INDEX is 'Zero-based position of the column in the tab.';
comment on column HEADER_MAP.COLUMN_LETTER is 'Excel column letter, such as BM.';
comment on column HEADER_MAP.SHEET_YEAR is 'Year of the template tab.';
comment on column HEADER_MAP.GENERATION_STATUS is 'SUPPORTED for a real submission template. SAMPLE for a test template, which is never loaded as payroll.';
comment on column HEADER_MAP.GROUP_HEADER is 'The band label above the header row, such as External HC, repeated for every column the band spans.';
comment on column HEADER_MAP.SOURCE_HEADER is 'The column header exactly as it appears in the template.';
comment on column HEADER_MAP.COMPONENT_GROUP is 'SALARY, BONUS, COMMISSION, EXTERNAL or ADHOC for pay-related columns. EMPLOYEE and OTHER for descriptive columns.';
comment on column HEADER_MAP.COMPONENT_NAME is 'The component the column belongs to, such as MONTHLY_SALARY or YEAR_END.';
comment on column HEADER_MAP.MEASURE_BASIS is 'What the column holds: PAYMENT, RATE, FEE or ELIGIBILITY for values, CURRENCY for a currency cell, ATTRIBUTE for descriptive content.';
comment on column HEADER_MAP.PERIOD_TYPE is 'MONTH, QUARTER or FY for a column tied to a period. Empty otherwise.';
comment on column HEADER_MAP.PERIOD_KEY is 'The period the column covers: YYYY-MM, YYYY-Qn or YYYY. Empty where PERIOD_TYPE is empty.';
comment on column HEADER_MAP.CURRENCY_SCOPE is 'LOCAL for a local-currency column, USD for a USD column in the 2024 and 2025 templates, NA for a column without a currency.';
comment on column HEADER_MAP.NEEDS_REVIEW is 'TRUE where the meaning of the column still needs confirming.';
comment on column HEADER_MAP.REVIEW_REASON is 'Why the column needs review.';
comment on column HEADER_MAP.RESOLUTION_NOTE is 'How a conflict between the band label and the header was resolved, where there was one.';
comment on column HEADER_MAP.CREATED_AT is 'When the mapping row was loaded.';
comment on column HEADER_MAP.CANONICAL_FIELD is 'Fixed name for a column the loader needs individually, such as EMPLOYEE_SAP_ID, SUBSIDIARY, CONTRACT_CURRENCY or AGENCY_FEE. Needed because the position of a column differs between template versions.';

-- ---------------------------------------------------------------------------
-- FACT_PAYROLL_COMPONENT
-- ---------------------------------------------------------------------------
comment on view FACT_PAYROLL_COMPONENT is 'Every payroll value in one place: FACT_PAYROLL_PAYMENT and FACT_PAYROLL_ENTITLEMENT combined. Use MEASURE_BASIS to separate amounts paid from contractual figures.';
alter view FACT_PAYROLL_COMPONENT alter column MEASURE_ID comment 'Unique identifier of this value. It is unique across FACT_PAYROLL_PAYMENT and FACT_PAYROLL_ENTITLEMENT together, so it identifies one row in either table.';
alter view FACT_PAYROLL_COMPONENT alter column PAYROLL_ROW_ID comment 'The employee line in the submitted workbook this row came from. Join to PAYROLL_ROW.';
alter view FACT_PAYROLL_COMPONENT alter column TAB_LOAD_ID comment 'The workbook tab this row came from. Join to TAB_LOAD.';
alter view FACT_PAYROLL_COMPONENT alter column EMPLOYEE_SAP_ID comment 'Employee identifier from SAP, as submitted. This is the authoritative employee key. Stored as text so that a non-numeric identifier is never lost.';
alter view FACT_PAYROLL_COMPONENT alter column EMPLOYMENT_KEY comment 'Identifies one employment: SAP ID, join date and leave date, separated by a vertical bar. Group by this rather than by EMPLOYEE_SAP_ID, because one employee can hold two contracts or move between subsidiaries.';
alter view FACT_PAYROLL_COMPONENT alter column SUBSIDIARY_CODE comment 'Subsidiary code as recorded on the submission, such as BR02. It stays as it stood at the time, so an employee who later transfers keeps earlier values under the original subsidiary. Empty where the submission gives the entity name without a code.';
alter view FACT_PAYROLL_COMPONENT alter column REPORT_YEAR comment 'Reporting year of the workbook tab the value came from.';
alter view FACT_PAYROLL_COMPONENT alter column COMPONENT_GROUP comment 'Pay component family: SALARY, BONUS, COMMISSION or ADHOC.';
alter view FACT_PAYROLL_COMPONENT alter column COMPONENT_NAME comment 'The specific pay component, such as MONTHLY_SALARY, YEAR_END or THIRTEENTH_MONTH. The list comes from HEADER_MAP, so a new component appears here without any change to the table.';
alter view FACT_PAYROLL_COMPONENT alter column MEASURE_BASIS comment 'What the value is. PAYMENT is an amount actually paid. RATE is a contractual figure such as gross monthly salary or a bonus maximum. ELIGIBILITY is a yes or no bonus scheme flag. Only PAYMENT rows are money paid.';
alter view FACT_PAYROLL_COMPONENT alter column PERIOD_TYPE comment 'MONTH, QUARTER or FY: the kind of period the value covers. Empty on contractual salary rates and eligibility flags, which are not tied to a period.';
alter view FACT_PAYROLL_COMPONENT alter column PERIOD_KEY comment 'The period the value covers: YYYY-MM for a month, YYYY-Qn for a quarter, YYYY for a year. Empty where PERIOD_TYPE is empty.';
alter view FACT_PAYROLL_COMPONENT alter column CURRENCY_SCOPE comment 'LOCAL for an amount in local currency. USD for a value from the USD columns of the 2024 and 2025 templates, which mostly repeat local amounts converted at an unknown rate. NA for eligibility flags, which have no currency. Reporting views use LOCAL.';
alter view FACT_PAYROLL_COMPONENT alter column AMOUNT comment 'The amount, in CURRENCY_CODE. Empty on eligibility flags. Masked for roles not entitled to see payroll amounts.';
alter view FACT_PAYROLL_COMPONENT alter column CURRENCY_CODE comment 'Currency of AMOUNT. Taken from the component''s own currency column where the template has one, otherwise from the contract currency, so salary and bonus can differ for the same employee. Codes are as submitted, so Chinese yuan appears as RMB, and invalid codes are flagged in DQ_FLAG.';
alter view FACT_PAYROLL_COMPONENT alter column IS_ELIGIBLE comment 'Set on eligibility flags only: TRUE for yes, FALSE for no, empty if the cell held anything else.';
alter view FACT_PAYROLL_COMPONENT alter column TEXT_VALUE comment 'The value as typed, kept only when it could not be read as a number, such as a salary entered as text. Empty whenever AMOUNT is set. Masked for roles not entitled to see payroll amounts.';
alter view FACT_PAYROLL_COMPONENT alter column LOADED_AT comment 'When this row was loaded.';

-- ---------------------------------------------------------------------------
-- V_GOLD_PAYROLL_COMPONENT
-- ---------------------------------------------------------------------------
comment on view V_GOLD_PAYROLL_COMPONENT is 'Reporting view of amounts paid and contractual rates in local currency, all years. Leaves out sample templates and values held back by identity findings. Eligibility flags are not included, see V_GOLD_ENTITLEMENT.';
alter view V_GOLD_PAYROLL_COMPONENT alter column MEASURE_ID comment 'Unique identifier of this value. It is unique across FACT_PAYROLL_PAYMENT and FACT_PAYROLL_ENTITLEMENT together, so it identifies one row in either table.';
alter view V_GOLD_PAYROLL_COMPONENT alter column PAYROLL_ROW_ID comment 'The employee line in the submitted workbook this row came from. Join to PAYROLL_ROW.';
alter view V_GOLD_PAYROLL_COMPONENT alter column TAB_LOAD_ID comment 'The workbook tab this row came from. Join to TAB_LOAD.';
alter view V_GOLD_PAYROLL_COMPONENT alter column EMPLOYEE_SAP_ID comment 'Employee identifier from SAP, as submitted. This is the authoritative employee key. Stored as text so that a non-numeric identifier is never lost.';
alter view V_GOLD_PAYROLL_COMPONENT alter column EMPLOYMENT_KEY comment 'Identifies one employment: SAP ID, join date and leave date, separated by a vertical bar. Group by this rather than by EMPLOYEE_SAP_ID, because one employee can hold two contracts or move between subsidiaries.';
alter view V_GOLD_PAYROLL_COMPONENT alter column SUBSIDIARY_CODE comment 'Subsidiary code as recorded on the submission, such as BR02. It stays as it stood at the time, so an employee who later transfers keeps earlier values under the original subsidiary. Empty where the submission gives the entity name without a code.';
alter view V_GOLD_PAYROLL_COMPONENT alter column REPORT_YEAR comment 'Reporting year of the workbook tab the value came from.';
alter view V_GOLD_PAYROLL_COMPONENT alter column COMPONENT_GROUP comment 'Pay component family: SALARY, BONUS, COMMISSION or ADHOC.';
alter view V_GOLD_PAYROLL_COMPONENT alter column COMPONENT_NAME comment 'The specific pay component, such as MONTHLY_SALARY, YEAR_END or THIRTEENTH_MONTH. The list comes from HEADER_MAP, so a new component appears here without any change to the table.';
alter view V_GOLD_PAYROLL_COMPONENT alter column MEASURE_BASIS comment 'PAYMENT for an amount actually paid, RATE for a contractual figure. Only PAYMENT rows are money paid.';
alter view V_GOLD_PAYROLL_COMPONENT alter column PERIOD_TYPE comment 'MONTH, QUARTER or FY: the kind of period the value covers. Empty on contractual salary rates.';
alter view V_GOLD_PAYROLL_COMPONENT alter column PERIOD_KEY comment 'The period the value covers: YYYY-MM for a month, YYYY-Qn for a quarter, YYYY for a year. Empty where PERIOD_TYPE is empty.';
alter view V_GOLD_PAYROLL_COMPONENT alter column CURRENCY_SCOPE comment 'Always LOCAL in this view.';
alter view V_GOLD_PAYROLL_COMPONENT alter column AMOUNT comment 'The amount, in CURRENCY_CODE. Masked for roles not entitled to see payroll amounts.';
alter view V_GOLD_PAYROLL_COMPONENT alter column CURRENCY_CODE comment 'Currency of AMOUNT. Taken from the component''s own currency column where the template has one, otherwise from the contract currency, so salary and bonus can differ for the same employee. Codes are as submitted, so Chinese yuan appears as RMB, and invalid codes are flagged in DQ_FLAG.';
alter view V_GOLD_PAYROLL_COMPONENT alter column IS_ELIGIBLE comment 'Always empty in this view, because eligibility flags are not included.';
alter view V_GOLD_PAYROLL_COMPONENT alter column TEXT_VALUE comment 'The value as typed, kept only when it could not be read as a number, such as a salary entered as text. Empty whenever AMOUNT is set. Masked for roles not entitled to see payroll amounts.';
alter view V_GOLD_PAYROLL_COMPONENT alter column LOADED_AT comment 'When this row was loaded.';

-- ---------------------------------------------------------------------------
-- V_GOLD_PAYROLL_PAYMENT
-- ---------------------------------------------------------------------------
comment on view V_GOLD_PAYROLL_PAYMENT is 'Reporting view of amounts actually paid, in local currency, all years. Leaves out sample templates and values held back by identity findings.';
alter view V_GOLD_PAYROLL_PAYMENT alter column MEASURE_ID comment 'Unique identifier of this value. It is unique across FACT_PAYROLL_PAYMENT and FACT_PAYROLL_ENTITLEMENT together, so it identifies one row in either table.';
alter view V_GOLD_PAYROLL_PAYMENT alter column PAYROLL_ROW_ID comment 'The employee line in the submitted workbook this row came from. Join to PAYROLL_ROW.';
alter view V_GOLD_PAYROLL_PAYMENT alter column TAB_LOAD_ID comment 'The workbook tab this row came from. Join to TAB_LOAD.';
alter view V_GOLD_PAYROLL_PAYMENT alter column EMPLOYEE_SAP_ID comment 'Employee identifier from SAP, as submitted. This is the authoritative employee key. Stored as text so that a non-numeric identifier is never lost.';
alter view V_GOLD_PAYROLL_PAYMENT alter column EMPLOYMENT_KEY comment 'Identifies one employment: SAP ID, join date and leave date, separated by a vertical bar. Group by this rather than by EMPLOYEE_SAP_ID, because one employee can hold two contracts or move between subsidiaries.';
alter view V_GOLD_PAYROLL_PAYMENT alter column SUBSIDIARY_CODE comment 'Subsidiary code as recorded on the submission, such as BR02. It stays as it stood at the time, so an employee who later transfers keeps earlier values under the original subsidiary. Empty where the submission gives the entity name without a code.';
alter view V_GOLD_PAYROLL_PAYMENT alter column REPORT_YEAR comment 'Reporting year of the workbook tab the value came from.';
alter view V_GOLD_PAYROLL_PAYMENT alter column COMPONENT_GROUP comment 'Pay component family: SALARY, BONUS, COMMISSION or ADHOC.';
alter view V_GOLD_PAYROLL_PAYMENT alter column COMPONENT_NAME comment 'The specific pay component, such as MONTHLY_SALARY, YEAR_END or THIRTEENTH_MONTH. The list comes from HEADER_MAP, so a new component appears here without any change to the table.';
alter view V_GOLD_PAYROLL_PAYMENT alter column MEASURE_BASIS comment 'Always PAYMENT: an amount actually paid.';
alter view V_GOLD_PAYROLL_PAYMENT alter column PERIOD_TYPE comment 'MONTH, QUARTER or FY: the kind of period the payment covers.';
alter view V_GOLD_PAYROLL_PAYMENT alter column PERIOD_KEY comment 'The period the payment covers: YYYY-MM for a month, YYYY-Qn for a quarter, YYYY for a year.';
alter view V_GOLD_PAYROLL_PAYMENT alter column CURRENCY_SCOPE comment 'Always LOCAL in this view.';
alter view V_GOLD_PAYROLL_PAYMENT alter column AMOUNT comment 'The amount paid, in CURRENCY_CODE. Masked for roles not entitled to see payroll amounts.';
alter view V_GOLD_PAYROLL_PAYMENT alter column CURRENCY_CODE comment 'Currency of AMOUNT. Taken from the component''s own currency column where the template has one, otherwise from the contract currency, so salary and bonus can differ for the same employee. Codes are as submitted, so Chinese yuan appears as RMB, and invalid codes are flagged in DQ_FLAG.';
alter view V_GOLD_PAYROLL_PAYMENT alter column TEXT_VALUE comment 'The value as typed, kept only when it could not be read as a number, such as a salary entered as text. Empty whenever AMOUNT is set. Masked for roles not entitled to see payroll amounts.';
alter view V_GOLD_PAYROLL_PAYMENT alter column LOADED_AT comment 'When this row was loaded.';

-- ---------------------------------------------------------------------------
-- V_GOLD_ENTITLEMENT
-- ---------------------------------------------------------------------------
comment on view V_GOLD_ENTITLEMENT is 'Reporting view of the contractual position, all years: agreed rates in local currency, and bonus scheme eligibility. Never add these rows to amounts paid.';
alter view V_GOLD_ENTITLEMENT alter column REPORT_YEAR comment 'Reporting year of the workbook tab the value came from.';
alter view V_GOLD_ENTITLEMENT alter column SUBSIDIARY_CODE comment 'Subsidiary code as recorded on the submission, such as BR02. It stays as it stood at the time, so an employee who later transfers keeps earlier values under the original subsidiary. Empty where the submission gives the entity name without a code.';
alter view V_GOLD_ENTITLEMENT alter column EMPLOYEE_SAP_ID comment 'Employee identifier from SAP, as submitted. This is the authoritative employee key. Stored as text so that a non-numeric identifier is never lost.';
alter view V_GOLD_ENTITLEMENT alter column EMPLOYMENT_KEY comment 'Identifies one employment: SAP ID, join date and leave date, separated by a vertical bar. Group by this rather than by EMPLOYEE_SAP_ID, because one employee can hold two contracts or move between subsidiaries.';
alter view V_GOLD_ENTITLEMENT alter column COMPONENT_GROUP comment 'Pay component family: SALARY, BONUS, COMMISSION or ADHOC.';
alter view V_GOLD_ENTITLEMENT alter column COMPONENT_NAME comment 'The specific pay component, such as MONTHLY_SALARY, YEAR_END or THIRTEENTH_MONTH. The list comes from HEADER_MAP, so a new component appears here without any change to the table.';
alter view V_GOLD_ENTITLEMENT alter column MEASURE_BASIS comment 'RATE for a contractual figure such as gross monthly salary, allowance or a bonus maximum. ELIGIBILITY for a yes or no bonus scheme flag.';
alter view V_GOLD_ENTITLEMENT alter column AMOUNT comment 'The contractual amount on RATE rows, in CURRENCY_CODE. Empty on eligibility flags. Masked for roles not entitled to see payroll amounts.';
alter view V_GOLD_ENTITLEMENT alter column CURRENCY_CODE comment 'Currency of AMOUNT on RATE rows. Empty on eligibility flags.';
alter view V_GOLD_ENTITLEMENT alter column IS_ELIGIBLE comment 'Set on eligibility flags only: TRUE for yes, FALSE for no, empty if the cell held anything else.';

-- ---------------------------------------------------------------------------
-- V_GOLD_ANNUAL_COMPENSATION
-- ---------------------------------------------------------------------------
comment on view V_GOLD_ANNUAL_COMPENSATION is 'Total paid per employment, per component group and per currency, for the current reporting year. The template''s annual salary total is left out because it repeats the monthly figures. Amounts in different currencies are never added together.';
alter view V_GOLD_ANNUAL_COMPENSATION alter column REPORT_YEAR comment 'The current reporting year: the latest year loaded, never later than the calendar year.';
alter view V_GOLD_ANNUAL_COMPENSATION alter column SUBSIDIARY_CODE comment 'Subsidiary code as recorded on the submission, such as BR02. It stays as it stood at the time, so an employee who later transfers keeps earlier values under the original subsidiary. Empty where the submission gives the entity name without a code.';
alter view V_GOLD_ANNUAL_COMPENSATION alter column EMPLOYEE_SAP_ID comment 'Employee identifier from SAP, as submitted. This is the authoritative employee key. Stored as text so that a non-numeric identifier is never lost.';
alter view V_GOLD_ANNUAL_COMPENSATION alter column EMPLOYMENT_KEY comment 'Identifies one employment: SAP ID, join date and leave date, separated by a vertical bar. Group by this rather than by EMPLOYEE_SAP_ID, because one employee can hold two contracts or move between subsidiaries.';
alter view V_GOLD_ANNUAL_COMPENSATION alter column COMPONENT_GROUP comment 'Pay component family: SALARY, BONUS, COMMISSION or ADHOC.';
alter view V_GOLD_ANNUAL_COMPENSATION alter column CURRENCY_CODE comment 'Currency of AMOUNT_PAID.';
alter view V_GOLD_ANNUAL_COMPENSATION alter column AMOUNT_PAID comment 'Total paid for the component group in this currency during the year. Masked for roles not entitled to see payroll amounts.';

-- ---------------------------------------------------------------------------
-- V_GOLD_SINGLE_CURRENCY_EMPLOYMENT
-- ---------------------------------------------------------------------------
comment on view V_GOLD_SINGLE_CURRENCY_EMPLOYMENT is 'Employments paid in only one currency during the current reporting year, with their total across all components. Employments paid in more than one currency are left out rather than added across currencies.';
alter view V_GOLD_SINGLE_CURRENCY_EMPLOYMENT alter column REPORT_YEAR comment 'The current reporting year: the latest year loaded, never later than the calendar year.';
alter view V_GOLD_SINGLE_CURRENCY_EMPLOYMENT alter column SUBSIDIARY_CODE comment 'Subsidiary code as recorded on the submission, such as BR02. It stays as it stood at the time, so an employee who later transfers keeps earlier values under the original subsidiary. Empty where the submission gives the entity name without a code.';
alter view V_GOLD_SINGLE_CURRENCY_EMPLOYMENT alter column EMPLOYEE_SAP_ID comment 'Employee identifier from SAP, as submitted. This is the authoritative employee key. Stored as text so that a non-numeric identifier is never lost.';
alter view V_GOLD_SINGLE_CURRENCY_EMPLOYMENT alter column EMPLOYMENT_KEY comment 'Identifies one employment: SAP ID, join date and leave date, separated by a vertical bar. Group by this rather than by EMPLOYEE_SAP_ID, because one employee can hold two contracts or move between subsidiaries.';
alter view V_GOLD_SINGLE_CURRENCY_EMPLOYMENT alter column CURRENCY_CODE comment 'The single currency this employment is paid in.';
alter view V_GOLD_SINGLE_CURRENCY_EMPLOYMENT alter column TOTAL_PAID comment 'Total paid across all component groups during the year. Masked for roles not entitled to see payroll amounts.';

-- ---------------------------------------------------------------------------
-- V_GOLD_EXTERNAL_HEADCOUNT
-- ---------------------------------------------------------------------------
comment on view V_GOLD_EXTERNAL_HEADCOUNT is 'External headcount per employment: the supplying agency and its fee, one row for each employment with either.';
alter view V_GOLD_EXTERNAL_HEADCOUNT alter column REPORT_YEAR comment 'Reporting year of the workbook tab the value came from.';
alter view V_GOLD_EXTERNAL_HEADCOUNT alter column SUBSIDIARY_CODE comment 'Subsidiary code as recorded on the submission, such as BR02. It stays as it stood at the time, so an employee who later transfers keeps earlier values under the original subsidiary. Empty where the submission gives the entity name without a code.';
alter view V_GOLD_EXTERNAL_HEADCOUNT alter column EMPLOYEE_SAP_ID comment 'Employee identifier from SAP, as submitted. This is the authoritative employee key. Stored as text so that a non-numeric identifier is never lost.';
alter view V_GOLD_EXTERNAL_HEADCOUNT alter column EMPLOYMENT_KEY comment 'Identifies one employment: SAP ID, join date and leave date, separated by a vertical bar. Group by this rather than by EMPLOYEE_SAP_ID, because one employee can hold two contracts or move between subsidiaries.';
alter view V_GOLD_EXTERNAL_HEADCOUNT alter column AGENCY_NAME comment 'Name of the agency supplying the worker. Masked for roles not entitled to see payroll amounts, because it is stored in a masked column.';
alter view V_GOLD_EXTERNAL_HEADCOUNT alter column AGENCY_FEE comment 'The agency fee. Masked for roles not entitled to see payroll amounts.';
alter view V_GOLD_EXTERNAL_HEADCOUNT alter column CURRENCY_CODE comment 'Currency of the agency fee. The template has no currency cell for the fee, so this is the contract currency of the employee.';

-- ---------------------------------------------------------------------------
-- V_PAYROLL_CELL
-- ---------------------------------------------------------------------------
comment on view V_PAYROLL_CELL is 'Loader working view: every mapped cell of every employee line, with its meaning and resolved currency. The loader reads it to fill the payroll tables. Not intended for reporting.';
alter view V_PAYROLL_CELL alter column PAYROLL_ROW_ID comment 'The employee line in the submitted workbook this row came from. Join to PAYROLL_ROW.';
alter view V_PAYROLL_CELL alter column TAB_LOAD_ID comment 'The workbook tab this row came from. Join to TAB_LOAD.';
alter view V_PAYROLL_CELL alter column EMPLOYEE_SAP_ID comment 'Employee identifier from SAP, as submitted. This is the authoritative employee key. Stored as text so that a non-numeric identifier is never lost.';
alter view V_PAYROLL_CELL alter column EMPLOYMENT_KEY comment 'Identifies one employment: SAP ID, join date and leave date, separated by a vertical bar. Group by this rather than by EMPLOYEE_SAP_ID, because one employee can hold two contracts or move between subsidiaries.';
alter view V_PAYROLL_CELL alter column SUBSIDIARY_CODE comment 'Subsidiary code as recorded on the submission, such as BR02. It stays as it stood at the time, so an employee who later transfers keeps earlier values under the original subsidiary. Empty where the submission gives the entity name without a code.';
alter view V_PAYROLL_CELL alter column REPORT_YEAR comment 'Reporting year of the workbook tab the value came from.';
alter view V_PAYROLL_CELL alter column COMPONENT_GROUP comment 'From HEADER_MAP: SALARY, BONUS, COMMISSION, EXTERNAL, ADHOC, EMPLOYEE or OTHER.';
alter view V_PAYROLL_CELL alter column COMPONENT_NAME comment 'From HEADER_MAP: the component the column belongs to.';
alter view V_PAYROLL_CELL alter column MEASURE_BASIS comment 'From HEADER_MAP: PAYMENT, RATE, FEE, ELIGIBILITY, CURRENCY or ATTRIBUTE.';
alter view V_PAYROLL_CELL alter column PERIOD_TYPE comment 'From HEADER_MAP: MONTH, QUARTER or FY, empty when the column is not tied to a period.';
alter view V_PAYROLL_CELL alter column PERIOD_KEY comment 'From HEADER_MAP: the period the column covers.';
alter view V_PAYROLL_CELL alter column CURRENCY_SCOPE comment 'From HEADER_MAP: LOCAL, USD or NA.';
alter view V_PAYROLL_CELL alter column CANONICAL_FIELD comment 'Fixed name for a column the loader needs individually, such as EMPLOYEE_SAP_ID, SUBSIDIARY, CONTRACT_CURRENCY or AGENCY_FEE. Needed because the position of a column differs between template versions.';
alter view V_PAYROLL_CELL alter column SOURCE_HEADER comment 'The column header exactly as it appears in the workbook.';
alter view V_PAYROLL_CELL alter column COLUMN_INDEX comment 'Zero-based position of the column in the tab.';
alter view V_PAYROLL_CELL alter column RAW_VALUE comment 'The cell as submitted, trimmed, empty when blank. Masked for roles not entitled to see payroll amounts, because it is read from the masked copy of the line.';
alter view V_PAYROLL_CELL alter column CURRENCY_CODE comment 'Resolved currency for the cell: the component''s own currency cell, otherwise the contract currency. Also read from the masked copy of the line.';

-- ---------------------------------------------------------------------------
-- V_PAYROLL_FILE
-- ---------------------------------------------------------------------------
comment on view V_PAYROLL_FILE is 'Every ingested file version, with the reason it is skipped if the loader leaves it out. Nothing is deleted, so a skipped file stays visible here.';
alter view V_PAYROLL_FILE alter column LOAD_ID comment 'Unique identifier of this ingested file version.';
alter view V_PAYROLL_FILE alter column RUN_ID comment 'Identifier of the ingestion run that loaded the file.';
alter view V_PAYROLL_FILE alter column FILE_NAME comment 'File name as it appears on SharePoint.';
alter view V_PAYROLL_FILE alter column FILE_PATH comment 'SharePoint folder path of the file.';
alter view V_PAYROLL_FILE alter column SHAREPOINT_MODIFIED_AT comment 'When the file was last modified on SharePoint.';
alter view V_PAYROLL_FILE alter column FILE_SIZE_BYTES comment 'File size in bytes.';
alter view V_PAYROLL_FILE alter column INGESTED_AT comment 'When the pipeline downloaded the file.';
alter view V_PAYROLL_FILE alter column INGEST_STATUS comment 'Result of downloading the file. SUCCESS when it worked. Any other value means the download failed and the file is skipped.';
alter view V_PAYROLL_FILE alter column EXTRACTED_AT comment 'When the contents of the file were extracted.';
alter view V_PAYROLL_FILE alter column EXTRACT_STATUS comment 'Result of extracting the file contents: SUCCESS, FAILED or NOT_ATTEMPTED. Only SUCCESS is processed.';
alter view V_PAYROLL_FILE alter column RAW_CONTENT comment 'Every cell of every tab, as extracted from the workbook. Includes all amounts and is not masked.';
alter view V_PAYROLL_FILE alter column ERROR_MESSAGE comment 'Error details when ingestion or extraction failed.';
alter view V_PAYROLL_FILE alter column SHAREPOINT_MODIFIED_BY comment 'SharePoint user who last modified the file.';
alter view V_PAYROLL_FILE alter column SHAREPOINT_CREATED_BY comment 'SharePoint user who created the file.';
alter view V_PAYROLL_FILE alter column SHAREPOINT_CREATED_AT comment 'When the file was created on SharePoint.';
alter view V_PAYROLL_FILE alter column IS_CURRENT comment 'TRUE for the latest version of the file. FALSE for an earlier version that has since been replaced.';
alter view V_PAYROLL_FILE alter column SHAREPOINT_ITEM_ID comment 'SharePoint identifier of the file. It survives a rename, but a file that is deleted and uploaded again gets a new one.';
alter view V_PAYROLL_FILE alter column SKIP_REASON comment 'Why the loader skips this file: SUPERSEDED, INGEST_FAILED, EXTRACT_FAILED, SAMPLE, NOT_PAYROLL or TEST. Empty for files that are processed.';

-- ---------------------------------------------------------------------------
-- V_PAYROLL_FILE_CURRENT
-- ---------------------------------------------------------------------------
comment on view V_PAYROLL_FILE_CURRENT is 'The file versions the loader processes: every file in V_PAYROLL_FILE with no skip reason.';
alter view V_PAYROLL_FILE_CURRENT alter column LOAD_ID comment 'Unique identifier of this ingested file version.';
alter view V_PAYROLL_FILE_CURRENT alter column RUN_ID comment 'Identifier of the ingestion run that loaded the file.';
alter view V_PAYROLL_FILE_CURRENT alter column FILE_NAME comment 'File name as it appears on SharePoint.';
alter view V_PAYROLL_FILE_CURRENT alter column FILE_PATH comment 'SharePoint folder path of the file.';
alter view V_PAYROLL_FILE_CURRENT alter column SHAREPOINT_MODIFIED_AT comment 'When the file was last modified on SharePoint.';
alter view V_PAYROLL_FILE_CURRENT alter column FILE_SIZE_BYTES comment 'File size in bytes.';
alter view V_PAYROLL_FILE_CURRENT alter column INGESTED_AT comment 'When the pipeline downloaded the file.';
alter view V_PAYROLL_FILE_CURRENT alter column INGEST_STATUS comment 'Result of downloading the file. SUCCESS when it worked. Any other value means the download failed and the file is skipped.';
alter view V_PAYROLL_FILE_CURRENT alter column EXTRACTED_AT comment 'When the contents of the file were extracted.';
alter view V_PAYROLL_FILE_CURRENT alter column EXTRACT_STATUS comment 'Result of extracting the file contents: SUCCESS, FAILED or NOT_ATTEMPTED. Only SUCCESS is processed.';
alter view V_PAYROLL_FILE_CURRENT alter column RAW_CONTENT comment 'Every cell of every tab, as extracted from the workbook. Includes all amounts and is not masked.';
alter view V_PAYROLL_FILE_CURRENT alter column ERROR_MESSAGE comment 'Error details when ingestion or extraction failed.';
alter view V_PAYROLL_FILE_CURRENT alter column SHAREPOINT_MODIFIED_BY comment 'SharePoint user who last modified the file.';
alter view V_PAYROLL_FILE_CURRENT alter column SHAREPOINT_CREATED_BY comment 'SharePoint user who created the file.';
alter view V_PAYROLL_FILE_CURRENT alter column SHAREPOINT_CREATED_AT comment 'When the file was created on SharePoint.';
alter view V_PAYROLL_FILE_CURRENT alter column IS_CURRENT comment 'TRUE for the latest version of the file. FALSE for an earlier version that has since been replaced.';
alter view V_PAYROLL_FILE_CURRENT alter column SHAREPOINT_ITEM_ID comment 'SharePoint identifier of the file. It survives a rename, but a file that is deleted and uploaded again gets a new one.';
alter view V_PAYROLL_FILE_CURRENT alter column SKIP_REASON comment 'Always empty in this view, since only processed files are included.';

-- ---------------------------------------------------------------------------
-- V_TAB_GENERATION
-- ---------------------------------------------------------------------------
comment on view V_TAB_GENERATION is 'Every year tab of every ingested file version, with the template version it resolves to and whether that version is known.';
alter view V_TAB_GENERATION alter column LOAD_ID comment 'The ingested file version. Join to FILE_LOAD.';
alter view V_TAB_GENERATION alter column FILE_NAME comment 'File name as it appears on SharePoint.';
alter view V_TAB_GENERATION alter column IS_CURRENT comment 'TRUE for the latest version of the file. FALSE for an earlier version that has since been replaced.';
alter view V_TAB_GENERATION alter column TAB_NAME comment 'Tab name, always a four-digit year in this view.';
alter view V_TAB_GENERATION alter column TAB_YEAR comment 'The tab name as a number.';
alter view V_TAB_GENERATION alter column TOTAL_ROWS comment 'Every row in the tab, including the band and header rows and formatted but empty rows.';
alter view V_TAB_GENERATION alter column COLUMN_COUNT comment 'Number of columns in the header row of the tab.';
alter view V_TAB_GENERATION alter column GENERATION comment 'Template version, written as tab year and column count, such as 2026-75col. Join to HEADER_MAP.';
alter view V_TAB_GENERATION alter column HEADER_HASH comment 'Fingerprint of the header row. A change on a known template version means headers were edited.';
alter view V_TAB_GENERATION alter column IS_MAPPED comment 'TRUE when HEADER_MAP knows this template version as a real submission template.';
alter view V_TAB_GENERATION alter column IS_SAMPLE comment 'TRUE when HEADER_MAP knows this template version as a test template.';
