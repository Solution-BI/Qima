"""Extract the two header rows for every template generation in FILE_LOAD.

Writes headers_observed.csv alongside this script - the raw input that
build_header_map.py turns into a HEADER_MAP seed. Read-only against Snowflake.

    python transformation/reference_data/header_map/extract_headers.py
"""
import csv, json, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "lib"))
from snowflake_helper import connect, query

OUT = Path(__file__).resolve().parent

SQL = """
select s.key as SHEET_NAME, array_size(s.value[1]) as N_COLS,
       min(f.LOAD_ID) as SAMPLE_LOAD_ID,
       any_value(s.value[0]) as ROW0, any_value(s.value[1]) as ROW1
from SANDBOX_DB.HR_PAYROLL_QIMA.FILE_LOAD f,
     lateral flatten(input => f.RAW_CONTENT) s
where s.key rlike '^[0-9]{4}$'
group by 1, 2, hash(s.value[1]::string)
order by 1, 2
"""

def is_blank(v):
    """True for None, empty, or whitespace-only - including the non-breaking
    spaces the 2024 sheets use in place of empty band cells."""
    return v is None or not str(v).replace(" ", " ").strip()


def forward_fill(band):
    """Row 0 is a merged group band: the label appears once, then blanks.

    Blank-looking cells are treated as merge continuation, so a band label
    carries forward across them.
    """
    out, cur = [], None
    for v in band:
        if not is_blank(v):
            cur = str(v)
        out.append(cur)
    return out

with connect() as conn:
    rows = query(conn, SQL)

OUT.mkdir(parents=True, exist_ok=True)
path = OUT / "headers_observed.csv"
n = 0
with path.open("w", newline="", encoding="utf-8") as fh:
    w = csv.writer(fh)
    w.writerow(["GENERATION", "SHEET_YEAR", "COLUMN_INDEX", "COLUMN_LETTER",
                "GROUP_HEADER", "SOURCE_HEADER", "SAMPLE_LOAD_ID"])
    for r in rows:
        gen = f"{r['SHEET_NAME']}-{r['N_COLS']}col"
        band = forward_fill(json.loads(r["ROW0"]))
        hdr = json.loads(r["ROW1"])
        for i, h in enumerate(hdr):
            letter = ""
            x = i
            while True:
                letter = chr(ord("A") + x % 26) + letter
                x = x // 26 - 1
                if x < 0:
                    break
            w.writerow([gen, r["SHEET_NAME"], i, letter,
                        band[i] if i < len(band) else None, h, r["SAMPLE_LOAD_ID"]])
            n += 1

print(f"{len(rows)} generations, {n} columns -> {path}")
for r in rows:
    print(f"  {r['SHEET_NAME']}-{r['N_COLS']}col")
