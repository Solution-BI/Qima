-- T_PAYROLL_INGEST: daily scheduled task calling SP_INGEST_PAYROLL_FILES.
--
-- Created SUSPENDED. Only resume after the verification suite passes
-- (see plan_stored_procedure_migration_2026-09-10.md, "Verification" section).
--
-- Warehouse-backed rather than serverless -- serverless task support for
-- external access integrations has not been confirmed.

CREATE OR REPLACE TASK {{ database }}.{{ schema_raw }}.T_PAYROLL_INGEST
    WAREHOUSE = {{ warehouse }}
    SCHEDULE  = 'USING CRON 0 6 * * * UTC'
    COMMENT   = 'Daily payroll ingestion from SharePoint. Calls SP_INGEST_PAYROLL_FILES.'
AS
    CALL {{ database }}.{{ schema_raw }}.SP_INGEST_PAYROLL_FILES(1);

-- Task is created suspended by default.
-- Resume only after all verification steps pass:
--   ALTER TASK {{ database }}.{{ schema_raw }}.T_PAYROLL_INGEST RESUME;
