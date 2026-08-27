"""Frozen column definitions for the QIMA payroll template.

Single source of truth used by:
  - parse.py (header assertion)
  - generate_ddl.py (table DDL generation)
  - staging.py (INSERT column ordering)

Derived from row 2 of Delivery/QIMA Payroll - Template.xlsx (sheet "2026").
"""
from __future__ import annotations

# Raw Excel header text exactly as it appears in row 2.
# Whitespace (including embedded newlines) is preserved here for assertion;
# the parser normalises before comparing.
EXPECTED_HEADERS: tuple[str, ...] = (
    "Employee SAP ID",                                    # A
    "SAP Staff Name",                                     # B
    "Join Date",                                          # C
    "Leave Date",                                         # D
    "Subsidiary",                                         # E
    "Monthly Gross Salary",                               # F
    "Monthly Allowance / 2nd part of salary",             # G
    "QIMA (Employer) Social Charges",                     # H
    "Total Monthly Salary cost (F+G+H)",                  # I
    "Currency",                                           # J
    "Actual salary\nJan 2026",                            # K
    "Actual salary\nFeb 2026",                            # L
    "Actual salary\nMar 2026",                            # M
    "Actual salary\nApr 2026",                            # N
    "Actual salary\nMay 2026",                            # O
    "Actual salary\nJun 2026",                            # P
    "Actual salary\nJul 2026",                            # Q
    "Actual salary\nAug 2026",                            # R
    "Actual salary\nSept 2026",                           # S
    "Actual salary\nOct 2026",                            # T
    "Actual salary\nNov 2026",                            # U
    "Actual salary\nDec 2026",                            # V
    "Total salary 2026",                                  # W
    "Eligible for Year-end bonus ",                       # X  (trailing space in source)
    "Year-end bonus (Currency)",                          # Y
    "Max Year-end bonus amount in 2026",                  # Z
    "Actual Year-end Bonus amount Paid in 2026",          # AA
    "Eligible for Half-year bonus ",                      # AB (trailing space in source)
    "Half-Year bonus (Currency)",                         # AC
    "Max Half-year bonus amount in 2026",                 # AD
    "Actual Half-year Bonus amount Paid in 2026",         # AE
    "Eligible for 13th Month salary / Christmas Bonus / Aguinaldo",  # AF
    "13th Month salary (Currency)",                       # AG
    "Max 13th Month salary / Aguinaldo / Christmas Bonus in 2026",   # AH
    "Actual 13th Month salary paid in 2026",              # AI
    "Eligible for Holiday Bonus",                         # AJ
    "Holiday Bonus (Currency)",                           # AK
    "Max Holiday Bonus amount in 2026",                   # AL
    "Actual Holiday Bonus amount paid in 2026",           # AM
    "Eligible for Profit Sharing",                        # AN
    "Profit Sharing (Currency)",                          # AO
    "Max Profit Sharing amount in 2026",                  # AP
    "Actual Profit Sharing amount Paid in 2026",          # AQ
    "Eligible for CCLAB Bonus",                           # AR
    "CCLAB bonus (Currency)",                             # AS
    "MaxCCLAB Bonus amount paid in 2026",                 # AT
    "Actual Bonus amount paid in 2026",                   # AU
    "Eligible for Gratuity",                              # AV
    "Gratuity (Currency)",                                # AW
    "Max Gratuity in 2026",                               # AX
    "Actual Gratuity paid in 2026",                       # AY
    "Auditor Bonus (Currency)",                           # AZ
    "Auditor Bonus paid\n2026 Q1",                        # BA
    "Auditor Bonus paid\n2026 Q2",                        # BB
    "Auditor Bonus paid\n2026 Q3",                        # BC
    "Auditor Bonus paid\n2026 Q4",                        # BD
    "Commission (Currency)",                              # BE
    "Commissions paid\n2026 Q1",                          # BF
    "Commissions paid\n2026 Q2",                          # BG
    "Commissions paid\n2026 Q3",                          # BH
    "Commissions paid\n2026 Q4",                          # BI
    "Payment type",                                       # BJ
    "Currency",                                           # BK (duplicate of J)
    "Bonus amount",                                       # BL
    "Agency Name",                                        # BM
    "Agency Fee",                                         # BN
    "Remarks",                                            # BO
)

# SQL-safe staging column names — positional, UPPER_SNAKE_CASE.
# Duplicates disambiguated by Excel column letter suffix.
COLUMNS: tuple[str, ...] = (
    "EMPLOYEE_SAP_ID",                       # A
    "SAP_STAFF_NAME",                        # B
    "JOIN_DATE",                             # C
    "LEAVE_DATE",                            # D
    "SUBSIDIARY",                            # E
    "MONTHLY_GROSS_SALARY",                  # F
    "MONTHLY_ALLOWANCE",                     # G
    "EMPLOYER_SOCIAL_CHARGES",               # H
    "TOTAL_MONTHLY_SALARY_COST",             # I
    "CURRENCY_CONTRACTUAL",                  # J  (disambiguated)
    "ACTUAL_SALARY_JAN",                     # K
    "ACTUAL_SALARY_FEB",                     # L
    "ACTUAL_SALARY_MAR",                     # M
    "ACTUAL_SALARY_APR",                     # N
    "ACTUAL_SALARY_MAY",                     # O
    "ACTUAL_SALARY_JUN",                     # P
    "ACTUAL_SALARY_JUL",                     # Q
    "ACTUAL_SALARY_AUG",                     # R
    "ACTUAL_SALARY_SEP",                     # S
    "ACTUAL_SALARY_OCT",                     # T
    "ACTUAL_SALARY_NOV",                     # U
    "ACTUAL_SALARY_DEC",                     # V
    "TOTAL_SALARY_2026",                     # W
    "ELIGIBLE_YEAR_END_BONUS",               # X
    "YEAR_END_BONUS_CURRENCY",               # Y
    "MAX_YEAR_END_BONUS",                    # Z
    "ACTUAL_YEAR_END_BONUS",                 # AA
    "ELIGIBLE_HALF_YEAR_BONUS",              # AB
    "HALF_YEAR_BONUS_CURRENCY",              # AC
    "MAX_HALF_YEAR_BONUS",                   # AD
    "ACTUAL_HALF_YEAR_BONUS",                # AE
    "ELIGIBLE_13TH_MONTH",                   # AF
    "THIRTEENTH_MONTH_CURRENCY",             # AG
    "MAX_13TH_MONTH",                        # AH
    "ACTUAL_13TH_MONTH",                     # AI
    "ELIGIBLE_HOLIDAY_BONUS",                # AJ
    "HOLIDAY_BONUS_CURRENCY",                # AK
    "MAX_HOLIDAY_BONUS",                     # AL
    "ACTUAL_HOLIDAY_BONUS",                  # AM
    "ELIGIBLE_PROFIT_SHARING",               # AN
    "PROFIT_SHARING_CURRENCY",               # AO
    "MAX_PROFIT_SHARING",                    # AP
    "ACTUAL_PROFIT_SHARING",                 # AQ
    "ELIGIBLE_CCLAB_BONUS",                  # AR
    "CCLAB_BONUS_CURRENCY",                  # AS
    "MAX_CCLAB_BONUS",                       # AT
    "ACTUAL_CCLAB_BONUS",                    # AU
    "ELIGIBLE_GRATUITY",                     # AV
    "GRATUITY_CURRENCY",                     # AW
    "MAX_GRATUITY",                          # AX
    "ACTUAL_GRATUITY",                       # AY
    "AUDITOR_BONUS_CURRENCY",                # AZ
    "AUDITOR_BONUS_Q1",                      # BA
    "AUDITOR_BONUS_Q2",                      # BB
    "AUDITOR_BONUS_Q3",                      # BC
    "AUDITOR_BONUS_Q4",                      # BD
    "COMMISSION_CURRENCY",                   # BE
    "COMMISSION_Q1",                         # BF
    "COMMISSION_Q2",                         # BG
    "COMMISSION_Q3",                         # BH
    "COMMISSION_Q4",                         # BI
    "PAYMENT_TYPE",                          # BJ
    "CURRENCY_ADHOC",                        # BK (disambiguated)
    "BONUS_AMOUNT",                          # BL
    "AGENCY_NAME",                           # BM
    "AGENCY_FEE",                            # BN
    "REMARKS",                               # BO
)

METADATA_COLUMNS: tuple[str, ...] = (
    "LOAD_DATE",
    "SOURCE_FILE_NAME",
    "SUBSIDIARY_CODE",
    "SOURCE_MODIFIED_DATE",
)

# DDL types for the metadata columns, keyed by name so generate_ddl.py and the
# INSERT column order can never drift apart.
METADATA_DDL: dict[str, str] = {
    "LOAD_DATE": "TIMESTAMP_NTZ  NOT NULL",
    "SOURCE_FILE_NAME": "VARCHAR        NOT NULL",
    "SUBSIDIARY_CODE": "VARCHAR        NOT NULL",
    # SharePoint lastModifiedDateTime — the change signal that suppresses reloads.
    "SOURCE_MODIFIED_DATE": "TIMESTAMP_NTZ  NOT NULL",
}

COLUMN_COUNT = 67

assert len(EXPECTED_HEADERS) == COLUMN_COUNT
assert len(COLUMNS) == COLUMN_COUNT
