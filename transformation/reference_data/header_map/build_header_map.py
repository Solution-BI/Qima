"""Draft a HEADER_MAP seed from the observed template headers.

Input :  headers_observed.csv   (every column of every generation in FILE_LOAD)
Output:  header_map_seed.csv    (one mapping row per column, for human review)
         header_map_review.md   (what could not be classified with confidence)

The output is a DRAFT. Anything this script is unsure about is marked
NEEDS_REVIEW = TRUE with a reason, and is expected to be corrected by hand
before the seed is loaded. Per the input data contract, a column that maps to
nothing is a convention-class issue to log - never a reason to reject a file.

Categories come from Qima_Payroll_Input_Data_Contract.md section 4:
  COMPONENT_GROUP  SALARY | BONUS | COMMISSION | EXTERNAL | ADHOC (+ EMPLOYEE, OTHER)
  MEASURE_BASIS    PAYMENT | RATE | FEE (+ ELIGIBILITY, CURRENCY, ATTRIBUTE)
  PERIOD_TYPE      MONTH | QUARTER | FY

CURRENCY_SCOPE is ours, not the contract's. The 2024/2025 generations carry a
second copy of most amounts converted to USD at unknown FX rates; the contract
puts FX normalisation out of scope, so those columns must be distinguishable
and excluded from GOLD rather than summed alongside local-currency values.

Usage:  python transformation/reference_data/header_map/build_header_map.py
"""

from __future__ import annotations

import csv
import re
from pathlib import Path

HERE = Path(__file__).resolve().parent
SRC = HERE / "headers_observed.csv"
OUT_SEED = HERE / "header_map_seed.csv"
OUT_REVIEW = HERE / "header_map_review.md"

# --- band -> component ------------------------------------------------------
# Ordered: the first match wins. Some bands name two schemes (e.g. "13th Month
# salary ... BD Eid Festival Bonus (Mar)"); the leading one is the component,
# which is why 13th month and Christmas are tested before Eid.
BAND_RULES: list[tuple[str, str, str]] = [
    (r"employee (information|basic data)",      "EMPLOYEE",   "EMPLOYEE_ATTR"),
    (r"contractual salary|salary detail",       "SALARY",     "CONTRACT_SALARY"),
    (r"monthly (actual )?total salary cost",    "SALARY",     "MONTHLY_SALARY"),
    (r"year-end bonus",                         "BONUS",      "YEAR_END"),
    (r"half-year bonus",                        "BONUS",      "HALF_YEAR"),
    (r"13th month s[la]+ry",                    "BONUS",      "THIRTEENTH_MONTH"),
    (r"aguinaldo",                              "BONUS",      "AGUINALDO"),
    (r"christmas bonus",                        "BONUS",      "CHRISTMAS"),
    (r"holiday bonus",                          "BONUS",      "HOLIDAY"),
    (r"profit sharing",                         "BONUS",      "PROFIT_SHARING"),
    (r"cclab bonus",                            "BONUS",      "CCLAB"),
    (r"gratuity",                               "BONUS",      "GRATUITY"),
    (r"eid festival bonus \(paid in feb\)",     "BONUS",      "EID_FESTIVAL_FEB"),
    (r"eid festival bonus \(paid in april\)",   "BONUS",      "EID_FESTIVAL_APR"),
    (r"auditor bonus",                          "BONUS",      "AUDITOR"),
    (r"commission ?/ ?quarterly bonus",         "COMMISSION", "COMMISSION"),
    (r"adhoc payment",                          "ADHOC",      "ADHOC"),
    (r"external hc",                            "EXTERNAL",   "EXTERNAL_HC"),
    (r"^other$",                                "OTHER",      "REMARK"),
]

# Component keywords detectable in the header text itself. Used only to catch a
# header that disagrees with its own band - a known template copy-paste class of
# error, e.g. "Eligible for Holiday Bonus" sitting under the Profit sharing band.
HEADER_COMPONENT_HINTS: list[tuple[str, str]] = [
    (r"year-end",                "YEAR_END"),
    (r"half-year",               "HALF_YEAR"),
    (r"13th month",              "THIRTEENTH_MONTH"),
    (r"aguinaldo",               "AGUINALDO"),
    (r"christmas",               "CHRISTMAS"),
    (r"holiday bonus",           "HOLIDAY"),
    (r"profit sharing",          "PROFIT_SHARING"),
    (r"cclab",                   "CCLAB"),
    (r"gratuity",                "GRATUITY"),
    (r"eid festible|eid festival", "EID_FESTIVAL"),
    (r"auditor bonus",           "AUDITOR"),
    (r"commission",              "COMMISSION"),
]

# --- resolved band/header conflicts ----------------------------------------
# Both classes below are defects in Qima's template, not in the data. They
# resolve in OPPOSITE directions, which is why neither can be a blanket rule.
#
# 1. "Eligible for Holiday Bonus" sits under the Profit sharing band in all five
#    2024/2025 generations. The column IS the profit-sharing eligibility flag -
#    the header text was copy-pasted from the Holiday block above it and never
#    corrected. The BAND wins.
# 2. "Commission (Currency)" sits under the Auditor Bonus band in both 2026
#    generations. Here the header is right: it is the commission currency
#    column, and the merged band simply runs one column too wide. The HEADER
#    wins.
#
# Both are worth raising with Qima under the contract's change-management gap
# (section 7) rather than being silently absorbed forever.
CONFLICT_RESOLUTIONS: dict[tuple[str, str], tuple[str, str, str]] = {
    ("PROFIT_SHARING", "HOLIDAY"): (
        "BONUS", "PROFIT_SHARING",
        "band wins: stale header text copy-pasted from the Holiday block"),
    ("AUDITOR", "COMMISSION"): (
        "COMMISSION", "COMMISSION",
        "header wins: merged Auditor band overruns into the Commission block"),
}

# --- generations that are not real submissions ------------------------------
# The SharePoint payroll tree has exactly three owner folders, so there are
# three real submission files. 2026-64col comes only from BR05_Payroll_Sample /
# BR02_Payroll_Sample - one item renamed - parked inside the live BR02 folder,
# 4 data rows, all duplicating BR02. It is a test artefact, not a template
# generation, and is now absent from SharePoint entirely.
#
# Its columns still load into HEADER_MAP so a sheet matching it can be
# recognised and rejected by name, rather than silently mapped as real payroll.
SAMPLE_GENERATIONS = {"2026-64col"}

MONTHS = {m: i for i, m in enumerate(
    ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"], start=1)}

# Headers that are annotations about the data rather than the data itself.
ANNOTATION_RE = re.compile(
    r"^(remark|remarks|correction steps|salary & bonus data issues|staff data issue|"
    r"employee class|payment type|agency name|no)$", re.I)


def norm(text: str | None) -> str:
    """Collapse whitespace (incl. embedded newlines and nbsp) and lowercase."""
    if text is None:
        return ""
    return re.sub(r"\s+", " ", str(text).replace("\xa0", " ")).strip().lower()


def classify_component(band: str, header: str) -> tuple[str, str, str | None]:
    """-> (component_group, component_name, conflict_note)"""
    b = norm(band)
    group = component = None
    for pattern, grp, comp in BAND_RULES:
        if re.search(pattern, b):
            group, component = grp, comp
            break
    if group is None:
        return "UNKNOWN", "UNKNOWN", f"band not recognised: {band!r}"

    # Does the header name a different scheme than its band?
    h = norm(header)
    for pattern, comp in HEADER_COMPONENT_HINTS:
        if re.search(pattern, h):
            if component.startswith(comp) or comp.startswith(component):
                break
            if group in ("EMPLOYEE", "SALARY", "OTHER"):
                break
            fix = CONFLICT_RESOLUTIONS.get((component, comp))
            if fix:
                return fix[0], fix[1], f"RESOLVED ({fix[2]})"
            return group, component, (
                f"header names {comp}, band says {component}")
    return group, component, None


def classify_measure(header: str, component: str) -> str:
    h = norm(header)
    if not h:
        return "ATTRIBUTE"
    if h.startswith("eligible"):
        return "ELIGIBILITY"
    if h == "currency" or h == "local currency" or "(currency)" in h or h.startswith("currency ("):
        return "CURRENCY"
    if h == "agency fee":
        return "FEE"
    if ANNOTATION_RE.match(h):
        return "ATTRIBUTE"
    if component == "EMPLOYEE_ATTR":
        return "ATTRIBUTE"
    if h.startswith("max"):
        return "RATE"          # a ceiling/entitlement, not money paid
    if component == "CONTRACT_SALARY":
        return "RATE"          # contractual position, per contract section 4
    if h.startswith("actual") or "paid" in h or "payout" in h or h.startswith("total salary"):
        return "PAYMENT"
    if component == "MONTHLY_SALARY":
        return "PAYMENT"
    if component == "ADHOC" and h == "bonus amount":
        return "PAYMENT"
    return "UNKNOWN"


def classify_period(header: str, band: str, sheet_year: str, component: str) -> tuple[str | None, str | None]:
    """-> (period_type, period_key)"""
    h = norm(header)

    # 2024 sheets store month headers as datetimes: 2024-03-01T00:00:00
    m = re.match(r"^(\d{4})-(\d{2})-\d{2}t", h)
    if m:
        return "MONTH", f"{m.group(1)}-{m.group(2)}"

    # Jan-2025 (LC) / Jan-2025 (USD)
    m = re.match(r"^([a-z]{3})[a-z]*-(\d{4})", h)
    if m and m.group(1) in MONTHS:
        return "MONTH", f"{m.group(2)}-{MONTHS[m.group(1)]:02d}"

    # "Actual salary Jan 2026", "Actual salary Sept 2026"
    m = re.search(r"\b([a-z]{3})[a-z]*\.? (\d{4})\b", h)
    if m and m.group(1) in MONTHS and component == "MONTHLY_SALARY":
        return "MONTH", f"{m.group(2)}-{MONTHS[m.group(1)]:02d}"

    # Quarters: "2026 Q3", "Actual Payout in Q3 (USD)"
    m = re.search(r"\bq([1-4])\b", h)
    if m:
        y = re.search(r"\b(20\d{2})\b", h)
        return "QUARTER", f"{y.group(1) if y else sheet_year}-Q{m.group(1)}"

    if h.startswith("total salary"):
        y = re.search(r"\b(20\d{2})\b", h)
        return "FY", (y.group(1) if y else sheet_year)

    if component in ("EMPLOYEE_ATTR", "REMARK", "EXTERNAL_HC", "CONTRACT_SALARY"):
        return None, None

    # Annual bonus schemes: the amount is for the sheet's year unless stated.
    y = re.search(r"\b(20\d{2})\b", h)
    return "FY", (y.group(1) if y else sheet_year)


def classify_currency_scope(header: str, band: str) -> str:
    """LOCAL, USD, or NA. 2024/2025 carry a USD copy at unknown FX rates."""
    blob = f"{norm(header)} {norm(band)}"
    if "(usd)" in blob or "cost (usd)" in blob:
        return "USD"
    if "(lc)" in blob or "local currency" in blob or "(local currency)" in blob:
        return "LOCAL"
    return "LOCAL"


def main() -> int:
    rows = list(csv.DictReader(SRC.open(encoding="utf-8")))
    out: list[dict] = []

    for r in rows:
        band, header = r["GROUP_HEADER"], r["SOURCE_HEADER"]
        group, component, conflict = classify_component(band, header)
        measure = classify_measure(header, component)
        ptype, pkey = classify_period(header, band, r["SHEET_YEAR"], component)
        scope = classify_currency_scope(header, band)

        reasons = []
        resolution = ""
        if conflict and conflict.startswith("RESOLVED"):
            resolution = conflict
        elif conflict:
            reasons.append(conflict)
        if group == "UNKNOWN":
            reasons.append("unmapped band")
        if measure == "UNKNOWN":
            reasons.append("measure basis not derivable from header")
        if not norm(header):
            reasons.append("header is blank in the source template")

        # Only amounts carry a period; eligibility/currency/attribute do not.
        if measure in ("ELIGIBILITY", "CURRENCY", "ATTRIBUTE"):
            ptype = pkey = None
        if measure in ("ELIGIBILITY", "ATTRIBUTE"):
            scope = "NA"

        out.append({
            "GENERATION": r["GENERATION"],
            "GENERATION_STATUS": "SAMPLE" if r["GENERATION"] in SAMPLE_GENERATIONS else "SUPPORTED",
            "SHEET_YEAR": r["SHEET_YEAR"],
            "COLUMN_INDEX": r["COLUMN_INDEX"],
            "COLUMN_LETTER": r["COLUMN_LETTER"],
            "GROUP_HEADER": band,
            "SOURCE_HEADER": header,
            "COMPONENT_GROUP": group,
            "COMPONENT_NAME": component,
            "MEASURE_BASIS": measure,
            "PERIOD_TYPE": ptype or "",
            "PERIOD_KEY": pkey or "",
            "CURRENCY_SCOPE": scope,
            "NEEDS_REVIEW": "TRUE" if reasons else "FALSE",
            "REVIEW_REASON": "; ".join(reasons),
            "RESOLUTION_NOTE": resolution,
        })

    with OUT_SEED.open("w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=list(out[0].keys()))
        w.writeheader()
        w.writerows(out)

    samples = [o for o in out if o["GENERATION_STATUS"] == "SAMPLE"]
    flagged = [o for o in out if o["NEEDS_REVIEW"] == "TRUE"]
    with OUT_REVIEW.open("w", encoding="utf-8") as fh:
        fh.write("# HEADER_MAP - columns needing human review\n\n")
        fh.write(f"{len(flagged)} of {len(out)} columns "
                 f"({100 * len(flagged) / len(out):.1f}%) could not be classified "
                 "with confidence.\n\n")
        by_reason: dict[str, list[dict]] = {}
        for o in flagged:
            by_reason.setdefault(o["REVIEW_REASON"], []).append(o)
        for reason, items in sorted(by_reason.items(), key=lambda kv: -len(kv[1])):
            fh.write(f"\n## {reason} ({len(items)})\n\n")
            fh.write("| Generation | Col | Band | Header |\n|---|---|---|---|\n")
            for o in items:
                hdr = o["SOURCE_HEADER"].replace("\n", " ").replace("|", "\\|")
                bnd = o["GROUP_HEADER"].replace("\n", " ").replace("|", "\\|")
                fh.write(f"| {o['GENERATION']} | {o['COLUMN_LETTER']} | {bnd[:45]} | {hdr[:60]} |\n")

    print(f"{len(out)} rows -> {OUT_SEED.name}")
    print(f"{len(samples)} rows belong to sample generations "
          f"({', '.join(sorted(SAMPLE_GENERATIONS))}) - loaded but never treated as real payroll")
    print(f"{len(flagged)} need review -> {OUT_REVIEW.name}\n")
    for key in ("COMPONENT_GROUP", "MEASURE_BASIS", "PERIOD_TYPE", "CURRENCY_SCOPE"):
        counts: dict[str, int] = {}
        for o in out:
            counts[o[key] or "(none)"] = counts.get(o[key] or "(none)", 0) + 1
        print(f"  {key}: " + ", ".join(f"{k}={v}" for k, v in sorted(counts.items())))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
