# Going live: GSheet sync

This is the operator runbook for turning on the optional one-way Google Sheet
mirror. The local SQLite stays the source of truth; an hourly job pushes a
**redacted, aggregated** view (hours per member per session-type per day — no
IPs, no raw student IDs, no names). Design + guarantees:
[`GSHEET_SYNC_DESIGN.md`](GSHEET_SYNC_DESIGN.md).

You should not need to edit any code — only supply two things: a **spreadsheet
id** and a **service-account key**.

## 1. Install the core (if you haven't)

```bash
sudo ./install/install.sh        # Linux / macOS
.\install\install.ps1            # Windows (elevated)
```

## 2. Create a Google service account + sheet

1. In Google Cloud Console: create (or pick) a project and **enable the Google
   Sheets API**.
2. Create a **service account**; under *Keys*, add a **JSON key** and download
   it. Save it somewhere outside the repo, e.g. `/secure/service_account.json`
   (or `C:\secure\service_account.json`). **Never commit this file.**
3. Create the target Google Sheet. **Share it (Editor) with the service
   account's email** (`...@...iam.gserviceaccount.com`). Without this share the
   sync cannot write.
4. Note the spreadsheet **id** — the long token in the URL
   `https://docs.google.com/spreadsheets/d/<THIS>/edit`.

## 3. Configure + go live (one command)

```bash
# Linux / macOS
sudo python3 install/setup_sync.py \
    --sheet-id <SPREADSHEET_ID> \
    --creds /secure/service_account.json \
    --mode initials \
    --salt "$(openssl rand -hex 16)" \
    --install-deps --check --schedule

# Windows (elevated PowerShell)
python install\setup_sync.py `
    --sheet-id <SPREADSHEET_ID> `
    --creds C:\secure\service_account.json `
    --mode initials --install-deps --check --schedule
```

Run with no flags to be prompted for each value interactively. What it does:

- writes the settings into the installed `config.env` (only the *path* to your
  key is stored — never the key itself);
- `--install-deps` installs `gspread` + `google-auth` (from
  [`requirements-sync.txt`](../requirements-sync.txt));
- `--check` verifies it can authenticate and open the sheet;
- `--schedule` registers an **hourly** job for your OS: a systemd timer
  (`logix-sync.timer`), a launchd daemon (`com.mindlab.logix-sync`), or a Task
  Scheduler task (`LogixGSheetSync`). Removal commands are printed after setup.

## 4. Verify

```bash
# Preview exactly what would be pushed — no creds, no network, no writes:
python <install-dir>/gsheet_sync.py --dry-run

# Confirm live connectivity (auth + open sheet), still writing nothing:
python <install-dir>/gsheet_sync.py --check

# Force a sync now (the schedule also runs it hourly):
python <install-dir>/gsheet_sync.py
```

`<install-dir>` is `/opt/software/logix`, `/Library/Application Support/Logix`,
or `C:\ProgramData\Logix`.

## Redaction modes

`--mode` / `LOGIX_REDACT_MODE`:

| mode | member column shows | notes |
|---|---|---|
| `initials` (default) | `B.S.` | no salt needed |
| `hash` | `u-3f9a2c10ab` | salted one-way; keep `LOGIX_GSHEET_SALT` stable |
| `code` | `M-3F9A` | salted opaque code; keep the salt stable |

**Keep the salt stable** across runs, or member tokens change and the sheet
will accumulate parallel rows. Changing the salt is how you'd deliberately
rotate identities.

## Safety properties (enforced, tested)

- The exporter reads the DB **read-only** — a bad key or network outage can
  never corrupt local data.
- The redaction gate is a **whitelist**: only date / member-token /
  session_type / hours can ever be emitted. Verified by tests across all modes.
- The upsert is **idempotent** (keyed by `date|member|session_type`), so
  re-runs update in place instead of duplicating rows.
