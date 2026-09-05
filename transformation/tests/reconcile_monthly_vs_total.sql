-- ===========================================================================
-- Test: does HEADER_MAP pick the right columns?
--
-- The 2026 template carries its own checksum: twelve "Actual salary <month>"
-- columns and a "Total salary 2026" column. If HEADER_MAP has classified them
-- correctly, summing the twelve must reproduce the thirteenth - per employee,
-- without any loader code in between.
--
-- Column positions are never hardcoded here. Every column is located by asking
-- HEADER_MAP, which is exactly what the loader will do.
--
-- A missing annual total is reported separately from a wrong one. They are
-- different problems: a wrong total means the file disagrees with itself, a
-- missing one just means nobody filled the formula down. Note also that an
-- empty spreadsheet cell arrives as a JSON null inside RAW_CONTENT, and
-- Snowflake treats that as NOT NULL - IS_NULL_VALUE is the correct test.
-- ===========================================================================
with sheets as (
    select f.LOAD_ID, f.FILE_NAME,
           s.key || '-' || array_size(s.value[1]) || 'col' as GENERATION,
           s.value as GRID
    from V_PAYROLL_FILE_CURRENT f,
         lateral flatten(input => f.RAW_CONTENT) s
    where s.key = '2026'
),
rows_ as (
    select sh.LOAD_ID, sh.FILE_NAME, sh.GENERATION, r.index as RIDX, r.value as RV
    from sheets sh, lateral flatten(input => sh.GRID) r
    where r.index >= 2
      and r.value[0] is not null and r.value[0]::string <> ''
),
monthly as (
    select x.LOAD_ID, x.RIDX,
           count(m.COLUMN_INDEX)                                             as N_MONTH_COLS,
           sum(try_to_number(get(x.RV, m.COLUMN_INDEX)::string, 18, 2))      as SUM_OF_MONTHS
    from rows_ x
    join HEADER_MAP m
      on  m.GENERATION     = x.GENERATION
      and m.COMPONENT_NAME = 'MONTHLY_SALARY'
      and m.MEASURE_BASIS  = 'PAYMENT'
      and m.PERIOD_TYPE    = 'MONTH'
      and m.CURRENCY_SCOPE = 'LOCAL'
    group by 1, 2
),
reported as (
    select x.LOAD_ID, x.RIDX, x.FILE_NAME, x.RV[0]::string as SAP_ID,
           try_to_number(get(x.RV, m.COLUMN_INDEX)::string, 18, 2) as TOTAL_REPORTED
    from rows_ x
    join HEADER_MAP m
      on  m.GENERATION     = x.GENERATION
      and m.COMPONENT_NAME = 'MONTHLY_SALARY'
      and m.MEASURE_BASIS  = 'PAYMENT'
      and m.PERIOD_TYPE    = 'FY'
      and m.CURRENCY_SCOPE = 'LOCAL'
)
select split_part(r.FILE_NAME, '.xlsx', 1)                        as FILE,
       count(*)                                                   as EMPLOYEES,
       min(m.N_MONTH_COLS)                                        as MIN_MONTH_COLS,
       max(m.N_MONTH_COLS)                                        as MAX_MONTH_COLS,
       count_if(r.TOTAL_REPORTED is not null
                and abs(m.SUM_OF_MONTHS - r.TOTAL_REPORTED) <= 0.01)  as MATCHES,
       count_if(r.TOTAL_REPORTED is not null
                and abs(m.SUM_OF_MONTHS - r.TOTAL_REPORTED)  > 0.01)  as REAL_MISMATCHES,
       count_if(r.TOTAL_REPORTED is null
                and coalesce(m.SUM_OF_MONTHS, 0) <> 0)                as TOTAL_MISSING
from reported r
join monthly m on m.LOAD_ID = r.LOAD_ID and m.RIDX = r.RIDX
group by 1
order by 1;
