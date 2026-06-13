# Logix — development roadmap

Living plan for what's built and what's next. Privacy rules in
[`GSHEET_SYNC_DESIGN.md`](GSHEET_SYNC_DESIGN.md) and the handoff in
[`CLAUDE_CODE_HANDOFF.md`](CLAUDE_CODE_HANDOFF.md) take precedence over this file.

## Done

- **Phase 1 — publication.** Privacy hygiene, MIT license, CI, `v0.1.0` tagged
  and pushed.
- **Cross-platform core + installer.** Logging bridge, report generator, and
  SQL helper run natively on Linux/macOS/Windows; one installer (`install/`)
  sets up a system-wide deploy. Path/config resolution centralized in
  `logix/paths.py`.
- **GSheet sync core (Phase 2a).** `logix/gsheet_sync.py`: redaction gate
  (whitelist → date/member/session_type/hours), stable one-way member tokens
  (initials | hash | code), hourly aggregation, idempotent upsert keyed by
  `date|member|session_type`, read-only DB access. Unit-tested in `tests/` —
  the "no IP, no raw NIM ever leaves the box" guarantee is enforced by tests
  across all three redaction modes.

## Next

1. **Live Google push validation (Phase 2b).** *Blocked on credentials.*
   Needs a Google service account (JSON key) and a shared Sheet. Then:
   `pip install gspread google-auth`, set `LOGIX_GSHEET_ID` / `LOGIX_GSHEET_CREDS`
   / `LOGIX_REDACT_MODE` / `LOGIX_GSHEET_SALT` in `config.env`, and verify two
   runs produce no duplicate rows against the real sheet.
2. **Hourly scheduling.** Wrap `gsheet_sync.main()` in a systemd timer (Linux),
   launchd agent (macOS), or Task Scheduler job (Windows). Best-effort: a failed
   run never touches the local DB.
3. **Per-user popup customization.** Extend the Windows WPF popup
   (`windows/logbook_popup.ps1`) so fields/branding can vary per system/user
   without touching the capture core. Windows-side only.

## Won't do (by decision)

- A macOS/Linux GUI popup for physical "at-keyboard" capture. That's a separate
  native-UI project; physical capture stays Windows-only and SSH covers the
  POSIX side. (See the platform-support matrix in the README.)
