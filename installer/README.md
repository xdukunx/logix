# Logix Agent — wizard installer

`logix-agent.iss` builds **`LogixAgentSetup.exe`**, a single GUI wizard that
installs the Logix agent on any Windows device: sign-in/timer agent, AnyDesk 7
(for the dashboard **Remote** action), the native Python logging core, the
monitor scheduled task, and the central-server settings — all elevated and
unattended after the operator fills a couple of fields.

> **Two installers, same payload.** This Inno Setup wizard is the default. A
> compact **NSIS (Comnyang-style)** alternative lives in [nsis/](nsis/) — same
> install logic, smaller window, mascot strip, EN/ID picker. Use whichever look
> you prefer.

## What it installs
| Path | Contents |
|---|---|
| `C:\Program Files\Logix\` | agent scripts + bundled AnyDesk installer (read-only) |
| `C:\ProgramData\Logix\` | native Python core (`log_physical.py`, `paths.py`), `config.env` |
| `C:\ProgramData\MindLabLogbook\` | runtime state (created by the agent) |

The wizard runs `install_logbook_tasks.ps1 -NonInteractive -RunNow` under the
hood, which registers the monitor as a **non-elevated** scheduled task, installs
AnyDesk, writes `config.env`, and starts the agent.

## Branding (mascot)
The wizard shows the faculty mascot on a Logix-blue panel (Welcome/Finish
pages), a small logo in every inner-page header, a matching `.exe` icon, and
the same mascot in the sign-in popup — one source image drives all of it.

1. Drop the mascot at `installer/branding/mascot-source.png` (transparent PNG,
   ≥ 512×512, roughly square is best). See `installer/branding/README.md`.
2. `build.ps1` regenerates the assets automatically before compiling. To do it
   by hand: `py installer\build_branding.py`.

If no mascot is present the build still works — Inno uses its stock wizard
images. Panel colors / wordmark / tagline are constants at the top of
`build_branding.py`.

## Build
1. Install **Inno Setup 6** → https://jrsoftware.org/isdl.php
2. Make sure the AnyDesk installer is at `installer/assets/anydesk-7-0-0.exe`
   (already staged; it is git-ignored so it isn't committed).
3. (Optional) Drop the mascot — see **Branding** above.
4. Compile:
   ```powershell
   & 'C:\Program Files (x86)\Inno Setup 6\ISCC.exe' installer\logix-agent.iss
   ```
   or run the helper: `powershell -File installer\build.ps1` (also builds the
   mascot branding first).
5. Output: **`installer\Output\LogixAgentSetup.exe`**

## Deploy to a device
Run `LogixAgentSetup.exe` **as administrator** on the target PC. The wizard asks
for:
- **Server URL** — where the dashboard/server runs (e.g. `http://192.168.1.10:8000`)
- **Server API key** — the ingest key (`LOGIX_INGEST_API_KEY` on the server)
- **Device name** — optional; blank uses the hostname

It then installs everything and starts the agent. Lock/unlock the machine to
confirm the sign-in form appears; the device shows up on the dashboard within a
few seconds, AnyDesk ID auto-reported.

## Notes
- **Python 3** is required only for *local* session logging (`log_physical.py`).
  The sign-in/timer/lock/remote features are pure PowerShell and work without
  it. The wizard warns (doesn't block) if Python isn't found.
- **AnyDesk unattended access**: to let admins connect without the user clicking
  Accept, set `LOGIX_ANYDESK_PASSWORD=...` in `C:\ProgramData\Logix\config.env`
  and reinstall AnyDesk, or run `AnyDesk.exe --set-password`.
- **Auth**: with `LOGIX_DEV_MODE=1` the dashboard auto-logs in with no Google
  Cloud (fine for a trusted LAN, but *anyone* who reaches the server gets admin).
  For a real deployment set up Google OAuth: `LOGIX_DEV_MODE=0`,
  `GOOGLE_CLIENT_ID`/`GOOGLE_CLIENT_SECRET`, and `ADMIN_EMAILS`. See `server/.env`.
