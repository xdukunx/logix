import os
import csv
import io
import json
import logging
import sqlite3
import subprocess
import secrets
import hmac
import urllib.request
import urllib.parse
import uuid
from datetime import datetime, timedelta
from logging.handlers import RotatingFileHandler
from typing import Optional, List, Dict, Any
from pathlib import Path
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Header, Depends, Query, Body, Cookie, Request
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse, JSONResponse, RedirectResponse, HTMLResponse, Response
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel


# Lifespan handler -- the modern FastAPI replacement for the deprecated
# @app.on_event("startup"). The actual startup work lives in startup_event()
# further down, next to the init_db/init_control_tables helpers it calls;
# lifespan only invokes it when the server actually starts, so referencing a
# function defined later in the module resolves fine at call time.
@asynccontextmanager
async def lifespan(app: FastAPI):
    startup_event()
    yield


app = FastAPI(title="Logix Central Admin Server", lifespan=lifespan)


# --- Logging ----------------------------------------------------------------
# Structured server logs so production failures leave a trace (the old
# best-effort `except: pass` blocks were silent). Logs go to stdout -- captured
# by journald under systemd -- AND to a rotating file the ops watchdog scans
# for ERROR spikes. Level via LOGIX_LOG_LEVEL (default INFO). No PII is logged:
# messages describe *what* failed, never the row contents.
def _setup_logging() -> logging.Logger:
    log_dir = Path(__file__).resolve().parent / "logs"
    try:
        log_dir.mkdir(exist_ok=True)
    except Exception:
        log_dir = None
    level = getattr(logging, os.environ.get("LOGIX_LOG_LEVEL", "INFO").upper(), logging.INFO)
    fmt = logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s")
    lg = logging.getLogger("logix")
    lg.setLevel(level)
    lg.handlers.clear()
    stream = logging.StreamHandler()
    stream.setFormatter(fmt)
    lg.addHandler(stream)
    if log_dir is not None:
        try:
            fileh = RotatingFileHandler(log_dir / "logix.log", maxBytes=5_000_000,
                                        backupCount=5, encoding="utf-8")
            fileh.setFormatter(fmt)
            lg.addHandler(fileh)
        except Exception:
            pass  # stdout logging still works even if the file handler can't open
    lg.propagate = False
    return lg


logger = _setup_logging()


# Log any unhandled exception with a traceback (HTTPException is routed to
# FastAPI's own handler and is not caught here), then return a clean 500 that
# leaks no internals to the client.
@app.exception_handler(Exception)
async def _unhandled_exception_handler(request: Request, exc: Exception):
    logger.exception("Unhandled error on %s %s", request.method, request.url.path)
    return JSONResponse(status_code=500, content={"detail": "Internal server error"})


# --- .env autoload -----------------------------------------------------------
# Minimal stdlib loader so `uvicorn main:app` works right after
# install/setup_server.py without the operator exporting variables or wiring
# systemd's EnvironmentFile. Real environment variables always win: a key
# already present in os.environ is never overwritten.
def _load_dotenv(path: Path) -> None:
    if not path.is_file():
        return
    for line in path.read_text(encoding="utf-8-sig").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        key = key.strip()
        val = val.strip()
        if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'":
            val = val[1:-1]
        if key and key not in os.environ:
            os.environ[key] = val


_load_dotenv(Path(__file__).resolve().parent / ".env")

# --- Deployment mode & CORS -------------------------------------------------
# 0 = production posture (no mock auth, strict origin allowlist).
# 1 = local development (mock auth allowed, permissive CORS).
LOGIX_DEV_MODE = os.environ.get("LOGIX_DEV_MODE", "0") == "1"

if LOGIX_DEV_MODE:
    _cors_origins = ["*"]
    _cors_credentials = False  # wildcard origins + credentials is an invalid/unsafe combo
else:
    _cors_origins = [
        o.strip() for o in os.environ.get("LOGIX_ALLOWED_ORIGINS", "").split(",") if o.strip()
    ]
    _cors_credentials = True

app.add_middleware(
    CORSMiddleware,
    allow_origins=_cors_origins,
    allow_credentials=_cors_credentials,
    allow_methods=["*"],
    allow_headers=["*"],
)

BASE_DIR = Path(__file__).resolve().parent
DB_PATH = BASE_DIR / "central_logix.db"
CONFIG_PATH = BASE_DIR / "server_config.json"
REPORTS_DIR = BASE_DIR / "reports"

# In-memory authentication tokens
# Format: { token: { "email": str, "expires": datetime } }
ACTIVE_TOKENS: Dict[str, Dict[str, Any]] = {}

# Command queue for clients
# Format: { hostname: [ { "command": str, "param": str } ] }
PENDING_COMMANDS: Dict[str, List[Dict[str, Any]]] = {}

# In-memory heartbeats storage
# Format: { hostname: { "status": str, "username": str, "anydesk_id": str, "last_seen": datetime } }
HEARTBEATS: Dict[str, Dict[str, Any]] = {}

# SQLite columns helper
BASE_COLUMNS = {
    "id": "INTEGER PRIMARY KEY AUTOINCREMENT",
    "timestamp": "TEXT NOT NULL",
    "event": "TEXT NOT NULL",
    "username": "TEXT",
    "nama": "TEXT",
    "nim": "TEXT",
    "tujuan": "TEXT",
    "keterangan": "TEXT",
    "session_type": "TEXT",
    "source": "TEXT",
    "session_id": "TEXT",
    "windows_user": "TEXT",
    "hostname": "TEXT",
    "client_ip": "TEXT",
    "anydesk_detected": "INTEGER DEFAULT 0",
    "raw_json": "TEXT",
    # Mirrors logix/log_physical.py's BASE_COLUMNS -- a stable per-event id
    # generated once agent-side, carried through sync/retry unchanged.
    # Empty for a legacy agent that hasn't upgraded yet; log_event() falls
    # back to the old tuple-based dedup in that case.
    "event_uid": "TEXT",
    "synced": "INTEGER DEFAULT 0",
}

# Logix Control: persisted device registry. See docs/LOGIX_CONTROL.md §5.
# device_id is still assigned as a stopgap on first-seen hostname via
# upsert_device() for devices that never go through /api/enroll (e.g. an
# existing deployment that hasn't adopted invite-code enrollment yet) --
# real enrollment (below) additionally sets api_key/category/enrolled_at.
DEVICE_COLUMNS = {
    "device_id": "TEXT PRIMARY KEY",
    "hostname": "TEXT NOT NULL",
    "display_name": "TEXT",
    "category": "TEXT NOT NULL DEFAULT 'custom'",
    "owner": "TEXT",
    "location": "TEXT",
    "tags": "TEXT",
    "status": "TEXT NOT NULL DEFAULT 'active'",
    "enrolled_at": "TEXT",
    "last_seen": "TEXT",
    "privacy_mode": "TEXT DEFAULT 'local_only'",
    "sync_enabled": "INTEGER DEFAULT 1",
    "capabilities": "TEXT",
    "policy_profile": "TEXT DEFAULT 'lab_standard'",
    # Per-device ingest credential, issued at successful /api/enroll.
    # Plaintext, matching the existing shared LOGIX_INGEST_API_KEY precedent
    # (verify_api_key already compares that as a raw value via
    # secrets.compare_digest -- hashing only this one column would be an
    # inconsistent, one-off pattern). UNIQUE makes the per-device lookup in
    # verify_api_key a single indexed row match and stops an enrollment
    # collision from silently overwriting another device's key. NULL until
    # enrolled, and set back to NULL on revoke -- never returned by
    # GET /api/devices (see get_devices()).
    "api_key": "TEXT UNIQUE",
    # Set by PUT /api/devices/rename. Once true, upsert_device() (heartbeat
    # path) stops overwriting display_name with whatever the agent reports --
    # otherwise an admin rename would silently revert on the device's next
    # heartbeat (every 30s by default). See CATEGORY_PROFILES for interval.
    "display_name_set_by_admin": "INTEGER DEFAULT 0",
    "created_at": "TEXT NOT NULL",
    "updated_at": "TEXT NOT NULL",
}

# Device enrollment (Logix Control). Locked design in API_CONTRACT.md:
# single-use invite code, 15-minute TTL, DB-persisted (not an in-memory
# dict like ACTIVE_TOKENS -- a restart must not silently invalidate codes
# an admin already handed out without them being able to see that).
ENROLLMENT_INVITE_COLUMNS = {
    "invite_code": "TEXT PRIMARY KEY",
    "category": "TEXT NOT NULL DEFAULT 'custom'",
    "display_name": "TEXT",
    "note": "TEXT",
    "created_by": "TEXT NOT NULL",
    "created_at": "TEXT NOT NULL",
    "expires_at": "TEXT NOT NULL",
    "used_at": "TEXT",
    "used_by_device_id": "TEXT",
}

INVITE_TTL_MINUTES = 15

# category -> agent profile defaults, per API_CONTRACT.md §4. A module-level
# constant for now; the contract describes this as eventually server-side
# config rather than code, matching how device_policies shipped seeded-but-
# not-yet-editable.
CATEGORY_PROFILES = {
    "lab_workstation": {"heartbeat_interval_seconds": 30, "popup_frequency": "every_unlock"},
    "office_workstation": {"heartbeat_interval_seconds": 60, "popup_frequency": "every_unlock"},
    "loaned_laptop": {"heartbeat_interval_seconds": 300, "popup_frequency": "once_per_day"},
    "mobile_device": {"heartbeat_interval_seconds": 300, "popup_frequency": "once_per_day"},
    "server": {"heartbeat_interval_seconds": 300, "popup_frequency": "never"},
    "custom": {"heartbeat_interval_seconds": 60, "popup_frequency": "every_unlock"},
}


def compute_sync_status(category: Optional[str], last_seen, now: Optional[datetime] = None) -> str:
    """Bucket a device's freshness against its category's expected heartbeat
    cadence (CATEGORY_PROFILES) instead of one flat cutoff -- replaces the
    flat 5-minute check that used to be duplicated in
    get_active_workstations() and get_devices(). Thresholds are multiples of
    heartbeat_interval_seconds: online <= 2x (tolerates one missed beat +
    jitter), stale <= 6x (several missed beats, plausibly reachable), else
    offline. last_seen may be a datetime, an ISO string, or None/falsy.
    """
    if not last_seen:
        return "never_seen"
    last_seen_dt = last_seen if isinstance(last_seen, datetime) else datetime.fromisoformat(last_seen)
    now = now or datetime.now()
    profile = CATEGORY_PROFILES.get(category or "custom", CATEGORY_PROFILES["custom"])
    interval = profile["heartbeat_interval_seconds"]
    age = (now - last_seen_dt).total_seconds()
    if age <= interval * 2:
        return "online"
    if age <= interval * 6:
        return "stale"
    return "offline"


# Policy profiles: named bundles a device can be assigned to. Seeded with the
# 7 profiles from docs/LOGIX_CONTROL.md §5. allowed_capabilities is now
# real: enforce_command_policy() reads the command_allowlist rows seeded from
# POLICY_COMMAND_RULES below before any control command is queued.
POLICY_COLUMNS = {
    "policy_name": "TEXT PRIMARY KEY",
    "description": "TEXT",
    "allowed_capabilities": "TEXT",
    "privacy_mode_default": "TEXT",
    "is_system_default": "INTEGER DEFAULT 0",
    "created_at": "TEXT NOT NULL",
    "updated_at": "TEXT NOT NULL",
}

SYSTEM_POLICY_PROFILES = [
    ("strict_privacy", "Maximum privacy; no sync beyond what's explicitly opted into.", "local_only"),
    ("lab_standard", "Default for shared lab workstations.", "local_only"),
    ("exam_mode", "Locked-down posture for exam periods.", "local_only"),
    ("instructor_demo", "Instructor-facing devices used for demonstrations.", "local_only"),
    ("office_device", "Single-user office workstation.", "local_only"),
    ("loaned_laptop", "Laptop loaned out to a student/staff member.", "local_only"),
    ("server_monitoring", "Headless server; no interactive session capture.", "local_only"),
]

# Which commands a policy profile allows, and whether a reason is required.
COMMAND_ALLOWLIST_COLUMNS = {
    "policy_name": "TEXT NOT NULL",
    "command_type": "TEXT NOT NULL",
    "allowed": "INTEGER DEFAULT 1",
    "requires_reason": "INTEGER DEFAULT 0",
}
KNOWN_COMMAND_TYPES = ["LOCK", "BROADCAST", "SCREENSHOT", "SHUTDOWN", "RESTART", "LOGOFF"]

# policy -> command -> (allowed, requires_reason). Seeded into
# command_allowlist (INSERT OR IGNORE, so an admin's later edits stick) and
# enforced by enforce_command_policy() on every control endpoint. LOCK and
# BROADCAST stay allowed everywhere they were before this shipped; the
# larger-permission commands are differentiated per posture: privacy-first
# profiles get nothing new, exam/instructor postures get screen view, and
# headless servers get power actions but no interactive-session commands
# (server_monitoring is the one profile that drops LOCK/BROADCAST on a
# fresh install; an existing DB keeps its already-seeded rows untouched).
POLICY_COMMAND_RULES = {
    "strict_privacy":    {"LOCK": (1, 0), "BROADCAST": (1, 0), "SCREENSHOT": (0, 0), "SHUTDOWN": (0, 0), "RESTART": (0, 0), "LOGOFF": (0, 0)},
    "lab_standard":      {"LOCK": (1, 0), "BROADCAST": (1, 0), "SCREENSHOT": (1, 1), "SHUTDOWN": (1, 1), "RESTART": (1, 1), "LOGOFF": (1, 1)},
    "exam_mode":         {"LOCK": (1, 0), "BROADCAST": (1, 0), "SCREENSHOT": (1, 0), "SHUTDOWN": (1, 0), "RESTART": (1, 0), "LOGOFF": (1, 0)},
    "instructor_demo":   {"LOCK": (1, 0), "BROADCAST": (1, 0), "SCREENSHOT": (1, 0), "SHUTDOWN": (0, 0), "RESTART": (0, 0), "LOGOFF": (0, 0)},
    "office_device":     {"LOCK": (1, 0), "BROADCAST": (1, 0), "SCREENSHOT": (0, 0), "SHUTDOWN": (1, 1), "RESTART": (1, 1), "LOGOFF": (0, 0)},
    "loaned_laptop":     {"LOCK": (1, 0), "BROADCAST": (1, 0), "SCREENSHOT": (0, 0), "SHUTDOWN": (0, 0), "RESTART": (0, 0), "LOGOFF": (0, 0)},
    "server_monitoring": {"LOCK": (0, 0), "BROADCAST": (0, 0), "SCREENSHOT": (0, 0), "SHUTDOWN": (1, 1), "RESTART": (1, 1), "LOGOFF": (0, 0)},
}

# Audit log for every Control command, retrofitted onto the two that already
# existed (lock, broadcast) rather than left as an empty table for a future
# feature. status progresses 'queued' -> 'done'/'failed' (agent-acked on a
# later heartbeat, see HeartbeatPayload.acks) or -> 'expired' (TTL elapsed
# before delivery, see COMMAND_TTL_MINUTES). A 'queued' row must still never
# be read as 'done' -- see docs/LOGIX_CONTROL.md §6.
REMOTE_ACTION_COLUMNS = {
    "action_id": "INTEGER PRIMARY KEY AUTOINCREMENT",
    "actor_email": "TEXT NOT NULL",
    "target_device": "TEXT",
    "target_device_id": "TEXT",
    "action_type": "TEXT NOT NULL",
    "status": "TEXT NOT NULL",
    "reason": "TEXT",
    "param": "TEXT",
    "timestamp": "TEXT NOT NULL",
    "error_message": "TEXT",
    "result_summary": "TEXT",
    # Addressable so a later heartbeat's ack (or a TTL sweep) can update
    # this exact row's status without ambiguity.
    "command_id": "TEXT",
    # Set only by an ack or a TTL expiry -- distinguishes "queued" from
    # "we know what actually happened and when."
    "executed_at": "TEXT",
    # Roadmap item J: minimal retry lifecycle. A retry is a new child row
    # (retry_of_action_id points at the original), not an in-place mutation
    # -- preserves full history the same way alerts are resolved rather than
    # deleted. retry_count is *this row's* attempt number (0 for an original
    # action); max_retries caps how many times it may still be retried.
    "retry_count": "INTEGER DEFAULT 0",
    "max_retries": "INTEGER DEFAULT 1",
    "retry_of_action_id": "INTEGER",
}

# How long a queued command waits for its device to check in before it's
# considered stale and withheld rather than delivered. Without this, a
# device offline for hours would fire an old LOCK/BROADCAST the moment it
# reconnects, with no indication to the admin that context is stale. Also
# the single TTL used by reconcile_expired_actions() for DB-level expiry,
# so a command expires consistently whether or not its device ever
# heartbeats again (see that function's docstring).
COMMAND_TTL_MINUTES = 5

# Only these action types are ever queued/delivered to a device and can
# genuinely fail due to connectivity -- safe to retry. RENAME and
# REVOKE_API_KEY are synchronous server-side edits (never queued, always
# logged 'done' immediately), and REVOKE_API_KEY is explicitly
# security-sensitive -- neither is offered a Retry action, automatic or
# manual, per roadmap item J §C.
RETRYABLE_ACTION_TYPES = {"LOCK", "BROADCAST", "SCREENSHOT", "SHUTDOWN", "RESTART", "LOGOFF"}
DEFAULT_MAX_RETRIES = 1

# Latest screenshot per device (Logix Control screen view). Deliberately a
# single row per device (PRIMARY KEY device_id, upsert-replace): screen
# content is never persisted as history, per docs/PRIVACY.md's "Design
# boundaries -- Logix Control" commitment. A capture only ever exists as
# the direct, audit-logged result of POST /api/control/screenshot, and the
# agent shows the local user a notice when it runs (never silent).
DEVICE_SCREENSHOT_COLUMNS = {
    "device_id": "TEXT PRIMARY KEY",
    "hostname": "TEXT NOT NULL",
    "command_id": "TEXT",
    "image_base64": "TEXT NOT NULL",
    "content_type": "TEXT DEFAULT 'image/jpeg'",
    "captured_at": "TEXT NOT NULL",
}

# Replies sent by the person at a device in response to an admin broadcast
# (or unsolicited, from the session-timer widget). command_id links back to
# the remote_actions BROADCAST row that prompted it, when there is one.
DEVICE_REPLY_COLUMNS = {
    "id": "INTEGER PRIMARY KEY AUTOINCREMENT",
    "device_id": "TEXT",
    "hostname": "TEXT NOT NULL",
    "device_name": "TEXT",
    "message": "TEXT NOT NULL",
    "command_id": "TEXT",
    "created_at": "TEXT NOT NULL",
    "read_at": "TEXT",
}
REPLY_MAX_LENGTH = 1000

# System Alerts (roadmap item I). Rows are never deleted -- a cleared
# condition is marked 'resolved' (status: active|acknowledged|resolved) so
# history survives and a later recurrence can create a fresh row. device_id
# is nullable for future non-device-scoped alerts, though every category
# generated today is device-scoped. See reconcile_alerts() below.
ALERT_COLUMNS = {
    "id": "INTEGER PRIMARY KEY AUTOINCREMENT",
    "severity": "TEXT NOT NULL",
    "category": "TEXT NOT NULL",
    "title": "TEXT NOT NULL",
    "message": "TEXT NOT NULL",
    "device_id": "TEXT",
    "device_name": "TEXT",
    "status": "TEXT NOT NULL DEFAULT 'active'",
    "created_at": "TEXT NOT NULL",
    "acknowledged_at": "TEXT",
    "resolved_at": "TEXT",
}

class LogPayload(BaseModel):
    timestamp: str
    event: str
    username: Optional[str] = ""
    nama: Optional[str] = ""
    nim: Optional[str] = ""
    tujuan: Optional[str] = ""
    keterangan: Optional[str] = ""
    session_type: Optional[str] = ""
    source: Optional[str] = ""
    session_id: Optional[str] = ""
    windows_user: Optional[str] = ""
    hostname: Optional[str] = ""
    client_ip: Optional[str] = ""
    anydesk_detected: Optional[int] = 0
    raw_json: Optional[str] = ""
    event_uid: Optional[str] = ""

class HeartbeatPayload(BaseModel):
    hostname: str
    status: str
    username: Optional[str] = ""
    anydesk_id: Optional[str] = ""
    device_name: Optional[str] = ""
    # Outcomes for commands delivered on a *previous* heartbeat -- the agent
    # executes LOCK/BROADCAST synchronously after already processing that
    # response, so there's no request left to attach the outcome to; it
    # rides the next one instead. Each entry: {command_id, status
    # ("done"|"failed"), detail}.
    acks: Optional[List[Dict[str, Any]]] = None
    # Session context for the Monitoring station card (v3 design D-03): the
    # card's second line is "{user} · {access type} · {duration}", which needs
    # a start time and an access type the server did not previously receive.
    # All optional -- an older agent build simply omits them and the card
    # degrades to the username alone.
    session_started_at: Optional[str] = None
    access_type: Optional[str] = None
    purpose: Optional[str] = None

class ControlRequest(BaseModel):
    hostname: str
    param: Optional[str] = ""
    reason: Optional[str] = ""

DEFAULT_CONFIG = {
    "branding": {
        "logoText": "Logix",
        "logoPath": "C:\\Program Files\\Logix\\logo.png",
        "title": "Report Logbook",
        "subtitle": "Computational Workstation",
        "colors": {
            "primary": "#0E1626",
            "accent": "#2563EB",
            "muted": "#93A1B8",
            "text": "#EEF3FB",
            "surface": "#070C15",
            "surfaceWidget": "#0B1017",
            "surfaceElevated": "#0E1626",
            "border": "#223451"
        },
        "signals": {
            "normal": "#22C55E",
            "notice": "#3B82F6",
            "warning": "#F59E0B",
            "critical": "#EF4444"
        }
    },
    "text": {
        "intro": "Isi data penggunaan workstation sebelum memulai sesi.",
        "startHint": "Waktu mulai akan dicatat saat tombol Mulai sesi ditekan.",
        "namaLabel": "Nama Pengguna",
        "nimLabel": "NIM/NIP/NIK",
        "accessLabel": "Tipe Akses",
        "purposeLabel": "Tujuan Penggunaan",
        "ketLabel": "Keterangan Kegiatan",
        "submit": "Mulai Sesi",
        "hint": "Mohon isi data dengan benar dan selengkap mungkin, apabila ada error atau kesalahan, segera hubungi admin.",
        "hintIncomplete": "Lengkapi Nama, NIM/ID, tipe akses, tujuan, dan keterangan.",
        "hintReady": "Siap disimpan. Tuliskan keterangan kegiatan sedetail mungkin agar mudah dipahami admin -- hanya nama, NIM, tipe akses, tujuan, dan keterangan yang dicatat, bukan aktivitas di layar Anda."
    },
    "accessTypes": ["Physical", "AnyDesk"],
    "purposes": ["Visualisasi Data", "Running Data", "Maintenance"],
    "requiredFields": ["nama", "nim", "access", "purpose", "keterangan"],
    "devices": {
        "device_types": ["Laptop", "PC", "Lab Workstation", "Office Workstation", "Loaned Laptop", "Server"],
        "naming_pattern": "{type} - {room} - {number}"
    },
    "reports": {
        "default_scope": "today",
        "include_branding": True,
        "include_purpose_summary": True,
        "include_device_summary": True
    },
    "privacy": {
        "notice": "This system records session information only.",
        "collected": ["device name", "session start and end", "selected purpose", "workstation status"],
        "not_collected": ["keystrokes", "screenshots", "browser history", "private files"]
    }
}


def get_db():
    conn = sqlite3.connect(str(DB_PATH))
    conn.row_factory = sqlite3.Row
    return conn


def init_db():
    conn = get_db()
    try:
        col_defs = ",\n        ".join(f"{k} {v}" for k, v in BASE_COLUMNS.items())
        conn.execute(f"CREATE TABLE IF NOT EXISTS physical_log (\n        {col_defs}\n    )")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_physical_log_timestamp ON physical_log(timestamp)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_physical_log_session ON physical_log(session_id)")

        # Additive migration: a physical_log table created before this
        # shipped won't have event_uid yet. Same idiom as devices.api_key
        # above. A partial unique index (not a plain UNIQUE column) so rows
        # from legacy agents -- which all have event_uid = '' -- never
        # collide with each other; only two genuinely equal non-empty uids
        # would.
        existing_log_cols = {row["name"] for row in conn.execute("PRAGMA table_info(physical_log)").fetchall()}
        if "event_uid" not in existing_log_cols:
            conn.execute("ALTER TABLE physical_log ADD COLUMN event_uid TEXT")
        conn.execute(
            "CREATE UNIQUE INDEX IF NOT EXISTS idx_physical_log_event_uid "
            "ON physical_log(event_uid) WHERE event_uid IS NOT NULL AND event_uid != ''"
        )
        conn.commit()
    finally:
        conn.close()


# Logix Control tables, kept separate from init_db() so this file's diff for
# each Control milestone stays isolated and reviewable. See docs/LOGIX_CONTROL.md.
def init_control_tables():
    conn = get_db()
    try:
        col_defs = ",\n        ".join(f"{k} {v}" for k, v in DEVICE_COLUMNS.items())
        conn.execute(f"CREATE TABLE IF NOT EXISTS devices (\n        {col_defs}\n    )")
        conn.execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_devices_hostname ON devices(hostname)")

        # Additive migration: a devices table created before enrollment
        # shipped won't have api_key yet. Matches the ALTER TABLE ADD COLUMN
        # idiom already used in logix/log_physical.py's migrate().
        existing_device_cols = {row["name"] for row in conn.execute("PRAGMA table_info(devices)").fetchall()}
        if "api_key" not in existing_device_cols:
            conn.execute("ALTER TABLE devices ADD COLUMN api_key TEXT")
        conn.execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_devices_api_key ON devices(api_key)")
        if "display_name_set_by_admin" not in existing_device_cols:
            conn.execute("ALTER TABLE devices ADD COLUMN display_name_set_by_admin INTEGER DEFAULT 0")

        invite_defs = ",\n        ".join(f"{k} {v}" for k, v in ENROLLMENT_INVITE_COLUMNS.items())
        conn.execute(f"CREATE TABLE IF NOT EXISTS enrollment_invites (\n        {invite_defs}\n    )")

        policy_defs = ",\n        ".join(f"{k} {v}" for k, v in POLICY_COLUMNS.items())
        conn.execute(f"CREATE TABLE IF NOT EXISTS device_policies (\n        {policy_defs}\n    )")

        allowlist_defs = ",\n        ".join(f"{k} {v}" for k, v in COMMAND_ALLOWLIST_COLUMNS.items())
        conn.execute(
            f"CREATE TABLE IF NOT EXISTS command_allowlist (\n        {allowlist_defs},\n"
            "        PRIMARY KEY (policy_name, command_type)\n    )"
        )

        action_defs = ",\n        ".join(f"{k} {v}" for k, v in REMOTE_ACTION_COLUMNS.items())
        conn.execute(f"CREATE TABLE IF NOT EXISTS remote_actions (\n        {action_defs}\n    )")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_remote_actions_timestamp ON remote_actions(timestamp)")

        alert_defs = ",\n        ".join(f"{k} {v}" for k, v in ALERT_COLUMNS.items())
        conn.execute(f"CREATE TABLE IF NOT EXISTS alerts (\n        {alert_defs}\n    )")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_alerts_category_device ON alerts(category, device_id)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_alerts_status ON alerts(status)")

        screenshot_defs = ",\n        ".join(f"{k} {v}" for k, v in DEVICE_SCREENSHOT_COLUMNS.items())
        conn.execute(f"CREATE TABLE IF NOT EXISTS device_screenshots (\n        {screenshot_defs}\n    )")

        reply_defs = ",\n        ".join(f"{k} {v}" for k, v in DEVICE_REPLY_COLUMNS.items())
        conn.execute(f"CREATE TABLE IF NOT EXISTS device_replies (\n        {reply_defs}\n    )")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_device_replies_created ON device_replies(created_at)")

        # Additive migration: a remote_actions table created before command
        # acks shipped won't have these yet.
        existing_action_cols = {row["name"] for row in conn.execute("PRAGMA table_info(remote_actions)").fetchall()}
        if "command_id" not in existing_action_cols:
            conn.execute("ALTER TABLE remote_actions ADD COLUMN command_id TEXT")
        if "executed_at" not in existing_action_cols:
            conn.execute("ALTER TABLE remote_actions ADD COLUMN executed_at TEXT")
        # Additive migration: a remote_actions table created before roadmap
        # item J's retry lifecycle won't have these yet.
        if "retry_count" not in existing_action_cols:
            conn.execute("ALTER TABLE remote_actions ADD COLUMN retry_count INTEGER DEFAULT 0")
        if "max_retries" not in existing_action_cols:
            conn.execute(f"ALTER TABLE remote_actions ADD COLUMN max_retries INTEGER DEFAULT {DEFAULT_MAX_RETRIES}")
        if "retry_of_action_id" not in existing_action_cols:
            conn.execute("ALTER TABLE remote_actions ADD COLUMN retry_of_action_id INTEGER")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_remote_actions_command_id ON remote_actions(command_id)")

        now = datetime.now().isoformat()
        for policy_name, description, privacy_mode_default in SYSTEM_POLICY_PROFILES:
            rules = POLICY_COMMAND_RULES[policy_name]
            capabilities = [cmd.lower() for cmd in KNOWN_COMMAND_TYPES if rules[cmd][0]]
            # INSERT OR IGNORE: idempotent across restarts, never clobbers an
            # admin's later edits to a seeded row.
            conn.execute(
                "INSERT OR IGNORE INTO device_policies "
                "(policy_name, description, allowed_capabilities, privacy_mode_default, "
                "is_system_default, created_at, updated_at) VALUES (?, ?, ?, ?, 1, ?, ?)",
                (policy_name, description, json.dumps(capabilities), privacy_mode_default, now, now),
            )
            for command_type in KNOWN_COMMAND_TYPES:
                allowed, requires_reason = rules[command_type]
                conn.execute(
                    "INSERT OR IGNORE INTO command_allowlist "
                    "(policy_name, command_type, allowed, requires_reason) VALUES (?, ?, ?, ?)",
                    (policy_name, command_type, allowed, requires_reason),
                )

        conn.commit()
    finally:
        conn.close()


# Upsert-on-heartbeat: devices is the durable registry (survives restart);
# HEARTBEATS stays the fast in-memory "online now" cache, untouched by this.
# Uses explicit SELECT-then-INSERT/UPDATE (not ON CONFLICT DO UPDATE) to match
# the existing idempotency idiom in logix/log_physical.py. Returns the
# *effective* display_name -- callers (post_heartbeat) must use this, not the
# name they passed in, so the in-memory HEARTBEATS cache and the /api/active
# view it feeds also respect an admin rename (see display_name_set_by_admin).
def upsert_device(conn, hostname: str, display_name: str) -> str:
    now = datetime.now().isoformat()
    existing = conn.execute(
        "SELECT device_id, display_name_set_by_admin, display_name FROM devices WHERE hostname = ?", (hostname,)
    ).fetchone()
    if existing:
        if existing["display_name_set_by_admin"]:
            # An admin renamed this device from the dashboard -- that name
            # is authoritative until explicitly changed again, regardless
            # of what this heartbeat's agent-reported name says.
            conn.execute(
                "UPDATE devices SET last_seen = ?, status = 'active', updated_at = ? WHERE hostname = ?",
                (now, now, hostname),
            )
            conn.commit()
            return existing["display_name"]
        else:
            conn.execute(
                "UPDATE devices SET display_name = ?, last_seen = ?, status = 'active', updated_at = ? WHERE hostname = ?",
                (display_name, now, now, hostname),
            )
    else:
        conn.execute(
            "INSERT INTO devices (device_id, hostname, display_name, last_seen, created_at, updated_at) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (str(uuid.uuid4()), hostname, display_name, now, now, now),
        )
    conn.commit()
    return display_name


def log_remote_action(conn, actor_email: str, target_device: str, action_type: str,
                       status: str, reason: str = "", param: str = "",
                       error_message: str = "", result_summary: str = "",
                       command_id: str = ""):
    device_row = conn.execute("SELECT device_id FROM devices WHERE hostname = ?", (target_device,)).fetchone()
    target_device_id = device_row["device_id"] if device_row else None
    conn.execute(
        "INSERT INTO remote_actions "
        "(actor_email, target_device, target_device_id, action_type, status, reason, param, "
        "timestamp, error_message, result_summary, command_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (actor_email, target_device, target_device_id, action_type, status, reason, param,
         datetime.now().isoformat(), error_message, result_summary, command_id or None),
    )
    conn.commit()


def apply_command_acks(conn, acks: List[Dict[str, Any]]):
    """Apply agent-reported outcomes to remote_actions. The
    'AND status = queued' guard makes this idempotent against a resent ack
    (the agent retries at-least-once, never exactly-once -- see
    windows/logbook_common.ps1's pending_acks.json) and silently no-ops an
    ack for an unknown or already-terminal command_id rather than raising --
    an ack is a best-effort report, not something the caller depends on."""
    now = datetime.now().isoformat()
    for ack in acks:
        command_id = ack.get("command_id")
        status = ack.get("status")
        if not command_id or status not in ("done", "failed"):
            continue
        detail = str(ack.get("detail", ""))
        if status == "failed":
            conn.execute(
                "UPDATE remote_actions SET status = ?, error_message = ?, executed_at = ? "
                "WHERE command_id = ? AND status = 'queued'",
                (status, detail, now, command_id),
            )
        else:
            conn.execute(
                "UPDATE remote_actions SET status = ?, result_summary = ?, executed_at = ? "
                "WHERE command_id = ? AND status = 'queued'",
                (status, detail, now, command_id),
            )
    conn.commit()


# Roadmap item J: command lifecycle reliability. -----------------------------

def reconcile_expired_actions(conn) -> None:
    """Mark any 'queued' remote_actions row older than COMMAND_TTL_MINUTES as
    'expired', DB-wide -- not just for whichever hostname happens to be
    heartbeating right now. post_heartbeat's old inline sweep only expired
    entries sitting in *that device's* in-memory PENDING_COMMANDS list, so a
    device that never heartbeats again left its queued row stuck 'queued'
    forever. This is the real fix: called lazily from GET /api/alerts, device detail,
    and post_heartbeat, so it's current within one request of anywhere that
    matters, without a background scheduler.

    Also purges the same command_ids from the in-memory PENDING_COMMANDS
    queues so an expired command is never handed to a device as work, even
    if it's still sitting in that dict for some other reason.
    """
    cutoff = (datetime.now() - timedelta(minutes=COMMAND_TTL_MINUTES)).isoformat()
    now = datetime.now().isoformat()
    newly_expired = conn.execute(
        "SELECT command_id FROM remote_actions WHERE status = 'queued' AND timestamp < ?",
        (cutoff,),
    ).fetchall()
    if not newly_expired:
        return
    conn.execute(
        "UPDATE remote_actions SET status = 'expired', executed_at = ? "
        "WHERE status = 'queued' AND timestamp < ?",
        (now, cutoff),
    )
    conn.commit()
    expired_command_ids = {row["command_id"] for row in newly_expired if row["command_id"]}
    if not expired_command_ids:
        return
    for hostname in list(PENDING_COMMANDS.keys()):
        PENDING_COMMANDS[hostname] = [
            c for c in PENDING_COMMANDS[hostname] if c.get("command_id") not in expired_command_ids
        ]


def rehydrate_pending_commands() -> None:
    """Rebuild the in-memory delivery queue from 'queued' DB rows at startup.
    PENDING_COMMANDS is memory-only and wiped by a server restart, but the
    remote_actions rows survive it -- without this, a command queued right
    before a restart would sit 'queued' in the DB forever, undeliverable,
    until reconcile_expired_actions() eventually marked it expired, even if
    its device reconnects well within the TTL. Idempotent (checks
    command_id membership first) so calling it more than once is harmless.
    """
    conn = get_db()
    try:
        rows = conn.execute(
            "SELECT target_device, command_id, action_type, param, timestamp FROM remote_actions "
            "WHERE status = 'queued' AND target_device IS NOT NULL"
        ).fetchall()
    finally:
        conn.close()
    for row in rows:
        existing_ids = {c.get("command_id") for c in PENDING_COMMANDS.get(row["target_device"], [])}
        if row["command_id"] in existing_ids:
            continue
        PENDING_COMMANDS.setdefault(row["target_device"], []).append({
            "command_id": row["command_id"],
            "command": row["action_type"],
            "param": row["param"] or "",
            "queued_at": row["timestamp"],
        })


# --- System Alerts (roadmap item I) ---------------------------------------
# No background scheduler exists in this codebase (the closest precedent,
# the command TTL sweep, runs inline inside post_heartbeat), so alerts are
# reconciled lazily: reconcile_alerts() re-evaluates every device/action
# condition and upserts the alerts table each time GET /api/alerts is
# called, rather than on a timer. Cheap for the device counts this project
# targets (a shared lab, not a datacenter fleet).

def _get_or_create_alert(conn, category: str, device_id: str, device_name: str,
                          severity: str, title: str, message: str) -> None:
    """Dedup key: category + device_id + status != 'resolved' (an
    'unresolved' alert). A persistent condition (e.g. a device that stays
    offline across many reconcile passes) must not spam a new row every
    time this runs -- only create one if no unresolved row already covers
    the same category+device."""
    existing = conn.execute(
        "SELECT id FROM alerts WHERE category = ? AND device_id = ? AND status != 'resolved'",
        (category, device_id),
    ).fetchone()
    if existing:
        return
    conn.execute(
        "INSERT INTO alerts (severity, category, title, message, device_id, device_name, status, created_at) "
        "VALUES (?, ?, ?, ?, ?, ?, 'active', ?)",
        (severity, category, title, message, device_id, device_name, datetime.now().isoformat()),
    )


def _resolve_alert_if_unresolved(conn, category: str, device_id: str) -> None:
    """The underlying condition cleared -- mark resolved rather than delete,
    so history survives and a later recurrence is free to create a fresh
    row (a resolved row is no longer 'unresolved', so the dedup check in
    _get_or_create_alert won't be blocked by it)."""
    conn.execute(
        "UPDATE alerts SET status = 'resolved', resolved_at = ? "
        "WHERE category = ? AND device_id = ? AND status != 'resolved'",
        (datetime.now().isoformat(), category, device_id),
    )


def _reconcile_event_alerts(conn, category: str, action_status: str, severity: str,
                             device_names: dict, title_fn, message_fn) -> None:
    """Shared dedup logic for discrete, already-happened event alerts
    (failed commands, expired commands) that have no ongoing condition to
    clear -- see action_failed's original comment. A matching
    remote_actions row never disappears on its own, so the plain
    unresolved-only dedup in _get_or_create_alert isn't enough by itself:
    once an alert is resolved, only alert again on a failure/expiry newer
    than the most recent existing alert (any status) for that
    category+device -- a genuine new occurrence is always newer than the
    alert its predecessor produced, so this lets a fresh recurrence through
    without resurrecting an already-closed one.
    """
    rows = conn.execute(
        "SELECT target_device_id, target_device, MAX(timestamp) AS latest FROM remote_actions "
        "WHERE status = ? AND target_device_id IS NOT NULL GROUP BY target_device_id, target_device",
        (action_status,),
    ).fetchall()
    for row in rows:
        device_id = row["target_device_id"]
        last_alert = conn.execute(
            "SELECT created_at FROM alerts WHERE category = ? AND device_id = ? "
            "ORDER BY created_at DESC LIMIT 1",
            (category, device_id),
        ).fetchone()
        if last_alert and last_alert["created_at"] >= row["latest"]:
            continue  # this occurrence (or a later one) was already alerted on
        device_name, hostname = device_names.get(device_id, (row["target_device"], row["target_device"]))
        _get_or_create_alert(
            conn, category, device_id, device_name, severity,
            title_fn(device_name), message_fn(device_name, hostname),
        )


def reconcile_alerts(conn) -> None:
    # Close the loop roadmap item I left open: a command stuck 'queued'
    # past its TTL is now actually marked 'expired' here, before
    # command_expired alerts are evaluated further down.
    reconcile_expired_actions(conn)

    now = datetime.now()
    devices = conn.execute(
        "SELECT device_id, hostname, display_name, category, last_seen FROM devices"
    ).fetchall()
    device_names = {d["device_id"]: (d["display_name"] or d["hostname"], d["hostname"]) for d in devices}

    for d in devices:
        device_id = d["device_id"]
        device_name = d["display_name"] or d["hostname"]
        live = HEARTBEATS.get(d["hostname"])
        live_last_seen = live["last_seen"] if live else None
        status = compute_sync_status(d["category"], live_last_seen or d["last_seen"], now)

        if status == "stale":
            _get_or_create_alert(
                conn, "device_stale", device_id, device_name, "warning",
                f"Device stale: {device_name}",
                f"{device_name} ({d['hostname']}) belum mengirim heartbeat sesuai jadwal.",
            )
        else:
            _resolve_alert_if_unresolved(conn, "device_stale", device_id)

        if status == "offline":
            _get_or_create_alert(
                conn, "device_offline", device_id, device_name, "critical",
                f"Device offline: {device_name}",
                f"{device_name} ({d['hostname']}) tidak terhubung dalam waktu yang cukup lama.",
            )
        else:
            _resolve_alert_if_unresolved(conn, "device_offline", device_id)

    # Failed and expired remote actions are both discrete, already-happened
    # events (not ongoing conditions) -- see _reconcile_event_alerts's
    # docstring for the dedup rationale. Failed commands are closed manually
    # via POST /api/alerts/{id}/resolve (no "cleared" state exists to
    # auto-resolve on); expired ones the same way.
    _reconcile_event_alerts(
        conn, "action_failed", "failed", "critical", device_names,
        title_fn=lambda name: f"Perintah gagal: {name}",
        message_fn=lambda name, host: f"Salah satu perintah untuk {name} ({host}) gagal dijalankan.",
    )
    _reconcile_event_alerts(
        conn, "command_expired", "expired", "warning", device_names,
        title_fn=lambda name: f"Perintah kedaluwarsa: {name}",
        message_fn=lambda name, host: f"Salah satu perintah untuk {name} ({host}) kedaluwarsa sebelum sempat dikirim.",
    )

    conn.commit()


# --- RBAC (Logix Control Milestone 3, docs/LOGIX_CONTROL.md §4) -----------
# Permissions-only: which role can call which endpoint. Deliberately does
# NOT restrict by faculty/lab/room scope -- no backing entity for "their
# faculty" exists yet, and inventing one here would be unscoped work.

_VALID_ROLES = {"super_admin", "faculty_admin", "lab_admin", "instructor", "viewer", "auditor"}

ROLE_PERMISSIONS: Dict[str, set] = {
    "super_admin": {"*"},
    # Same explicit set as lab_admin, NOT a wildcard -- a wildcard here would
    # make faculty_admin functionally equal to super_admin for as long as
    # scope enforcement (faculty-level restriction) remains unbuilt.
    "faculty_admin": {
        "lock", "broadcast", "power", "screenshot", "devices_read", "devices_write",
        "sessions_read", "analytics_read", "audit_log_read", "reports_read",
        "invite_create", "devices_revoke", "alerts_read", "alerts_write",
        "replies_read", "replies_write",
    },
    "lab_admin": {
        "lock", "broadcast", "power", "screenshot", "devices_read", "devices_write",
        "sessions_read", "analytics_read", "audit_log_read", "reports_read",
        "invite_create", "devices_revoke", "alerts_read", "alerts_write",
        "replies_read", "replies_write",
    },
    # Instructors get screen view for classroom/demo oversight but not power
    # actions -- shutting devices down is an admin's call, not a class-time one.
    "instructor": {"lock", "broadcast", "screenshot", "replies_read"},
    "viewer": {"devices_read", "sessions_read", "analytics_read", "audit_log_read", "reports_read", "alerts_read", "replies_read"},
    "auditor": {"audit_log_read", "reports_read"},
}


# Resolve Auth Configurations
def get_admin_roles() -> Dict[str, str]:
    """Parse ADMIN_EMAILS into email->role. Backward compatible: a bare
    email (no ':role' suffix) defaults to super_admin, so every existing
    deployment's flat comma list keeps working unchanged. An unknown role
    suffix fails fast (a config typo shouldn't silently misassign a role)."""
    raw = os.environ.get("ADMIN_EMAILS", "admin@example.org")
    roles: Dict[str, str] = {}
    for entry in raw.split(","):
        entry = entry.strip()
        if not entry:
            continue
        if ":" in entry:
            email, role = entry.split(":", 1)
            email = email.strip().lower()
            role = role.strip().lower()
            if role not in _VALID_ROLES:
                raise RuntimeError(f"ADMIN_EMAILS: unknown role '{role}' for {email!r}")
        else:
            email, role = entry.strip().lower(), "super_admin"
        roles[email] = role
    return roles


def get_allowed_admins():
    return list(get_admin_roles().keys())


def _resolve_session(authorization: Optional[str]) -> dict:
    token = None
    if authorization and authorization.startswith("Bearer "):
        token = authorization[7:]

    if not token or token not in ACTIVE_TOKENS:
        raise HTTPException(status_code=401, detail="Unauthorized: invalid or missing session token")

    session = ACTIVE_TOKENS[token]
    if datetime.now() > session["expires"]:
        ACTIVE_TOKENS.pop(token, None)
        raise HTTPException(status_code=401, detail="Unauthorized: session expired")

    # Slide session window
    session["expires"] = datetime.now() + timedelta(hours=8)
    return session


# Dependency to verify token
def verify_token(authorization: Optional[str] = Header(None)):
    return _resolve_session(authorization)["email"]


def require_permission(action: str):
    """FastAPI dependency factory: 401 on no/invalid session, 403 if the
    session's role isn't permitted to perform `action`. Fails closed on an
    unrecognized role (e.g. removed from ROLE_PERMISSIONS) rather than
    raising a KeyError."""
    def _dependency(authorization: Optional[str] = Header(None)) -> str:
        session = _resolve_session(authorization)
        role = session.get("role", "")
        permissions = ROLE_PERMISSIONS.get(role, set())
        if "*" not in permissions and action not in permissions:
            raise HTTPException(status_code=403, detail=f"Forbidden: role '{role}' cannot perform '{action}'")
        return session["email"]
    return _dependency


# Dependency to verify the shared ingest API key sent by local agents.
# Unset LOGIX_INGEST_API_KEY only ever happens in dev mode; production
# deployments must configure it, otherwise ingest is rejected outright.
def verify_api_key(x_api_key: Optional[str] = Header(None)):
    # A per-device key issued by /api/enroll takes priority over the shared
    # bootstrap key. Guard empty/missing header BEFORE the DB lookup -- a
    # NULL api_key column (unenrolled or revoked device) must never match
    # an empty/missing X-API-Key.
    if x_api_key:
        conn = get_db()
        try:
            # Single indexed lookup via the UNIQUE constraint/index on
            # devices.api_key -- not a table scan. Plaintext exact match,
            # matching the shared key's own secrets.compare_digest precedent
            # (not constant-time against the DB, an accepted tradeoff at
            # this project's scale -- self-hosted, low hundreds of devices).
            row = conn.execute("SELECT device_id FROM devices WHERE api_key = ?", (x_api_key,)).fetchone()
            if row:
                return
        finally:
            conn.close()

    expected = os.environ.get("LOGIX_INGEST_API_KEY", "")
    if not expected:
        if LOGIX_DEV_MODE:
            return
        raise HTTPException(status_code=503, detail="Server misconfigured: LOGIX_INGEST_API_KEY is not set")
    if not x_api_key or not secrets.compare_digest(x_api_key, expected):
        raise HTTPException(status_code=401, detail="Unauthorized: invalid or missing X-API-Key")


def startup_event():
    # Invoked from the lifespan handler at the top of this module (was
    # @app.on_event("startup"), now deprecated in FastAPI).
    init_db()
    init_control_tables()
    rehydrate_pending_commands()
    REPORTS_DIR.mkdir(parents=True, exist_ok=True)
    if not CONFIG_PATH.exists():
        with open(CONFIG_PATH, "w", encoding="utf-8") as f:
            json.dump(DEFAULT_CONFIG, f, indent=4)
    logger.info("Logix server started (dev_mode=%s, db=%s)", LOGIX_DEV_MODE, DB_PATH.name)


# --- Local admin authentication (email + password) -----------------------
# Google OAuth was removed in favour of a self-contained email + password
# login. The password is read from the LOGIX_ADMIN_PASSWORD environment
# variable (set in server/.env, which is gitignored) -- never hardcoded in
# source or stored in the database. Whoever signs in must (a) be on the
# ADMIN_EMAILS allowlist and (b) present the shared admin password. In dev
# mode a default password ("admin123") is used when none is configured, and a
# passwordless /api/auth/dev-login shortcut exists for the test suite -- both
# are gated behind LOGIX_DEV_MODE and must never be used on a shared server.
ADMIN_PASSWORD = os.environ.get("LOGIX_ADMIN_PASSWORD", "")
if not ADMIN_PASSWORD and LOGIX_DEV_MODE:
    ADMIN_PASSWORD = "admin123"

# Simple in-memory brute-force guard: lock a client IP after LOGIN_MAX_FAILURES
# failed attempts within LOGIN_WINDOW_SECONDS. Resets on a successful login.
LOGIN_MAX_FAILURES = 5
LOGIN_WINDOW_SECONDS = 300
_LOGIN_FAILURES: Dict[str, List[datetime]] = {}


def _login_client_ip(request: Request) -> str:
    return request.client.host if request.client else "unknown"


def _login_is_locked(ip: str) -> bool:
    cutoff = datetime.now() - timedelta(seconds=LOGIN_WINDOW_SECONDS)
    recent = [t for t in _LOGIN_FAILURES.get(ip, []) if t > cutoff]
    _LOGIN_FAILURES[ip] = recent
    return len(recent) >= LOGIN_MAX_FAILURES


def _login_record_failure(ip: str) -> None:
    _LOGIN_FAILURES.setdefault(ip, []).append(datetime.now())


def _login_clear(ip: str) -> None:
    _LOGIN_FAILURES.pop(ip, None)


def _issue_session(email: str, role: str) -> str:
    token = secrets.token_hex(24)
    ACTIVE_TOKENS[token] = {
        "email": email,
        "expires": datetime.now() + timedelta(hours=8),
        "role": role,
    }
    return token


class LoginRequest(BaseModel):
    email: str
    password: str


# Authentication Routes
@app.post("/api/auth/login")
def password_login(payload: LoginRequest, request: Request):
    ip = _login_client_ip(request)
    if _login_is_locked(ip):
        raise HTTPException(status_code=429, detail="Terlalu banyak percobaan login. Coba lagi dalam beberapa menit.")

    email = payload.email.strip().lower()
    admin_roles = get_admin_roles()
    email_ok = email in admin_roles
    # Constant-time compare, always evaluated so wrong-email and wrong-password
    # take the same path. An empty ADMIN_PASSWORD (production with no password
    # configured) can never match -- login stays closed by design, no backdoor.
    password_ok = bool(ADMIN_PASSWORD) and hmac.compare_digest(
        payload.password.encode("utf-8"), ADMIN_PASSWORD.encode("utf-8")
    )
    if not (email_ok and password_ok):
        _login_record_failure(ip)
        raise HTTPException(status_code=401, detail="Email atau password salah, atau email tidak terdaftar sebagai admin.")

    _login_clear(ip)
    token = _issue_session(email, admin_roles[email])
    logger.info("Admin login ok: %s (role=%s)", email, admin_roles[email])
    return {"token": token, "email": email, "role": admin_roles[email]}


@app.post("/api/auth/dev-login")
def dev_login():
    # Dev-only convenience (tests + local): mint a session for the first
    # whitelisted admin without a password. 404 in production posture so it
    # can't be discovered or used on a shared server.
    if not LOGIX_DEV_MODE:
        raise HTTPException(status_code=404, detail="Not found")
    admin_roles = get_admin_roles()
    email = next(iter(admin_roles))
    token = _issue_session(email, admin_roles[email])
    return {"token": token, "email": email, "role": admin_roles[email]}


@app.get("/api/auth/verify")
def verify(email: str = Depends(verify_token)):
    return {"status": "ok", "email": email}


@app.post("/api/auth/logout")
def logout(authorization: Optional[str] = Header(None)):
    if authorization and authorization.startswith("Bearer "):
        token = authorization[7:]
        ACTIVE_TOKENS.pop(token, None)
    return {"status": "success"}


# Config Endpoints
@app.get("/api/config")
def get_config():
    if CONFIG_PATH.exists():
        try:
            with open(CONFIG_PATH, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            logger.warning("Failed to read %s; serving defaults", CONFIG_PATH, exc_info=True)
    return DEFAULT_CONFIG


@app.put("/api/config")
def update_config(config: Dict[str, Any], email: str = Depends(require_permission("config_write"))):
    try:
        with open(CONFIG_PATH, "w", encoding="utf-8") as f:
            json.dump(config, f, indent=4)
        return {"status": "success"}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))


# Heartbeat Endpoint (Workstations post here periodically)
@app.post("/api/heartbeat")
def post_heartbeat(payload: HeartbeatPayload, _: None = Depends(verify_api_key)):
    ad_id = payload.anydesk_id or ""
    device_name = payload.device_name or payload.hostname

    # Persist to the devices registry first -- upsert_device() returns the
    # *effective* display_name (an admin rename overrides what the agent
    # reported), which HEARTBEATS below must also use. Must never block the
    # heartbeat response the agent is waiting on -- log and continue on failure.
    try:
        conn = get_db()
        try:
            device_name = upsert_device(conn, payload.hostname, device_name)
        finally:
            conn.close()
    except Exception:
        logger.warning("heartbeat: upsert_device failed for %s", payload.hostname, exc_info=True)

    now = datetime.now()
    status = payload.status.upper()
    # "Dikunci admin · 14:02" needs the moment the status last CHANGED, not the
    # last heartbeat -- carry the previous timestamp forward while it holds.
    previous = HEARTBEATS.get(payload.hostname)
    status_since = (
        previous["status_since"]
        if previous and previous.get("status_since") and previous.get("status") == status
        else now
    )

    HEARTBEATS[payload.hostname] = {
        "status": status,
        "status_since": status_since,
        "username": payload.username,
        "anydesk_id": ad_id,
        "device_name": device_name,
        "session_started_at": payload.session_started_at or "",
        "access_type": payload.access_type or "",
        "purpose": payload.purpose or "",
        "last_seen": now,
    }

    # Apply any outcomes the agent is reporting for commands delivered on a
    # previous heartbeat. Best-effort: an ack is a report, not something the
    # agent depends on succeeding, so this must never fail the heartbeat.
    if payload.acks:
        try:
            conn = get_db()
            try:
                apply_command_acks(conn, payload.acks)
            finally:
                conn.close()
        except Exception:
            logger.warning("heartbeat: apply_command_acks failed for %s", payload.hostname, exc_info=True)

    # Housekeeping: expire anything (this device's queue or any other's)
    # that has sat 'queued' past COMMAND_TTL_MINUTES -- see
    # reconcile_expired_actions()'s docstring for why this replaced the old
    # inline, this-hostname-only sweep. Best-effort, same as the ack/upsert
    # calls above: must never block the heartbeat response.
    try:
        conn = get_db()
        try:
            reconcile_expired_actions(conn)
        finally:
            conn.close()
    except Exception:
        logger.warning("heartbeat: reconcile_expired_actions failed", exc_info=True)

    # Retrieve pending commands for this workstation -- anything past its
    # TTL was already purged from PENDING_COMMANDS above, so everything
    # remaining here is still within window and safe to deliver.
    cmds = PENDING_COMMANDS.get(payload.hostname, [])
    if cmds:
        PENDING_COMMANDS[payload.hostname] = []  # clear queue either way

    return {"status": "ok", "commands": cmds}


@app.get("/api/active")
def get_active_workstations(email: str = Depends(verify_token)):
    now = datetime.now()
    conn = get_db()
    try:
        categories = {r["hostname"]: r["category"] for r in conn.execute("SELECT hostname, category FROM devices")}
    finally:
        conn.close()
    active_pcs = []
    for host, info in HEARTBEATS.items():
        if compute_sync_status(categories.get(host), info["last_seen"], now) == "online":
            status_since = info.get("status_since")
            active_pcs.append({
                "hostname": host,
                "device_name": info["device_name"],
                "status": info["status"],
                "username": info["username"],
                "anydesk_id": info["anydesk_id"],
                "last_seen": info["last_seen"].isoformat(),
                "status_since": status_since.isoformat() if status_since else None,
                "session_started_at": info.get("session_started_at") or None,
                "access_type": info.get("access_type") or None,
                "purpose": info.get("purpose") or None,
            })
    return active_pcs


# Device registry (Logix Control, Milestone 2). Persisted, unlike /api/active
# above which only reflects the last 5 minutes of in-memory heartbeats -- this
# lists every device ever seen, including stale/offline ones. See
# docs/LOGIX_CONTROL.md §5.
@app.get("/api/devices")
def get_devices(email: str = Depends(require_permission("devices_read"))):
    conn = get_db()
    try:
        rows = conn.execute("SELECT * FROM devices ORDER BY last_seen DESC").fetchall()
        now = datetime.now()
        devices = []
        for r in rows:
            d = dict(r)
            d.pop("api_key", None)  # never expose the ingest credential, even to admins
            live = HEARTBEATS.get(d["hostname"])
            live_last_seen = live["last_seen"] if live else None
            status = compute_sync_status(d["category"], live_last_seen or d["last_seen"], now)
            d["sync_status"] = status
            d["currently_online"] = status == "online"
            devices.append(d)
        return devices
    finally:
        conn.close()


# Device Detail (Dashboard roadmap item G). Joins the registry row with its
# assigned policy and its remote_actions history, and rolls the latter up
# into per-status counts -- the "Sync Health" the Devices tab shows per
# device. Reuses devices_read, same as the list endpoint above: anyone who
# can see the registry can see one device's detail.
@app.get("/api/devices/{device_id}")
def get_device_detail(device_id: str, email: str = Depends(require_permission("devices_read"))):
    conn = get_db()
    try:
        reconcile_expired_actions(conn)

        row = conn.execute("SELECT * FROM devices WHERE device_id = ?", (device_id,)).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Device not found")
        device = dict(row)
        device.pop("api_key", None)

        now = datetime.now()
        live = HEARTBEATS.get(device["hostname"])
        live_last_seen = live["last_seen"] if live else None
        status = compute_sync_status(device["category"], live_last_seen or device["last_seen"], now)
        device["sync_status"] = status
        device["currently_online"] = status == "online"

        policy_row = conn.execute(
            "SELECT policy_name, description, allowed_capabilities, privacy_mode_default, is_system_default "
            "FROM device_policies WHERE policy_name = ?",
            (device["policy_profile"],),
        ).fetchone()
        policy = dict(policy_row) if policy_row else None

        action_rows = conn.execute(
            "SELECT * FROM remote_actions WHERE target_device_id = ? ORDER BY timestamp DESC LIMIT 20",
            (device_id,),
        ).fetchall()
        recent_actions = [dict(r) for r in action_rows]
        # Roadmap item J: the Retry button in the Device Detail modal should
        # mirror the server's actual policy, not a client-side guess -- see
        # RETRYABLE_ACTION_TYPES's comment on why RENAME/REVOKE_API_KEY are
        # excluded, and the retry endpoint below for the same three checks
        # enforced authoritatively.
        for a in recent_actions:
            max_retries = a["max_retries"] if a["max_retries"] is not None else DEFAULT_MAX_RETRIES
            a["retryable"] = (
                a["action_type"] in RETRYABLE_ACTION_TYPES
                and a["status"] in ("failed", "expired")
                and (a["retry_count"] or 0) < max_retries
            )

        sync_health = {"queued": 0, "done": 0, "failed": 0, "expired": 0, "total": 0}
        for status_row in conn.execute(
            "SELECT status, COUNT(*) as count FROM remote_actions WHERE target_device_id = ? GROUP BY status",
            (device_id,),
        ):
            sync_health[status_row["status"]] = status_row["count"]
            sync_health["total"] += status_row["count"]

        return {"device": device, "policy": policy, "recent_actions": recent_actions, "sync_health": sync_health}
    finally:
        conn.close()


# Manual retry (roadmap item J §D). Creates a new queued child row rather
# than mutating the original -- see REMOTE_ACTION_COLUMNS' comment on
# retry_of_action_id -- so the original failed/expired row's history is
# preserved exactly like alerts are resolved rather than deleted. Reuses
# devices_write, the same permission rename_device already requires, since
# this is fundamentally a device-command action, not an alert action.
@app.post("/api/devices/{device_id}/actions/{action_id}/retry")
def retry_action(device_id: str, action_id: int, email: str = Depends(require_permission("devices_write"))):
    conn = get_db()
    try:
        action = conn.execute(
            "SELECT * FROM remote_actions WHERE action_id = ? AND target_device_id = ?",
            (action_id, device_id),
        ).fetchone()
        if not action:
            raise HTTPException(status_code=404, detail="Action not found")
        if action["action_type"] not in RETRYABLE_ACTION_TYPES:
            raise HTTPException(status_code=400, detail=f"{action['action_type']} is not retryable")
        if action["status"] not in ("failed", "expired"):
            raise HTTPException(status_code=400, detail="Only failed or expired actions can be retried")

        retry_count = action["retry_count"] or 0
        max_retries = action["max_retries"] if action["max_retries"] is not None else DEFAULT_MAX_RETRIES
        if retry_count >= max_retries:
            raise HTTPException(status_code=400, detail="Max retry attempts reached")

        device = conn.execute("SELECT hostname FROM devices WHERE device_id = ?", (device_id,)).fetchone()
        if not device:
            raise HTTPException(status_code=404, detail="Device not found")
        hostname = device["hostname"]

        new_command_id = str(uuid.uuid4())
        PENDING_COMMANDS.setdefault(hostname, []).append({
            "command_id": new_command_id,
            "command": action["action_type"],
            "param": action["param"] or "",
            "queued_at": datetime.now().isoformat(),
        })
        conn.execute(
            "INSERT INTO remote_actions "
            "(actor_email, target_device, target_device_id, action_type, status, reason, param, "
            "timestamp, command_id, retry_count, max_retries, retry_of_action_id) "
            "VALUES (?, ?, ?, ?, 'queued', ?, ?, ?, ?, ?, ?, ?)",
            (email, hostname, device_id, action["action_type"], action["reason"] or "", action["param"] or "",
             datetime.now().isoformat(), new_command_id, retry_count + 1, max_retries, action_id),
        )
        conn.commit()
        return {"status": "success", "command_id": new_command_id, "retry_count": retry_count + 1}
    finally:
        conn.close()


# System Alerts (roadmap item I): dashboard-facing read + acknowledge/resolve.
# reconcile_alerts() runs at the top of the GET so the list is never stale by
# more than one request -- see that function's docstring for why there's no
# background scheduler instead.
@app.get("/api/alerts")
def get_alerts(
    active: Optional[bool] = None,
    severity: Optional[str] = None,
    category: Optional[str] = None,
    device_id: Optional[str] = None,
    limit: int = 100,
    offset: int = 0,
    email: str = Depends(require_permission("alerts_read")),
):
    conn = get_db()
    try:
        reconcile_alerts(conn)

        query = "SELECT * FROM alerts WHERE 1=1"
        count_query = "SELECT COUNT(*) FROM alerts WHERE 1=1"
        args = []

        if active is not None:
            clause = " AND status != 'resolved'" if active else " AND status = 'resolved'"
            query += clause
            count_query += clause
        if severity:
            query += " AND severity = ?"
            count_query += " AND severity = ?"
            args.append(severity)
        if category:
            query += " AND category = ?"
            count_query += " AND category = ?"
            args.append(category)
        if device_id:
            query += " AND device_id = ?"
            count_query += " AND device_id = ?"
            args.append(device_id)

        total = conn.execute(count_query, args).fetchone()[0]
        query += " ORDER BY created_at DESC LIMIT ? OFFSET ?"
        args.extend([limit, offset])

        rows = conn.execute(query, args).fetchall()
        alerts = [dict(r) for r in rows]
        return {"total": total, "alerts": alerts}
    finally:
        conn.close()


@app.post("/api/alerts/{alert_id}/acknowledge")
def acknowledge_alert(alert_id: int, email: str = Depends(require_permission("alerts_write"))):
    conn = get_db()
    try:
        existing = conn.execute("SELECT id, status FROM alerts WHERE id = ?", (alert_id,)).fetchone()
        if not existing:
            raise HTTPException(status_code=404, detail="Alert not found")
        if existing["status"] == "active":
            conn.execute(
                "UPDATE alerts SET status = 'acknowledged', acknowledged_at = ? WHERE id = ?",
                (datetime.now().isoformat(), alert_id),
            )
            conn.commit()
        return {"status": "success", "alert_id": alert_id}
    finally:
        conn.close()



# Manually closes an alert. Meaningful mainly for action_failed (a discrete
# event with no auto-clear condition) -- resolving a still-true condition
# alert like device_stale/device_offline just gets recreated by the next
# reconcile_alerts() pass in GET /api/alerts, since it reflects live state
# rather than an admin's dismissal. Use acknowledge for those instead.
@app.post("/api/alerts/{alert_id}/resolve")
def resolve_alert(alert_id: int, email: str = Depends(require_permission("alerts_write"))):
    conn = get_db()
    try:
        existing = conn.execute("SELECT id, status FROM alerts WHERE id = ?", (alert_id,)).fetchone()
        if not existing:
            raise HTTPException(status_code=404, detail="Alert not found")
        if existing["status"] != "resolved":
            conn.execute(
                "UPDATE alerts SET status = 'resolved', resolved_at = ? WHERE id = ?",
                (datetime.now().isoformat(), alert_id),
            )
            conn.commit()
        return {"status": "success", "alert_id": alert_id}
    finally:
        conn.close()


# Device enrollment (Logix Control). See docs/LOGIX_CONTROL.md §5 and the
# locked design in API_CONTRACT.md.
class EnrollInviteRequest(BaseModel):
    category: Optional[str] = "custom"
    display_name: Optional[str] = ""
    note: Optional[str] = ""


class EnrollRequest(BaseModel):
    invite_code: str
    hostname: str
    os: Optional[str] = ""
    os_version: Optional[str] = ""
    agent_version: Optional[str] = ""


# Naive in-memory sliding-window rate limit for POST /api/enroll, keyed by
# source IP. This endpoint has no auth (the device has no key yet), so it's
# the one ingest-adjacent surface that needs its own abuse guard. In-memory
# is an accepted tradeoff HERE specifically (unlike the invite codes
# themselves, which must survive a restart) -- a restart just resets the
# attempt counter, no invite/device data is lost.
_ENROLL_ATTEMPTS: Dict[str, List[datetime]] = {}
ENROLL_RATE_LIMIT_MAX_ATTEMPTS = 10
ENROLL_RATE_LIMIT_WINDOW_MINUTES = 5


def _check_enroll_rate_limit(client_ip: str):
    now = datetime.now()
    window_start = now - timedelta(minutes=ENROLL_RATE_LIMIT_WINDOW_MINUTES)
    attempts = [t for t in _ENROLL_ATTEMPTS.get(client_ip, []) if t > window_start]
    if len(attempts) >= ENROLL_RATE_LIMIT_MAX_ATTEMPTS:
        _ENROLL_ATTEMPTS[client_ip] = attempts
        raise HTTPException(status_code=429, detail="Too many enrollment attempts, try again later")
    attempts.append(now)
    _ENROLL_ATTEMPTS[client_ip] = attempts


@app.post("/api/enroll/invite", status_code=201)
def create_enroll_invite(payload: EnrollInviteRequest, email: str = Depends(require_permission("invite_create"))):
    category = payload.category or "custom"
    if category not in CATEGORY_PROFILES:
        raise HTTPException(status_code=400, detail=f"Unknown category: {category}")

    # High-entropy, grouped for readability -- not a short PIN (the contract
    # explicitly rules that out since this endpoint has no other auth).
    invite_code = "-".join(secrets.token_hex(2).upper() for _ in range(4))
    now = datetime.now()
    expires_at = now + timedelta(minutes=INVITE_TTL_MINUTES)

    conn = get_db()
    try:
        conn.execute(
            "INSERT INTO enrollment_invites "
            "(invite_code, category, display_name, note, created_by, created_at, expires_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
            (invite_code, category, payload.display_name, payload.note, email,
             now.isoformat(), expires_at.isoformat()),
        )
        conn.commit()
    finally:
        conn.close()

    return {"invite_code": invite_code, "expires_at": expires_at.isoformat(), "category": category}


@app.post("/api/enroll")
def redeem_enroll_invite(payload: EnrollRequest, request: Request):
    client_ip = request.client.host if request.client else "unknown"
    _check_enroll_rate_limit(client_ip)

    conn = get_db()
    try:
        invite = conn.execute(
            "SELECT * FROM enrollment_invites WHERE invite_code = ?", (payload.invite_code,)
        ).fetchone()
        if not invite:
            raise HTTPException(status_code=400, detail="Invalid or already-used invite code")
        if invite["used_at"]:
            raise HTTPException(status_code=400, detail="Invalid or already-used invite code")
        if datetime.now() > datetime.fromisoformat(invite["expires_at"]):
            raise HTTPException(status_code=410, detail="Invite code expired")

        category = invite["category"] or "custom"
        device_id = str(uuid.uuid4())
        api_key = secrets.token_hex(32)
        now = datetime.now().isoformat()

        existing = conn.execute("SELECT device_id FROM devices WHERE hostname = ?", (payload.hostname,)).fetchone()
        if existing:
            conn.execute(
                "UPDATE devices SET api_key = ?, category = ?, enrolled_at = ?, "
                "display_name = COALESCE(NULLIF(?, ''), display_name), status = 'active', updated_at = ? "
                "WHERE hostname = ?",
                (api_key, category, now, invite["display_name"], now, payload.hostname),
            )
            device_id = existing["device_id"]
        else:
            conn.execute(
                "INSERT INTO devices (device_id, hostname, display_name, category, api_key, "
                "enrolled_at, last_seen, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (device_id, payload.hostname, invite["display_name"] or payload.hostname, category,
                 api_key, now, now, now, now),
            )

        conn.execute(
            "UPDATE enrollment_invites SET used_at = ?, used_by_device_id = ? WHERE invite_code = ?",
            (now, device_id, payload.invite_code),
        )
        conn.commit()
    finally:
        conn.close()

    profile = CATEGORY_PROFILES.get(category, CATEGORY_PROFILES["custom"])
    return {
        "device_id": device_id,
        "api_key": api_key,
        "category": category,
        "profile": profile,
        "server_time": datetime.now().isoformat(),
    }


@app.post("/api/devices/{device_id}/revoke")
def revoke_device(device_id: str, email: str = Depends(require_permission("devices_revoke"))):
    conn = get_db()
    try:
        existing = conn.execute("SELECT device_id, hostname FROM devices WHERE device_id = ?", (device_id,)).fetchone()
        if not existing:
            raise HTTPException(status_code=404, detail="Device not found")
        conn.execute(
            "UPDATE devices SET api_key = NULL, updated_at = ? WHERE device_id = ?",
            (datetime.now().isoformat(), device_id),
        )
        conn.commit()
        # Mirrors rename_device's audit trail below -- revoking a device's
        # ingest credential is exactly as auditable as renaming it, and the
        # Device Detail modal's Recent Commands list should show it.
        log_remote_action(conn, email, existing["hostname"], "REVOKE_API_KEY", "done", result_summary="API key revoked")
    finally:
        conn.close()
    return {"status": "success", "detail": f"Revoked API key for device {device_id}"}


class RenameDeviceRequest(BaseModel):
    hostname: str
    display_name: str


# Keyed by hostname, not device_id, matching ControlRequest's existing
# convention for the "live session" surface (GET /api/active doesn't carry
# device_id today). Marks display_name_set_by_admin so upsert_device() stops
# overwriting it from the agent's own heartbeat-reported name -- see the
# comment on that column.
@app.put("/api/devices/rename")
def rename_device(payload: RenameDeviceRequest, email: str = Depends(require_permission("devices_write"))):
    name = payload.display_name.strip()
    if not name:
        raise HTTPException(status_code=400, detail="display_name cannot be empty")
    conn = get_db()
    try:
        existing = conn.execute("SELECT device_id FROM devices WHERE hostname = ?", (payload.hostname,)).fetchone()
        if not existing:
            raise HTTPException(status_code=404, detail="Device not found")
        conn.execute(
            "UPDATE devices SET display_name = ?, display_name_set_by_admin = 1, updated_at = ? WHERE hostname = ?",
            (name, datetime.now().isoformat(), payload.hostname),
        )
        conn.commit()
        # Synchronous, server-side-only edit -- no agent round-trip, so
        # 'done' applies immediately (unlike LOCK/BROADCAST's 'queued').
        log_remote_action(conn, email, payload.hostname, "RENAME", "done", result_summary=f"Renamed to '{name}'")
    finally:
        conn.close()
    # Reflect instantly in the in-memory "online now" cache too -- otherwise
    # /api/active (what the Monitoring tab actually polls) wouldn't show the
    # new name until this device's next heartbeat, up to 30s away.
    if payload.hostname in HEARTBEATS:
        HEARTBEATS[payload.hostname]["device_name"] = name
    return {"status": "success", "display_name": name}


# --- Control Command Endpoints (Admins post commands here) -----------------

def enforce_command_policy(hostname: str, command_type: str, reason: str) -> None:
    """Gate a control command on the target device's assigned policy profile
    (docs/LOGIX_CONTROL.md §5 -- this is where device_policies /
    command_allowlist stop being data-only). Raises 403 when the policy
    disallows the command, 400 when the policy requires a reason and none
    was given. Fails open for LOCK/BROADCAST when no rule exists (a device
    the registry hasn't seen yet keeps the pre-Control behavior) and closed
    for every newer, larger-permission command type."""
    rule = None
    try:
        conn = get_db()
        try:
            device = conn.execute(
                "SELECT policy_profile FROM devices WHERE hostname = ?", (hostname,)
            ).fetchone()
            if device:
                rule = conn.execute(
                    "SELECT allowed, requires_reason FROM command_allowlist "
                    "WHERE policy_name = ? AND command_type = ?",
                    (device["policy_profile"], command_type),
                ).fetchone()
        finally:
            conn.close()
    except HTTPException:
        raise
    except Exception:
        rule = None

    if rule is None:
        if command_type in ("LOCK", "BROADCAST"):
            return
        raise HTTPException(status_code=403,
                            detail=f"{command_type} is not permitted: no policy rule covers this device")
    if not rule["allowed"]:
        raise HTTPException(status_code=403,
                            detail=f"Device policy does not allow {command_type}")
    if rule["requires_reason"] and not (reason or "").strip():
        raise HTTPException(status_code=400,
                            detail=f"Device policy requires a reason for {command_type}")


def queue_command(email: str, hostname: str, command_type: str, param: str = "",
                  reason: str = "", command_id: Optional[str] = None) -> str:
    """Append one command to a device's in-memory delivery queue and write
    its audit row. The audit write is best-effort -- it must never block the
    command that was already queued (the original retrofit contract from
    docs/LOGIX_CONTROL.md §6)."""
    command_id = command_id or str(uuid.uuid4())
    entry = {
        "command_id": command_id, "command": command_type, "param": param,
        "queued_at": datetime.now().isoformat(),
    }
    if command_type == "BROADCAST":
        entry["reason"] = reason or "Direction Message"
    PENDING_COMMANDS.setdefault(hostname, []).append(entry)
    try:
        conn = get_db()
        try:
            log_remote_action(conn, email, hostname, command_type, "queued", reason=reason,
                               param=param, result_summary=f"{command_type} queued for {hostname}",
                               command_id=command_id)
        finally:
            conn.close()
    except Exception:
        logger.warning("queue_command: audit write failed for %s %s", command_type, hostname, exc_info=True)
    return command_id


@app.post("/api/control/lock")
def queue_lock_command(payload: ControlRequest, email: str = Depends(require_permission("lock"))):
    enforce_command_policy(payload.hostname, "LOCK", payload.reason)
    queue_command(email, payload.hostname, "LOCK", reason=payload.reason)
    return {"status": "success", "detail": f"Lock command queued for {payload.hostname}"}


@app.post("/api/control/broadcast")
def queue_broadcast_command(payload: ControlRequest, email: str = Depends(require_permission("broadcast"))):
    host = payload.hostname
    msg = payload.param or "Perhatian: Alert dari Administrator."

    if host == "ALL":
        # Broadcast to all known heartbeating hosts whose policy allows it.
        # All fanned-out copies share one command_id, matching the "one
        # admin action, one audit row" precedent -- the first device to ack
        # it transitions the shared row to done/failed (apply_command_acks'
        # UPDATE guard makes later acks for the same command_id no-ops).
        command_id = str(uuid.uuid4())
        queued_at = datetime.now().isoformat()
        skipped = []
        for h in HEARTBEATS.keys():
            try:
                enforce_command_policy(h, "BROADCAST", payload.reason)
            except HTTPException:
                skipped.append(h)
                continue
            PENDING_COMMANDS.setdefault(h, []).append({
                "command_id": command_id, "command": "BROADCAST", "param": msg,
                "reason": payload.reason or "Direction Message", "queued_at": queued_at,
            })
        detail = "Broadcast queued for all hosts"
        if skipped:
            detail += f" (skipped by policy: {', '.join(sorted(skipped))})"
        # One audit row for this one admin action, not one per fanned-out
        # host -- an admin took a single action; that's what the log reflects.
        try:
            conn = get_db()
            try:
                log_remote_action(conn, email, "ALL", "BROADCAST", "queued",
                                   reason=payload.reason, param=msg, result_summary=detail,
                                   command_id=command_id)
            finally:
                conn.close()
        except Exception:
            logger.warning("broadcast: audit write failed for ALL", exc_info=True)
        return {"status": "success", "detail": detail}

    enforce_command_policy(host, "BROADCAST", payload.reason)
    queue_command(email, host, "BROADCAST", param=msg, reason=payload.reason)
    return {"status": "success", "detail": f"Broadcast queued for {host}"}


class PowerRequest(BaseModel):
    hostname: str
    action: str  # shutdown | restart | logoff
    reason: Optional[str] = ""


POWER_ACTIONS = {"shutdown": "SHUTDOWN", "restart": "RESTART", "logoff": "LOGOFF"}


# Power actions (Logix Control). The agent executes these with a 30-second
# on-screen warning (never instantly, never silently) -- see the SHUTDOWN/
# RESTART/LOGOFF handlers in windows/logbook_common.ps1.
@app.post("/api/control/power")
def queue_power_command(payload: PowerRequest, email: str = Depends(require_permission("power"))):
    action_type = POWER_ACTIONS.get((payload.action or "").lower())
    if not action_type:
        raise HTTPException(status_code=400, detail="action must be one of: shutdown, restart, logoff")
    enforce_command_policy(payload.hostname, action_type, payload.reason)
    queue_command(email, payload.hostname, action_type, reason=payload.reason)
    return {"status": "success", "detail": f"{action_type} queued for {payload.hostname}"}


# On-demand screen view (Logix Control). One capture per explicit admin
# action: queues SCREENSHOT to the agent, which captures the screen, shows
# the local user a notice that it happened (never silent -- docs/PRIVACY.md
# "Design boundaries -- Logix Control"), and uploads the image on the spot.
# Only the latest capture per device is stored, never a history.
@app.post("/api/control/screenshot")
def queue_screenshot_command(payload: ControlRequest, email: str = Depends(require_permission("screenshot"))):
    enforce_command_policy(payload.hostname, "SCREENSHOT", payload.reason)
    command_id = queue_command(email, payload.hostname, "SCREENSHOT", reason=payload.reason)
    return {"status": "success", "detail": f"Screenshot request queued for {payload.hostname}",
            "command_id": command_id}


class ScreenshotUpload(BaseModel):
    hostname: str
    command_id: str
    image_base64: str
    content_type: Optional[str] = "image/jpeg"


# ~4 MB of base64 (~3 MB decoded) is far above what the agent's downscaled
# JPEG produces; anything bigger is malformed or abusive.
SCREENSHOT_MAX_BASE64_CHARS = 4_000_000


@app.post("/api/control/screenshot/upload")
def upload_screenshot(payload: ScreenshotUpload, _: None = Depends(verify_api_key)):
    if not payload.image_base64 or len(payload.image_base64) > SCREENSHOT_MAX_BASE64_CHARS:
        raise HTTPException(status_code=400, detail="image_base64 missing or too large")
    conn = get_db()
    try:
        # The upload must answer a real, audit-logged SCREENSHOT command for
        # this exact hostname -- an agent credential alone can't push
        # arbitrary images into the dashboard.
        action = conn.execute(
            "SELECT action_id FROM remote_actions WHERE command_id = ? "
            "AND action_type = 'SCREENSHOT' AND target_device = ?",
            (payload.command_id, payload.hostname),
        ).fetchone()
        if not action:
            raise HTTPException(status_code=400, detail="Unknown screenshot command_id for this hostname")
        device = conn.execute(
            "SELECT device_id FROM devices WHERE hostname = ?", (payload.hostname,)
        ).fetchone()
        if not device:
            raise HTTPException(status_code=404, detail="Device not found")
        now = datetime.now().isoformat()
        conn.execute(
            "INSERT INTO device_screenshots (device_id, hostname, command_id, image_base64, content_type, captured_at) "
            "VALUES (?, ?, ?, ?, ?, ?) "
            "ON CONFLICT(device_id) DO UPDATE SET hostname = excluded.hostname, "
            "command_id = excluded.command_id, image_base64 = excluded.image_base64, "
            "content_type = excluded.content_type, captured_at = excluded.captured_at",
            (device["device_id"], payload.hostname, payload.command_id,
             payload.image_base64, payload.content_type or "image/jpeg", now),
        )
        conn.commit()
    finally:
        conn.close()
    return {"status": "success"}


@app.get("/api/devices/{device_id}/screenshot")
def get_device_screenshot(device_id: str, email: str = Depends(require_permission("screenshot"))):
    conn = get_db()
    try:
        row = conn.execute(
            "SELECT hostname, command_id, image_base64, content_type, captured_at "
            "FROM device_screenshots WHERE device_id = ?",
            (device_id,),
        ).fetchone()
    finally:
        conn.close()
    if not row:
        raise HTTPException(status_code=404, detail="No screenshot captured for this device")
    return dict(row)


# --- Device replies (user -> admin messages) --------------------------------

class ReplyPayload(BaseModel):
    hostname: str
    message: str
    command_id: Optional[str] = ""
    device_name: Optional[str] = ""


@app.post("/api/replies")
def post_reply(payload: ReplyPayload, _: None = Depends(verify_api_key)):
    message = (payload.message or "").strip()
    if not message:
        raise HTTPException(status_code=400, detail="message cannot be empty")
    if len(message) > REPLY_MAX_LENGTH:
        raise HTTPException(status_code=400, detail=f"message exceeds {REPLY_MAX_LENGTH} characters")
    conn = get_db()
    try:
        device = conn.execute(
            "SELECT device_id, display_name FROM devices WHERE hostname = ?", (payload.hostname,)
        ).fetchone()
        conn.execute(
            "INSERT INTO device_replies (device_id, hostname, device_name, message, command_id, created_at) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (device["device_id"] if device else None,
             payload.hostname,
             payload.device_name or (device["display_name"] if device else payload.hostname),
             message, payload.command_id or None, datetime.now().isoformat()),
        )
        conn.commit()
    finally:
        conn.close()
    return {"status": "success"}


@app.get("/api/replies")
def get_replies(
    unread: Optional[bool] = None,
    limit: int = 50,
    offset: int = 0,
    email: str = Depends(require_permission("replies_read")),
):
    conn = get_db()
    try:
        query = "SELECT * FROM device_replies WHERE 1=1"
        count_query = "SELECT COUNT(*) FROM device_replies WHERE 1=1"
        args: List[Any] = []
        if unread is not None:
            clause = " AND read_at IS NULL" if unread else " AND read_at IS NOT NULL"
            query += clause
            count_query += clause
        total = conn.execute(count_query, args).fetchone()[0]
        unread_count = conn.execute(
            "SELECT COUNT(*) FROM device_replies WHERE read_at IS NULL"
        ).fetchone()[0]
        query += " ORDER BY created_at DESC LIMIT ? OFFSET ?"
        args.extend([limit, offset])
        rows = conn.execute(query, args).fetchall()
        replies = []
        for r in rows:
            reply = dict(r)
            # Show what the user was replying to, when the reply is linked
            # to a broadcast the admin sent.
            if reply.get("command_id"):
                original = conn.execute(
                    "SELECT param FROM remote_actions WHERE command_id = ? AND action_type = 'BROADCAST' LIMIT 1",
                    (reply["command_id"],),
                ).fetchone()
                reply["in_reply_to"] = original["param"] if original else None
            else:
                reply["in_reply_to"] = None
            replies.append(reply)
        return {"total": total, "unread": unread_count, "replies": replies}
    finally:
        conn.close()


@app.post("/api/replies/{reply_id}/read")
def mark_reply_read(reply_id: int, email: str = Depends(require_permission("replies_write"))):
    conn = get_db()
    try:
        existing = conn.execute("SELECT id, read_at FROM device_replies WHERE id = ?", (reply_id,)).fetchone()
        if not existing:
            raise HTTPException(status_code=404, detail="Reply not found")
        if not existing["read_at"]:
            conn.execute(
                "UPDATE device_replies SET read_at = ? WHERE id = ?",
                (datetime.now().isoformat(), reply_id),
            )
            conn.commit()
    finally:
        conn.close()
    return {"status": "success", "reply_id": reply_id}


# Logging Endpoints
@app.post("/api/log")
def log_event(logs: List[LogPayload], _: None = Depends(verify_api_key)):
    conn = get_db()
    inserted = 0
    try:
        cols = list(BASE_COLUMNS.keys())
        cols.remove("id")
        placeholders = ",".join("?" for _ in cols)
        sql = f"INSERT INTO physical_log ({','.join(cols)}) VALUES ({placeholders})"
        
        for payload in logs:
            # event_uid is the real identity when present (survives a retry
            # with a different timestamp, unlike the tuple match below).
            # Empty means a legacy agent that hasn't upgraded yet -- fall
            # back to the old match so it keeps deduping the way it always
            # has, rather than assuming every caller sends the new field.
            if payload.event_uid:
                cur = conn.execute(
                    "SELECT 1 FROM physical_log WHERE event_uid = ?",
                    (payload.event_uid,)
                )
            else:
                cur = conn.execute(
                    "SELECT 1 FROM physical_log WHERE session_id = ? AND event = ? AND timestamp = ?",
                    (payload.session_id, payload.event, payload.timestamp)
                )
            if cur.fetchone():
                continue

            vals = [
                payload.timestamp,
                payload.event,
                payload.username,
                payload.nama,
                payload.nim,
                payload.tujuan,
                payload.keterangan,
                payload.session_type,
                payload.source,
                payload.session_id,
                payload.windows_user,
                payload.hostname,
                payload.client_ip,
                payload.anydesk_detected,
                payload.raw_json,
                payload.event_uid or None,
                1  # mark as synced on the server DB
            ]
            conn.execute(sql, vals)
            inserted += 1
        
        conn.commit()
    except Exception as e:
        conn.rollback()
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()
    
    return {"status": "success", "inserted": inserted}


# Riwayat (v3) filters the session log by a period preset, so both log
# endpoints take an inclusive YYYY-MM-DD range. `timestamp` is stored as an
# ISO string, so a lexical compare on its date prefix is both correct and
# index-friendly. Returns the SQL fragment plus its args.
def _date_range_clause(column: str, start_date: Optional[str], end_date: Optional[str]):
    clause, args = "", []
    for label, value, op in (("start_date", start_date, ">="), ("end_date", end_date, "<=")):
        if not value:
            continue
        try:
            datetime.strptime(value, "%Y-%m-%d")
        except ValueError:
            raise HTTPException(status_code=400, detail=f"Invalid {label}, expected YYYY-MM-DD")
        clause += f" AND substr({column}, 1, 10) {op} ?"
        args.append(value)
    return clause, args


# Pairs each session's START with whichever close event came first and yields
# one span per session. Shared by the Riwayat summary and the CSV exports so
# "148 j total / 96 sesi / 31 pengguna" and the downloaded file can never
# disagree about what counts as a session.
def _session_spans(conn, start_date: Optional[str] = None, end_date: Optional[str] = None):
    clause, args = _date_range_clause("timestamp", start_date, end_date)
    rows = conn.execute(
        "SELECT session_id, event, timestamp, hostname, nama, nim, username, tujuan, session_type "
        f"FROM physical_log WHERE session_id IS NOT NULL AND session_id != ''{clause} "
        "ORDER BY session_id, timestamp ASC",
        args,
    ).fetchall()

    grouped: Dict[str, List[Dict[str, Any]]] = {}
    for r in rows:
        grouped.setdefault(r["session_id"], []).append(dict(r))

    closing = {"END", "LOCK", "AUTO_FINISH", "AUTO_CLOSE", "DISCONNECT", "LOGOFF"}
    spans = []
    for session_id, events in grouped.items():
        start_row = next((e for e in events if e["event"] == "START"), None)
        if not start_row:
            continue
        close_row = next((e for e in events if e["event"] in closing), None)
        duration = None
        if close_row:
            try:
                duration = max(
                    0.0,
                    (
                        datetime.fromisoformat(close_row["timestamp"])
                        - datetime.fromisoformat(start_row["timestamp"])
                    ).total_seconds(),
                )
            except Exception:
                duration = None
        spans.append({
            "session_id": session_id,
            "timestamp": start_row["timestamp"],
            "hostname": start_row["hostname"] or "",
            "nama": start_row["nama"] or "",
            "nim": start_row["nim"] or "",
            "username": start_row["username"] or "",
            "tujuan": start_row["tujuan"] or "",
            "session_type": start_row["session_type"] or "",
            "duration_seconds": duration,
        })
    return spans


# The three inline summary numbers on Riwayat. Deliberately derived from
# _session_spans rather than a separate aggregation, so the sentence always
# matches a manual count of the table below it.
@app.get("/api/sessions/summary")
def get_sessions_summary(
    start_date: Optional[str] = None,
    end_date: Optional[str] = None,
    email: str = Depends(require_permission("sessions_read")),
):
    conn = get_db()
    try:
        spans = _session_spans(conn, start_date, end_date)
    finally:
        conn.close()
    total_seconds = sum(s["duration_seconds"] or 0 for s in spans)
    users = {s["nim"] or s["nama"] or s["username"] for s in spans}
    users.discard("")
    return {
        "hours": round(total_seconds / 3600, 1),
        "sessions": len(spans),
        "users": len(users),
    }


# Riwayat's "Log Sesi" table is one row PER SESSION with a real duration, not
# one row per physical_log event -- /api/sessions below still returns the raw
# event stream for anything that needs it (and for backward compatibility).
@app.get("/api/sessions/spans")
def get_session_spans(
    limit: int = 25,
    offset: int = 0,
    hostname: Optional[str] = None,
    username: Optional[str] = None,
    start_date: Optional[str] = None,
    end_date: Optional[str] = None,
    email: str = Depends(require_permission("sessions_read")),
):
    conn = get_db()
    try:
        spans = _session_spans(conn, start_date, end_date)
    finally:
        conn.close()

    if hostname:
        needle = hostname.lower()
        spans = [s for s in spans if needle in s["hostname"].lower()]
    if username:
        needle = username.lower()
        spans = [s for s in spans if needle in f"{s['nama']} {s['username']} {s['nim']}".lower()]

    spans.sort(key=lambda s: s["timestamp"], reverse=True)
    return {"total": len(spans), "sessions": spans[offset:offset + limit]}


@app.get("/api/sessions")
def get_sessions(
    limit: int = 100,
    offset: int = 0,
    hostname: Optional[str] = None,
    username: Optional[str] = None,
    start_date: Optional[str] = None,
    end_date: Optional[str] = None,
    email: str = Depends(require_permission("sessions_read"))
):
    conn = get_db()
    try:
        query = "SELECT * FROM physical_log WHERE 1=1"
        count_query = "SELECT COUNT(*) FROM physical_log WHERE 1=1"
        args = []

        if hostname:
            query += " AND hostname LIKE ?"
            count_query += " AND hostname LIKE ?"
            args.append(f"%{hostname}%")
        if username:
            query += " AND (nama LIKE ? OR username LIKE ?)"
            count_query += " AND (nama LIKE ? OR username LIKE ?)"
            args.append(f"%{username}%")
            args.append(f"%{username}%")

        date_clause, date_args = _date_range_clause("timestamp", start_date, end_date)
        query += date_clause
        count_query += date_clause
        args.extend(date_args)

        total = conn.execute(count_query, args).fetchone()[0]
        query += " ORDER BY timestamp DESC LIMIT ? OFFSET ?"
        args.extend([limit, offset])
        
        rows = conn.execute(query, args).fetchall()
        sessions = [dict(r) for r in rows]
        return {"total": total, "sessions": sessions}
    finally:
        conn.close()


# Audit log for Control commands (Logix Control, Milestone 2). Read-only.
# Rows show 'queued', never 'done' -- see docs/LOGIX_CONTROL.md §6 for why.
@app.get("/api/audit-log")
def get_audit_log(
    limit: int = 100,
    offset: int = 0,
    target_device: Optional[str] = None,
    status: Optional[str] = None,
    start_date: Optional[str] = None,
    end_date: Optional[str] = None,
    email: str = Depends(require_permission("audit_log_read"))
):
    conn = get_db()
    try:
        query = "SELECT * FROM remote_actions WHERE 1=1"
        count_query = "SELECT COUNT(*) FROM remote_actions WHERE 1=1"
        args = []

        if target_device:
            query += " AND target_device LIKE ?"
            count_query += " AND target_device LIKE ?"
            args.append(f"%{target_device}%")

        if status:
            query += " AND status = ?"
            count_query += " AND status = ?"
            args.append(status)

        # Same period preset as the session log, so switching sub-tabs keeps
        # the range the admin already chose.
        date_clause, date_args = _date_range_clause("timestamp", start_date, end_date)
        query += date_clause
        count_query += date_clause
        args.extend(date_args)

        total = conn.execute(count_query, args).fetchone()[0]
        query += " ORDER BY timestamp DESC LIMIT ? OFFSET ?"
        args.extend([limit, offset])

        rows = conn.execute(query, args).fetchall()
        actions = [dict(r) for r in rows]
        return {"total": total, "actions": actions}
    finally:
        conn.close()


# Rich Analytics Endpoints
@app.get("/api/analytics")
def get_analytics(email: str = Depends(require_permission("analytics_read"))):
    conn = get_db()
    try:
        rows = conn.execute("SELECT session_id, event, timestamp, hostname, tujuan FROM physical_log ORDER BY session_id, timestamp ASC").fetchall()
        
        sessions = {}
        for r in rows:
            sid = r["session_id"]
            if not sid:
                continue
            if sid not in sessions:
                sessions[sid] = []
            sessions[sid].append(dict(r))
            
        total_seconds = 0
        hostname_seconds = {}
        purpose_counts = {}
        hour_counts = [0] * 24
        dow_hour = [[0] * 24 for _ in range(7)]  # weekday (Mon=0..Sun=6) x hour-of-day
        active_sessions_count = 0
        
        for sid, s_rows in sessions.items():
            start_row = next((r for r in s_rows if r["event"] == "START"), None)
            close_row = next((r for r in s_rows if r["event"] in ["END", "LOCK", "AUTO_FINISH", "AUTO_CLOSE", "DISCONNECT", "LOGOFF"]), None)
            
            if start_row:
                active_sessions_count += 1
                host = start_row["hostname"] or "Unknown"
                tujuan = start_row["tujuan"] or "Lain-lain"
                
                try:
                    dt = datetime.fromisoformat(start_row["timestamp"])
                    hour_counts[dt.hour] += 1
                    dow_hour[dt.weekday()][dt.hour] += 1
                except Exception:
                    pass
                    
                purpose_counts[tujuan] = purpose_counts.get(tujuan, 0) + 1
                
                if close_row:
                    try:
                        t_start = datetime.fromisoformat(start_row["timestamp"])
                        t_close = datetime.fromisoformat(close_row["timestamp"])
                        diff = (t_close - t_start).total_seconds()
                        if diff > 0:
                            total_seconds += diff
                            hostname_seconds[host] = hostname_seconds.get(host, 0) + diff
                    except Exception:
                        pass
        
        total_hours = round(total_seconds / 3600, 1)
        by_workstation = [{"hostname": h, "hours": round(s / 3600, 1)} for h, s in hostname_seconds.items()]
        by_purpose = [{"purpose": p, "count": c} for p, c in purpose_counts.items()]
        by_hour = [{"hour": f"{h:02d}:00", "count": count} for h, count in enumerate(hour_counts)]
        _DOW = ["Sen", "Sel", "Rab", "Kam", "Jum", "Sab", "Min"]
        by_dow_hour = [{"day": _DOW[d], "hours": dow_hour[d]} for d in range(7)]

        return {
            "totals": {
                "hours": total_hours,
                "sessions": active_sessions_count,
                "workstations": len(by_workstation)
            },
            "by_workstation": sorted(by_workstation, key=lambda x: x["hours"], reverse=True)[:5], # top 5
            "by_purpose": sorted(by_purpose, key=lambda x: x["count"], reverse=True),
            "by_hour": by_hour,
            "by_dow_hour": by_dow_hour
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        conn.close()


# Report Generation Endpoint
@app.get("/api/reports")
def download_report(
    today: bool = False,
    full: bool = False,
    start_date: Optional[str] = None,
    end_date: Optional[str] = None,
    format: str = "xlsx",
    email: str = Depends(require_permission("reports_read")),
):
    # start_date/end_date map directly onto logbook_report.py's existing
    # --start/--end flags (YYYY-MM-DD, end inclusive) -- that script already
    # validates and parses them; this endpoint just passes them through.
    if start_date or end_date:
        for label, value in (("start_date", start_date), ("end_date", end_date)):
            if value:
                try:
                    datetime.strptime(value, "%Y-%m-%d")
                except ValueError:
                    raise HTTPException(status_code=400, detail=f"Invalid {label}, expected YYYY-MM-DD")

    if format not in ("xlsx", "csv", "per_user"):
        raise HTTPException(status_code=400, detail="Invalid format, expected xlsx, csv or per_user")

    # The two CSV shapes Riwayat's Unduh menu offers. Both are built from
    # _session_spans -- the same pairing the summary sentence uses -- so an
    # export can never disagree with the numbers on screen. The xlsx path
    # below is untouched, keeping the existing report byte-identical.
    if format in ("csv", "per_user"):
        conn = get_db()
        try:
            spans = _session_spans(conn, start_date, end_date)
        finally:
            conn.close()
        spans.sort(key=lambda s: s["timestamp"], reverse=True)

        buffer = io.StringIO()
        writer = csv.writer(buffer)
        if format == "csv":
            writer.writerow(["Waktu", "Perangkat", "Pengguna", "NIM", "Tipe akses", "Tujuan", "Durasi (menit)"])
            for s in spans:
                writer.writerow([
                    s["timestamp"], s["hostname"], s["nama"] or s["username"], s["nim"],
                    s["session_type"], s["tujuan"],
                    "" if s["duration_seconds"] is None else round(s["duration_seconds"] / 60),
                ])
            stem = "sesi"
        else:
            per_user: Dict[str, Dict[str, Any]] = {}
            for s in spans:
                key = s["nim"] or s["nama"] or s["username"] or "-"
                entry = per_user.setdefault(key, {
                    "nama": s["nama"] or s["username"], "nim": s["nim"], "sessions": 0, "seconds": 0.0,
                })
                entry["sessions"] += 1
                entry["seconds"] += s["duration_seconds"] or 0
            writer.writerow(["Nama", "NIM", "Jumlah sesi", "Total jam"])
            for entry in sorted(per_user.values(), key=lambda e: e["seconds"], reverse=True):
                writer.writerow([entry["nama"], entry["nim"], entry["sessions"], round(entry["seconds"] / 3600, 2)])
            stem = "rekap-per-pengguna"

        filename = f"{stem}-{datetime.now().strftime('%Y%m%d-%H%M%S')}.csv"
        # utf-8-sig: Excel on Windows needs the BOM to read the Indonesian
        # names as UTF-8 rather than the system codepage.
        return Response(
            content=buffer.getvalue().encode("utf-8-sig"),
            media_type="text/csv; charset=utf-8",
            headers={"Content-Disposition": f'attachment; filename="{filename}"'},
        )

    out_file = REPORTS_DIR / f"report-{datetime.now().strftime('%Y%m%d-%H%M%S')}.xlsx"
    cmd = [
        "python",
        str(BASE_DIR.parent / "logix" / "logbook_report.py"),
        "--db", str(DB_PATH),
        "--out", str(out_file)
    ]
    if start_date or end_date:
        if start_date:
            cmd.extend(["--start", start_date])
        if end_date:
            cmd.extend(["--end", end_date])
    elif today:
        cmd.append("--today")
    elif full:
        cmd.append("--full")

    try:
        res = subprocess.run(cmd, capture_output=True, text=True, check=True)
        if out_file.exists():
            return FileResponse(
                path=str(out_file), 
                filename=out_file.name, 
                media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
            )
        else:
            raise HTTPException(status_code=500, detail=f"Report file not generated. Output: {res.stdout}")
    except subprocess.CalledProcessError as e:
        raise HTTPException(status_code=500, detail=f"Report failed: {e.stderr or e.stdout}")


# Liveness probe for the dashboard's sidebar connectivity indicator (roadmap
# item H). Deliberately unauthenticated -- "is the server reachable at all"
# is a different question from "is my session token still valid" (that's
# already handled by fetchWithAuth's 401 -> onSessionExpired path), and a
# health check shouldn't paint the sidebar red just because a token expired.
@app.get("/api/health")
def health_check():
    return {"status": "ok", "server_time": datetime.now().isoformat()}


# Browsers request this automatically regardless of any <link rel="icon">;
# without a route it 404s on every page load. No icon asset is worth adding
# for this -- a silent 204 is enough to stop the console noise.
@app.get("/favicon.ico", include_in_schema=False)
def favicon():
    return Response(status_code=204)


# Mount frontend static directory. Prefers the built React dashboard
# (frontend/dist, produced by `npm run build` in frontend/) when present;
# falls back to the legacy vanilla-JS dashboard in server/static/ so a
# checkout without Node still serves a working UI.
_react_dist = BASE_DIR.parent / "frontend" / "dist"
if (_react_dist / "index.html").exists():
    static_dir = _react_dist
else:
    static_dir = BASE_DIR / "static"
    static_dir.mkdir(exist_ok=True)

@app.get("/")
def read_root():
    index_file = static_dir / "index.html"
    if index_file.exists():
        return FileResponse(str(index_file))
    return JSONResponse({"message": "Logix Central Server Active. Static Dashboard missing."})

app.mount("/", StaticFiles(directory=str(static_dir)), name="static")
