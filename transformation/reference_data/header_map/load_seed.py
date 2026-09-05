import sys, csv, pathlib
sys.path.insert(0, r"C:\Users\gerard.avena\Projects\snowflake-project-qima\tools")
from snowflake_helper import connect, query

ROOT = pathlib.Path(r"C:\Users\gerard.avena\Projects\snowflake-project-qima")
SEEDS = [
    ("HEADER_MAP",     ROOT/"transformation/reference_data/header_map/header_map_seed.csv"),
    ("FILE_EXCLUSION", ROOT/"transformation/reference_data/file_exclusion/excluded_files.csv"),
]

def cast_for(sf_type: str, pos: int) -> str:
    """Positional stage reference, cast to the target column's type.
    nullif('') matters: the CSV writes an unset value as an empty field."""
    t = sf_type.upper()
    expr = f"nullif(${pos}, '')"
    if t.startswith("NUMBER"):    return f"try_to_number({expr})"
    if t.startswith("BOOLEAN"):   return f"try_to_boolean({expr})"
    if t.startswith("DATE"):      return f"try_to_date({expr})"
    if t.startswith("TIMESTAMP"): return f"try_to_timestamp_tz({expr})"
    return expr

with connect() as c:
    cur = c.cursor()
    cur.execute("use schema SANDBOX_DB.HR_PAYROLL_QIMA")
    for table, path in SEEDS:
        cols = next(csv.reader(path.open(encoding="utf-8")))
        types = {r["name"]: r["type"] for r in query(c, f"desc table {table}")}
        missing = [x for x in cols if x not in types]
        if missing:
            print(f"    ABORT {table}: CSV columns not in table: {missing}"); continue

        uri = "file://" + str(path).replace("\\", "/")
        cur.execute(f"remove @%{table}")
        cur.execute(f"put '{uri}' @%{table} auto_compress=true overwrite=true")

        select = ",\n       ".join(cast_for(types[col], i + 1) for i, col in enumerate(cols))
        cur.execute(f"""
            insert into {table} ({', '.join(cols)})
            select {select}
            from @%{table}/{path.name}.gz (file_format => FF_HEADER_MAP_CSV)""")
        print(f"=== {table}: inserted {cur.rowcount} rows from {path.name}")
        cur.execute(f"remove @%{table}")

    print("\n=== HEADER_MAP by generation")
    for r in query(c, """select GENERATION, GENERATION_STATUS, count(*) as COLS,
                                count_if(NEEDS_REVIEW) as NEEDS_REVIEW
                         from HEADER_MAP group by 1,2 order by 1"""):
        print(f"    {r['GENERATION']:<12} {r['GENERATION_STATUS']:<10} cols={r['COLS']:<4} needs_review={r['NEEDS_REVIEW']}")
    print("\n=== files that will be processed")
    for r in query(c, "select LOAD_ID, FILE_NAME from V_PAYROLL_FILE_CURRENT order by LOAD_ID"):
        print(f"    [{r['LOAD_ID']}] {r['FILE_NAME']}")
