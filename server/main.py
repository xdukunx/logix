import os
import json
import sqlite3
import subprocess
import secrets
import urllib.request
import urllib.parse
import uuid
from datetime import datetime, timedelta
from typing import Optional, List, Dict, Any
from pathlib import Path

from fastapi import FastAPI, HTTPException, Header, Depends, Query, Body, Cookie, Request
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse, JSONResponse, RedirectResponse, HTMLResponse
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

app = FastAPI(title="Logix Central Admin Server")

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

# Policy profiles: named bundles a device can be assigned to. Seeded with the
# 7 profiles from docs/LOGIX_CONTROL.md §5 -- data only, nothing reads or
# enforces allowed_capabilities yet (there's only "lock" and "broadcast" to
# allow, so there's nothing to meaningfully differentiate profiles by).
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
# 7 policies x 2 commands (the only two that exist) = 14 rows, seeded as
# today's actual behavior (any admin token can lock/broadcast any device, no
# reason required) expressed as data -- nothing enforces this yet.
COMMAND_ALLOWLIST_COLUMNS = {
    "policy_name": "TEXT NOT NULL",
    "command_type": "TEXT NOT NULL",
    "allowed": "INTEGER DEFAULT 1",
    "requires_reason": "INTEGER DEFAULT 0",
}
KNOWN_COMMAND_TYPES = ["LOCK", "BROADCAST"]

# Audit log for every Control command, retrofitted onto the two that already
# existed (lock, broadcast) rather than left as an empty table for a future
# feature. IMPORTANT LIMITATION, stated here and in docs/LOGIX_CONTROL.md §6:
# status can only ever be 'queued' or 'failed' -- this proves an admin queued
# a command, not that the device executed it. True execution confirmation
# needs the agent to report outcomes back, which does not exist yet.
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

class HeartbeatPayload(BaseModel):
    hostname: str
    status: str
    username: Optional[str] = ""
    anydesk_id: Optional[str] = ""
    device_name: Optional[str] = ""

class ControlRequest(BaseModel):
    hostname: str
    param: Optional[str] = ""
    reason: Optional[str] = ""

DEFAULT_CONFIG = {
    "branding": {
        "logoText": "Logix",
        "logoPath": "C:\\lab\\logo.png",
        "title": "Report Logbook",
        "subtitle": "Computational Workstation",
        "colors": {
            "primary": "#073763",
            "accent": "#741B47",
            "muted": "#C0C0C0",
            "text": "#FFFFFF"
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
        "hintReady": "Siap disimpan. Nama, NIM, tujuan, dan keterangan akan dikirim ke SQLite."
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

        now = datetime.now().isoformat()
        for policy_name, description, privacy_mode_default in SYSTEM_POLICY_PROFILES:
            # INSERT OR IGNORE: idempotent across restarts, never clobbers an
            # admin's later edits to a seeded row.
            conn.execute(
                "INSERT OR IGNORE INTO device_policies "
                "(policy_name, description, allowed_capabilities, privacy_mode_default, "
                "is_system_default, created_at, updated_at) VALUES (?, ?, ?, ?, 1, ?, ?)",
                (policy_name, description, json.dumps(["lock", "broadcast"]), privacy_mode_default, now, now),
            )
            for command_type in KNOWN_COMMAND_TYPES:
                conn.execute(
                    "INSERT OR IGNORE INTO command_allowlist "
                    "(policy_name, command_type, allowed, requires_reason) VALUES (?, ?, 1, 0)",
                    (policy_name, command_type),
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
                       error_message: str = "", result_summary: str = ""):
    device_row = conn.execute("SELECT device_id FROM devices WHERE hostname = ?", (target_device,)).fetchone()
    target_device_id = device_row["device_id"] if device_row else None
    conn.execute(
        "INSERT INTO remote_actions "
        "(actor_email, target_device, target_device_id, action_type, status, reason, param, "
        "timestamp, error_message, result_summary) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (actor_email, target_device, target_device_id, action_type, status, reason, param,
         datetime.now().isoformat(), error_message, result_summary),
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
        "lock", "broadcast", "devices_read", "devices_write", "sessions_read", "analytics_read",
        "audit_log_read", "reports_read", "invite_create", "devices_revoke",
    },
    "lab_admin": {
        "lock", "broadcast", "devices_read", "devices_write", "sessions_read", "analytics_read",
        "audit_log_read", "reports_read", "invite_create", "devices_revoke",
    },
    "instructor": {"lock", "broadcast"},
    "viewer": {"devices_read", "sessions_read", "analytics_read", "audit_log_read", "reports_read"},
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


@app.on_event("startup")
def startup_event():
    init_db()
    init_control_tables()
    REPORTS_DIR.mkdir(parents=True, exist_ok=True)
    if not CONFIG_PATH.exists():
        with open(CONFIG_PATH, "w", encoding="utf-8") as f:
            json.dump(DEFAULT_CONFIG, f, indent=4)


# Google OAuth configuration variables
GOOGLE_CLIENT_ID = os.environ.get("GOOGLE_CLIENT_ID", "")
GOOGLE_CLIENT_SECRET = os.environ.get("GOOGLE_CLIENT_SECRET", "")
GOOGLE_REDIRECT_URI = os.environ.get("GOOGLE_REDIRECT_URI", "http://localhost:8000/api/auth/callback")

# Authentication Routes
@app.get("/api/auth/google/login")
def google_login():
    if not GOOGLE_CLIENT_ID:
        if not LOGIX_DEV_MODE:
            raise HTTPException(
                status_code=503,
                detail="Server misconfigured: Google OAuth is not set up and LOGIX_DEV_MODE is not enabled",
            )
        # Developer Mock Fallback (LOGIX_DEV_MODE=1 only): auto-authenticate as first whitelist admin
        mock_token = secrets.token_hex(24)
        admin_roles = get_admin_roles()
        mock_email = next(iter(admin_roles))
        ACTIVE_TOKENS[mock_token] = {
            "email": mock_email,
            "expires": datetime.now() + timedelta(hours=8),
            "role": admin_roles[mock_email],
        }
        return RedirectResponse(url=f"/?token={mock_token}")

    params = {
        "client_id": GOOGLE_CLIENT_ID,
        "redirect_uri": GOOGLE_REDIRECT_URI,
        "response_type": "code",
        "scope": "openid email profile",
        "access_type": "online",
        "prompt": "select_account"
    }
    url = "https://accounts.google.com/o/oauth2/v2/auth?" + urllib.parse.urlencode(params)
    return RedirectResponse(url=url)


@app.get("/api/auth/callback")
def google_callback(code: str):
    if not GOOGLE_CLIENT_ID or not GOOGLE_CLIENT_SECRET:
        raise HTTPException(status_code=400, detail="Google OAuth is not configured on the server.")
        
    token_url = "https://oauth2.googleapis.com/token"
    data = urllib.parse.urlencode({
        "code": code,
        "client_id": GOOGLE_CLIENT_ID,
        "client_secret": GOOGLE_CLIENT_SECRET,
        "redirect_uri": GOOGLE_REDIRECT_URI,
        "grant_type": "authorization_code"
    }).encode("utf-8")
    
    req = urllib.request.Request(
        token_url,
        data=data,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST"
    )
    
    try:
        with urllib.request.urlopen(req) as res:
            token_data = json.loads(res.read().decode())
            access_token = token_data.get("access_token")
            
        if not access_token:
            raise HTTPException(status_code=400, detail="Failed to retrieve access token from Google.")
            
        userinfo_url = f"https://www.googleapis.com/oauth2/v3/userinfo?access_token={access_token}"
        userinfo_req = urllib.request.Request(userinfo_url)
        
        with urllib.request.urlopen(userinfo_req) as res:
            user_data = json.loads(res.read().decode())
            email = user_data.get("email", "").strip().lower()
            
        if not email:
            raise HTTPException(status_code=400, detail="Google account has no associated email address.")
            
        admin_roles = get_admin_roles()
        if email in admin_roles:
            session_token = secrets.token_hex(24)
            ACTIVE_TOKENS[session_token] = {
                "email": email,
                "expires": datetime.now() + timedelta(hours=8),
                "role": admin_roles[email],
            }
            return RedirectResponse(url=f"/?token={session_token}")
        else:
            return HTMLResponse(
                content=f"""
                <html>
                  <head>
                    <title>Akses Ditolak</title>
                    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;600;700&display=swap" rel="stylesheet">
                    <style>
                      body {{ font-family: 'Inter', sans-serif; background: #080d16; color: #f8fafc; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; }}
                      .card {{ background: rgba(239, 68, 68, 0.08); border: 1px solid rgba(239, 68, 68, 0.2); padding: 32px; border-radius: 16px; text-align: center; max-width: 400px; box-shadow: 0 4px 30px rgba(0, 0, 0, 0.5); }}
                      h2 {{ color: #ef4444; margin-top: 0; }}
                      p {{ color: #94a3b8; font-size: 14px; line-height: 1.5; }}
                      .btn {{ display: inline-block; margin-top: 20px; background: #3b82f6; color: white; padding: 10px 20px; border-radius: 8px; text-decoration: none; font-size: 13px; font-weight: 600; }}
                    </style>
                  </head>
                  <body>
                    <div class="card">
                      <h2>Akses Tidak Diberikan</h2>
                      <p>Surel Google Anda (<strong>{email}</strong>) tidak terdaftar dalam daftar putih admin di server Logix.</p>
                      <a href="/" class="btn">Kembali ke Halaman Masuk</a>
                    </div>
                  </body>
                </html>
                """,
                status_code=403
            )
            
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"OAuth verification error: {str(e)}")


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
            pass
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
        pass

    HEARTBEATS[payload.hostname] = {
        "status": payload.status.upper(),
        "username": payload.username,
        "anydesk_id": ad_id,
        "device_name": device_name,
        "last_seen": datetime.now()
    }

    # Retrieve pending commands for this workstation
    cmds = PENDING_COMMANDS.get(payload.hostname, [])
    if cmds:
        PENDING_COMMANDS[payload.hostname] = [] # clear queue

    return {"status": "ok", "commands": cmds}


@app.get("/api/active")
def get_active_workstations(email: str = Depends(verify_token)):
    now = datetime.now()
    active_pcs = []
    for host, info in HEARTBEATS.items():
        if now - info["last_seen"] < timedelta(minutes=5):
            active_pcs.append({
                "hostname": host,
                "device_name": info["device_name"],
                "status": info["status"],
                "username": info["username"],
                "anydesk_id": info["anydesk_id"],
                "last_seen": info["last_seen"].isoformat()
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
            d["currently_online"] = bool(live and now - live["last_seen"] < timedelta(minutes=5))
            devices.append(d)
        return devices
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
        existing = conn.execute("SELECT device_id FROM devices WHERE device_id = ?", (device_id,)).fetchone()
        if not existing:
            raise HTTPException(status_code=404, detail="Device not found")
        conn.execute(
            "UPDATE devices SET api_key = NULL, updated_at = ? WHERE device_id = ?",
            (datetime.now().isoformat(), device_id),
        )
        conn.commit()
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


# Control Command Endpoints (Admins post commands here)
@app.post("/api/control/lock")
def queue_lock_command(payload: ControlRequest, email: str = Depends(require_permission("lock"))):
    host = payload.hostname
    if host not in PENDING_COMMANDS:
        PENDING_COMMANDS[host] = []
    PENDING_COMMANDS[host].append({"command": "LOCK", "param": ""})
    detail = f"Lock command queued for {host}"

    # Audit logging must never block the real command from being queued --
    # it already was, above, regardless of what happens here.
    try:
        conn = get_db()
        try:
            log_remote_action(conn, email, host, "LOCK", "queued", reason=payload.reason, result_summary=detail)
        finally:
            conn.close()
    except Exception:
        pass

    return {"status": "success", "detail": detail}


@app.post("/api/control/broadcast")
def queue_broadcast_command(payload: ControlRequest, email: str = Depends(require_permission("broadcast"))):
    host = payload.hostname
    msg = payload.param or "Perhatian: Alert dari Administrator."

    if host == "ALL":
        # Broadcast to all known heartbeating hosts
        for h in HEARTBEATS.keys():
            if h not in PENDING_COMMANDS:
                PENDING_COMMANDS[h] = []
            PENDING_COMMANDS[h].append({"command": "BROADCAST", "param": msg})
        detail = "Broadcast queued for all hosts"
        # One audit row for this one admin action, not one per fanned-out
        # host -- an admin took a single action; that's what the log reflects.
        try:
            conn = get_db()
            try:
                log_remote_action(conn, email, "ALL", "BROADCAST", "queued",
                                   reason=payload.reason, param=msg, result_summary=detail)
            finally:
                conn.close()
        except Exception:
            pass
        return {"status": "success", "detail": detail}

    if host not in PENDING_COMMANDS:
        PENDING_COMMANDS[host] = []
    PENDING_COMMANDS[host].append({"command": "BROADCAST", "param": msg})
    detail = f"Broadcast queued for {host}"
    try:
        conn = get_db()
        try:
            log_remote_action(conn, email, host, "BROADCAST", "queued",
                               reason=payload.reason, param=msg, result_summary=detail)
        finally:
            conn.close()
    except Exception:
        pass

    return {"status": "success", "detail": detail}


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


@app.get("/api/sessions")
def get_sessions(
    limit: int = 100, 
    offset: int = 0, 
    hostname: Optional[str] = None, 
    username: Optional[str] = None,
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
        
        return {
            "totals": {
                "hours": total_hours,
                "sessions": active_sessions_count,
                "workstations": len(by_workstation)
            },
            "by_workstation": sorted(by_workstation, key=lambda x: x["hours"], reverse=True)[:5], # top 5
            "by_purpose": sorted(by_purpose, key=lambda x: x["count"], reverse=True),
            "by_hour": by_hour
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


# Mount frontend static directory
static_dir = BASE_DIR / "static"
static_dir.mkdir(exist_ok=True)

@app.get("/")
def read_root():
    index_file = static_dir / "index.html"
    if index_file.exists():
        return FileResponse(str(index_file))
    return JSONResponse({"message": "Logix Central Server Active. Static Dashboard missing."})

app.mount("/", StaticFiles(directory=str(static_dir)), name="static")
