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

With no flags, it prompts for the handful of things that matter (device name,
central server URL/key, privacy mode) — blank answers are fine for local-only
use. For scripted/unattended installs, pass flags instead (same convention as
every other installer here — anything you don't pass gets prompted for):

```bash
sudo ./install/install.sh --non-interactive --device-name "Lab PC 3" \
     --server-url https://logix.example.org --server-api-key <key>
```

Run `install.py --help` (via either wrapper) for the full flag list. Either
way it copies the core files, writes a starter `config.env`, and initializes
the local database. You should see output like:

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
- **Windows**: the physical sign-in popup is a separate piece
  ([`windows/install_logbook_tasks.ps1`](../windows/install_logbook_tasks.ps1),
  registers the Task Scheduler entries and the WPF popup/timer). If you used
  the one-liner from the README ([`windows/bootstrap-client.ps1`](../windows/bootstrap-client.ps1)),
  this step is already done — skip ahead to
  [Using the sign-in popup](#using-the-sign-in-popup).

### 4. See the reports

On the device itself, open **Laporan Logix** (or run
`windows\logix_reports.ps1`). It opens a page on this computer only, showing
today / this week / this month / everything, with an `.xlsx` export. No server
and no terminal required — see
[DEVICE_AND_SERVER.md §5](DEVICE_AND_SERVER.md#5-reports-without-a-server).

The command-line generator still exists and is unchanged:

```bash
python <install-dir>/logbook_report.py
```

Writes an `.xlsx` into `<install-dir>/reports` with hours per user, per
session type. The export button produces the same file — both call the same
generator, so they cannot disagree.

### 5. Connect to a server (optional)

Open **Koneksi Server** on the device (or run `windows\logix_server.ps1`),
enter the server address and a single-use pairing code from your admin. The
same screen unpairs the device again; neither reinstalls anything, and
unpairing keeps every session already recorded locally.

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
the first time you sign in. Fill in your name/ID, pick the access type and
purpose, and submit. That's it — the system records the session start; it
does not record keystrokes, screenshots, or anything from your browser. See
[`PRIVACY.md`](PRIVACY.md) if you want the full explanation of what is and
isn't collected.

Locking the screen or letting the laptop sleep doesn't end your session —
it's still the same visit when you come back, no matter how long you were
away, and the timer widget just keeps going. Only a real sign-off ends it:
click **SELESAI** on the timer widget (it locks the workstation for you),
sign all the way out, or shut down/restart. The next person to sign in then
gets a fresh popup.

---

## Part 2 — Central server + dashboard

This part gives you a live dashboard showing which machines are active and
lets you browse session logs from a browser, on one central machine.

The defaults are locked down (see [`SECURITY.md`](../SECURITY.md)): without an
admin password set (`LOGIX_ADMIN_PASSWORD`) the login simply refuses rather
than letting anyone in, and devices must present an API key to push anything.
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

It prompts for admin email(s) and a single admin login password (use a strong
one — it's the only thing between the internet and the dashboard), generates a
strong device API key, and writes everything to `server/.env`. Add `--service`
(elevated) to also start the server on every boot. Prefer doing it by hand?
Copy `server/.env.example` to `server/.env` and fill in `ADMIN_EMAILS` +
`LOGIX_ADMIN_PASSWORD` — the server auto-loads that file on start.

### 2. Run it

```bash
cd server
uvicorn main:app --host 0.0.0.0 --port 8000
```

Then open `http://<server-ip>:8000` in a browser. You'll see the email +
password sign-in screen; log in with an `ADMIN_EMAILS` address and the
`LOGIX_ADMIN_PASSWORD` you set.

### 3. Point a device at it

**Fresh Windows lab PC, one line** (elevated PowerShell) does both the core
install and the sign-in popup agent, already pointed at your server:

```powershell
irm https://raw.githubusercontent.com/xdukunx/logix/main/windows/bootstrap-client.ps1 | iex
```

For mass deployment (imaging, a scripted rollout to many machines), download
then run with flags so it's fully unattended:

```powershell
iwr -useb https://raw.githubusercontent.com/xdukunx/logix/main/windows/bootstrap-client.ps1 -OutFile bootstrap-client.ps1
.\bootstrap-client.ps1 -ServerUrl "http://<server-ip>:8000" -ServerApiKey "<the key setup_server.py printed>" -DeviceName "WS-07"
```

Already has the core installed (Part 1) and just needs to be pointed at a
server? Either answer the device installer's prompts (it asks for exactly
this, and can redeem a per-device enrollment code from the dashboard instead
of the shared key), or edit `config.env` directly (in the install directory
from Part 1) and add:

```
LOGIX_SERVER_URL="http://<server-ip>:8000"
LOGIX_SERVER_API_KEY="<the key setup_server.py printed>"
```

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
| Login rejected ("Email atau password salah") | Email isn't in `ADMIN_EMAILS`, or the password doesn't match `LOGIX_ADMIN_PASSWORD`. In production, an empty `LOGIX_ADMIN_PASSWORD` rejects all logins by design. |
| Device isn't showing as active in the dashboard | Check `LOGIX_SERVER_URL` is set in that device's `config.env`, and that it can reach the server's IP/port over the network. |
| `/api/reports` download fails on the server | Known bug — see `AUDIT_AND_ROADMAP.md` item C; the endpoint points at the wrong file path today. |
