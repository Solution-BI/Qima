-- ===========================================================================
-- transformation / 02 - SILVER model
--
-- RAW (FILE_LOAD.RAW_CONTENT) -> SILVER, driven entirely by HEADER_MAP.
--
-- The fact is long, not wide. The data contract defines every value by
-- component group x measure basis x period, and the set of components differs
-- per generation - the Eid festival blocks exist only in 2026-75col, the USD
-- columns only in 2024/2025. Wide columns would mean a DDL change per
-- generation; long absorbs them as data.
-- ===========================================================================

use role "SF_APA_SANDBOX-ETL";
use warehouse SANDBOX_WH;
use schema SANDBOX_DB.HR_PAYROLL_QIMA;

-- ---------------------------------------------------------------------------
-- SHEET_LOAD - one row per sheet inside an ingested workbook.
--
-- A workbook is not one dataset. Each holds several year sheets plus
-- "Instructions", and the year sheets are different template generations from
-- each other: BR02's 2024 sheet is 2024-91col while its 2026 sheet is
-- 2026-67col. Resolving the generation per sheet is what makes that safe.
-- ---------------------------------------------------------------------------
create table if not exists SHEET_LOAD (
    SHEET_LOAD_ID       number(38,0)   identity start 1 increment 1,
    LOAD_ID             number(38,0)   not null comment 'FK -> FILE_LOAD.',
    SHEET_NAME          varchar        not null comment 'Key from RAW_CONTENT.',
    SHEET_YEAR          number(4,0)    comment 'Null when the sheet name is not a year, e.g. Instructions.',
    GENERATION          varchar        comment 'FK -> HEADER_MAP.GENERATION. Null when unmatched.',
    COLUMN_COUNT        number(38,0),
    HEADER_HASH         number(38,0)
        comment 'Fingerprint of the header row. Not the join key - a corrected typo changes it - but a change here on a known generation is worth alerting on.',
    HEADER_JSON         variant        comment 'Header row verbatim, so a new generation can be mapped without reopening the workbook.',
    TOTAL_ROWS          number(38,0),
    DATA_ROWS           number(38,0)
        comment 'Rows carrying an employee id. Some sheets are over 95 percent formatted-but-empty padding.',
    MAPPING_STATUS      varchar        not null default 'UNMAPPED',
    CREATED_AT          timestamp_tz   not null default current_timestamp(),
    constraint PK_SHEET_LOAD primary key (SHEET_LOAD_ID),
    constraint UQ_SHEET_LOAD unique (LOAD_ID, SHEET_NAME),
    constraint CHK_MAPPING_STATUS check (MAPPING_STATUS in ('MAPPED','UNMAPPED','SAMPLE','NOT_APPLICABLE'))
) comment = 'One row per sheet per ingested file, with its resolved template generation.';

-- ---------------------------------------------------------------------------
-- PAYROLL_ROW - one row per employee line.
--
-- Per contract section 5, EMPLOYEE_SAP_ID is the only authoritative field here;
-- name, join and leave dates are informative and resolve from the HRIS
-- downstream. SUBSIDIARY is the deliberate exception - Antoine confirmed it
-- must be a point-in-time fact tied to the payment, because an employee who
-- transfers must not have historic payments re-attributed to the new entity.
-- That is why SUBSIDIARY_CODE is carried down onto PAYROLL_MEASURE too.
-- ---------------------------------------------------------------------------
create table if not exists PAYROLL_ROW (
    PAYROLL_ROW_ID      number(38,0)   identity start 1 increment 1,
    SHEET_LOAD_ID       number(38,0)   not null,
    ROW_INDEX           number(38,0)   not null comment 'Index in the sheet array. Row 0 is the band, row 1 the headers, data starts at 2.',
    REPORT_YEAR         number(4,0)    not null,

    EMPLOYEE_SAP_ID     varchar        comment 'Authoritative. Text, not numeric - the platform must not silently drop a non-numeric id.',
    SUBSIDIARY_CODE     varchar        comment 'Parsed from SUBSIDIARY_RAW as the part before the first " - ".',
    SUBSIDIARY_RAW      varchar        comment 'Verbatim cell. Not every label carries a code prefix - CPQUALI and CPHOSP do not.',
    EMPLOYEE_NAME       varchar        comment 'Informative only.',
    JOIN_DATE           date           comment 'Informative only.',
    LEAVE_DATE          date           comment 'Informative only.',

    IS_BLANK            boolean        not null default false,
    ROW_DATA            variant        not null comment 'The full cell array, kept so a HEADER_MAP fix can be replayed without re-ingesting.',
    LOADED_AT           timestamp_tz   not null default current_timestamp(),
    constraint PK_PAYROLL_ROW primary key (PAYROLL_ROW_ID),
    constraint UQ_PAYROLL_ROW unique (SHEET_LOAD_ID, ROW_INDEX)
) comment = 'One row per employee line per sheet. Employee attributes informative except subsidiary.';

-- ---------------------------------------------------------------------------
-- PAYROLL_MEASURE - the long fact. One row per cell that HEADER_MAP says
-- carries a value.
--
-- Grain: PAYROLL_ROW x COMPONENT_NAME x MEASURE_BASIS x PERIOD_KEY x
--        CURRENCY_SCOPE.
--
-- CURRENCY_SCOPE is in the grain because 2024/2025 report each amount twice -
-- once in local currency, once converted to USD at an unknown rate. Both load;
-- only LOCAL reaches GOLD.
-- ---------------------------------------------------------------------------
create table if not exists PAYROLL_MEASURE (
    MEASURE_ID          number(38,0)   identity start 1 increment 1,
    PAYROLL_ROW_ID      number(38,0)   not null,
    SHEET_LOAD_ID       number(38,0)   not null,

    EMPLOYEE_SAP_ID     varchar,
    SUBSIDIARY_CODE     varchar        comment 'Point-in-time, copied from PAYROLL_ROW. Do not resolve this live.',
    REPORT_YEAR         number(4,0)    not null,

    COMPONENT_GROUP     varchar        not null,
    COMPONENT_NAME      varchar        not null,
    MEASURE_BASIS       varchar        not null,
    PERIOD_TYPE         varchar,
    PERIOD_KEY          varchar,
    CURRENCY_SCOPE      varchar        not null,

    AMOUNT              number(18,2)   comment 'Set where MEASURE_BASIS is PAYMENT, RATE or FEE and the cell parsed as a number.',
    CURRENCY_CODE       varchar(8)     comment 'As supplied. The files use RMB where ISO is CNY; normalised in GOLD, not here.',
    IS_ELIGIBLE         boolean        comment 'Set where MEASURE_BASIS is ELIGIBILITY.',
    TEXT_VALUE          varchar        comment 'Set where the value is not numeric - an ATTRIBUTE, or a salary typed as text.',
    RAW_VALUE           varchar        comment 'The cell exactly as extracted, always populated, for dispute resolution.',

    SOURCE_COLUMN_INDEX number(38,0)   not null,
    LOADED_AT           timestamp_tz   not null default current_timestamp(),
    constraint PK_PAYROLL_MEASURE primary key (MEASURE_ID),
    constraint UQ_PAYROLL_MEASURE unique
        (PAYROLL_ROW_ID, COMPONENT_NAME, MEASURE_BASIS, PERIOD_KEY, CURRENCY_SCOPE)
) comment = 'Long-format payroll fact. One row per meaningful cell, classified by HEADER_MAP.';

-- ---------------------------------------------------------------------------
-- DQ_FLAG - the four classes from contract section 6, each with its own
-- downstream treatment. The class is what decides whether a row reaches GOLD,
-- so it is a column, not a comment.
-- ---------------------------------------------------------------------------
create table if not exists DQ_FLAG (
    FLAG_ID             number(38,0)   identity start 1 increment 1,
    LOAD_ID             number(38,0),
    SHEET_LOAD_ID       number(38,0),
    PAYROLL_ROW_ID      number(38,0),
    MEASURE_ID          number(38,0),

    DQ_CLASS            varchar        not null
        comment 'STRUCTURAL rejects the file or sheet. IDENTITY loads but is excluded from GOLD until resolved. VALUE loads and stays in GOLD with the flag visible. CONVENTION is auto-resolved where possible and logged for a HEADER_MAP update.',
    RULE_NAME           varchar        not null
        comment 'e.g. UNMAPPED_GENERATION, SAMPLE_FILE_INGESTED, UNMAPPED_COLUMN, SALARY_AS_TEXT, UNPARSEABLE_DATE, MISSING_CURRENCY, UNKNOWN_SUBSIDIARY, SUBSIDIARY_NOT_DECLARED_BY_FOLDER, TOTAL_MISMATCH, DUPLICATE_SAP_ID_ACROSS_FILES',
    COLUMN_INDEX        number(38,0),
    SOURCE_HEADER       varchar,
    RAW_VALUE           varchar,
    MESSAGE             varchar,
    CREATED_AT          timestamp_tz   not null default current_timestamp(),
    constraint PK_DQ_FLAG primary key (FLAG_ID),
    constraint CHK_DQ_CLASS check (DQ_CLASS in ('STRUCTURAL','IDENTITY','VALUE','CONVENTION'))
) comment = 'Data quality findings, classified per input data contract section 6.';

-- ---------------------------------------------------------------------------
-- GOLD views.
--
-- Three exclusions, each traceable to a decision rather than a preference:
--   CURRENCY_SCOPE = 'LOCAL'  - FX normalisation is out of scope (contract s.3)
--   no IDENTITY flag          - identity issues are excluded until resolved (s.6)
--   NEEDS_REVIEW = FALSE      - an unreviewed mapping must not reach reporting
-- ---------------------------------------------------------------------------
create or replace view V_GOLD_PAYROLL_MEASURE as
select m.*
from PAYROLL_MEASURE m
join SHEET_LOAD sl on sl.SHEET_LOAD_ID = m.SHEET_LOAD_ID
where m.CURRENCY_SCOPE = 'LOCAL'
  and sl.MAPPING_STATUS = 'MAPPED'   -- excludes SAMPLE sheets
  and not exists (
      select 1 from DQ_FLAG f
      where f.DQ_CLASS = 'IDENTITY'
        and (f.PAYROLL_ROW_ID = m.PAYROLL_ROW_ID or f.MEASURE_ID = m.MEASURE_ID)
  );

-- Annual compensation per employee per subsidiary. EXTERNAL is excluded:
-- agency fees are an external headcount cost, not compensation (contract s.4).
create or replace view V_GOLD_ANNUAL_COMPENSATION as
select REPORT_YEAR,
       SUBSIDIARY_CODE,
       EMPLOYEE_SAP_ID,
       CURRENCY_CODE,
       sum(iff(COMPONENT_GROUP = 'SALARY',     AMOUNT, 0)) as SALARY_PAID,
       sum(iff(COMPONENT_GROUP = 'BONUS',      AMOUNT, 0)) as BONUS_PAID,
       sum(iff(COMPONENT_GROUP = 'COMMISSION', AMOUNT, 0)) as COMMISSION_PAID,
       sum(iff(COMPONENT_GROUP = 'ADHOC',      AMOUNT, 0)) as ADHOC_PAID,
       sum(AMOUNT)                                         as TOTAL_PAID
from V_GOLD_PAYROLL_MEASURE
where MEASURE_BASIS = 'PAYMENT'
  and COMPONENT_GROUP <> 'EXTERNAL'
group by 1, 2, 3, 4;

show tables in schema SANDBOX_DB.HR_PAYROLL_QIMA;
