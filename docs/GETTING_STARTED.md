# Getting started with Logix

A walkthrough for setting up Logix today — as the code actually works right
now, not the roadmap. Two audiences, one guide:

- **If you're a student/staff member** using a machine that already has Logix
  installed, skip to [Using the sign-in popup](#using-the-sign-in-popup).
- **If you're the admin/IT person** installing Logix, read from the top.

> Two things worth knowing before you start:
> 1. The **core** (Part 1 below) is stable and safe to use as-is.
> 2. The **central server + dashboard** (Part 2) is a **preview**. Read the
>    warning box before running it — there's a real security gap you need to
>    know about.

---

## Part 1 — Core install (one machine, no server needed)

This is enough on its own if you just want local session logging + Excel
reports on a single shared computer, with no central dashboard.

### 1. Requirements

- Python 3.8+ installed and on your `PATH`.
- Admin/root access on the machine (the installer writes to a system
  directory).

### 2. Run the installer

```bash
# Linux / macOS
sudo ./install/install.sh

# Windows (PowerShell, run as Administrator)
.\install\install.ps1
```

There are no flags to choose — it always does the same thing: copies the core
files, writes a starter `config.env`, and initializes the local database. You
should see output like:

```
Logix installer - platform=linux
Install dir: /opt/software/logix
  copied paths.py
  copied log_physical.py
  copied logbook_report.py
  copied logbook_sql.py
  copied logbook_ssh_login.py
  copied gsheet_sync.py
  wrote config.env
  initialized logix.db
  wrote logix-ssh-hook.sh
```

(On Windows there's no SSH hook line — that piece is Linux/macOS only.)

**Where things land:**

| OS | Install directory |
|---|---|
| Linux | `/opt/software/logix` |
| macOS | `/Library/Application Support/Logix` |
| Windows | `C:\ProgramData\Logix` |

### 3. Wire up capture for this OS

The installer prints the exact next step for your platform. In short:

- **Linux/macOS**: it generates an SSH login hook; follow the printed
  `ln -sf` command to activate it. SSH logins will then log automatically.
- **Windows**: the physical sign-in popup is separate — see
  [`windows/logbook_setup.ps1`](../windows/logbook_setup.ps1) and the
  Task Scheduler entries it registers.

### 4. Generate a report

```bash
python <install-dir>/logbook_report.py
```

Writes an `.xlsx` into `<install-dir>/reports` with hours per user, per
session type.

### 5. (Optional) Mirror redacted data to a Google Sheet

This is documented in full in [`GOING_LIVE.md`](GOING_LIVE.md) — the short
version:

```bash
sudo python3 install/setup_sync.py --sheet-id <ID> --creds /secure/sa.json \
     --mode initials --install-deps --check --schedule
```

Nothing here talks to any central Logix server — it's a separate, optional
one-way push straight to Google Sheets.

---

## Using the sign-in popup

If your admin has set up the Windows popup on this machine, you'll see it
when you unlock or log in. Fill in your name/ID, pick the access type and
purpose, and submit. That's it — the system records the session start; it
does not record keystrokes, screenshots, or anything from your browser. See
[`PRIVACY.md`](PRIVACY.md) if you want the full explanation of what is and
isn't collected.

---

## Part 2 — Central server + dashboard

This part gives you a live dashboard showing which machines are active and
lets you browse session logs from a browser, on one central machine.

The defaults are locked down (see [`SECURITY.md`](../SECURITY.md)): without
real Google OAuth credentials the login simply refuses (503) rather than
letting anyone in, and devices must present an API key to push anything.
The two rules that remain yours to follow:

> - Never set `LOGIX_DEV_MODE=1` on a machine other people can reach — it
>   re-enables the local-development mock login.
> - Anything reachable beyond `localhost` belongs behind a TLS reverse
>   proxy (walkthrough in the README's "Running it for real" section).

### 1. Configure + install in one command

On the machine that will act as the server (your spare PC / mini-PC / Pi),
from a clone of this repo:

```bash
python3 install/setup_server.py --install-deps
```

It prompts for admin email(s) and Google OAuth credentials (from Google
Cloud Console: OAuth 2.0 Client, "Web application" type, redirect URI
`http://<server-ip>:8000/api/auth/callback` — must match
`GOOGLE_REDIRECT_URI` exactly), generates a strong device API key, and
writes everything to `server/.env`. Add `--service` (elevated) to also
start the server on every boot. Prefer doing it by hand? Copy
`server/.env.example` to `server/.env` and fill it in — the server
auto-loads that file on start.

### 2. Run it

```bash
cd server
uvicorn main:app --host 0.0.0.0 --port 8000
```

Then open `http://<server-ip>:8000` in a browser. If OAuth is configured
correctly, you'll see a "Sign in with Google" screen.

### 3. Point a device at it

On a device that already has the core installed (Part 1), edit its
`config.env` (in the install directory from Part 1) and add:

```
LOGIX_SERVER_URL="http://<server-ip>:8000"
LOGIX_SERVER_API_KEY="<the key setup_server.py printed>"
```

(Or answer the device installer's prompts — it asks for exactly these, and
can redeem a per-device enrollment code from the dashboard instead of the
shared key.)

The device then appears on the dashboard via its heartbeats, and remote
commands (lock, broadcast message) work. **Session rows are a separate,
deliberate step**: per [`PRIVACY.md`](PRIVACY.md), nothing from the local
logbook leaves the device unless `LOGIX_PRIVACY_MODE=admin_full_sync` is
set explicitly — the default (`local_only`) keeps all session data local
even with a server configured.

### What's genuinely not built yet

To set expectations correctly — these are **designed, not implemented**
(see [`LOGIX_CONTROL.md`](LOGIX_CONTROL.md) milestones 4-11):

- Open-website / approved-program remote commands.
- The branded lock-screen overlay.
- File transfer, screen thumbnails, remote view/control, power actions —
  all deliberately deferred until the auth/RBAC/audit foundations they
  require are proven in the field.
- The mascot / branded onboarding UI.

---

## Getting this onto your own GitHub

Nothing has been pushed anywhere by anyone but you — this repo only exists as
files here. Once you've downloaded the zip and unpacked it:

```bash
cd logix
git remote -v          # check what's already configured
git push origin main   # if you already have a remote set up
```

If you don't have a remote yet, create an empty repository on GitHub first
(don't initialize it with a README), then:

```bash
git remote add origin https://github.com/<you>/<repo>.git
git push -u origin main
```

---

## Troubleshooting quick reference

| Symptom | Likely cause |
|---|---|
| Installer says "Permission denied" | Re-run with `sudo` (Linux/macOS) or an Administrator shell (Windows). |
| `python: command not found` | Install Python 3.8+ and make sure it's on `PATH`. |
| Dashboard shows "Akses Ditolak" after Google sign-in | Your email isn't in `ADMIN_EMAILS`. |
| Device isn't showing as active in the dashboard | Check `LOGIX_SERVER_URL` is set in that device's `config.env`, and that it can reach the server's IP/port over the network. |
| `/api/reports` download fails on the server | Known bug — see `AUDIT_AND_ROADMAP.md` item C; the endpoint points at the wrong file path today. |
