# Logix

**Log, Track, Integrate** — an access logbook for a shared lab workstation.

Logix records who used a machine, how, and when — across three session
types: SSH, AnyDesk (remote), and physical (at the keyboard). It produces
attendance/audit reports from a local database.

Built for the MindLab computational chemistry workstation (a shared
Windows + WSL2 box). It's published as a reference; adapt paths and detection
to your environment.

## What it captures

- **SSH sessions** — a `profile.d` hook logs interactive SSH logins once per
  session and closes them on logout.
- **AnyDesk sessions** — remote-desktop access detected at login.
- **Physical sessions** — a Windows lock/unlock popup records who's at the
  keyboard, with a sign-in form.

All three write through one idempotent bridge (`log_physical.py`) into a
local SQLite database. An Excel report (`logbook_report.py`) summarizes hours
per user per session type.

## Privacy — read this first

Logix processes personal data: names, student IDs (NIM), and client IP
addresses. By design:

- **All PII stays in the local database.** It never leaves the workstation.
- The repository contains code only. The database, session JSON, reports, and
  logs are git-ignored and must never be committed.
- If you deploy this, you are responsible for the data it collects. Inform
  users that sessions are logged, and follow your institution's data rules.

## Status

Current: local capture + Excel reporting, working.

Planned: optional one-way sync to a shared Google Sheet for live reporting —
**with a redaction gate** that strips IPs and reduces names before anything
leaves the box. See `docs/GSHEET_SYNC_DESIGN.md`. Not yet implemented.

## Layout

    logix/      Linux capture + bridge + reporting (Python + shell)
    windows/    PowerShell popup + monitor scripts
    docs/       design docs (GSheet sync, Claude Code handoff)

## License

MIT.
