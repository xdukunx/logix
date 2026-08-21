#!/usr/bin/env python3
"""Logix cross-platform installer (system-wide).

Installs the Logix *core* -- the logging bridge, the report generator, and the
read-only SQL helper -- to a system location, initializes the SQLite schema,
and interactively asks the handful of things that matter (device name,
central server, privacy mode) before printing the remaining per-OS steps.

  Linux/macOS:  sudo python3 install/install.py
  Windows:      (elevated PowerShell)  python install\\install.py

Stdlib only; no third-party dependencies. Run it again any time to upgrade the
installed core in place -- it never clobbers an existing config.env or database.

Non-interactive (CI/automation) -- pass flags; anything omitted is prompted for
when a terminal is attached, same convention as install/setup_sync.py:

  sudo python3 install/install.py --non-interactive \
      --device-name "Lab PC 3" --server-url https://logix.example.org \
      --enroll-code ABCD-1234-EFGH-5678 --privacy-mode admin_full_sync

Scope note: this installs the cross-platform core (which runs natively on all
three OSes) and, on Linux/macOS, generates an SSH login hook. The physical
"at-keyboard" sign-in popup is Windows-only (see windows/) and is not installed
here.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SRC = REPO / "logix"
sys.path.insert(0, str(SRC))
import paths  # noqa: E402  (resolved from SRC above -- single source of truth)

CORE_FILES = [
    "paths.py",
    "log_physical.py",
    "logbook_report.py",
    "logbook_sql.py",
    "logbook_ssh_login.py",
    "gsheet_sync.py",
]

PRIVACY_MODE_SUMMARY = {
    "local_only": "Nothing leaves this device. Strictest privacy (default).",
    "redacted_sync": "Only aggregated, redacted hours-per-user leave the device (via GSheet sync) -- no names, no IDs, no IPs.",
    "admin_full_sync": "Full session rows sync to the central server you configure. Requires informing local users.",
}


def starter_config(dest: Path) -> str:
    return (
        f"# Logix config - system install at {dest}\n"
        f"# Parsed directly by logix/paths.py on every OS (no shell `source` needed).\n"
        f"# Environment variables override anything set here.\n"
        f'LOGIX_HOME={dest}\n'
        f'# LOGIX_DB={dest / "logix.db"}\n'
        f'# LOGBOOK_REPORT_DIR={dest / "reports"}\n'
    )


# --------------------------------------------------------------------------- #
# config.env merge (replace key in place -- commented or not -- else append).
# Same idiom as install/setup_sync.py's update_config(), duplicated rather
# than shared -- each install/*.py script is a self-contained stdlib file.
# --------------------------------------------------------------------------- #
def update_config(cfg_path: Path, updates: dict[str, str], clears: set[str] | None = None) -> None:
    """Merge key=value updates into config.env. Blank values are skipped
    (not written) UNLESS the key is listed in `clears`, in which case any
    existing line for it is REMOVED. The distinction matters on re-install
    over an old config: answering blank to "Central server URL (blank =
    fully local, no sync)" must actually strip a stale URL left by an
    earlier install, or the agent keeps trying to reach a dead server
    forever (2s timeout on every popup open + a log line every heartbeat)."""
    clears = clears or set()
    lines = cfg_path.read_text(encoding="utf-8").splitlines() if cfg_path.exists() else []
    remaining = {k: v for k, v in updates.items() if v}  # never write blank values
    out: list[str] = []
    for line in lines:
        m = re.match(r"^\s*#?\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)\s*=", line)
        if m and m.group(1) in remaining:
            key = m.group(1)
            out.append(f"{key}={remaining.pop(key)}")
        elif m and m.group(1) in clears and not updates.get(m.group(1)):
            continue  # explicit blank answer: drop the stale line entirely
        else:
            out.append(line)
    for key, val in remaining.items():
        out.append(f"{key}={val}")
    cfg_path.parent.mkdir(parents=True, exist_ok=True)
    cfg_path.write_text("\n".join(out) + "\n", encoding="utf-8")


def prompt(label: str, default: str = "") -> str:
    if not sys.stdin.isatty():
        return default
    suffix = f" [{default}]" if default else ""
    try:
        val = input(f"{label}{suffix}: ").strip()
    except EOFError:
        return default
    return val or default


def prompt_privacy_mode(default: str) -> str:
    if not sys.stdin.isatty():
        return default
    print("\nPrivacy mode -- what leaves this device (docs/PRIVACY.md):")
    for mode, summary in PRIVACY_MODE_SUMMARY.items():
        marker = "*" if mode == default else " "
        print(f"  {marker} {mode}: {summary}")
    val = prompt("Privacy mode (local_only/redacted_sync/admin_full_sync)", default)
    if val not in PRIVACY_MODE_SUMMARY:
        print(f"  Unrecognized value {val!r}, keeping {default!r}.")
        return default
    return val


def machine_hostname() -> str:
    """The name this machine will heartbeat under, from the SAME source the
    agent uses.

    On Windows the agent (windows/logbook_common.ps1) always sends
    $env:COMPUTERNAME. This script used socket.gethostname(), which returns the
    DNS host name -- often spelled differently, sometimes only in case. The two
    enrolment paths therefore registered under two spellings of one machine's
    name, and the registry ended up with two devices: one under the raw PC
    name, one under the name the admin typed. The server now compares
    hostnames case-insensitively, and this makes the two paths agree outright.
    """
    if sys.platform.startswith("win"):
        return os.environ.get("COMPUTERNAME") or socket.gethostname()
    return socket.gethostname()


def redeem_enrollment_code(server_url: str, enroll_code: str, device_name: str) -> bool:
    """POST to /api/enroll and persist the result via paths.write_device_identity()
 -- the same identity file windows/logbook_setup.ps1's Save button writes,
    so either wizard path produces an agent in the same enrolled state.

    device_name is what the operator typed at the "Device name" prompt. It used
    to be accepted, written to config.env, and then NOT sent here -- so the
    registry row was created under the bare hostname and only picked the real
    name up on a later heartbeat. Sending it makes the row right immediately.
    """
    body = json.dumps({
        "invite_code": enroll_code,
        "hostname": machine_hostname(),
        "device_name": device_name,
        "os": sys.platform,
    }).encode("utf-8")
    req = urllib.request.Request(
        f"{server_url.rstrip('/')}/api/enroll",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, OSError) as exc:
        print(f"  Enrollment failed: {exc}", file=sys.stderr)
        return False
    path = paths.write_device_identity(data["device_id"], data["api_key"], data.get("category", ""))
    print(f"  enrolled: device_id={data['device_id']} -> wrote {path}")
    return True


def write_ssh_hook(dest: Path, python: str) -> Path:
    """Generate a POSIX SSH login hook pointing at this install. Quoted so it
    survives install paths with spaces (e.g. macOS Application Support)."""
    login = dest / "logbook_ssh_login.py"
    hook = dest / "logix-ssh-hook.sh"
    hook.write_text(
        "#!/bin/bash\n"
        "# Logix: log an interactive SSH login once per session. Generated by install.py.\n"
        'case "$-" in *i*) ;; *) return 0 2>/dev/null || exit 0 ;; esac\n'
        'if [ -n "$SSH_CONNECTION" ] && [ -z "$LOGBOOK_SSH_LOGGED" ]; then\n'
        "    export LOGBOOK_SSH_LOGGED=1\n"
        '    export COMPCHEM_SESSION_TYPE="SSH"\n'
        '    export LOGBOOK_SESSION_ID="ssh-${USER:-unknown}-$$-$(date +%s)"\n'
        f'    if [ -x "{login}" ]; then\n'
        f'        ( "{python}" "{login}" >/dev/null 2>&1 & )\n'
        "    fi\n"
        'elif [ -z "$COMPCHEM_SESSION_TYPE" ]; then\n'
        '    export COMPCHEM_SESSION_TYPE="LOCAL"\n'
        "fi\n",
        encoding="utf-8",
    )
    os.chmod(hook, 0o755)
    return hook


def print_next_steps(dest: Path, hook: Path | None) -> None:
    db = dest / "logix.db"
    bar = "-" * 60
    print(f"\n{bar}\nInstalled. Database: {db}\n{bar}")
    print("\nVerify logging + reporting (works on every OS):")
    print(f'  python "{dest / "logbook_sql.py"}" "select count(*) from physical_log"')
    print(f'  python "{dest / "logbook_report.py"}"      # writes an .xlsx into {dest / "reports"}')

    if sys.platform.startswith("win"):
        print("\nPhysical (at-keyboard) capture on Windows:")
        print("  Use the WPF popup in windows/ - run windows\\install_logbook_tasks.ps1")
        print("  (elevated) to register the lock/unlock sign-in. It writes to this same DB.")
    else:
        print("\nSSH capture -- install the generated hook:")
        if sys.platform == "darwin":
            print(f'  echo \'source "{hook}"\' | sudo tee -a /etc/zprofile   # or /etc/profile')
        else:
            print(f"  sudo ln -sf '{hook}' /etc/profile.d/zz_logbook_ssh.sh")
        print("  New interactive SSH logins will then be recorded automatically.")
    print()


def parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--non-interactive", action="store_true", help="skip all prompts; use flags/defaults as-is")
    p.add_argument("--device-name", default="", help="how this device shows up on the admin dashboard (default: hostname)")
    p.add_argument("--server-url", default="", help="central Logix server URL (blank = fully local, no sync)")
    p.add_argument("--server-api-key", default="", help="shared ingest key (only used if no --enroll-code)")
    p.add_argument("--enroll-code", default="", help="admin-issued invite code -- gets this device its own revocable key instead of a shared one")
    p.add_argument("--privacy-mode", default="local_only", choices=list(PRIVACY_MODE_SUMMARY), help="what leaves this device -- see docs/PRIVACY.md")
    return p.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    ns = parse_args(argv if argv is not None else sys.argv[1:])
    dest = paths._system_data_home()
    reports = dest / "reports"
    print(f"Logix installer - platform={sys.platform}")
    print(f"Install dir: {dest}")

    try:
        dest.mkdir(parents=True, exist_ok=True)
        reports.mkdir(parents=True, exist_ok=True)
    except PermissionError:
        print(
            f"\nPermission denied creating {dest}.\n"
            "Re-run with elevated privileges: sudo on Linux/macOS, "
            "an Administrator shell on Windows.",
            file=sys.stderr,
        )
        return 1

    # Copy the core files into the install dir -- UNLESS we're already running
    # from it. A package-manager install (deb/rpm/homebrew) lays the core files
    # down itself and then runs this script in-place as `logix configure`, so
    # SRC and dest are the same directory; copying a file onto itself throws
    # SameFileError. In the normal repo/one-liner install, SRC (repo/logix) and
    # dest (the OS data home) differ, so the copy runs as before -- which is
    # what the install tests exercise.
    for f in CORE_FILES:
        src, dst = SRC / f, dest / f
        if src.resolve() == dst.resolve():
            continue
        shutil.copy2(src, dst)
        print(f"  copied {f}")

    cfg = dest / "config.env"
    if cfg.exists():
        print(f"  kept existing {cfg.name}")
    else:
        cfg.write_text(starter_config(dest), encoding="utf-8")
        print(f"  wrote {cfg.name}")

    # First-run wizard: interactive unless --non-interactive or no terminal
    # is attached (prompt() itself no-ops to the default in that case, same
    # as install/setup_sync.py).
    if ns.non_interactive:
        device_name = ns.device_name or machine_hostname()
        server_url = ns.server_url
        server_api_key = ns.server_api_key
        enroll_code = ns.enroll_code
        privacy_mode = ns.privacy_mode
    else:
        print()
        device_name = prompt("Device name (shown on the admin dashboard)", ns.device_name or machine_hostname())
        server_url = prompt("Central server URL (blank = fully local, no sync)", ns.server_url)
        enroll_code = ""
        server_api_key = ns.server_api_key
        if server_url:
            enroll_code = prompt("Enrollment code from your admin (blank to use a shared key instead)", ns.enroll_code)
            if not enroll_code:
                server_api_key = prompt("Shared server API key (blank if the server doesn't require one)", ns.server_api_key)
        privacy_mode = prompt_privacy_mode(ns.privacy_mode)

    # Interactive blank = an explicit "fully local" answer -> clear any stale
    # server URL/key a previous install left behind. Non-interactive blank
    # just means "not specified on the command line" -> leave config as-is.
    clears = {"LOGIX_SERVER_URL", "LOGIX_SERVER_API_KEY"} if (not ns.non_interactive and sys.stdin.isatty()) else set()
    update_config(cfg, {
        "LOGIX_DEVICE_NAME": device_name,
        "LOGIX_SERVER_URL": server_url,
        "LOGIX_SERVER_API_KEY": server_api_key,
        "LOGIX_PRIVACY_MODE": privacy_mode,
    }, clears=clears)
    print(f"  updated {cfg.name}")

    if server_url and enroll_code:
        redeem_enrollment_code(server_url, enroll_code, device_name)

    env = dict(os.environ, LOGIX_HOME=str(dest))
    r = subprocess.run([sys.executable, str(dest / "log_physical.py"), "--migrate"], env=env)
    if r.returncode != 0:
        print("ERROR: schema migration failed.", file=sys.stderr)
        return r.returncode
    print(f"  initialized {(dest / 'logix.db').name}")

    hook = None if sys.platform.startswith("win") else write_ssh_hook(dest, sys.executable)
    if hook:
        print(f"  wrote {hook.name}")

    print_next_steps(dest, hook)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
