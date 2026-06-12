#!/usr/bin/env python3
from __future__ import annotations

import os
import shlex
import subprocess
import sys
from pathlib import Path

LOG_PHYSICAL = Path("/opt/software/logix/log_physical.py")


def main() -> int:
    ssh = os.environ.get("SSH_CONNECTION", "").strip()
    if not ssh:
        return 0
    parts = ssh.split()
    client_ip = parts[0] if parts else ""
    session_id = os.environ.get("LOGBOOK_SESSION_ID") or f"ssh-{os.environ.get('USER','unknown')}-{os.getppid()}"
    cmd = [
        sys.executable,
        str(LOG_PHYSICAL),
        "--event", "SSH_LOGIN",
        "--username", os.environ.get("USER", ""),
        "--session-type", "SSH",
        "--source", "ssh_profile",
        "--session-id", session_id,
        "--client-ip", client_ip,
        "--keterangan", f"SSH login from {client_ip}",
    ]
    subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
