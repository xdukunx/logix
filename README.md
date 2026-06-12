# Logix

> **Log · Track · Integrate** — an access logbook for a shared lab workstation.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![CI](https://img.shields.io/badge/CI-py__compile%20%2B%20import%20smoke-brightgreen.svg)](.github/workflows/ci.yml)
[![status: reference](https://img.shields.io/badge/status-reference%20publication-orange.svg)](#status)
[![PII: local only](https://img.shields.io/badge/PII-local%20only-critical.svg)](#privacy--read-this-first)

Logix records **who** used a machine, **how**, and **when** — across three
session types: SSH, AnyDesk (remote), and physical (at the keyboard). It
produces attendance / audit reports from a local database.

Built for the **MindLab** computational-chemistry workstation (a shared
Windows + WSL2 box). It's published as a reference; adapt paths and detection
to your environment.

---

## How it works

```
  SSH login ─────┐
  AnyDesk login ─┼──►  log_physical.py  ──►  notify.db  ──►  logbook_report.py
  Physical (WPF) ┘     (idempotent bridge)   (SQLite)       (Excel: hrs/user/type)
   sign-in popup
```

All three capture paths write through **one idempotent bridge**
(`log_physical.py`) into a local SQLite database. Re-running never
double-counts a session. An Excel report (`logbook_report.py`) summarizes
hours per user, per session type.

## What it captures

| Session type | How it's detected | Source |
|---|---|---|
| **SSH** | a `profile.d` hook logs interactive SSH logins once per session, closes them on logout | `logbook_ssh_login.py`, `zz_logbook_ssh.sh` |
| **AnyDesk** | remote-desktop access detected at login | `log_physical.py` |
| **Physical** | a Windows lock/unlock **WPF sign-in popup** records who's at the keyboard | `windows/logbook_popup.ps1` |

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
leaves the box. See [`docs/GSHEET_SYNC_DESIGN.md`](docs/GSHEET_SYNC_DESIGN.md).
Not yet implemented.

## Layout

```
logix/      Linux capture + bridge + reporting (Python + shell)
windows/    PowerShell popup + monitor scripts (WPF sign-in UI)
docs/       design docs (GSheet sync, Claude Code handoff)
examples/   config.env.example — copy to config.env (gitignored)
```

## Quick start

> Logix is environment-specific. These steps describe the shape of a deploy;
> adapt paths to your box.

1. **Configure.** Copy the example config and point it at your database:
   ```bash
   cp examples/config.env.example config.env
   # edit config.env — set NOTIFY_DB to your SQLite path. config.env is gitignored.
   ```
2. **Linux capture.** Install the SSH hook (`zz_logbook_ssh.sh`) into
   `/etc/profile.d/`. SSH/AnyDesk logins flow through `log_physical.py`.
3. **Windows physical capture.** Register the popup tasks with
   `windows/install_logbook_tasks.ps1` (lock/unlock triggers the WPF sign-in).
4. **Report.** Generate the Excel summary:
   ```bash
   python logix/logbook_report.py    # reads NOTIFY_DB, writes an .xlsx (gitignored)
   ```

## Customization

- **Paths / DB location** — all via `config.env` (gitignored), never inline
  constants. The Linux side reads `NOTIFY_DB`.
- **The physical sign-in UI** (`windows/logbook_popup.ps1`) is a WPF form and
  is intentionally site-specific — keep your own faculty/lab branding and
  fields here. It's the natural place to add per-system or per-user
  customization without touching the capture/report core.
- The capture and report core is **stdlib-only by design** — keep new
  third-party dependencies isolated (see the GSheet sync design).

## Development

```bash
python -m py_compile logix/*.py     # what CI checks: parse + import on a synthetic DB
```

CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) compiles the
modules and runs an import smoke test against a **synthetic** database only —
never real PII.

## License

[MIT](LICENSE).
