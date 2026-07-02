# Logix

> **Log · Track · Integrate** — an access logbook for a shared lab workstation.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![CI](https://img.shields.io/badge/CI-compile%20%2B%20round--trip%20%2B%20unit%20tests-brightgreen.svg)](.github/workflows/ci.yml)
[![status: reference](https://img.shields.io/badge/status-reference%20publication-orange.svg)](#status)
[![PII: local only](https://img.shields.io/badge/PII-local%20only-critical.svg)](#privacy--read-this-first)

Logix records **who** used a machine, **how**, and **when** — across three
session types: SSH, AnyDesk (remote), and physical (at the keyboard). It
produces attendance / audit reports from a local database.

Built for the **MindLab** computational-chemistry workstation (a shared
Windows + WSL2 box). It's published as a reference; adapt paths and detection
to your environment.

<p align="center">
  <img src="docs/screenshots/login-screen.svg" alt="Logix admin login screen mockup" width="46%">
  &nbsp;&nbsp;
  <img src="docs/screenshots/admin-dashboard.svg" alt="Logix admin dashboard Monitoring tab mockup" width="46%">
</p>

<p align="center"><sub>Illustrative mockups of the central admin server's dashboard (<a href="#hosting-the-central-server-for-admins">optional, self-hosted</a>) — not live screenshots.</sub></p>

---

## Quick start

**On a lab workstation** (records sessions locally; no server required):

```bash
git clone https://github.com/xdukunx/logix.git
cd logix

# Linux / macOS
sudo ./install/install.sh

# Windows (elevated PowerShell)
.\install\install.ps1
```

That's it for local-only use. Full details, including the Windows sign-in
popup setup wizard, are in [Installing on a lab device](#installing-on-a-lab-device-for-users).

**Running a central admin server** (to see all your lab's workstations on one
dashboard): see [Hosting the central server](#hosting-the-central-server-for-admins) —
it's a `pip install` and one `python -m uvicorn` away for a quick local trial,
with a full production walkthrough (systemd, HTTPS, Google OAuth) for the
real thing.

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

See [docs/PRIVACY.md](docs/PRIVACY.md) for exactly what's collected and the
available privacy/sync modes, [SECURITY.md](SECURITY.md) for the server's
current hardening status, and [ETHICAL_USE.md](ETHICAL_USE.md) for what this
project is — and is explicitly not — meant to be used for.

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
server/     optional central admin server + dashboard (FastAPI) — see below
docs/       design + audit docs (roadmap, privacy, GSheet sync, getting started)
tests/      pytest suite: core round-trip, redaction gate, server hardening
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

## Installing on a lab device (for users)

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

**On Windows**, once the sign-in popup + monitor scheduled task are
installed, a small setup window opens automatically
(`windows/logbook_setup.ps1`) asking for:

| Field | Required? | Notes |
|---|---|---|
| **Nama Device** | Yes | How this workstation shows up on the admin dashboard — e.g. "Lab PC 3 (dekat pintu)" instead of a raw hostname like `LAB-PC-03`. Defaults to the hostname if you don't have a naming scheme yet. |
| **URL Server Administrasi** | No | Leave blank to run fully local (`privacyMode: local_only`, nothing leaves the device — see [Privacy](#privacy--read-this-first)). Fill in if an admin has a central server running (see the admin guide below) and gave you its URL. |
| **API Key Server** | No | Only needed if the server enforces `LOGIX_INGEST_API_KEY` (it should, outside dev mode). Get this from your admin. |
| **Kode Enrollment** | No | An admin-issued invite code (`POST /api/enroll/invite`, 15-minute TTL — see [`API_CONTRACT.md`](API_CONTRACT.md)). If filled, this device redeems it for its own per-device API key on save, replacing the shared key above. Recommended over a shared key for any real deployment. |

Use **Uji Koneksi** to verify the server URL/key actually reach a running
server before saving. You can re-run this setup window any time — it's
`C:\lab\logbook_setup.ps1` after install — to rename the device or update
server details. The device only appears on the admin dashboard once it
starts sending heartbeats (every 30s while the monitor is running).

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

## Hosting the central server (for admins)

[`server/`](server/) is a small FastAPI app for fleets of workstations: a
live dashboard (active machines by device name, session log search, usage
analytics), Excel report downloads, and remote lock/broadcast commands. It's
a separate, optional component — the core agent works standalone with zero
network dependency (`privacyMode: local_only` by default, see
[docs/PRIVACY.md](docs/PRIVACY.md)).

### Quick local run (evaluation only)

```bash
cd server
pip install -r requirements.txt
cp .env.example .env   # fill in and load before starting — see below
uvicorn main:app --host 0.0.0.0 --port 8000
```

It **must** be configured before any shared/production use — the defaults
are deliberately locked down, not deliberately open:

| Env var | Purpose |
|---|---|
| `LOGIX_DEV_MODE` | `0` (default) = production posture. `1` = local dev only: allows an unauthenticated mock admin login and permissive CORS. Never set `1` on a reachable server. |
| `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` | Google OAuth for the admin dashboard. Required for real auth outside dev mode. |
| `ADMIN_EMAILS` | Comma-separated allowlist of Google accounts permitted to sign in. |
| `LOGIX_INGEST_API_KEY` | Shared secret workstations send as `X-API-Key` when pushing logs/heartbeats. Required outside dev mode. Generate one with `openssl rand -hex 32`. |
| `LOGIX_ALLOWED_ORIGINS` | Comma-separated dashboard origins for CORS (used instead of a wildcard outside dev mode) — e.g. `https://logix.example.org`. |

See [SECURITY.md](SECURITY.md) for the server's current hardening status.

### Running it for real: a Linux host with systemd + a reverse proxy

The server has no built-in TLS and stores tokens/heartbeats in memory (lost
on restart, by design — see [SECURITY.md](SECURITY.md)) — it's meant to sit
behind a reverse proxy on a host you control, not exposed directly to the
internet.

1. **Get the code onto the server** and install dependencies into a venv:
   ```bash
   git clone https://github.com/xdukunx/logix.git /opt/logix
   cd /opt/logix/server
   python3 -m venv .venv
   .venv/bin/pip install -r requirements.txt
   ```

2. **Write a real `.env`** (copy `.env.example`, fill in `ADMIN_EMAILS`,
   Google OAuth credentials, a generated `LOGIX_INGEST_API_KEY`,
   `LOGIX_ALLOWED_ORIGINS` set to your real dashboard domain, and
   `LOGIX_DEV_MODE=0`). Keep this file outside the repo checkout or at least
   out of git (it already matches `.gitignore`'s `*.env` pattern) and
   readable only by the service account below.

3. **Run it as a systemd service**, not a foreground terminal, under a
   dedicated non-root user:
   ```ini
   # /etc/systemd/system/logix-server.service
   [Unit]
   Description=Logix central admin server
   After=network.target

   [Service]
   Type=simple
   User=logix
   WorkingDirectory=/opt/logix/server
   EnvironmentFile=/opt/logix/server/.env
   ExecStart=/opt/logix/server/.venv/bin/uvicorn main:app --host 127.0.0.1 --port 8000
   Restart=on-failure

   [Install]
   WantedBy=multi-user.target
   ```
   ```bash
   sudo useradd --system --no-create-home logix
   sudo chown -R logix:logix /opt/logix
   sudo systemctl enable --now logix-server
   ```
   Bind to `127.0.0.1`, not `0.0.0.0` — only the reverse proxy on the same
   host should reach it directly.

4. **Put nginx (or any reverse proxy) in front with TLS.** The dashboard
   sends session tokens and devices send API keys in headers — this must be
   HTTPS, not plain HTTP, on anything reachable beyond localhost:
   ```nginx
   server {
       listen 443 ssl;
       server_name logix.example.org;
       ssl_certificate     /etc/letsencrypt/live/logix.example.org/fullchain.pem;
       ssl_certificate_key /etc/letsencrypt/live/logix.example.org/privkey.pem;

       location / {
           proxy_pass http://127.0.0.1:8000;
           proxy_set_header Host $host;
           proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
       }
   }
   ```
   `certbot --nginx` handles issuing/renewing the certificate. Set
   `LOGIX_ALLOWED_ORIGINS` and `GOOGLE_REDIRECT_URI` to the same
   `https://logix.example.org` domain.

5. **Firewall**: only `443` needs to be open publicly. `8000` should stay
   bound to localhost, unreachable from outside the host.

### Pointing devices at it

Once the server is reachable, give each device's setup window (see the user
guide above) the server URL and the `LOGIX_INGEST_API_KEY` value — or set
directly in the device's `config.env`:

```bash
LOGIX_SERVER_URL=https://logix.example.org
LOGIX_SERVER_API_KEY=<same value as LOGIX_INGEST_API_KEY>
```

Devices appear on the dashboard, by whatever name was set during their
install, as soon as their next heartbeat arrives.

Per-invite-code device enrollment (so each device gets its own revocable
key instead of sharing one) is a locked design, not yet implemented — see
[API_CONTRACT.md](API_CONTRACT.md).

## Customization

- **Paths / DB location** — resolved by [`logix/paths.py`](logix/paths.py) in
  one place: environment variable → `config.env` → OS-aware default. `config.env`
  is parsed directly (no shell `source`), so the same file works on every OS.
  Key knobs: `LOGIX_HOME`, `LOGIX_DB`, `LOGBOOK_REPORT_DIR`.
- **The physical sign-in UI** (`windows/logbook_popup.ps1`) reads an optional
  JSON config so each system or user can rebrand and re-field it **without
  editing code**. Copy [`windows/logbook_config.example.json`](windows/logbook_config.example.json)
  to either location — later overrides earlier:
  1. built-in defaults (the original FTMM faculty UI),
  2. `C:\lab\logbook_config.json` (machine-wide),
  3. `%APPDATA%\MindLabLogbook\logbook_config.json` (per-user).

  Override any subset of: branding (logo text/image, title, subtitle, theme
  colors), all labels/hint text, the **access** and **purpose** dropdown
  options, and which fields are **required**. With no config file present the
  popup renders exactly as before.
- The capture and report core is **stdlib-only by design** — keep new
  third-party dependencies isolated (see the GSheet sync design).

## Development

```bash
python -m py_compile logix/*.py     # parse + import check
python -m pytest tests/ -q          # redaction gate, upsert, server hardening
```

CI ([`.github/workflows/ci.yml`](.github/workflows/ci.yml)) compiles the
modules, runs a log→query round-trip on **Linux, macOS, and Windows**, runs
the full `tests/` suite (including `tests/test_server_security.py`, the
server hardening smoke tests), and runs a system-wide installer test — all
against a **synthetic** database only, never real PII.

## License

[MIT](LICENSE).
