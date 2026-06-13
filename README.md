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
  AnyDesk login ─┼──►  log_physical.py  ──►  logix.db  ──►  logbook_report.py
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

Current: local capture + Excel reporting, working on all three OSes.

GSheet sync: the **privacy-first core** — a redaction gate (strips IPs, drops
raw NIMs, reduces names to a stable token), hourly aggregation, and idempotent
upsert — is implemented in [`logix/gsheet_sync.py`](logix/gsheet_sync.py) and
covered by tests ([`tests/`](tests/)). The live Google push is wired behind an
optional `gspread` dependency and awaits validation against a real sheet. See
[`docs/GSHEET_SYNC_DESIGN.md`](docs/GSHEET_SYNC_DESIGN.md) and
[`docs/ROADMAP.md`](docs/ROADMAP.md).

## Layout

```
logix/      cross-platform core: bridge + reporting + SQL helper (Python)
install/    one installer for all three OSes (install.py + launchers)
windows/    PowerShell popup + monitor scripts (WPF sign-in UI)
docs/       design docs (GSheet sync, Claude Code handoff)
examples/   config.env.example — copy to config.env (gitignored)
```

## Platform support

The **core** — session logging and Excel reporting — runs natively on Linux,
macOS, and Windows (no WSL required). The **capture** front-ends are
OS-specific by nature:

| Capability | Linux | macOS | Windows |
|---|:---:|:---:|:---:|
| Log bridge + Excel reporting + SQL query | ✅ | ✅ | ✅ |
| SSH login capture (`profile.d` / shell hook) | ✅ | ✅ | — |
| Physical at-keyboard sign-in (WPF popup) | — | — | ✅ |

> The physical-session popup is a Windows WPF app; macOS/Linux desktops would
> each need their own native UI, so that piece is intentionally Windows-only.

## Install

One installer, system-wide, no third-party dependencies (Python 3.8+ only):

```bash
# Linux / macOS
sudo ./install/install.sh

# Windows (elevated PowerShell)
.\install\install.ps1
```

It creates the system data dir (`/opt/software/logix`,
`/Library/Application Support/Logix`, or `C:\ProgramData\Logix`), installs the
core, writes a starter `config.env`, initializes the SQLite schema, and prints
the per-OS steps to wire up capture (SSH hook on Linux/macOS; the WPF popup on
Windows). Re-run any time to upgrade in place — it never clobbers your config
or database.

**Report:**
```bash
python logbook_report.py    # writes an .xlsx into <data-dir>/reports (gitignored)
```

## Going live with GSheet sync (optional)

Mirror a **redacted, aggregated** view to a Google Sheet on an hourly schedule.
After installing, you only supply a spreadsheet id and a service-account key —
no code editing:

```bash
# Linux / macOS (run with no flags to be prompted instead)
sudo python3 install/setup_sync.py --sheet-id <ID> --creds /secure/sa.json \
     --mode initials --install-deps --check --schedule
```

It writes the config, installs the Google libs, verifies sheet access, and
registers the hourly job (systemd / launchd / Task Scheduler). Preview what
would leave the box anytime — no creds needed:

```bash
python <install-dir>/gsheet_sync.py --dry-run
```

Full runbook: [`docs/GOING_LIVE.md`](docs/GOING_LIVE.md).

## Customization

- **Paths / DB location** — resolved by [`logix/paths.py`](logix/paths.py) in
  one place: environment variable → `config.env` → OS-aware default. `config.env`
  is parsed directly (no shell `source`), so the same file works on every OS.
  Key knobs: `LOGIX_HOME`, `LOGIX_DB`, `LOGBOOK_REPORT_DIR`.
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
modules and runs a log→query round-trip on **Linux, macOS, and Windows**, plus
a system-wide installer test — all against a **synthetic** database only, never
real PII.

## License

[MIT](LICENSE).
