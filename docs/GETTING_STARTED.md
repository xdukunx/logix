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

## Part 2 — Central server + dashboard (preview — read this first)

> ### ⚠ Before you touch this section
> The server currently has a real authentication gap: **if you don't
> configure real Google OAuth credentials, anyone who can reach the server
> gets a full admin session automatically** (this is a known issue, tracked
> in [`SECURITY.md`](../SECURITY.md) and [`AUDIT_AND_ROADMAP.md`](AUDIT_AND_ROADMAP.md)).
> Until that's patched:
> - **Do not** expose this server to the public internet.
> - **Do not** run it somewhere untrusted people can reach it on the network.
> - If you do set it up, configure a real `GOOGLE_CLIENT_ID` /
>   `GOOGLE_CLIENT_SECRET` (see step 2 below) rather than leaving them blank —
>   leaving them blank is what triggers the bypass.
> This section exists so you can experiment on a trusted LAN or your own
> laptop, not to hand a student a public URL.

This part gives you a live dashboard showing which machines are active and
lets you browse session logs from a browser, on one central machine.

### 1. Install server dependencies

On the machine that will act as the server (your spare PC / mini-PC / Pi):

```bash
cd server
pip install -r requirements.txt --break-system-packages   # or use a venv
```

### 2. Configure it

Copy the example env file and fill it in:

```bash
cp server/.env.example server/.env
```

At minimum, set:

- `ADMIN_EMAILS` — comma-separated Google account emails allowed to sign in.
- `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` — from Google Cloud Console
  (OAuth 2.0 Client, "Web application" type). **Leaving these blank is the
  bypass mentioned above — don't skip this if anyone besides you can reach
  the machine.**
- `GOOGLE_REDIRECT_URI` — must exactly match what you register in Google
  Cloud Console, e.g. `http://<server-ip>:8000/api/auth/callback`.

Load the file before starting the server (exact command depends on your
shell — `export $(cat server/.env | xargs)` on bash, or use a process
manager that reads `.env` files for you).

### 3. Run it

```bash
cd server
uvicorn main:app --host 0.0.0.0 --port 8000
```

Then open `http://<server-ip>:8000` in a browser. If OAuth is configured
correctly, you'll see a "Sign in with Google" screen.

### 4. Point a device at it

On a device that already has the core installed (Part 1), edit its
`config.env` (in the install directory from Part 1) and add:

```
LOGIX_SERVER_URL="http://<server-ip>:8000"
```

The next time an event is logged on that device, `log_physical.py` will try
to push any unsynced rows to `/api/log` on the server. Note: as of today the
server does **not** yet validate an API key on that endpoint (also tracked in
the security doc) — this works, but treat it as a LAN-only, trusted-network
feature for now, not something to expose publicly.

### What's genuinely not built yet

To set expectations correctly — these are **designed, not implemented**:

- An installer flag to pick "server" vs "device" role. Today, "being the
  server" just means running `uvicorn` in `server/`, and "being a device"
  just means setting `LOGIX_SERVER_URL` in `config.env`. There's no wizard.
- Enrollment tokens / a device registry / device categories.
- The mascot / branded onboarding UI.
- Enforced privacy modes (`local_only` / `redacted_sync` / `admin_full_sync`)
  — right now, if `LOGIX_SERVER_URL` is set, everything in the local table
  gets pushed as-is.

See [`AUDIT_AND_ROADMAP.md`](AUDIT_AND_ROADMAP.md) for the plan to build
these.

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
