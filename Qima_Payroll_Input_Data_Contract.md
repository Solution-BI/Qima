# Qima HR Payroll – Input Data Contract

**Between:** Qima subsidiary/local HR submitters (producers) and the SBI-built platform (consumer of the submission, before any transformation).

**Status:** draft. Several sections describe what's actually true of the files we've seen; a few describe what we'd need Qima to formally agree to, and are marked as such. Nothing marked "confirmed" here is invented – it's either from the three dummy files analysed, or from something said directly by Antoine or Tess on 27 August. Everything else is a proposal.

**What this is not:** an automatically enforced schema, the way an API contract might be. Qima's local HR staff fill in a spreadsheet by hand; there's no validator standing between them and SharePoint. This document is the agreed definition of "valid," enforced on our side by the data quality checks in ingestion and transformation, not by anything blocking the submitter.

---

## 1. Delivery mechanics

| Aspect | Expectation | Source |
|---|---|---|
| Format | .xlsx workbook | confirmed, all 3 sample files |
| Location | SharePoint, one folder per payroll owner (not one folder per subsidiary – an owner covering multiple subsidiaries shares a folder) | confirmed, 27 Aug meeting (Tess, Antoine) |
| Sheet structure | One sheet per calendar year (e.g. "2024", "2025", "2026"), plus an "Instructions" sheet | confirmed, all 3 sample files |
| Cadence | Monthly, by the 3rd working day of the month | confirmed, 27 Aug meeting (Deepanjali, Tess). Tess flagged "3rd of the month" as currently interpreted too literally – should be 3rd *working* day, not yet corrected in practice |
| Restatement behaviour | Each monthly submission restates the full year to date, not just the new month | confirmed, prior discovery-pack findings |
| Ownership / escalation contact | One named contact per folder, for alerting on file errors | proposed by Antoine (27 Aug), not yet built – **we don't have the actual folder-to-owner name list from Qima yet, needed before this is usable** |

## 2. Known template generations

Seven distinct column layouts observed across the three sample files (by year and column count) – this is what the platform's HEADER_MAP is built against today:

| Generation | Columns | Component groups present | Measure basis |
|---|---|---|---|
| 2024-89col | 88 | SALARY, BONUS, COMMISSION | PAYMENT, RATE |
| 2024-91col | 88 | SALARY, BONUS, COMMISSION | PAYMENT, RATE |
| 2025-91col | 91 | SALARY, BONUS, COMMISSION, EXTERNAL | PAYMENT, RATE, FEE |
| 2025-95col | 95 | SALARY, BONUS, COMMISSION, EXTERNAL | PAYMENT, RATE, FEE |
| 2025-96col | 96 | SALARY, BONUS, COMMISSION, EXTERNAL | PAYMENT, RATE, FEE |
| 2026-67col | 67 | SALARY, BONUS, COMMISSION, EXTERNAL, ADHOC | PAYMENT, RATE, FEE |
| 2026-75col | 75 | SALARY, BONUS, COMMISSION, EXTERNAL, ADHOC | PAYMENT, RATE, FEE |

**Important caveat, already flagged once and repeating deliberately: this is only what's present in the three dummy files we have.** Antoine confirmed all subsidiary templates are otherwise standardised, but Greg raised directly in the 27 Aug meeting that if these three files represent only a small fraction of Qima's real subsidiaries, there could be generations or variants not yet seen. This table should be treated as a starting point to be validated against the real file set, not a closed list.

## 3. Structural conventions tolerated

These are known oddities in the template that the platform is built to accept rather than reject, because rejecting them would mean rejecting every file received to date:

- **Two header rows** on every sheet, not one.
- **Ad hoc bonuses recorded horizontally**, while every other component is recorded vertically – Tess's own words were "not good practice," and she suspects it happened because a one-off bonus for a new entity didn't warrant a new column at the time. Accepted as-is; a future template revision may remove it, per Tess/Antoine's offline discussion, but nothing is committed.
- **Currency columns present in 2024–2025, dropped in 2026.** Earlier generations included a locally-converted USD figure using inconsistent, unknown FX rates; 2026 dropped it and reports local/contract currency only. FX normalisation stays out of scope regardless of generation.
- **Employee attribute columns shrinking over time.** 2024/2025 carried more descriptive employee fields; 2026 stripped most of them back, per Tess's explanation that duplicate manual entry (once in the HRIS, once in this file) was causing discrepancies.

## 4. Field expectations

Rather than repeating all ~600 header-to-role mappings here (they change per generation and are already captured, generation by generation, in the platform's HEADER_MAP reference table), this contract defines the logical categories every generation is expected to map into:

- **Component groups:** SALARY, BONUS, COMMISSION, EXTERNAL (agency/vendor fees), ADHOC.
- **Measure basis:** PAYMENT (an amount actually paid), RATE (a contractual position, not a payment), FEE (external headcount cost, excluded from compensation totals).
- **Period type:** MONTH, QUARTER, or FY, depending on the component.

Any new column in a future submission is expected to map to one of these categories. A column that doesn't is a **convention-class** data quality issue (see section 6), not an automatic rejection – but it does mean the file is missing something in the model until HEADER_MAP is updated to cover it.

## 5. Mandatory vs informative fields

**Employee SAP ID is the only field the platform treats as authoritative from this file.** Every other employee attribute (name, position, subsidiary, and anything else describing the person rather than the payment) is informative only – confirmed directly by both Tess and Antoine on 27 August. Downstream, descriptive employee data resolves from Qima's HR system, not from what's typed into this template. The one exception is subsidiary, which Antoine explicitly confirmed needs to be captured as a point-in-time fact tied to the payment, not resolved live – because if an employee transfers subsidiary, the platform needs to know which subsidiary they were under *at the time of that specific payment*.

## 6. Data quality expectations

Every field-level issue is expected to fall into one of four classes, each with a different treatment:

| Class | Example from what we've actually seen | Treatment |
|---|---|---|
| Structural | File can't be opened, or a sheet is fundamentally unreadable | Reject the file (or the sheet, decision pending – see the ingestion design doc) |
| Identity | Mismatched SAP ID between the payroll file and Qima's HR system (confirmed pattern per Deepanjali) | Load, flag, exclude from GOLD until resolved |
| Value | Salary entered as text instead of a number (confirmed pattern per Deepanjali); salary recorded in the wrong month's column | Load, flag, keep in GOLD with the flag visible |
| Convention | A new column that doesn't map to any known component | Auto-resolve where possible, log for HEADER_MAP update |

## 7. Change management – open, not yet agreed

There is currently no process for Qima notifying SBI before a template changes. This is the single biggest gap in this contract, not a minor detail – everything in section 2 depends on knowing about a structural change before it silently shows up as a wall of convention-class flags. Proposed (not yet agreed): Antoine or Tess notifies SBI of any planned column addition, removal, or rename before the next submission cycle it affects.

## 8. Open items still needing Qima's confirmation

- Folder-to-owner contact list, for alerting.
- Confirmation of whether the three sample files are representative of all subsidiaries, or a small subset.
- Formal sign-off on the change-notification process in section 7.
- Whether the replacement/correction policy (does a resubmission overwrite silently or surface as a restatement) applies uniformly across all component types, or differs by type – still open per the 27 Aug meeting.
