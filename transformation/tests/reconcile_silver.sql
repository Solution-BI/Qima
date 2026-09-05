-- ===========================================================================
-- Test: does PAYROLL_MEASURE reproduce the file's own annual total?
--
-- Same checksum as reconcile_monthly_vs_total.sql, but run against the loaded
-- SILVER table rather than RAW_CONTENT. Passing both means the mapping is right
-- AND the loader preserved it.
-- ===========================================================================
with monthly as (
    select PAYROLL_ROW_ID, EMPLOYMENT_KEY, SUBSIDIARY_CODE,
           sum(AMOUNT) as SUM_OF_MONTHS, count(*) as N_MONTHS
    from PAYROLL_MEASURE
    where REPORT_YEAR = 2026 and COMPONENT_NAME = 'MONTHLY_SALARY'
      and MEASURE_BASIS = 'PAYMENT' and PERIOD_TYPE = 'MONTH'
      and CURRENCY_SCOPE = 'LOCAL'
    group by 1, 2, 3
),
reported as (
    select PAYROLL_ROW_ID, AMOUNT as TOTAL_REPORTED
    from PAYROLL_MEASURE
    where REPORT_YEAR = 2026 and COMPONENT_NAME = 'MONTHLY_SALARY'
      and MEASURE_BASIS = 'PAYMENT' and PERIOD_TYPE = 'FY'
      and CURRENCY_SCOPE = 'LOCAL'
)
select count(*)                                                          as EMPLOYMENTS,
       count_if(r.TOTAL_REPORTED is not null
                and abs(m.SUM_OF_MONTHS - r.TOTAL_REPORTED) <= 0.01)     as MATCHES,
       count_if(r.TOTAL_REPORTED is not null
                and abs(m.SUM_OF_MONTHS - r.TOTAL_REPORTED)  > 0.01)     as REAL_MISMATCHES,
       count_if(r.TOTAL_REPORTED is null)                                as TOTAL_MISSING
from monthly m
left join reported r on r.PAYROLL_ROW_ID = m.PAYROLL_ROW_ID;
