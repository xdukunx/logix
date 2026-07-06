# Logix Agent — NSIS installer (Comnyang-style)

An alternative to the Inno Setup wizard ([../logix-agent.iss](../logix-agent.iss))
with the compact NSIS window, a mascot branding strip down the left, and an
**EN/ID language picker**. It installs the exact same payload and runs the same
registrar (`install_logbook_tasks.ps1`), so the two are interchangeable — pick
whichever look you prefer.

## Build
1. Install **NSIS** → https://nsis.sourceforge.io/Download (bundles the
   `LangDLL` plugin and the Indonesian language file this uses).
2. Compile:
   ```powershell
   powershell -File installer\nsis\build.ps1
   ```
   Output: **`installer\Output\LogixAgentSetup-nsis.exe`**.

The build regenerates the mascot assets from `installer/branding/mascot-source.png`
first (same pipeline as the Inno build), so the `.ico` and branding `.bmp` are
always fresh.

## Preview the UI without installing
```powershell
powershell -File installer\nsis\build.ps1 -Preview
installer\Output\LogixAgentSetup-nsis-preview.exe
```
The `-Preview` build runs **without elevation and installs nothing** — it just
shows the language picker, the mascot window, and the server-settings page so
you can check the look. Safe to double-click.

## What it does (same as the Inno wizard)
- Elevates, installs the agent scripts to `C:\Program Files\Logix` and the
  Python core to `C:\ProgramData\Logix`.
- Asks for the server URL / API key / device name (validates URL + key).
- Runs `install_logbook_tasks.ps1 -NonInteractive -RunNow ...` to register the
  monitor task, install AnyDesk, write `config.env`, and start the agent.
- Writes an uninstaller that stops and removes the scheduled task.

## Notes
- The compact window is NSIS's classic UI (no MUI2) — that's what gives the
  small Comnyang-style installer rather than a full-page wizard.
- Dev/test scripts (`test_*.ps1`, `preview_popup.ps1`) are excluded from what
  ships to client PCs, same as the Inno build.
