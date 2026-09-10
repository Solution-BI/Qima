-- ===========================================================================
-- transformation / 90 - staging: the consolidated workbook
--
-- DELIBERATELY OUTSIDE THE MODEL. This table is not read by HEADER_MAP, not by
-- 04_load_silver.sql, and not by any V_GOLD_* view. It exists so the
-- consolidated file Qima supplied can be inspected and reconciled against the
-- model, nothing more.
--
-- Why it is not modelled on: the file is wide - one row per employee, twelve
-- month columns, a column block per bonus scheme. That is the shape the model
-- deliberately unpivots away from. Loading it as a fact table would reintroduce
-- a schema change per template revision.
--
-- Why it is worth keeping:
--   * it carries an organisational hierarchy the payroll templates do not
--     (division, business unit, department, team, position, office, country)
--   * row 0 of the sheet labels each column's provenance - every "(USD)"
--     column sits under a "CalculationN" band, i.e. the file marks its own
--     derived columns
--   * it is an independent second statement of 2026, usable for reconciliation
--
-- Every column is varchar. Nothing is parsed, coerced or interpreted, because
-- the point of the table is to preserve exactly what was submitted.
--
-- Column names below come from row 3 of the sheet. Regenerate if the file
-- changes shape.
-- ===========================================================================

use role "SF_APA_SANDBOX-ETL";
use warehouse SANDBOX_WH;
use schema SANDBOX_DB.HR_PAYROLL_QIMA;


create or replace table STG_CONSOLIDATED_2026 (
    LOAD_ID                                                          number(38,0),
    SOURCE_FILE_NAME                                                 varchar,
    ROW_INDEX                                                        number(38,0),
    EMPLOYEE_SAP_ID                                                  varchar,
    SAP_STAFF_NAME                                                   varchar,
    JOIN_DATE                                                        varchar,
    LEAVE_DATE                                                       varchar,
    SUBSIDIARY                                                       varchar,
    DIVISION                                                         varchar,
    BUSINESS_UNIT                                                    varchar,
    DEPARTMENT                                                       varchar,
    SUB_DEPARTMENT                                                   varchar,
    TEAM                                                             varchar,
    POSITION                                                         varchar,
    OFFICE                                                           varchar,
    COUNTRY                                                          varchar,
    CONTRACT                                                         varchar,
    EMPLOYEE_CLASS                                                   varchar,
    MONTHLY_GROSS_SALARY                                             varchar,
    MONTHLY_ALLOWANCE_2ND_PART_OF_SALARY                             varchar,
    QIMA_EMPLOYER_SOCIAL_CHARGES                                     varchar,
    TOTAL_MONTHLY_SALARY_COST_F_PLUS_G_PLUS_H                        varchar,
    CURRENCY                                                         varchar,
    ACTUAL_SALARY_JAN_2026                                           varchar,
    ACTUAL_SALARY_FEB_2026                                           varchar,
    ACTUAL_SALARY_MAR_2026                                           varchar,
    ACTUAL_SALARY_APR_2026                                           varchar,
    ACTUAL_SALARY_MAY_2026                                           varchar,
    ACTUAL_SALARY_JUN_2026                                           varchar,
    ACTUAL_SALARY_JUL_2026                                           varchar,
    ACTUAL_SALARY_AUG_2026                                           varchar,
    ACTUAL_SALARY_SEPT_2026                                          varchar,
    ACTUAL_SALARY_OCT_2026                                           varchar,
    ACTUAL_SALARY_NOV_2026                                           varchar,
    ACTUAL_SALARY_DEC_2026                                           varchar,
    TOTAL_SALARY_2026                                                varchar,
    ACTUAL_SALARY_JAN_2026_2                                         varchar,
    ACTUAL_SALARY_FEB_2026_2                                         varchar,
    ACTUAL_SALARY_MAR_2026_2                                         varchar,
    ACTUAL_SALARY_APR_2026_2                                         varchar,
    ACTUAL_SALARY_MAY_2026_2                                         varchar,
    ACTUAL_SALARY_JUN_2026_2                                         varchar,
    ACTUAL_SALARY_JUL_2026_2                                         varchar,
    ACTUAL_SALARY_AUG_2026_2                                         varchar,
    ACTUAL_SALARY_SEPT_2026_2                                        varchar,
    ACTUAL_SALARY_OCT_2026_2                                         varchar,
    ACTUAL_SALARY_NOV_2026_2                                         varchar,
    ACTUAL_SALARY_DEC_2026_2                                         varchar,
    TOTAL_SALARY_2026_2                                              varchar,
    ELIGIBLE_FOR_YEAR_END_BONUS                                      varchar,
    YEAR_END_BONUS_CURRENCY                                          varchar,
    MAX_YEAR_END_BONUS_AMOUNT_IN_2026                                varchar,
    ACTUAL_YEAR_END_BONUS_AMOUNT_PAID_IN_2026                        varchar,
    MAX_YEAR_END_BONUS_AMOUNT_IN_2026_USD                            varchar,
    ACTUAL_YEAR_END_BONUS_AMOUNT_PAID_IN_2026_USD                    varchar,
    ELIGIBLE_FOR_HALF_YEAR_BONUS                                     varchar,
    HALF_YEAR_BONUS_CURRENCY                                         varchar,
    MAX_HALF_YEAR_BONUS_AMOUNT_IN_2026                               varchar,
    ACTUAL_HALF_YEAR_BONUS_AMOUNT_PAID_IN_2026                       varchar,
    MAX_HALF_YEAR_BONUS_AMOUNT_IN_2026_USD                           varchar,
    ACTUAL_HALF_YEAR_BONUS_AMOUNT_PAID_IN_2026_USD                   varchar,
    ELIGIBLE_FOR_13TH_MONTH_SALARY_CHRISTMAS_BONUS_AGUINALDO         varchar,
    C_13TH_MONTH_SALARY_CURRENCY                                     varchar,
    MAX_13TH_MONTH_SALARY_AGUINALDO_CHRISTMAS_BONUS_IN_2026          varchar,
    ACTUAL_13TH_MONTH_SALARY_PAID_IN_2026                            varchar,
    MAX_13TH_MONTH_SALARY_AGUINALDO_CHRISTMAS_BONUS_IN_2026_USD      varchar,
    ACTUAL_13TH_MONTH_SALARY_PAID_IN_2026_USD                        varchar,
    ELIGIBLE_FOR_HOLIDAY_BONUS                                       varchar,
    HOLIDAY_BONUS_CURRENCY                                           varchar,
    MAX_HOLIDAY_BONUS_AMOUNT_IN_2026                                 varchar,
    ACTUAL_HOLIDAY_BONUS_AMOUNT_PAID_IN_2026                         varchar,
    MAX_HOLIDAY_BONUS_AMOUNT_IN_2026_USD                             varchar,
    ACTUAL_HOLIDAY_BONUS_AMOUNT_PAID_IN_2026_USD                     varchar,
    ELIGIBLE_FOR_PROFIT_SHARING                                      varchar,
    PROFIT_SHARING_CURRENCY                                          varchar,
    MAX_PROFIT_SHARING_AMOUNT_IN_2026                                varchar,
    ACTUAL_PROFIT_SHARING_AMOUNT_PAID_IN_2026                        varchar,
    MAX_PROFIT_SHARING_AMOUNT_IN_2026_USD                            varchar,
    ACTUAL_PROFIT_SHARING_AMOUNT_PAID_IN_2026_USD                    varchar,
    ELIGIBLE_FOR_CCLAB_BONUS                                         varchar,
    CCLAB_BONUS_CURRENCY                                             varchar,
    MAXCCLAB_BONUS_AMOUNT_PAID_IN_2026                               varchar,
    ACTUAL_BONUS_AMOUNT_PAID_IN_2026                                 varchar,
    MAXCCLAB_BONUS_AMOUNT_PAID_IN_2026_USD                           varchar,
    ACTUAL_BONUS_AMOUNT_PAID_IN_2026_USD                             varchar,
    ELIGIBLE_FOR_GRATUITY                                            varchar,
    GRATUITY_CURRENCY                                                varchar,
    MAX_GRATUITY_IN_2026                                             varchar,
    ACTUAL_GRATUITY_PAID_IN_2026                                     varchar,
    MAX_GRATUITY_IN_2026_USD                                         varchar,
    ACTUAL_GRATUITY_PAID_IN_2026_USD                                 varchar,
    AUDITOR_BONUS_CURRENCY                                           varchar,
    AUDITOR_BONUS_PAID_2026_Q1                                       varchar,
    AUDITOR_BONUS_PAID_2026_Q2                                       varchar,
    AUDITOR_BONUS_PAID_2026_Q3                                       varchar,
    AUDITOR_BONUS_PAID_2026_Q4                                       varchar,
    AUDITOR_BONUS_PAID_2026_Q1_USD                                   varchar,
    AUDITOR_BONUS_PAID_2026_Q2_USD                                   varchar,
    AUDITOR_BONUS_PAID_2026_Q3_USD                                   varchar,
    AUDITOR_BONUS_PAID_2026_Q4_USD                                   varchar,
    COMMISSION_CURRENCY                                              varchar,
    COMMISSIONS_PAID_2026_Q1                                         varchar,
    COMMISSIONS_PAID_2026_Q2                                         varchar,
    COMMISSIONS_PAID_2026_Q3                                         varchar,
    COMMISSIONS_PAID_2026_Q4                                         varchar,
    COMMISSIONS_PAID_2026_Q1_USD                                     varchar,
    COMMISSIONS_PAID_2026_Q2_USD                                     varchar,
    COMMISSIONS_PAID_2026_Q3_USD                                     varchar,
    COMMISSIONS_PAID_2026_Q4_USD                                     varchar,
    PAYMENT_TYPE                                                     varchar,
    CURRENCY_2                                                       varchar,
    BONUS_AMOUNT                                                     varchar,
    BONUS_AMOUNT_USD                                                 varchar,
    AGENCY_NAME                                                      varchar,
    AGENCY_FEE                                                       varchar,
    REMARKS                                                          varchar,
    ELIGIBLE_FOR_EID_FESTIBLE_BONUS                                  varchar,
    CURRENCY_3                                                       varchar,
    MAX_EID_FESTIBLE_BONUS_LOCAL_CURRENCY                            varchar,
    ELIGIBLE_FOR_EID_FESTIBLE_BONUS_2                                varchar,
    CURRENCY_4                                                       varchar,
    MAX_EID_FESTIBLE_BONUS_LOCAL_CURRENCY_2                          varchar,
    UNNAMED_119                                                      varchar,
    UNNAMED_120                                                      varchar,
    UNNAMED_121                                                      varchar,
    LOADED_AT                                                        timestamp_tz default current_timestamp()
)
comment = 'Staging copy of the consolidated workbook. Inspection and reconciliation only - not part of the payroll model, not read by any GOLD view. All columns varchar, nothing parsed.';


insert into STG_CONSOLIDATED_2026
    (LOAD_ID, SOURCE_FILE_NAME, ROW_INDEX, EMPLOYEE_SAP_ID, SAP_STAFF_NAME, JOIN_DATE, LEAVE_DATE, SUBSIDIARY, DIVISION, BUSINESS_UNIT, DEPARTMENT, SUB_DEPARTMENT, TEAM, POSITION, OFFICE, COUNTRY, CONTRACT, EMPLOYEE_CLASS, MONTHLY_GROSS_SALARY, MONTHLY_ALLOWANCE_2ND_PART_OF_SALARY, QIMA_EMPLOYER_SOCIAL_CHARGES, TOTAL_MONTHLY_SALARY_COST_F_PLUS_G_PLUS_H, CURRENCY, ACTUAL_SALARY_JAN_2026, ACTUAL_SALARY_FEB_2026, ACTUAL_SALARY_MAR_2026, ACTUAL_SALARY_APR_2026, ACTUAL_SALARY_MAY_2026, ACTUAL_SALARY_JUN_2026, ACTUAL_SALARY_JUL_2026, ACTUAL_SALARY_AUG_2026, ACTUAL_SALARY_SEPT_2026, ACTUAL_SALARY_OCT_2026, ACTUAL_SALARY_NOV_2026, ACTUAL_SALARY_DEC_2026, TOTAL_SALARY_2026, ACTUAL_SALARY_JAN_2026_2, ACTUAL_SALARY_FEB_2026_2, ACTUAL_SALARY_MAR_2026_2, ACTUAL_SALARY_APR_2026_2, ACTUAL_SALARY_MAY_2026_2, ACTUAL_SALARY_JUN_2026_2, ACTUAL_SALARY_JUL_2026_2, ACTUAL_SALARY_AUG_2026_2, ACTUAL_SALARY_SEPT_2026_2, ACTUAL_SALARY_OCT_2026_2, ACTUAL_SALARY_NOV_2026_2, ACTUAL_SALARY_DEC_2026_2, TOTAL_SALARY_2026_2, ELIGIBLE_FOR_YEAR_END_BONUS, YEAR_END_BONUS_CURRENCY, MAX_YEAR_END_BONUS_AMOUNT_IN_2026, ACTUAL_YEAR_END_BONUS_AMOUNT_PAID_IN_2026, MAX_YEAR_END_BONUS_AMOUNT_IN_2026_USD, ACTUAL_YEAR_END_BONUS_AMOUNT_PAID_IN_2026_USD, ELIGIBLE_FOR_HALF_YEAR_BONUS, HALF_YEAR_BONUS_CURRENCY, MAX_HALF_YEAR_BONUS_AMOUNT_IN_2026, ACTUAL_HALF_YEAR_BONUS_AMOUNT_PAID_IN_2026, MAX_HALF_YEAR_BONUS_AMOUNT_IN_2026_USD, ACTUAL_HALF_YEAR_BONUS_AMOUNT_PAID_IN_2026_USD, ELIGIBLE_FOR_13TH_MONTH_SALARY_CHRISTMAS_BONUS_AGUINALDO, C_13TH_MONTH_SALARY_CURRENCY, MAX_13TH_MONTH_SALARY_AGUINALDO_CHRISTMAS_BONUS_IN_2026, ACTUAL_13TH_MONTH_SALARY_PAID_IN_2026, MAX_13TH_MONTH_SALARY_AGUINALDO_CHRISTMAS_BONUS_IN_2026_USD, ACTUAL_13TH_MONTH_SALARY_PAID_IN_2026_USD, ELIGIBLE_FOR_HOLIDAY_BONUS, HOLIDAY_BONUS_CURRENCY, MAX_HOLIDAY_BONUS_AMOUNT_IN_2026, ACTUAL_HOLIDAY_BONUS_AMOUNT_PAID_IN_2026, MAX_HOLIDAY_BONUS_AMOUNT_IN_2026_USD, ACTUAL_HOLIDAY_BONUS_AMOUNT_PAID_IN_2026_USD, ELIGIBLE_FOR_PROFIT_SHARING, PROFIT_SHARING_CURRENCY, MAX_PROFIT_SHARING_AMOUNT_IN_2026, ACTUAL_PROFIT_SHARING_AMOUNT_PAID_IN_2026, MAX_PROFIT_SHARING_AMOUNT_IN_2026_USD, ACTUAL_PROFIT_SHARING_AMOUNT_PAID_IN_2026_USD, ELIGIBLE_FOR_CCLAB_BONUS, CCLAB_BONUS_CURRENCY, MAXCCLAB_BONUS_AMOUNT_PAID_IN_2026, ACTUAL_BONUS_AMOUNT_PAID_IN_2026, MAXCCLAB_BONUS_AMOUNT_PAID_IN_2026_USD, ACTUAL_BONUS_AMOUNT_PAID_IN_2026_USD, ELIGIBLE_FOR_GRATUITY, GRATUITY_CURRENCY, MAX_GRATUITY_IN_2026, ACTUAL_GRATUITY_PAID_IN_2026, MAX_GRATUITY_IN_2026_USD, ACTUAL_GRATUITY_PAID_IN_2026_USD, AUDITOR_BONUS_CURRENCY, AUDITOR_BONUS_PAID_2026_Q1, AUDITOR_BONUS_PAID_2026_Q2, AUDITOR_BONUS_PAID_2026_Q3, AUDITOR_BONUS_PAID_2026_Q4, AUDITOR_BONUS_PAID_2026_Q1_USD, AUDITOR_BONUS_PAID_2026_Q2_USD, AUDITOR_BONUS_PAID_2026_Q3_USD, AUDITOR_BONUS_PAID_2026_Q4_USD, COMMISSION_CURRENCY, COMMISSIONS_PAID_2026_Q1, COMMISSIONS_PAID_2026_Q2, COMMISSIONS_PAID_2026_Q3, COMMISSIONS_PAID_2026_Q4, COMMISSIONS_PAID_2026_Q1_USD, COMMISSIONS_PAID_2026_Q2_USD, COMMISSIONS_PAID_2026_Q3_USD, COMMISSIONS_PAID_2026_Q4_USD, PAYMENT_TYPE, CURRENCY_2, BONUS_AMOUNT, BONUS_AMOUNT_USD, AGENCY_NAME, AGENCY_FEE, REMARKS, ELIGIBLE_FOR_EID_FESTIBLE_BONUS, CURRENCY_3, MAX_EID_FESTIBLE_BONUS_LOCAL_CURRENCY, ELIGIBLE_FOR_EID_FESTIBLE_BONUS_2, CURRENCY_4, MAX_EID_FESTIBLE_BONUS_LOCAL_CURRENCY_2, UNNAMED_119, UNNAMED_120, UNNAMED_121)
select f.LOAD_ID,
       f.FILE_NAME,
       r.index,
       get(r.value,   0)::string as EMPLOYEE_SAP_ID,
       get(r.value,   1)::string as SAP_STAFF_NAME,
       get(r.value,   2)::string as JOIN_DATE,
       get(r.value,   3)::string as LEAVE_DATE,
       get(r.value,   4)::string as SUBSIDIARY,
       get(r.value,   5)::string as DIVISION,
       get(r.value,   6)::string as BUSINESS_UNIT,
       get(r.value,   7)::string as DEPARTMENT,
       get(r.value,   8)::string as SUB_DEPARTMENT,
       get(r.value,   9)::string as TEAM,
       get(r.value,  10)::string as POSITION,
       get(r.value,  11)::string as OFFICE,
       get(r.value,  12)::string as COUNTRY,
       get(r.value,  13)::string as CONTRACT,
       get(r.value,  14)::string as EMPLOYEE_CLASS,
       get(r.value,  15)::string as MONTHLY_GROSS_SALARY,
       get(r.value,  16)::string as MONTHLY_ALLOWANCE_2ND_PART_OF_SALARY,
       get(r.value,  17)::string as QIMA_EMPLOYER_SOCIAL_CHARGES,
       get(r.value,  18)::string as TOTAL_MONTHLY_SALARY_COST_F_PLUS_G_PLUS_H,
       get(r.value,  19)::string as CURRENCY,
       get(r.value,  20)::string as ACTUAL_SALARY_JAN_2026,
       get(r.value,  21)::string as ACTUAL_SALARY_FEB_2026,
       get(r.value,  22)::string as ACTUAL_SALARY_MAR_2026,
       get(r.value,  23)::string as ACTUAL_SALARY_APR_2026,
       get(r.value,  24)::string as ACTUAL_SALARY_MAY_2026,
       get(r.value,  25)::string as ACTUAL_SALARY_JUN_2026,
       get(r.value,  26)::string as ACTUAL_SALARY_JUL_2026,
       get(r.value,  27)::string as ACTUAL_SALARY_AUG_2026,
       get(r.value,  28)::string as ACTUAL_SALARY_SEPT_2026,
       get(r.value,  29)::string as ACTUAL_SALARY_OCT_2026,
       get(r.value,  30)::string as ACTUAL_SALARY_NOV_2026,
       get(r.value,  31)::string as ACTUAL_SALARY_DEC_2026,
       get(r.value,  32)::string as TOTAL_SALARY_2026,
       get(r.value,  33)::string as ACTUAL_SALARY_JAN_2026_2,
       get(r.value,  34)::string as ACTUAL_SALARY_FEB_2026_2,
       get(r.value,  35)::string as ACTUAL_SALARY_MAR_2026_2,
       get(r.value,  36)::string as ACTUAL_SALARY_APR_2026_2,
       get(r.value,  37)::string as ACTUAL_SALARY_MAY_2026_2,
       get(r.value,  38)::string as ACTUAL_SALARY_JUN_2026_2,
       get(r.value,  39)::string as ACTUAL_SALARY_JUL_2026_2,
       get(r.value,  40)::string as ACTUAL_SALARY_AUG_2026_2,
       get(r.value,  41)::string as ACTUAL_SALARY_SEPT_2026_2,
       get(r.value,  42)::string as ACTUAL_SALARY_OCT_2026_2,
       get(r.value,  43)::string as ACTUAL_SALARY_NOV_2026_2,
       get(r.value,  44)::string as ACTUAL_SALARY_DEC_2026_2,
       get(r.value,  45)::string as TOTAL_SALARY_2026_2,
       get(r.value,  46)::string as ELIGIBLE_FOR_YEAR_END_BONUS,
       get(r.value,  47)::string as YEAR_END_BONUS_CURRENCY,
       get(r.value,  48)::string as MAX_YEAR_END_BONUS_AMOUNT_IN_2026,
       get(r.value,  49)::string as ACTUAL_YEAR_END_BONUS_AMOUNT_PAID_IN_2026,
       get(r.value,  50)::string as MAX_YEAR_END_BONUS_AMOUNT_IN_2026_USD,
       get(r.value,  51)::string as ACTUAL_YEAR_END_BONUS_AMOUNT_PAID_IN_2026_USD,
       get(r.value,  52)::string as ELIGIBLE_FOR_HALF_YEAR_BONUS,
       get(r.value,  53)::string as HALF_YEAR_BONUS_CURRENCY,
       get(r.value,  54)::string as MAX_HALF_YEAR_BONUS_AMOUNT_IN_2026,
       get(r.value,  55)::string as ACTUAL_HALF_YEAR_BONUS_AMOUNT_PAID_IN_2026,
       get(r.value,  56)::string as MAX_HALF_YEAR_BONUS_AMOUNT_IN_2026_USD,
       get(r.value,  57)::string as ACTUAL_HALF_YEAR_BONUS_AMOUNT_PAID_IN_2026_USD,
       get(r.value,  58)::string as ELIGIBLE_FOR_13TH_MONTH_SALARY_CHRISTMAS_BONUS_AGUINALDO,
       get(r.value,  59)::string as C_13TH_MONTH_SALARY_CURRENCY,
       get(r.value,  60)::string as MAX_13TH_MONTH_SALARY_AGUINALDO_CHRISTMAS_BONUS_IN_2026,
       get(r.value,  61)::string as ACTUAL_13TH_MONTH_SALARY_PAID_IN_2026,
       get(r.value,  62)::string as MAX_13TH_MONTH_SALARY_AGUINALDO_CHRISTMAS_BONUS_IN_2026_USD,
       get(r.value,  63)::string as ACTUAL_13TH_MONTH_SALARY_PAID_IN_2026_USD,
       get(r.value,  64)::string as ELIGIBLE_FOR_HOLIDAY_BONUS,
       get(r.value,  65)::string as HOLIDAY_BONUS_CURRENCY,
       get(r.value,  66)::string as MAX_HOLIDAY_BONUS_AMOUNT_IN_2026,
       get(r.value,  67)::string as ACTUAL_HOLIDAY_BONUS_AMOUNT_PAID_IN_2026,
       get(r.value,  68)::string as MAX_HOLIDAY_BONUS_AMOUNT_IN_2026_USD,
       get(r.value,  69)::string as ACTUAL_HOLIDAY_BONUS_AMOUNT_PAID_IN_2026_USD,
       get(r.value,  70)::string as ELIGIBLE_FOR_PROFIT_SHARING,
       get(r.value,  71)::string as PROFIT_SHARING_CURRENCY,
       get(r.value,  72)::string as MAX_PROFIT_SHARING_AMOUNT_IN_2026,
       get(r.value,  73)::string as ACTUAL_PROFIT_SHARING_AMOUNT_PAID_IN_2026,
       get(r.value,  74)::string as MAX_PROFIT_SHARING_AMOUNT_IN_2026_USD,
       get(r.value,  75)::string as ACTUAL_PROFIT_SHARING_AMOUNT_PAID_IN_2026_USD,
       get(r.value,  76)::string as ELIGIBLE_FOR_CCLAB_BONUS,
       get(r.value,  77)::string as CCLAB_BONUS_CURRENCY,
       get(r.value,  78)::string as MAXCCLAB_BONUS_AMOUNT_PAID_IN_2026,
       get(r.value,  79)::string as ACTUAL_BONUS_AMOUNT_PAID_IN_2026,
       get(r.value,  80)::string as MAXCCLAB_BONUS_AMOUNT_PAID_IN_2026_USD,
       get(r.value,  81)::string as ACTUAL_BONUS_AMOUNT_PAID_IN_2026_USD,
       get(r.value,  82)::string as ELIGIBLE_FOR_GRATUITY,
       get(r.value,  83)::string as GRATUITY_CURRENCY,
       get(r.value,  84)::string as MAX_GRATUITY_IN_2026,
       get(r.value,  85)::string as ACTUAL_GRATUITY_PAID_IN_2026,
       get(r.value,  86)::string as MAX_GRATUITY_IN_2026_USD,
       get(r.value,  87)::string as ACTUAL_GRATUITY_PAID_IN_2026_USD,
       get(r.value,  88)::string as AUDITOR_BONUS_CURRENCY,
       get(r.value,  89)::string as AUDITOR_BONUS_PAID_2026_Q1,
       get(r.value,  90)::string as AUDITOR_BONUS_PAID_2026_Q2,
       get(r.value,  91)::string as AUDITOR_BONUS_PAID_2026_Q3,
       get(r.value,  92)::string as AUDITOR_BONUS_PAID_2026_Q4,
       get(r.value,  93)::string as AUDITOR_BONUS_PAID_2026_Q1_USD,
       get(r.value,  94)::string as AUDITOR_BONUS_PAID_2026_Q2_USD,
       get(r.value,  95)::string as AUDITOR_BONUS_PAID_2026_Q3_USD,
       get(r.value,  96)::string as AUDITOR_BONUS_PAID_2026_Q4_USD,
       get(r.value,  97)::string as COMMISSION_CURRENCY,
       get(r.value,  98)::string as COMMISSIONS_PAID_2026_Q1,
       get(r.value,  99)::string as COMMISSIONS_PAID_2026_Q2,
       get(r.value, 100)::string as COMMISSIONS_PAID_2026_Q3,
       get(r.value, 101)::string as COMMISSIONS_PAID_2026_Q4,
       get(r.value, 102)::string as COMMISSIONS_PAID_2026_Q1_USD,
       get(r.value, 103)::string as COMMISSIONS_PAID_2026_Q2_USD,
       get(r.value, 104)::string as COMMISSIONS_PAID_2026_Q3_USD,
       get(r.value, 105)::string as COMMISSIONS_PAID_2026_Q4_USD,
       get(r.value, 106)::string as PAYMENT_TYPE,
       get(r.value, 107)::string as CURRENCY_2,
       get(r.value, 108)::string as BONUS_AMOUNT,
       get(r.value, 109)::string as BONUS_AMOUNT_USD,
       get(r.value, 110)::string as AGENCY_NAME,
       get(r.value, 111)::string as AGENCY_FEE,
       get(r.value, 112)::string as REMARKS,
       get(r.value, 113)::string as ELIGIBLE_FOR_EID_FESTIBLE_BONUS,
       get(r.value, 114)::string as CURRENCY_3,
       get(r.value, 115)::string as MAX_EID_FESTIBLE_BONUS_LOCAL_CURRENCY,
       get(r.value, 116)::string as ELIGIBLE_FOR_EID_FESTIBLE_BONUS_2,
       get(r.value, 117)::string as CURRENCY_4,
       get(r.value, 118)::string as MAX_EID_FESTIBLE_BONUS_LOCAL_CURRENCY_2,
       get(r.value, 119)::string as UNNAMED_119,
       get(r.value, 120)::string as UNNAMED_120,
       get(r.value, 121)::string as UNNAMED_121
from FILE_LOAD f,
     lateral flatten(input => get(f.RAW_CONTENT, 'Sheet1')) r
where f.LOAD_ID = 1401
  and r.index >= 4
  and not coalesce(is_null_value(get(r.value, 0)), true)   -- employee id present
  and get(r.value, 0)::string <> '';


-- ---------------------------------------------------------------------------
-- No exclusion row is needed. The file is named Consolidated_Dummy.xlsx and
-- V_PAYROLL_FILE_CURRENT skips anything matching '%dummy%', so it cannot enter
-- the model by accident.
-- ---------------------------------------------------------------------------


-- ---------------------------------------------------------------------------
-- Masking. The file carries what appear to be real names and salaries, so the
-- amount-bearing columns get the same treatment as the model's.
-- MP_PAYROLL_AMOUNT_TEXT is the varchar-typed policy.
-- ---------------------------------------------------------------------------
alter table STG_CONSOLIDATED_2026 modify column MONTHLY_GROSS_SALARY
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column MONTHLY_ALLOWANCE_2ND_PART_OF_SALARY
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column QIMA_EMPLOYER_SOCIAL_CHARGES
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column TOTAL_MONTHLY_SALARY_COST_F_PLUS_G_PLUS_H
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column ACTUAL_SALARY_JAN_2026
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column ACTUAL_SALARY_FEB_2026
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column ACTUAL_SALARY_MAR_2026
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column ACTUAL_SALARY_APR_2026
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column ACTUAL_SALARY_MAY_2026
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column ACTUAL_SALARY_JUN_2026
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column ACTUAL_SALARY_JUL_2026
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column ACTUAL_SALARY_AUG_2026
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column ACTUAL_SALARY_SEPT_2026
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column ACTUAL_SALARY_OCT_2026
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column ACTUAL_SALARY_NOV_2026
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column ACTUAL_SALARY_DEC_2026
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column TOTAL_SALARY_2026
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column ACTUAL_SALARY_JAN_2026_2
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column ACTUAL_SALARY_FEB_2026_2
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column ACTUAL_SALARY_MAR_2026_2
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column ACTUAL_SALARY_APR_2026_2
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column ACTUAL_SALARY_MAY_2026_2
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column ACTUAL_SALARY_JUN_2026_2
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column ACTUAL_SALARY_JUL_2026_2
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column ACTUAL_SALARY_AUG_2026_2
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column ACTUAL_SALARY_SEPT_2026_2
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column ACTUAL_SALARY_OCT_2026_2
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column ACTUAL_SALARY_NOV_2026_2
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column ACTUAL_SALARY_DEC_2026_2
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column TOTAL_SALARY_2026_2
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column MAX_YEAR_END_BONUS_AMOUNT_IN_2026
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column ACTUAL_YEAR_END_BONUS_AMOUNT_PAID_IN_2026
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column MAX_YEAR_END_BONUS_AMOUNT_IN_2026_USD
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column ACTUAL_YEAR_END_BONUS_AMOUNT_PAID_IN_2026_USD
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column MAX_HALF_YEAR_BONUS_AMOUNT_IN_2026
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column ACTUAL_HALF_YEAR_BONUS_AMOUNT_PAID_IN_2026
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column MAX_HALF_YEAR_BONUS_AMOUNT_IN_2026_USD
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column ACTUAL_HALF_YEAR_BONUS_AMOUNT_PAID_IN_2026_USD
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column MAX_13TH_MONTH_SALARY_AGUINALDO_CHRISTMAS_BONUS_IN_2026
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column ACTUAL_13TH_MONTH_SALARY_PAID_IN_2026
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column MAX_13TH_MONTH_SALARY_AGUINALDO_CHRISTMAS_BONUS_IN_2026_USD
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column ACTUAL_13TH_MONTH_SALARY_PAID_IN_2026_USD
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column MAX_HOLIDAY_BONUS_AMOUNT_IN_2026
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column ACTUAL_HOLIDAY_BONUS_AMOUNT_PAID_IN_2026
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column MAX_HOLIDAY_BONUS_AMOUNT_IN_2026_USD
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column ACTUAL_HOLIDAY_BONUS_AMOUNT_PAID_IN_2026_USD
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column MAX_PROFIT_SHARING_AMOUNT_IN_2026
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column ACTUAL_PROFIT_SHARING_AMOUNT_PAID_IN_2026
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column MAX_PROFIT_SHARING_AMOUNT_IN_2026_USD
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column ACTUAL_PROFIT_SHARING_AMOUNT_PAID_IN_2026_USD
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column MAXCCLAB_BONUS_AMOUNT_PAID_IN_2026
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column ACTUAL_BONUS_AMOUNT_PAID_IN_2026
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column MAXCCLAB_BONUS_AMOUNT_PAID_IN_2026_USD
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column ACTUAL_BONUS_AMOUNT_PAID_IN_2026_USD
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column MAX_GRATUITY_IN_2026
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column ACTUAL_GRATUITY_PAID_IN_2026
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column MAX_GRATUITY_IN_2026_USD
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column ACTUAL_GRATUITY_PAID_IN_2026_USD
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column AUDITOR_BONUS_PAID_2026_Q1
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column AUDITOR_BONUS_PAID_2026_Q2
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column AUDITOR_BONUS_PAID_2026_Q3
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column AUDITOR_BONUS_PAID_2026_Q4
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column AUDITOR_BONUS_PAID_2026_Q1_USD
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column AUDITOR_BONUS_PAID_2026_Q2_USD
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column AUDITOR_BONUS_PAID_2026_Q3_USD
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column AUDITOR_BONUS_PAID_2026_Q4_USD
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column COMMISSIONS_PAID_2026_Q1
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column COMMISSIONS_PAID_2026_Q2
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column COMMISSIONS_PAID_2026_Q3
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column COMMISSIONS_PAID_2026_Q4
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column COMMISSIONS_PAID_2026_Q1_USD
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column COMMISSIONS_PAID_2026_Q2_USD
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column COMMISSIONS_PAID_2026_Q3_USD
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column COMMISSIONS_PAID_2026_Q4_USD
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column BONUS_AMOUNT
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column BONUS_AMOUNT_USD
    set masking policy MP_PAYROLL_AMOUNT_TEXT;
alter table STG_CONSOLIDATED_2026 modify column AGENCY_FEE
    set masking policy MP_PAYROLL_AMOUNT_TEXT;

-- ---------------------------------------------------------------------------
-- Checks.
-- ---------------------------------------------------------------------------
select count(*) as ROWS_LOADED from STG_CONSOLIDATED_2026;

select count(*) as STILL_PROCESSED_BY_THE_MODEL
from V_PAYROLL_FILE_CURRENT -- expect 0 rows: the file must no longer be picked up by the model
where LOAD_ID = 1401;
