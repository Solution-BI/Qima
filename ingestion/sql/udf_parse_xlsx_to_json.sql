-- PARSE_XLSX_TO_JSON: standalone parsing UDF for the payroll ingestion pipeline.
--
-- Reads an xlsx file from a scoped stage URL, walks every sheet cell by cell,
-- and returns a VARIANT: { "SheetName": [[cell, ...], ...], ... }
--
-- No header detection, no layout interpretation. All structural knowledge
-- lives in transformation (HEADER_MAP), not here. See CLAUDE.md for why.
--
-- Properties:
--   1. Never raises. Returns {"_error": "..."} on any failure so one corrupt
--      file does not abort a batch MERGE.
--   2. Knows nothing about FILE_LOAD. The caller decides which rows to parse.
--
-- Usage:
--   SELECT PARSE_XLSX_TO_JSON(BUILD_SCOPED_FILE_URL(@my_stage, 'file.xlsx'));

CREATE OR REPLACE FUNCTION {{ database }}.{{ schema_raw }}.PARSE_XLSX_TO_JSON(FILE_URL VARCHAR)
RETURNS VARIANT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'openpyxl')
HANDLER = 'run'
AS $$
import io
from datetime import datetime
from openpyxl import load_workbook
from snowflake.snowpark.files import SnowflakeFile

def run(file_url):
    try:
        with SnowflakeFile.open(file_url, 'rb') as f:
            data = f.read()

        wb = load_workbook(io.BytesIO(data), read_only=True, data_only=True)
        workbook_data = {}

        for sheet_name in wb.sheetnames:
            ws = wb[sheet_name]
            rows = []
            for row in ws.iter_rows():
                cells = []
                for cell in row:
                    val = cell.value
                    if val is None:
                        cells.append(None)
                    elif isinstance(val, datetime):
                        cells.append(val.isoformat())
                    elif isinstance(val, (int, float, bool)):
                        cells.append(val)
                    else:
                        cells.append(str(val))
                rows.append(cells)
            workbook_data[sheet_name] = rows

        wb.close()
        return workbook_data

    except Exception as e:
        return {'_error': f'{type(e).__name__}: {e}'}
$$;
