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

from fastapi import FastAPI, HTTPException, Header, Depends, Query, Body, Cookie
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
# Not enrollment (that's /api/enroll, still unimplemented per API_CONTRACT.md)
# -- device_id here is a server-assigned stopgap keyed on first-seen hostname.
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
    "created_at": "TEXT NOT NULL",
    "updated_at": "TEXT NOT NULL",
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
        "logoText": "FTMM",
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
    "requiredFields": ["nama", "nim", "access", "purpose", "keterangan"]
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
# the existing idempotency idiom in logix/log_physical.py.
def upsert_device(conn, hostname: str, display_name: str):
    now = datetime.now().isoformat()
    existing = conn.execute("SELECT device_id FROM devices WHERE hostname = ?", (hostname,)).fetchone()
    if existing:
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


# Resolve Auth Configurations
def get_allowed_admins():
    emails = os.environ.get("ADMIN_EMAILS", "admin@logix.com")
    return [e.strip().lower() for e in emails.split(",") if e.strip()]


# Dependency to verify token
def verify_token(authorization: Optional[str] = Header(None)):
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
    return session["email"]


# Dependency to verify the shared ingest API key sent by local agents.
# Unset LOGIX_INGEST_API_KEY only ever happens in dev mode; production
# deployments must configure it, otherwise ingest is rejected outright.
def verify_api_key(x_api_key: Optional[str] = Header(None)):
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
        mock_email = get_allowed_admins()[0]
        ACTIVE_TOKENS[mock_token] = {
            "email": mock_email,
            "expires": datetime.now() + timedelta(hours=8),
            # Inert groundwork for the real RBAC model (Milestone 3, see
            # docs/LOGIX_CONTROL.md §4). Every session is "admin" today --
            # this field's shape lets that milestone change the assigned
            # value, not the signature of every function that depends on
            # verify_token.
            "role": "admin",
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
            
        allowed = get_allowed_admins()
        if email in allowed:
            session_token = secrets.token_hex(24)
            ACTIVE_TOKENS[session_token] = {
                "email": email,
                "expires": datetime.now() + timedelta(hours=8),
                "role": "admin",  # see comment at the dev-mode mock login site
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
def update_config(config: Dict[str, Any], email: str = Depends(verify_token)):
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
    HEARTBEATS[payload.hostname] = {
        "status": payload.status.upper(),
        "username": payload.username,
        "anydesk_id": ad_id,
        "device_name": device_name,
        "last_seen": datetime.now()
    }

    # Persist to the devices registry. Must never block the heartbeat
    # response the agent is waiting on -- log and continue on failure.
    try:
        conn = get_db()
        try:
            upsert_device(conn, payload.hostname, device_name)
        finally:
            conn.close()
    except Exception:
        pass

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
def get_devices(email: str = Depends(verify_token)):
    conn = get_db()
    try:
        rows = conn.execute("SELECT * FROM devices ORDER BY last_seen DESC").fetchall()
        now = datetime.now()
        devices = []
        for r in rows:
            d = dict(r)
            live = HEARTBEATS.get(d["hostname"])
            d["currently_online"] = bool(live and now - live["last_seen"] < timedelta(minutes=5))
            devices.append(d)
        return devices
    finally:
        conn.close()


# Control Command Endpoints (Admins post commands here)
@app.post("/api/control/lock")
def queue_lock_command(payload: ControlRequest, email: str = Depends(verify_token)):
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
def queue_broadcast_command(payload: ControlRequest, email: str = Depends(verify_token)):
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
    email: str = Depends(verify_token)
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
    email: str = Depends(verify_token)
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
def get_analytics(email: str = Depends(verify_token)):
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
def download_report(today: bool = False, full: bool = False, email: str = Depends(verify_token)):
    out_file = REPORTS_DIR / f"report-{datetime.now().strftime('%Y%m%d-%H%M%S')}.xlsx"
    cmd = [
        "python",
        str(BASE_DIR.parent / "logix" / "logbook_report.py"),
        "--db", str(DB_PATH),
        "--out", str(out_file)
    ]
    if today:
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
