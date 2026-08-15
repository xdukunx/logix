#!/usr/bin/env python3
"""Start the Logix server in production posture.

Loads server/.env.production (written by ops/go_live.py) into the environment
before importing the app, so the startup preflight sees real secrets and the
server refuses to come up if any are missing.

  python ops/serve.py                 # 127.0.0.1:8791
  python ops/serve.py --host 0.0.0.0  # only behind a TLS reverse proxy

Binding to anything other than loopback without TLS in front means the admin
password and every device key cross the network in the clear, so that case
prints a warning it is hard to miss.
"""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SERVER = REPO / "server"
ENV_PATH = SERVER / ".env.production"


def load_env(path: Path) -> int:
    if not path.exists():
        print(f"ERROR: {path} not found. Run: python ops/go_live.py init --admin-email you@example.org")
        return 0
    loaded = 0
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        # A real environment variable always wins, so an operator can override
        # a single setting without editing the file.
        os.environ.setdefault(key.strip(), value.strip())
        loaded += 1
    return loaded


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=8791)
    ns = p.parse_args()

    if not load_env(ENV_PATH):
        return 1

    if ns.host not in ("127.0.0.1", "localhost", "::1"):
        print(
            "\n  !! Binding to a non-loopback address. Logix speaks plain HTTP.\n"
            "     Put a TLS reverse proxy in front of it (docs/deploy/Caddyfile),\n"
            "     or the admin password and every device key travel in clear text.\n"
        )

    sys.path.insert(0, str(SERVER))
    os.chdir(SERVER)
    import uvicorn  # noqa: E402

    # The app's own preflight runs on startup and aborts on an unsafe posture.
    uvicorn.run("main:app", host=ns.host, port=ns.port, log_level="info")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
