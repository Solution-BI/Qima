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
-- TAB_LOAD - one row per tab inside an ingested workbook.
--
-- A workbook is not one dataset. Each holds several year sheets plus
-- "Instructions", and the year sheets are different template generations from
-- each other: BR02's 2024 sheet is 2024-91col while its 2026 sheet is
-- 2026-67col. Resolving the generation per sheet is what makes that safe.
-- ---------------------------------------------------------------------------
create table if not exists TAB_LOAD (
    TAB_LOAD_ID         number(38,0)   identity start 1 increment 1,
    LOAD_ID             number(38,0)   not null comment 'FK -> FILE_LOAD.',
    TAB_NAME          varchar        not null comment 'Key from RAW_CONTENT.',
    TAB_YEAR          number(4,0)    comment 'Null when the sheet name is not a year, e.g. Instructions.',
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
    constraint PK_TAB_LOAD primary key (TAB_LOAD_ID),
    constraint UQ_TAB_LOAD unique (LOAD_ID, TAB_NAME),
    constraint CHK_MAPPING_STATUS check (MAPPING_STATUS in ('MAPPED','UNMAPPED','SAMPLE','NOT_APPLICABLE'))
) comment = 'One row per tab per ingested file, with its resolved template generation.';

-- ---------------------------------------------------------------------------
-- PAYROLL_ROW - one row per employee line.
--
-- Per contract section 5, EMPLOYEE_SAP_ID is the only authoritative field here;
-- name, join and leave dates are informative and resolve from the HRIS
-- downstream. SUBSIDIARY is the deliberate exception - Antoine confirmed it
-- must be a point-in-time fact tied to the payment, because an employee who
-- transfers must not have historic payments re-attributed to the new entity.
-- That is why SUBSIDIARY_CODE is carried down onto FACT_PAYROLL_COMPONENT too.
-- ---------------------------------------------------------------------------
create table if not exists PAYROLL_ROW (
    PAYROLL_ROW_ID      number(38,0)   identity start 1 increment 1,
    TAB_LOAD_ID         number(38,0)   not null,
    ROW_INDEX           number(38,0)   not null comment 'Index in the sheet array. Row 0 is the band, row 1 the headers, data starts at 2.',
    REPORT_YEAR         number(4,0)    not null,

    EMPLOYEE_SAP_ID     varchar        comment 'Authoritative. Text, not numeric - the platform must not silently drop a non-numeric id.',
    SUBSIDIARY_CODE     varchar        comment 'Parsed from SUBSIDIARY_RAW as the part before the first " - ".',
    SUBSIDIARY_RAW      varchar        comment 'Verbatim cell. Not every label carries a code prefix - CPQUALI and CPHOSP do not.',
    EMPLOYEE_NAME       varchar        comment 'Informative only.',
    JOIN_DATE           date           comment 'Informative only.',
    LEAVE_DATE          date           comment 'Informative only.',

    EMPLOYMENT_KEY      varchar        comment 'EMPLOYEE_SAP_ID | JOIN_DATE | LEAVE_DATE. The grain of a person''s employment, not of a person. Verified unique: 2812 distinct keys across 2812 current rows, where SAP ID alone gives 2810. Two real cases - one transfer between subsidiaries, one employee on two overlapping contracts at the same entity.',

    IS_BLANK            boolean        not null default false,
    ROW_DATA            variant        not null comment 'The full cell array, kept so a HEADER_MAP fix can be replayed without re-ingesting.',
    LOADED_AT           timestamp_tz   not null default current_timestamp(),
    constraint PK_PAYROLL_ROW primary key (PAYROLL_ROW_ID),
    constraint UQ_PAYROLL_ROW unique (TAB_LOAD_ID, ROW_INDEX)
) comment = 'One row per employee line per sheet. Employee attributes informative except subsidiary.';

-- ---------------------------------------------------------------------------
-- The payroll facts. Two tables, split by what the number means.
--
-- Greg's 11 September note asked for the contractual figures to be isolated
-- from what was actually paid, in storage rather than only behind a filter:
--
--   FACT_PAYROLL_PAYMENT      money that moved
--   FACT_PAYROLL_ENTITLEMENT  what the contract says - rates, and scheme
--                             eligibility, neither of which is a payment
--
-- This split is safe where the superseded PAYROLL_MONTHLY_FACT /
-- PAYROLL_BONUS_FACT proposal was not. That one split on component, and the
-- set of components grows with every template generation, so it needed a DDL
-- change per generation. MEASURE_BASIS is a closed set fixed by the data
-- contract, so splitting on it costs nothing when a new bonus column appears.
--
-- Both keep the long shape - one row per cell HEADER_MAP says carries a value,
-- no hardcoded component list. Grain on each:
--   PAYROLL_ROW x COMPONENT_NAME x MEASURE_BASIS x PERIOD_KEY x CURRENCY_SCOPE.
--
-- CURRENCY_SCOPE is in the grain because 2024/2025 report each amount twice -
-- once in local currency, once converted to USD at an unknown rate. Both load,
-- only LOCAL reaches GOLD. 2026 carries no USD duplicates at all.
-- ---------------------------------------------------------------------------

-- One sequence across both tables so a MEASURE_ID identifies a single row
-- whichever table holds it. DQ_FLAG.MEASURE_ID points at it and must not have
-- to know which of the two the row came from.
create sequence if not exists SEQ_MEASURE_ID start = 1 increment = 1
    comment = 'Shared identity for FACT_PAYROLL_PAYMENT and FACT_PAYROLL_ENTITLEMENT.';

create table if not exists FACT_PAYROLL_PAYMENT (
    MEASURE_ID          number(38,0)   not null default SEQ_MEASURE_ID.nextval,
    PAYROLL_ROW_ID      number(38,0)   not null,
    TAB_LOAD_ID         number(38,0)   not null,

    EMPLOYEE_SAP_ID     varchar,
    EMPLOYMENT_KEY      varchar        comment 'Copied from PAYROLL_ROW. Aggregating on EMPLOYEE_SAP_ID alone would merge two contracts into one person.',
    SUBSIDIARY_CODE     varchar        comment 'Point-in-time, copied from PAYROLL_ROW. Do not resolve this live.',
    REPORT_YEAR         number(4,0)    not null,

    COMPONENT_GROUP     varchar        not null,
    COMPONENT_NAME      varchar        not null,
    MEASURE_BASIS       varchar        not null comment 'Always PAYMENT. Kept so the union view and every existing query reading this column still work.',
    PERIOD_TYPE         varchar        comment 'MONTH, QUARTER or FY. Never null here - a payment always happened in a period.',
    PERIOD_KEY          varchar,
    CURRENCY_SCOPE      varchar        not null,

    AMOUNT              number(18,2),
    CURRENCY_CODE       varchar(8)
        comment 'The component own (Currency) column where the generation has one, otherwise the contractual currency. These genuinely differ - 1988 of 2812 current rows carry a bonus currency that is not the contract currency, overwhelmingly local-to-USD. Files use RMB where ISO is CNY; normalised in GOLD, not here.',
    TEXT_VALUE          varchar        comment 'Set where the value did not parse as a number - the contract salary-entered-as-text case.',

    LOADED_AT           timestamp_tz   not null default current_timestamp(),
    constraint PK_FACT_PAYROLL_PAYMENT primary key (MEASURE_ID),
    constraint UQ_FACT_PAYROLL_PAYMENT unique
        (PAYROLL_ROW_ID, COMPONENT_NAME, PERIOD_KEY, CURRENCY_SCOPE),
    constraint CHK_FACT_PAYMENT_BASIS check (MEASURE_BASIS = 'PAYMENT')
) comment = 'Amounts actually paid. One row per paid cell. No IS_ELIGIBLE column - a payment is not a flag.';

create table if not exists FACT_PAYROLL_ENTITLEMENT (
    MEASURE_ID          number(38,0)   not null default SEQ_MEASURE_ID.nextval,
    PAYROLL_ROW_ID      number(38,0)   not null,
    TAB_LOAD_ID         number(38,0)   not null,

    EMPLOYEE_SAP_ID     varchar,
    EMPLOYMENT_KEY      varchar,
    SUBSIDIARY_CODE     varchar        comment 'Point-in-time, copied from PAYROLL_ROW.',
    REPORT_YEAR         number(4,0)    not null,

    COMPONENT_GROUP     varchar        not null,
    COMPONENT_NAME      varchar        not null,
    MEASURE_BASIS       varchar        not null comment 'RATE or ELIGIBILITY.',
    PERIOD_TYPE         varchar        comment 'Null on the salary rates - a contractual monthly salary is a standing figure, not a monthly event. FY on the 15501 bonus maximums, which the template does state per year ("Max Year End Bonus Amount in 2026"). Never MONTH: nothing here is a monthly occurrence, which is the point of separating it from FACT_PAYROLL_PAYMENT.',
    PERIOD_KEY          varchar,
    CURRENCY_SCOPE      varchar        not null,

    AMOUNT              number(18,2)   comment 'Set on RATE rows - a contractual monthly salary, allowance or bonus maximum. Null on ELIGIBILITY.',
    CURRENCY_CODE       varchar(8),
    IS_ELIGIBLE         boolean        comment 'Set on ELIGIBILITY rows only.',
    TEXT_VALUE          varchar,

    LOADED_AT           timestamp_tz   not null default current_timestamp(),
    constraint PK_FACT_PAYROLL_ENTITLEMENT primary key (MEASURE_ID),
    constraint UQ_FACT_PAYROLL_ENTITLEMENT unique
        (PAYROLL_ROW_ID, COMPONENT_NAME, MEASURE_BASIS, PERIOD_KEY, CURRENCY_SCOPE),
    constraint CHK_FACT_ENTITLEMENT_BASIS check (MEASURE_BASIS in ('RATE','ELIGIBILITY'))
) comment = 'The contractual position: agreed rates and scheme eligibility. Never money that moved.';

-- ---------------------------------------------------------------------------
-- PAYROLL_ATTRIBUTE - the descriptive block. External headcount and remarks.
--
-- Greg flagged Agency Name, Agency Fee and Remarks as missing from the 2026
-- extract and Antoine agreed they belong in a separate table. They were mapped
-- in HEADER_MAP all along but had nowhere to land: two are free text, and a
-- fact of amounts is the wrong home for a supplier name or a comment.
--
-- Long, not wide, for the same reason the facts are: 2025-95col adds four more
-- External HC columns that no other generation has (Employee Class, two data
-- issue columns, Correction steps). A wide table would need a DDL change to
-- absorb them; this one takes them as rows.
--
-- AGENCY_FEE keeps AMOUNT and CURRENCY_CODE because it is a real cost. It is
-- deliberately not in FACT_PAYROLL_PAYMENT - an agency fee is an external
-- headcount cost, not employee compensation (contract section 4), which is why
-- V_GOLD_ANNUAL_COMPENSATION already excluded COMPONENT_GROUP = 'EXTERNAL'.
-- ---------------------------------------------------------------------------
create table if not exists PAYROLL_ATTRIBUTE (
    ATTRIBUTE_ID        number(38,0)   identity start 1 increment 1,
    PAYROLL_ROW_ID      number(38,0)   not null,
    TAB_LOAD_ID         number(38,0)   not null,

    EMPLOYEE_SAP_ID     varchar,
    EMPLOYMENT_KEY      varchar,
    SUBSIDIARY_CODE     varchar,
    REPORT_YEAR         number(4,0)    not null,

    ATTRIBUTE_GROUP     varchar        not null comment 'EXTERNAL for the External HC block, OTHER for Remarks.',
    ATTRIBUTE_NAME      varchar        not null
        comment 'HEADER_MAP.CANONICAL_FIELD where one exists - AGENCY_NAME, AGENCY_FEE, REMARK - otherwise the source header normalised. Stable across generations, which is why Remark (2024/2025) and Remarks (2026) both arrive as REMARK.',
    SOURCE_HEADER       varchar        comment 'The header verbatim, so an attribute traces back to a cell without reopening the workbook.',

    TEXT_VALUE          varchar        comment 'The cell as written. On AGENCY_FEE it is set only when the fee did not parse as a number, the same rule the fact tables follow.',
    AMOUNT              number(18,2)   comment 'Set on AGENCY_FEE only.',
    CURRENCY_CODE       varchar(8)     comment 'Set on AGENCY_FEE only. The template has no currency cell for the fee, so this is the contractual currency - an assumption, not something the file states.',

    LOADED_AT           timestamp_tz   not null default current_timestamp(),
    constraint PK_PAYROLL_ATTRIBUTE primary key (ATTRIBUTE_ID),
    constraint UQ_PAYROLL_ATTRIBUTE unique (PAYROLL_ROW_ID, ATTRIBUTE_NAME),
    constraint CHK_ATTRIBUTE_GROUP check (ATTRIBUTE_GROUP in ('EXTERNAL','OTHER','ADHOC'))
) comment = 'Non-measure cells: external headcount and free-text remarks, one row per attribute.';

-- ---------------------------------------------------------------------------
-- FACT_PAYROLL_COMPONENT - now a view over the two facts.
--
-- It was the single table until 11 September. Keeping the name as a view means
-- the extract already sent to Qima, the DQ rules, the GOLD views and the test
-- scripts all keep working unchanged, while storage is split underneath.
-- Column order matches the old table exactly, so SELECT * is unaffected.
-- ---------------------------------------------------------------------------
create or replace view FACT_PAYROLL_COMPONENT
    comment = 'Union of FACT_PAYROLL_PAYMENT and FACT_PAYROLL_ENTITLEMENT. Compatibility surface - write to the base tables, not here.'
as
select MEASURE_ID, PAYROLL_ROW_ID, TAB_LOAD_ID, EMPLOYEE_SAP_ID, EMPLOYMENT_KEY,
       SUBSIDIARY_CODE, REPORT_YEAR, COMPONENT_GROUP, COMPONENT_NAME,
       MEASURE_BASIS, PERIOD_TYPE, PERIOD_KEY, CURRENCY_SCOPE,
       AMOUNT, CURRENCY_CODE, null::boolean as IS_ELIGIBLE, TEXT_VALUE, LOADED_AT
from FACT_PAYROLL_PAYMENT
union all
select MEASURE_ID, PAYROLL_ROW_ID, TAB_LOAD_ID, EMPLOYEE_SAP_ID, EMPLOYMENT_KEY,
       SUBSIDIARY_CODE, REPORT_YEAR, COMPONENT_GROUP, COMPONENT_NAME,
       MEASURE_BASIS, PERIOD_TYPE, PERIOD_KEY, CURRENCY_SCOPE,
       AMOUNT, CURRENCY_CODE, IS_ELIGIBLE, TEXT_VALUE, LOADED_AT
from FACT_PAYROLL_ENTITLEMENT;

-- ---------------------------------------------------------------------------
-- DQ_FLAG - the four classes from contract section 6, each with its own
-- downstream treatment. The class is what decides whether a row reaches GOLD,
-- so it is a column, not a comment.
-- ---------------------------------------------------------------------------
create table if not exists DQ_FLAG (
    FLAG_ID             number(38,0)   identity start 1 increment 1,
    LOAD_ID             number(38,0),
    TAB_LOAD_ID       number(38,0),
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
create or replace view V_GOLD_PAYROLL_COMPONENT as
select m.*
from FACT_PAYROLL_COMPONENT m
join TAB_LOAD sl on sl.TAB_LOAD_ID = m.TAB_LOAD_ID
where m.CURRENCY_SCOPE = 'LOCAL'
  and sl.MAPPING_STATUS = 'MAPPED'   -- excludes SAMPLE sheets
  and not exists (
      select 1 from DQ_FLAG f
      where f.DQ_CLASS = 'IDENTITY'
        and (f.PAYROLL_ROW_ID = m.PAYROLL_ROW_ID or f.MEASURE_ID = m.MEASURE_ID)
  );

-- The same three exclusions, applied to the payment table directly. Anything
-- totalling money should read this rather than filtering the union view - it
-- cannot accidentally pick up a contractual rate.
create or replace view V_GOLD_PAYROLL_PAYMENT as
select m.*
from FACT_PAYROLL_PAYMENT m
join TAB_LOAD sl on sl.TAB_LOAD_ID = m.TAB_LOAD_ID
where m.CURRENCY_SCOPE = 'LOCAL'
  and sl.MAPPING_STATUS = 'MAPPED'
  and not exists (
      select 1 from DQ_FLAG f
      where f.DQ_CLASS = 'IDENTITY'
        and (f.PAYROLL_ROW_ID = m.PAYROLL_ROW_ID or f.MEASURE_ID = m.MEASURE_ID)
  );

-- Annual compensation per employment, per component group, PER CURRENCY.
--
-- Currency is in the grain and there is deliberately NO cross-component total.
-- Salary and bonus are usually denominated differently: 1988 of the 2812
-- current rows carry a year-end bonus currency that differs from the contract
-- currency, RMB salary against USD bonus being the single largest pattern
-- (1480 rows). Adding those together would be arithmetic on mixed units, and
-- FX normalisation is out of scope per the contract.
--
-- The grain is EMPLOYMENT_KEY, not EMPLOYEE_SAP_ID: an employee on two
-- contracts, or who transferred subsidiary mid-year, is two employments and
-- must not be collapsed into one.
--
-- Reads FACT_PAYROLL_PAYMENT, so contractual rates cannot leak into a paid
-- total. External headcount is not here either - agency fees live in
-- PAYROLL_ATTRIBUTE and are a supplier cost, not compensation (contract s.4).
create or replace view V_GOLD_ANNUAL_COMPENSATION as
select REPORT_YEAR,
       SUBSIDIARY_CODE,
       EMPLOYEE_SAP_ID,
       EMPLOYMENT_KEY,
       COMPONENT_GROUP,
       CURRENCY_CODE,
       sum(AMOUNT) as AMOUNT_PAID
from V_GOLD_PAYROLL_PAYMENT
-- The file own annual salary total restates the twelve monthly cells rather
-- than adding to them: verified equal for all 2784 employments that carry
-- both. Summing it alongside them counts the same salary twice.
where not (COMPONENT_NAME = 'MONTHLY_SALARY' and PERIOD_TYPE = 'FY')
  -- Current year only. "Current" is the newest year actually loaded, capped at
  -- today year so a mistyped tab name cannot hijack it. History stays
  -- available through V_GOLD_PAYROLL_COMPONENT, which is unfiltered.
  and REPORT_YEAR = (select max(REPORT_YEAR) from FACT_PAYROLL_PAYMENT
                     where REPORT_YEAR <= year(current_date()))
group by 1, 2, 3, 4, 5, 6;

-- A single-currency total is only safe where an employment reports exactly one
-- currency across every component. This view says which those are, so a
-- consumer can total them without an FX assumption and see the rest excluded
-- rather than silently mis-added.
create or replace view V_GOLD_SINGLE_CURRENCY_EMPLOYMENT as
select REPORT_YEAR, SUBSIDIARY_CODE, EMPLOYEE_SAP_ID, EMPLOYMENT_KEY,
       min(CURRENCY_CODE) as CURRENCY_CODE,
       sum(AMOUNT_PAID)   as TOTAL_PAID
from V_GOLD_ANNUAL_COMPENSATION
group by 1, 2, 3, 4
having count(distinct CURRENCY_CODE) = 1;
-- Inherits the current-year filter from V_GOLD_ANNUAL_COMPENSATION above.

-- The contractual position per employment: what was agreed, not what was paid.
-- Separated from compensation so the two are never accidentally summed.
create or replace view V_GOLD_ENTITLEMENT as
select e.REPORT_YEAR, e.SUBSIDIARY_CODE, e.EMPLOYEE_SAP_ID, e.EMPLOYMENT_KEY,
       e.COMPONENT_GROUP, e.COMPONENT_NAME, e.MEASURE_BASIS,
       e.AMOUNT, e.CURRENCY_CODE, e.IS_ELIGIBLE
from FACT_PAYROLL_ENTITLEMENT e
join TAB_LOAD sl on sl.TAB_LOAD_ID = e.TAB_LOAD_ID
where e.CURRENCY_SCOPE in ('LOCAL','NA')
  and sl.MAPPING_STATUS = 'MAPPED'
  and not exists (
      select 1 from DQ_FLAG f
      where f.DQ_CLASS = 'IDENTITY'
        and (f.PAYROLL_ROW_ID = e.PAYROLL_ROW_ID or f.MEASURE_ID = e.MEASURE_ID)
  );

-- External headcount in the shape Greg drew it: one row per employment, agency
-- name beside agency fee. The long storage underneath is what absorbs the four
-- extra columns 2025-95col carries; this view is just the readable face of it.
create or replace view V_GOLD_EXTERNAL_HEADCOUNT as
select * from (
    select REPORT_YEAR, SUBSIDIARY_CODE, EMPLOYEE_SAP_ID, EMPLOYMENT_KEY,
           max(iff(ATTRIBUTE_NAME = 'AGENCY_NAME', TEXT_VALUE,    null)) as AGENCY_NAME,
           max(iff(ATTRIBUTE_NAME = 'AGENCY_FEE',  AMOUNT,        null)) as AGENCY_FEE,
           max(iff(ATTRIBUTE_NAME = 'AGENCY_FEE',  CURRENCY_CODE, null)) as CURRENCY_CODE
    from PAYROLL_ATTRIBUTE
    where ATTRIBUTE_GROUP = 'EXTERNAL'
    group by 1, 2, 3, 4
)
where AGENCY_NAME is not null or AGENCY_FEE is not null;

show tables in schema SANDBOX_DB.HR_PAYROLL_QIMA;
