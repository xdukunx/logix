#!/usr/bin/env python3
"""Configure the Logix GSheet sync and (optionally) go live.

Run this AFTER install.py. It writes your sync settings into the installed
config.env, installs the Google client libraries, validates your service-account
key, verifies it can reach the sheet, and can register an hourly schedule
(systemd timer / launchd / Task Scheduler). The operator only supplies a
spreadsheet id and the path to a service-account JSON key.

  Linux/macOS:  sudo python3 install/setup_sync.py
  Windows:      (elevated)  python install\\setup_sync.py

Non-interactive (CI/automation) — pass flags; anything omitted is prompted for
when a terminal is attached:

  sudo python3 install/setup_sync.py \
      --sheet-id <ID> --creds /secure/service_account.json \
      --mode initials --salt "$(openssl rand -hex 16)" \
      --install-deps --check --schedule

Secrets are never written to the repo: only the *path* to your key is stored,
in the system config.env. The key itself stays wherever you put it.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SRC = REPO / "logix"
sys.path.insert(0, str(SRC))
import paths  # noqa: E402

REQUIREMENTS = REPO / "requirements-sync.txt"


# --------------------------------------------------------------------------- #
# config.env merge (replace key in place — commented or not — else append)
# --------------------------------------------------------------------------- #
def update_config(cfg_path: Path, updates: dict[str, str]) -> None:
    lines = cfg_path.read_text(encoding="utf-8").splitlines() if cfg_path.exists() else []
    remaining = dict(updates)
    out: list[str] = []
    for line in lines:
        m = re.match(r"^\s*#?\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)\s*=", line)
        if m and m.group(1) in remaining:
            key = m.group(1)
            out.append(f'{key}="{remaining.pop(key)}"')
        else:
            out.append(line)
    for key, val in remaining.items():
        out.append(f'{key}="{val}"')
    cfg_path.parent.mkdir(parents=True, exist_ok=True)
    cfg_path.write_text("\n".join(out) + "\n", encoding="utf-8")


# --------------------------------------------------------------------------- #
# helpers
# --------------------------------------------------------------------------- #
def prompt(label: str, default: str = "") -> str:
    if not sys.stdin.isatty():
        return default
    suffix = f" [{default}]" if default else ""
    try:
        val = input(f"{label}{suffix}: ").strip()
    except EOFError:
        return default
    return val or default


def validate_creds(creds_path: Path) -> str:
    if not creds_path.is_file():
        sys.exit(f"Credentials file not found: {creds_path}")
    try:
        # utf-8-sig tolerates a BOM that some Windows editors add when re-saving.
        data = json.loads(creds_path.read_text(encoding="utf-8-sig"))
    except json.JSONDecodeError as exc:
        sys.exit(f"Credentials file is not valid JSON: {exc}")
    if data.get("type") != "service_account" or not data.get("client_email"):
        sys.exit("That JSON is not a Google service-account key "
                 "(expected type=service_account with a client_email).")
    return data["client_email"]


def install_deps() -> None:
    print("Installing Google client libraries (gspread, google-auth)...")
    cmd = [sys.executable, "-m", "pip", "install", "-r", str(REQUIREMENTS)] \
        if REQUIREMENTS.is_file() else \
        [sys.executable, "-m", "pip", "install", "gspread>=6.0", "google-auth>=2.0"]
    subprocess.run(cmd, check=True)


# --------------------------------------------------------------------------- #
# scheduling (per OS) — writes an artifact into the install dir and registers it
# --------------------------------------------------------------------------- #
MACOS_LABEL = "com.mindlab.logix-sync"


def build_linux_units(dest: Path, python: str) -> tuple[str, str]:
    service = (
        "[Unit]\nDescription=Logix one-way GSheet sync (redacted)\n\n"
        "[Service]\nType=oneshot\n"
        f"Environment=LOGIX_HOME={dest}\n"
        f"ExecStart={python} {dest / 'gsheet_sync.py'}\n"
    )
    timer = (
        "[Unit]\nDescription=Run Logix GSheet sync hourly\n\n"
        "[Timer]\nOnCalendar=hourly\nPersistent=true\n\n"
        "[Install]\nWantedBy=timers.target\n"
    )
    return service, timer


def build_macos_plist(dest: Path, python: str, label: str = MACOS_LABEL) -> str:
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
        '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        '<plist version="1.0"><dict>\n'
        f"  <key>Label</key><string>{label}</string>\n"
        "  <key>ProgramArguments</key>\n"
        f"  <array><string>{python}</string><string>{dest / 'gsheet_sync.py'}</string></array>\n"
        "  <key>EnvironmentVariables</key>\n"
        f"  <dict><key>LOGIX_HOME</key><string>{dest}</string></dict>\n"
        "  <key>StartInterval</key><integer>3600</integer>\n"
        "  <key>RunAtLoad</key><false/>\n"
        "</dict></plist>\n"
    )


def build_windows_ps1(dest: Path, python: str) -> str:
    return (
        "$ErrorActionPreference='Stop'\n"
        f'$py = "{python}"\n'
        f'$script = "{dest / "gsheet_sync.py"}"\n'
        '$action = New-ScheduledTaskAction -Execute $py -Argument "`"$script`""\n'
        '$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) '
        '-RepetitionInterval (New-TimeSpan -Hours 1)\n'
        '$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" '
        '-LogonType ServiceAccount -RunLevel Highest\n'
        'Register-ScheduledTask -TaskName "LogixGSheetSync" -Action $action '
        '-Trigger $trigger -Principal $principal -Force\n'
    )


def schedule_linux(dest: Path, python: str) -> None:
    service, timer = build_linux_units(dest, python)
    Path("/etc/systemd/system/logix-sync.service").write_text(service, encoding="utf-8")
    Path("/etc/systemd/system/logix-sync.timer").write_text(timer, encoding="utf-8")
    subprocess.run(["systemctl", "daemon-reload"], check=True)
    subprocess.run(["systemctl", "enable", "--now", "logix-sync.timer"], check=True)
    print("Registered systemd timer 'logix-sync.timer' (hourly).")
    print("  status:  systemctl status logix-sync.timer")
    print("  remove:  systemctl disable --now logix-sync.timer")


def schedule_macos(dest: Path, python: str) -> None:
    plist = dest / f"{MACOS_LABEL}.plist"
    plist.write_text(build_macos_plist(dest, python), encoding="utf-8")
    target = Path("/Library/LaunchDaemons") / f"{MACOS_LABEL}.plist"
    target.write_bytes(plist.read_bytes())
    os.chmod(target, 0o644)
    subprocess.run(["launchctl", "load", "-w", str(target)], check=True)
    print(f"Registered launchd daemon '{MACOS_LABEL}' (hourly).")
    print(f"  remove:  sudo launchctl unload -w {target} && sudo rm {target}")


def schedule_windows(dest: Path, python: str) -> None:
    ps1 = dest / "install_sync_task.ps1"
    ps1.write_text(build_windows_ps1(dest, python), encoding="utf-8")
    subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
                    "-File", str(ps1)], check=True)
    print("Registered scheduled task 'LogixGSheetSync' (hourly).")
    print('  remove:  Unregister-ScheduledTask -TaskName "LogixGSheetSync" -Confirm:$false')


def register_schedule(dest: Path, python: str) -> None:
    if sys.platform.startswith("win"):
        schedule_windows(dest, python)
    elif sys.platform == "darwin":
        schedule_macos(dest, python)
    else:
        schedule_linux(dest, python)


# --------------------------------------------------------------------------- #
def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Configure and go live with Logix GSheet sync")
    ap.add_argument("--sheet-id", default="")
    ap.add_argument("--creds", default="", help="path to service_account.json")
    ap.add_argument("--mode", choices=["initials", "hash", "code"], default="")
    ap.add_argument("--salt", default="")
    ap.add_argument("--install-deps", action="store_true", help="pip install gspread + google-auth")
    ap.add_argument("--check", action="store_true", help="verify sheet access after configuring")
    ap.add_argument("--schedule", action="store_true", help="register the hourly schedule for this OS")
    ns = ap.parse_args(argv)

    dest = paths._system_data_home()
    cfg = dest / "config.env"
    if not (dest / "gsheet_sync.py").exists():
        sys.exit(f"Logix core not installed at {dest}. Run install.py first.")

    sheet_id = ns.sheet_id or prompt("Google spreadsheet id")
    creds = ns.creds or prompt("Path to service-account JSON key")
    mode = ns.mode or prompt("Redaction mode (initials|hash|code)", "initials")
    salt = ns.salt or prompt("Salt for hash/code modes (blank for initials)", "")
    if not sheet_id or not creds:
        sys.exit("Need both a spreadsheet id and a credentials path. Nothing changed.")

    email = validate_creds(Path(creds))
    print(f"\nService account: {email}")
    print(f">> Share your Google Sheet with this address (Editor), or the sync can't write.\n")

    try:
        update_config(cfg, {
            "LOGIX_GSHEET_ID": sheet_id,
            "LOGIX_GSHEET_CREDS": creds,
            "LOGIX_REDACT_MODE": mode,
            "LOGIX_GSHEET_SALT": salt,
        })
    except PermissionError:
        sys.exit(f"Permission denied writing {cfg}. Re-run with sudo/Administrator.")
    print(f"Wrote sync settings to {cfg}")

    if ns.install_deps:
        install_deps()

    if ns.check:
        print("\nVerifying sheet access...")
        env = dict(os.environ, LOGIX_HOME=str(dest))
        rc = subprocess.run([sys.executable, str(dest / "gsheet_sync.py"), "--check"], env=env)
        if rc.returncode != 0:
            return rc.returncode

    if ns.schedule:
        print("\nRegistering hourly schedule...")
        register_schedule(dest, sys.executable)

    print("\nDone. Preview anytime with:")
    print(f'  python "{dest / "gsheet_sync.py"}" --dry-run')
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
