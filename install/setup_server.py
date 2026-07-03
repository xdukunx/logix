#!/usr/bin/env python3
"""Configure the Logix central admin server and (optionally) run it as a service.

Run this from a clone of the repo on the machine that will host the server.
It writes server/.env (generating a strong ingest API key for you), installs
the server dependencies, and can register the server to start on boot
(systemd / launchd / Task Scheduler). No Docker, no external database —
the server is FastAPI + SQLite and runs on a plain Python install.

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
MACOS_LABEL = "com.mindlab.logix-server"
WINDOWS_TASK = "LogixServer"


def install_deps() -> None:
    print("Installing server dependencies (fastapi, uvicorn, openpyxl)...")
    subprocess.run(
        [sys.executable, "-m", "pip", "install", "-r", str(REQUIREMENTS)],
        check=True,
    )


# --------------------------------------------------------------------------- #
# service registration (per OS) — the server starts on boot and restarts on
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


def register_service(python: str, host: str, port: int, user: str) -> None:
    if sys.platform.startswith("win"):
        ps1 = SERVER_DIR / "install_server_task.ps1"
        ps1.write_text(build_windows_ps1(python, host, port), encoding="utf-8")
        subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
                        "-File", str(ps1)], check=True)
        print(f"Registered and started scheduled task '{WINDOWS_TASK}' (runs at startup).")
        print(f'  remove:  Unregister-ScheduledTask -TaskName "{WINDOWS_TASK}" -Confirm:$false')
    elif sys.platform == "darwin":
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
                    help="comma-separated Google accounts allowed to sign in")
    ap.add_argument("--google-client-id", default="")
    ap.add_argument("--google-client-secret", default="")
    ap.add_argument("--redirect-uri", default="",
                    help="OAuth callback, e.g. https://logix.example.org/api/auth/callback")
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
    ap.add_argument("--install-deps", action="store_true",
                    help="pip install -r server/requirements.txt")
    ap.add_argument("--service", action="store_true",
                    help="register the server to start on boot (needs sudo/Administrator)")
    ns = ap.parse_args(argv)

    if not REQUIREMENTS.is_file():
        sys.exit(f"server/ not found at {SERVER_DIR}. Run from a full clone of the repo.")

    admin_emails = ns.admin_emails or prompt("Admin email(s), comma-separated", "admin@example.org")
    client_id = ns.google_client_id or prompt("Google OAuth client id (blank = configure later)")
    client_secret = ns.google_client_secret
    if client_id and not client_secret:
        client_secret = prompt("Google OAuth client secret")
    redirect_uri = ns.redirect_uri or prompt(
        "OAuth redirect URI", f"http://localhost:{ns.port}/api/auth/callback")
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
            "GOOGLE_CLIENT_ID": client_id,
            "GOOGLE_CLIENT_SECRET": client_secret,
            "GOOGLE_REDIRECT_URI": redirect_uri,
            "LOGIX_INGEST_API_KEY": ingest_key,
            "LOGIX_ALLOWED_ORIGINS": allowed_origins,
            "LOGIX_DEV_MODE": dev_mode,
        })
    except PermissionError:
        sys.exit(f"Permission denied writing {ENV_PATH}.")
    if os.name == "posix":
        os.chmod(ENV_PATH, 0o600)
    print(f"\nWrote server settings to {ENV_PATH}")

    if dev_mode != "1" and not client_id:
        print("NOTE: no Google OAuth configured and dev mode is off -- the dashboard")
        print("      login stays locked until you add GOOGLE_CLIENT_ID/SECRET to .env.")
        print("      Device ingest (logs/heartbeats) works already via the API key.")

    if ns.install_deps:
        print()
        install_deps()

    if ns.service:
        print("\nRegistering the boot service...")
        try:
            register_service(sys.executable, ns.host, ns.port, ns.service_user)
        except PermissionError:
            sys.exit("Permission denied -- re-run with sudo (Linux/macOS) or an "
                     "elevated PowerShell (Windows) to register the service.")

    print("\nDone. Run the server in the foreground anytime with:")
    print(f"  cd {SERVER_DIR}")
    print(f"  {Path(sys.executable).name} -m uvicorn main:app --host {ns.host} --port {ns.port}")
    print(f"\nDashboard:  http://localhost:{ns.port}")
    print("\nPoint each device at this server (its installer asks for these):")
    print(f"  LOGIX_SERVER_URL     = http://<this-machine>:{ns.port}   (https:// in production)")
    print(f"  LOGIX_SERVER_API_KEY = {ingest_key}")
    print("\nFor anything reachable beyond this machine, put HTTPS in front --")
    print("see README 'Running it for real: a Linux host with systemd + a reverse proxy'.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
