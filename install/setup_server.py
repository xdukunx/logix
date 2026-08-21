#!/usr/bin/env python3
"""Configure the Logix central admin server and (optionally) run it as a service.

Run this from a clone of the repo on the machine that will host the server.
It writes server/.env (generating a strong ingest API key for you), installs
the server dependencies into server/.venv, and can register the server to
start on boot (systemd / launchd / Task Scheduler). No Docker, no external
database -- the server is FastAPI + SQLite.

The dependencies go into a virtualenv rather than the system interpreter
because Debian 12 and Ubuntu 23.04+ mark theirs externally managed (PEP 668),
where pip refuses to install at all. Pass --no-install-deps if you are
managing the environment yourself.

  Linux/macOS:  python3 install/setup_server.py
  Windows:      python install\\setup_server.py

Interactive by default; every value can also be passed as a flag for
automation (anything omitted is prompted for when a terminal is attached):

  python3 install/setup_server.py \
      --admin-emails you@example.org \
      --allowed-origins https://logix.example.org \
      --install-deps --service

Secrets stay on this machine: .env is written next to server/main.py,
matches .gitignore's *.env pattern, and is chmod 0600 on POSIX.
"""
from __future__ import annotations

import argparse
import os
import secrets
import subprocess
import sys
from pathlib import Path

# Same-directory reuse: prompt() and the config.env-style merge writer.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from setup_sync import prompt, update_config  # noqa: E402

REPO = Path(__file__).resolve().parent.parent
SERVER_DIR = REPO / "server"
ENV_PATH = SERVER_DIR / ".env"
REQUIREMENTS = SERVER_DIR / "requirements.txt"

SERVICE_NAME = "logix-server"
MACOS_LABEL = "com.logix.logix-server"
# Pre-rename label. Unloaded during install so an upgraded Mac does not
# keep running the old LaunchAgent alongside the new one.
LEGACY_MACOS_LABELS = ("com.mindlab.logix-server",)
WINDOWS_TASK = "LogixServer"


# Derived at call time rather than frozen at import, so that redirecting
# SERVER_DIR (as the tests do) redirects the venv with it instead of building
# one in the real checkout.
def venv_dir() -> Path:
    return SERVER_DIR / ".venv"


def venv_python() -> Path:
    """Where a virtualenv at venv_dir() keeps its interpreter."""
    if os.name == "nt":
        return venv_dir() / "Scripts" / "python.exe"
    return venv_dir() / "bin" / "python"


def server_python() -> str:
    """The interpreter that actually has fastapi/uvicorn -- the venv if one
    exists, otherwise whatever is running this script."""
    py = venv_python()
    return str(py) if py.exists() else sys.executable


def install_deps() -> str:
    """Install the server's dependencies into server/.venv and return its python.

    Deliberately NOT into the system interpreter. Debian 12 and Ubuntu 23.04+
    mark theirs as externally managed (PEP 668), so `pip install` there exits
    with "error: externally-managed-environment" and the whole setup falls
    over -- on precisely the OS most people host this on. A venv also means
    the server's dependencies can never conflict with something apt installed,
    and `sudo pip install` never has to enter the picture.
    """
    py = venv_python()
    if not py.exists():
        print(f"Creating a virtualenv at {venv_dir()} ...")
        result = subprocess.run([sys.executable, "-m", "venv", str(venv_dir())])
        if result.returncode != 0 or not py.exists():
            # Ubuntu/Debian strip ensurepip out of the system python into a
            # separate package, so `python3 -m venv` fails there until it is
            # installed. Say which package, rather than leaving the operator
            # with pip's "ensurepip is not available".
            sys.exit(
                f"Could not create a virtualenv at {venv_dir()}.\n"
                "On Debian/Ubuntu this usually means the venv module is packaged\n"
                "separately -- install it and re-run:\n"
                "    sudo apt-get install -y python3-venv"
            )
    print("Installing server dependencies (fastapi, uvicorn, openpyxl)...")
    subprocess.run([str(py), "-m", "pip", "install", "--upgrade", "pip"],
                   check=False)
    subprocess.run([str(py), "-m", "pip", "install", "-r", str(REQUIREMENTS)],
                   check=True)
    return str(py)


# --------------------------------------------------------------------------- #
# service registration (per OS) -- the server starts on boot and restarts on
# failure. The unit/task runs uvicorn bound to --host/--port; keep the default
# 127.0.0.1 and put a TLS reverse proxy in front for anything non-local
# (see README "Running it for real").
# --------------------------------------------------------------------------- #
def build_linux_unit(python: str, host: str, port: int, user: str) -> str:
    user_line = f"User={user}\n" if user else ""
    return (
        "[Unit]\nDescription=Logix central admin server\nAfter=network.target\n\n"
        "[Service]\nType=simple\n"
        f"{user_line}"
        f"WorkingDirectory={SERVER_DIR}\n"
        f"EnvironmentFile={ENV_PATH}\n"
        f"ExecStart={python} -m uvicorn main:app --host {host} --port {port}\n"
        "Restart=on-failure\n\n"
        "[Install]\nWantedBy=multi-user.target\n"
    )


def build_macos_plist(python: str, host: str, port: int) -> str:
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
        '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        '<plist version="1.0"><dict>\n'
        f"  <key>Label</key><string>{MACOS_LABEL}</string>\n"
        "  <key>ProgramArguments</key>\n"
        f"  <array><string>{python}</string><string>-m</string><string>uvicorn</string>"
        f"<string>main:app</string><string>--host</string><string>{host}</string>"
        f"<string>--port</string><string>{port}</string></array>\n"
        f"  <key>WorkingDirectory</key><string>{SERVER_DIR}</string>\n"
        "  <key>RunAtLoad</key><true/>\n"
        "  <key>KeepAlive</key><true/>\n"
        "</dict></plist>\n"
    )


def build_windows_ps1(python: str, host: str, port: int) -> str:
    return (
        "$ErrorActionPreference='Stop'\n"
        f'$action = New-ScheduledTaskAction -Execute "{python}" '
        f'-Argument "-m uvicorn main:app --host {host} --port {port}" '
        f'-WorkingDirectory "{SERVER_DIR}"\n'
        "$trigger = New-ScheduledTaskTrigger -AtStartup\n"
        '$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" '
        "-LogonType ServiceAccount -RunLevel Highest\n"
        "$settings = New-ScheduledTaskSettingsSet -RestartCount 3 "
        "-RestartInterval (New-TimeSpan -Minutes 1) "
        "-ExecutionTimeLimit (New-TimeSpan -Seconds 0)\n"
        f'Register-ScheduledTask -TaskName "{WINDOWS_TASK}" -Action $action '
        "-Trigger $trigger -Principal $principal -Settings $settings -Force\n"
        f'Start-ScheduledTask -TaskName "{WINDOWS_TASK}"\n'
    )


# The scheduled housekeeping. On Linux these are systemd timers in ops/systemd/;
# Windows had no equivalent, so a Windows-hosted server -- which is what a lab
# running Windows workstations most likely has -- was silently running with no
# backups, no report cleanup, no retention enforcement and no watchdog. Same
# jobs, same times, expressed as Task Scheduler entries.
#
# (script, task name suffix, daily time HH:mm, description)
WINDOWS_JOBS = [
    ("ops/backup_db.py", "Backup", "02:30", "Daily database backup, integrity-checked"),
    ("ops/cleanup_reports.py", "CleanupReports", "03:00", "Prune generated .xlsx reports (PII)"),
    ("ops/retention.py", "Retention", "03:15", "Enforce the personal-data retention window"),
    ("ops/watchdog.py", "Watchdog", None, "Health/error/backup checks -> Telegram"),
]
WATCHDOG_INTERVAL_MINUTES = 10


def build_windows_jobs_ps1(python: str) -> str:
    lines = ["$ErrorActionPreference='Stop'"]
    for script, suffix, at, description in WINDOWS_JOBS:
        task = f"{WINDOWS_TASK}-{suffix}"
        target = (REPO / script).as_posix().replace("/", "\\")
        lines.append(
            f'$action = New-ScheduledTaskAction -Execute "{python}" '
            f'-Argument "\\"{target}\\"" -WorkingDirectory "{REPO}"'
        )
        if at:
            lines.append(f'$trigger = New-ScheduledTaskTrigger -Daily -At "{at}"')
        else:
            # No -Daily equivalent for "every N minutes forever": a daily
            # trigger with a repetition is the Task Scheduler idiom.
            lines.append(
                '$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).Date '
                f'-RepetitionInterval (New-TimeSpan -Minutes {WATCHDOG_INTERVAL_MINUTES})'
            )
        lines.append(
            '$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" '
            "-LogonType ServiceAccount -RunLevel Highest"
        )
        # StartWhenAvailable is the Persistent=true of systemd timers: it
        # catches up a run the host was switched off for, instead of silently
        # skipping a night of backups.
        lines.append(
            "$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable "
            "-ExecutionTimeLimit (New-TimeSpan -Hours 1)"
        )
        lines.append(
            f'Register-ScheduledTask -TaskName "{task}" -Action $action -Trigger $trigger '
            f'-Principal $principal -Settings $settings -Description "{description}" -Force'
        )
        lines.append(f'Write-Host "registered {task}"')
    return "\n".join(lines) + "\n"


def register_windows_jobs(python: str) -> None:
    ps1 = SERVER_DIR / "install_server_jobs.ps1"
    ps1.write_text(build_windows_jobs_ps1(python), encoding="utf-8")
    subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
                    "-File", str(ps1)], check=True)
    print(f"Registered {len(WINDOWS_JOBS)} housekeeping task(s):")
    for _, suffix, at, description in WINDOWS_JOBS:
        when = f"daily {at}" if at else f"every {WATCHDOG_INTERVAL_MINUTES} min"
        print(f"  {WINDOWS_TASK}-{suffix:<15} {when:<18} {description}")
    print(f'  remove:  Get-ScheduledTask -TaskName "{WINDOWS_TASK}-*" | Unregister-ScheduledTask -Confirm:$false')



def unload_legacy_macos_daemons() -> None:
    """Unload and remove any launchd daemon registered under a pre-rename label.

    Renaming the label alone would leave the old plist loaded, so an upgraded
    Mac would run BOTH copies -- two servers fighting over the same port, or
    two sync jobs writing the same rows. Best-effort: launchctl exits non-zero
    for a label that was never loaded, which is the ordinary case.
    """
    for label in LEGACY_MACOS_LABELS:
        stale = Path("/Library/LaunchDaemons") / f"{label}.plist"
        if not stale.exists():
            continue
        subprocess.run(["launchctl", "unload", "-w", str(stale)], check=False)
        try:
            stale.unlink()
            print(f"Removed the pre-rename launchd daemon '{label}'.")
        except OSError as exc:
            print(f"  could not remove {stale}: {exc}", file=sys.stderr)


def register_service(python: str, host: str, port: int, user: str) -> None:
    if sys.platform.startswith("win"):
        ps1 = SERVER_DIR / "install_server_task.ps1"
        ps1.write_text(build_windows_ps1(python, host, port), encoding="utf-8")
        subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
                        "-File", str(ps1)], check=True)
        print(f"Registered and started scheduled task '{WINDOWS_TASK}' (runs at startup).")
        print(f'  remove:  Unregister-ScheduledTask -TaskName "{WINDOWS_TASK}" -Confirm:$false')
        register_windows_jobs(python)
    elif sys.platform == "darwin":
        unload_legacy_macos_daemons()
        target = Path("/Library/LaunchDaemons") / f"{MACOS_LABEL}.plist"
        target.write_text(build_macos_plist(python, host, port), encoding="utf-8")
        os.chmod(target, 0o644)
        subprocess.run(["launchctl", "load", "-w", str(target)], check=True)
        print(f"Registered launchd daemon '{MACOS_LABEL}' (starts at boot).")
        print(f"  remove:  sudo launchctl unload -w {target} && sudo rm {target}")
    else:
        unit = Path(f"/etc/systemd/system/{SERVICE_NAME}.service")
        unit.write_text(build_linux_unit(python, host, port, user), encoding="utf-8")
        subprocess.run(["systemctl", "daemon-reload"], check=True)
        subprocess.run(["systemctl", "enable", "--now", f"{SERVICE_NAME}"], check=True)
        print(f"Registered and started systemd service '{SERVICE_NAME}'.")
        print(f"  status:  systemctl status {SERVICE_NAME}")
        print(f"  logs:    journalctl -u {SERVICE_NAME} -f")
        print(f"  remove:  systemctl disable --now {SERVICE_NAME}")


# --------------------------------------------------------------------------- #
def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Configure the Logix central admin server")
    ap.add_argument("--admin-emails", default="",
                    help="comma-separated admin emails allowed to sign in")
    ap.add_argument("--admin-password", default="",
                    help="shared admin login password (leave blank to set later in .env)")
    ap.add_argument("--ingest-key", default="",
                    help="shared X-API-Key for devices (blank = generate a strong one)")
    ap.add_argument("--allowed-origins", default="",
                    help="comma-separated dashboard origins for CORS")
    ap.add_argument("--dev-mode", choices=["0", "1"], default="",
                    help="1 = local development only (mock login, permissive CORS)")
    ap.add_argument("--host", default="127.0.0.1",
                    help="bind address (keep 127.0.0.1 behind a reverse proxy)")
    ap.add_argument("--port", type=int, default=8000)
    ap.add_argument("--service-user", default="",
                    help="Linux only: run the systemd service as this existing user")
    # Installing the dependencies is the default because skipping it produces a
    # setup that reports success and then cannot start: the old default left
    # fastapi/uvicorn uninstalled, printed "Done. Run the server with ...", and
    # that command died on ModuleNotFoundError. Accepted-but-redundant
    # --install-deps is kept so existing docs and scripts keep working.
    ap.add_argument("--install-deps", action="store_true",
                    help="(default) install server dependencies into server/.venv")
    ap.add_argument("--no-install-deps", dest="skip_deps", action="store_true",
                    help="skip dependency installation (you are managing them yourself)")
    ap.add_argument("--service", action="store_true",
                    help="register the server to start on boot (needs sudo/Administrator)")
    ns = ap.parse_args(argv)

    if not REQUIREMENTS.is_file():
        sys.exit(f"server/ not found at {SERVER_DIR}. Run from a full clone of the repo.")

    admin_emails = ns.admin_emails or prompt("Admin email(s), comma-separated", "admin@example.org")
    admin_password = ns.admin_password or prompt(
        "Admin login password (blank = set later in .env; use a STRONG value, not admin123)")
    ingest_key = ns.ingest_key or secrets.token_hex(32)
    allowed_origins = ns.allowed_origins or prompt(
        "Allowed dashboard origin(s)", f"http://localhost:{ns.port}")
    dev_mode = ns.dev_mode or prompt("Dev mode? 0 = production posture, 1 = local dev only", "0")

    # Seed from the commented .env.example on first run so the operator keeps
    # the inline documentation; update_config then replaces keys in place.
    example = SERVER_DIR / ".env.example"
    if not ENV_PATH.exists() and example.is_file():
        ENV_PATH.write_text(example.read_text(encoding="utf-8"), encoding="utf-8")

    try:
        update_config(ENV_PATH, {
            "ADMIN_EMAILS": admin_emails,
            "LOGIX_ADMIN_PASSWORD": admin_password,
            "LOGIX_INGEST_API_KEY": ingest_key,
            "LOGIX_ALLOWED_ORIGINS": allowed_origins,
            "LOGIX_DEV_MODE": dev_mode,
        })
    except PermissionError:
        sys.exit(f"Permission denied writing {ENV_PATH}.")
    if os.name == "posix":
        os.chmod(ENV_PATH, 0o600)
    print(f"\nWrote server settings to {ENV_PATH}")

    if dev_mode != "1" and not admin_password:
        print("NOTE: no admin password set and dev mode is off -- the dashboard")
        print("      login stays locked until you set LOGIX_ADMIN_PASSWORD in .env.")
        print("      Device ingest (logs/heartbeats) works already via the API key.")

    python = server_python()
    if not ns.skip_deps:
        print()
        python = install_deps()

    if ns.service:
        print("\nRegistering the boot service...")
        try:
            # The venv interpreter, not sys.executable: the service has to
            # start from the one that actually has uvicorn installed.
            register_service(python, ns.host, ns.port, ns.service_user)
        except PermissionError:
            sys.exit("Permission denied -- re-run with sudo (Linux/macOS) or an "
                     "elevated PowerShell (Windows) to register the service.")

    print("\nDone. Run the server in the foreground anytime with:")
    print(f"  cd {SERVER_DIR}")
    print(f"  {python} -m uvicorn main:app --host {ns.host} --port {ns.port}")
    if python != sys.executable:
        print(f"\nDependencies live in {venv_dir()}, so use that interpreter for")
        print("the ops scripts too, e.g.:")
        print(f"  {python} {REPO / 'ops' / 'serve.py'}")
    print(f"\nDashboard:  http://localhost:{ns.port}")
    print("\nPoint each device at this server (its installer asks for these):")
    print(f"  LOGIX_SERVER_URL     = http://<this-machine>:{ns.port}   (https:// in production)")
    print(f"  LOGIX_SERVER_API_KEY = {ingest_key}")
    print("\nFor anything reachable beyond this machine, put HTTPS in front --")
    print("see README 'Running it for real: a Linux host with systemd + a reverse proxy'.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
