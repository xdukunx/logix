#!/usr/bin/env python3
"""Cross-platform path + config resolution for Logix.

Every setting resolves in this order:
  1. environment variable        (e.g. LOGIX_DB)
  2. key in the config file       (config.env: KEY=VALUE or `export KEY=VALUE`)
  3. OS-aware system-wide default

Keeping this in one place lets the core (bridge, report, sql query) run
natively on Windows, macOS, and Linux without WSL. The config file is parsed
directly here, so a single config.env works on all three OSes — no shell
`source` required (native Windows can't source a .env).
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path


def _system_data_home() -> Path:
    """System-wide install/data dir per OS (the installer's default target)."""
    if sys.platform.startswith("win"):
        base = os.environ.get("ProgramData", r"C:\ProgramData")
        return Path(base) / "Logix"
    if sys.platform == "darwin":
        return Path("/Library/Application Support/Logix")
    return Path("/opt/software/logix")  # linux / other posix


def _config_path() -> Path | None:
    """Locate config.env without depending on the (overridable) data home,
    to avoid a resolution cycle."""
    env = os.environ.get("LOGIX_CONFIG")
    if env and Path(env).is_file():
        return Path(env)
    for cand in (
        _system_data_home() / "config.env",
        Path(__file__).resolve().parent / "config.env",  # dev / co-located
    ):
        if cand.is_file():
            return cand
    return None


_CONFIG_CACHE: dict[str, str] | None = None


def _config_values() -> dict[str, str]:
    global _CONFIG_CACHE
    if _CONFIG_CACHE is not None:
        return _CONFIG_CACHE
    values: dict[str, str] = {}
    path = _config_path()
    if path:
        for raw in path.read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            if line.startswith("export "):
                line = line[len("export "):]
            key, _, val = line.partition("=")
            key = key.strip()
            val = val.strip().strip('"').strip("'")
            if key:
                values[key] = val
    _CONFIG_CACHE = values
    return values


def get(name: str, default: str = "") -> str:
    """Resolve a setting: env var > config file > default."""
    if os.environ.get(name):
        return os.environ[name]
    return _config_values().get(name, default)


def data_home() -> Path:
    v = get("LOGIX_HOME")
    return Path(v) if v else _system_data_home()


def default_db() -> Path:
    v = get("LOGIX_DB")
    return Path(v) if v else data_home() / "logix.db"


def default_reports_dir() -> Path:
    v = get("LOGBOOK_REPORT_DIR")
    return Path(v) if v else data_home() / "reports"


def default_session_json() -> Path:
    """Where the Windows physical popup drops session.json.

    On native Windows that's under ProgramData; on a WSL bridge the popup
    writes to the Windows side, surfaced at /mnt/c/ProgramData/... .
    """
    v = get("LOGBOOK_SESSION_JSON")
    if v:
        return Path(v)
    if sys.platform.startswith("win"):
        base = os.environ.get("ProgramData", r"C:\ProgramData")
        return Path(base) / "MindLabLogbook" / "session.json"
    return Path("/mnt/c/ProgramData/MindLabLogbook/session.json")


def server_url() -> str:
    return get("LOGIX_SERVER_URL", "")


def server_api_key() -> str:
    """The shared bootstrap/dev ingest key (LOGIX_INGEST_API_KEY on the
    server side). Used only when this device hasn't been enrolled yet --
    see device_api_key() for the per-device key, which takes priority."""
    return get("LOGIX_SERVER_API_KEY", "")


# --- Device identity (Logix Control enrollment) -----------------------------
# Per API_CONTRACT.md: local-first, retryable identity, deliberately kept
# separate from config.env (which is operator-supplied config written once
# by the setup wizard). device.json is server-assigned at /api/enroll and
# must survive independently of whether the wizard runs again.

def device_identity_path() -> Path:
    v = get("LOGIX_DEVICE_IDENTITY_FILE")
    return Path(v) if v else data_home() / "device.json"


def _read_device_identity() -> dict:
    path = device_identity_path()
    if not path.is_file():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def device_id() -> str:
    return str(_read_device_identity().get("device_id", ""))


def device_api_key() -> str:
    """The per-device key issued at enrollment. Takes priority over the
    shared server_api_key() wherever both are consulted -- mirrors the
    server's own fallback order in verify_api_key."""
    return str(_read_device_identity().get("api_key", ""))


def device_category() -> str:
    return str(_read_device_identity().get("category", ""))


def write_device_identity(device_id: str, api_key: str, category: str = "") -> Path:
    """Persist the identity returned by a successful POST /api/enroll."""
    path = device_identity_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {"device_id": device_id, "api_key": api_key, "category": category}
    path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    return path

