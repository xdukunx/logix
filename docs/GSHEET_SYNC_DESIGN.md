# Logix GSheet sync — design

Status: **redaction core + aggregation + idempotent upsert implemented and
unit-tested** in [`logix/gsheet_sync.py`](../logix/gsheet_sync.py)
(tests: [`tests/test_gsheet_sync.py`](../tests/test_gsheet_sync.py)). The live
Google push (`gspread`) is implemented but isolated behind a lazy import and
not yet validated against a real service account + sheet. The redaction rules
below are the contract the code enforces.

## Goal

Give the lab a live(ish) shared view of workstation usage without exporting
personal data to the cloud. The local SQLite stays the source of truth; an
hourly job pushes a REDACTED, aggregated view to a Google Sheet.

## Hard requirements (privacy-first — these are not optional)

1. **One-way only.** DB -> Sheet. The sheet is a read mirror. Logix never
   reads the sheet back. Anyone editing the sheet cannot corrupt the truth.

2. **Redaction gate before any write.** Raw rows never leave the box. The
   exporter transforms each record:
   - client IP: DROPPED entirely. Never goes to the sheet.
   - name: reduced to initials, OR a salted hash, OR an opaque member code.
     Decide which at deploy time; default to initials.
   - NIM (student ID): DROPPED, or replaced by the same opaque member code.
   - keep: session_type, date, duration/hours. These are the audit signal.
   The sheet shows AGGREGATE hours per member per type per day — not raw
   individual session rows with identifiers.

3. **Service-account auth, not OAuth user flow.** A Google service account
   with the target sheet shared to its address. The JSON key file lives
   outside the repo (gitignored as service_account.json) and is referenced
   by path via config.env. It is NEVER committed.

4. **Idempotent upsert.** Key each sheet row by a stable synthetic id
   (e.g. date+member_code+session_type) so re-running the export updates in
   place instead of duplicating. (Echoes the ghost-duplicate lesson from the
   logbook's own history — dedupe at write time.)

## Mechanism

- A new module, `logix/gsheet_sync.py`, reads the local DB, runs each row
  through `redact()`, aggregates, and upserts to the sheet via the Google
  Sheets API.
- Triggered hourly by a systemd timer (or Windows Task). Best-effort: if the
  sheet or network is down, the local DB is unaffected and the next run
  catches up.
- Config (config.env, gitignored):
    LOGIX_GSHEET_ID=...                 # the spreadsheet id
    LOGIX_GSHEET_CREDS=/path/service_account.json
    LOGIX_REDACT_MODE=initials          # initials | hash | code

## Dependencies

This is the one place Logix needs third-party libs (google-api-python-client
or gspread). Keep them isolated to gsheet_sync.py so the core capture/report
path stays dependency-light.

## Test plan (when built)

- redact() never emits a client IP or raw NIM (unit test on sample rows).
- two export runs produce no duplicate sheet rows (idempotent upsert).
- missing creds / network failure does not touch or corrupt the local DB.
- a name maps to a stable code across runs (same input -> same output).
