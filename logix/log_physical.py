#!/usr/bin/env python3
"""
MindLab Report Logbook bridge.
Idempotent SQLite migration + robust JSON-based logging for Windows physical/AnyDesk sessions and SSH sessions.
Designed not to overwrite or depend on bot.py.
"""
from __future__ import annotations

import argparse
import getpass
import json
import os
import socket
import sqlite3
import sys
import uuid
from datetime import datetime
from pathlib import Path
from typing import Any

import paths

DEFAULT_DB = paths.default_db()
DEFAULT_SESSION_JSON = paths.default_session_json()

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
    # Stable per-event identity, generated once in payload_from_args() and
    # carried through to the server's dedup check -- makes a retried sync
    # (clock drift or a retry hours later, either of which would defeat the
    # old session_id+event+timestamp tuple match) a true no-op instead of a
    # duplicate row.
    "event_uid": "TEXT",
    "synced": "INTEGER DEFAULT 0",
    # Mirrors server/main.py's BASE_COLUMNS. How the person's identity was
    # established, not merely what they typed:
    #   self_declared -- typed their own nama + NIM at the sign-in popup
    #   unverified    -- the popup could not run and the machine was let
    #                    through anyway (the deliberate fail-open policy); the
    #                    session is real, the person behind it is not known
    #   directory     -- resolved against the campus directory (reserved)
    # Carried here so a fail-open session survives an offline spell in the
    # agent's own queue and still reaches the server labelled honestly.
    "identity_source": "TEXT",
    "person_role": "TEXT",
}

WORKSTATION_TYPES = {"PHYSICAL", "ANYDESK"}
OPEN_EVENTS = {"START"}
CLOSE_EVENTS = {"END", "LOCK", "AUTO_FINISH", "AUTO_CLOSE", "DISCONNECT", "LOGOFF"}


def now_iso() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def connect(db_path: Path) -> sqlite3.Connection:
    db_path.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(str(db_path), timeout=30)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA journal_mode=WAL")
    con.execute("PRAGMA busy_timeout=30000")
    return con


def existing_columns(con: sqlite3.Connection, table: str) -> set[str]:
    try:
        rows = con.execute(f"PRAGMA table_info({table})").fetchall()
    except sqlite3.Error:
        return set()
    return {str(r[1]) for r in rows}


def drop_bad_unique_session_indexes(con: sqlite3.Connection) -> None:
    """Remove old unique indexes that make START/END impossible for same session_id."""
    try:
        indexes = con.execute("PRAGMA index_list(physical_log)").fetchall()
    except sqlite3.Error:
        return
    for idx in indexes:
        name = str(idx[1])
        is_unique = int(idx[2] or 0) == 1
        if not is_unique:
            continue
        try:
            cols = [str(r[2]) for r in con.execute(f"PRAGMA index_info({name})").fetchall()]
        except sqlite3.Error:
            continue
        if cols == ["session_id"] or ("session_id" in cols and len(cols) <= 2):
            try:
                con.execute(f'DROP INDEX IF EXISTS "{name}"')
            except sqlite3.Error:
                pass

def alter_decl_for_existing_table(name: str, decl: str) -> str:
    upper = decl.upper()
    if "PRIMARY KEY" in upper:
        return decl
    if "NOT NULL" in upper and "DEFAULT" not in upper:
        if upper.startswith("TEXT"):
            return decl.replace("NOT NULL", "").replace("not null", "").strip() + " DEFAULT ''"
        if upper.startswith("INTEGER"):
            return decl.replace("NOT NULL", "").replace("not null", "").strip() + " DEFAULT 0"
        return decl.replace("NOT NULL", "").replace("not null", "").strip()
    return decl


def migrate(con: sqlite3.Connection) -> None:
    col_defs = ",\n        ".join(f"{k} {v}" for k, v in BASE_COLUMNS.items())
    con.execute(f"CREATE TABLE IF NOT EXISTS physical_log (\n        {col_defs}\n    )")
    cols = existing_columns(con, "physical_log")
    for name, decl in BASE_COLUMNS.items():
        if name not in cols:
            if "PRIMARY KEY" in decl.upper():
                continue
            con.execute(f"ALTER TABLE physical_log ADD COLUMN {name} {alter_decl_for_existing_table(name, decl)}")
    con.execute("CREATE INDEX IF NOT EXISTS idx_physical_log_timestamp ON physical_log(timestamp)")
    con.execute("CREATE INDEX IF NOT EXISTS idx_physical_log_session ON physical_log(session_id)")
    con.execute("CREATE INDEX IF NOT EXISTS idx_physical_log_event_uid ON physical_log(event_uid)")
    con.execute("CREATE INDEX IF NOT EXISTS idx_physical_log_type ON physical_log(session_type)")
    con.execute("CREATE INDEX IF NOT EXISTS idx_physical_log_event ON physical_log(event)")

    jobs_cols = existing_columns(con, "jobs")
    if jobs_cols:
        for name, decl in {"session_type": "TEXT", "source": "TEXT", "client_ip": "TEXT"}.items():
            if name not in jobs_cols:
                con.execute(f"ALTER TABLE jobs ADD COLUMN {name} {decl}")
    con.commit()


def load_json_file(path: str | None) -> dict[str, Any]:
    if not path:
        return {}
    p = Path(path)
    if not p.exists():
        raise FileNotFoundError(f"json file not found: {p}")
    return json.loads(p.read_text(encoding="utf-8-sig"))


def norm(v: Any, default: str = "") -> str:
    if v is None:
        return default
    return str(v).strip()


def truthy(v: Any) -> int:
    return 1 if str(v).strip().lower() in {"1", "true", "yes", "y", "anydesk"} else 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Write a Report Logbook event into logix.db")
    p.add_argument("--db", default=str(DEFAULT_DB))
    p.add_argument("--migrate", action="store_true", help="only migrate schema and exit")
    p.add_argument("--json-file", default="", help="read all event fields from a UTF-8 JSON file")
    p.add_argument("--repair-active", action="store_true", help="repair currently active Windows session row from session.json")
    p.add_argument("--close-open", action="store_true", help="close all open workstation sessions using session.json or CLI fields")
    p.add_argument("--sync-to-server", action="store_true", help="sync all unsynced local logs to central API server")
    p.add_argument("--sync-preview", action="store_true", help="show what --sync-to-server would send, without sending it")
    p.add_argument("--event", default="START", help="START, END, AUTO_FINISH, SSH_LOGIN, SSH_LOGOUT, UNLOCK, LOCK")
    p.add_argument("--username", default=os.environ.get("USER") or os.environ.get("USERNAME") or getpass.getuser())
    p.add_argument("--nama", default="")
    p.add_argument("--nim", default="")
    p.add_argument("--tujuan", default="")
    p.add_argument("--keterangan", default="")
    p.add_argument("--session-type", default=os.environ.get("COMPCHEM_SESSION_TYPE", ""))
    p.add_argument("--source", default="")
    p.add_argument("--session-id", default="")
    p.add_argument("--windows-user", default="")
    p.add_argument("--hostname", default=socket.gethostname())
    p.add_argument("--client-ip", default="")
    p.add_argument("--anydesk-detected", default="0")
    p.add_argument("--raw-json", default="")
    return p.parse_args(argv)


def payload_from_args(ns: argparse.Namespace) -> dict[str, Any]:
    data = load_json_file(ns.json_file)
    event = norm(data.get("event"), norm(ns.event, "START")).upper()

    # Generated once and reused if already present in the JSON payload --
    # that file is the unit of retry (a crashed/retried process re-reads
    # the same --json-file), so preserving an existing event_uid rather
    # than minting a new one each attempt is what makes a retry actually
    # idempotent instead of just re-numbering the duplicate.
    payload = {
        "timestamp": norm(data.get("timestamp"), now_iso()),
        "event": event,
        "event_uid": norm(data.get("event_uid"), uuid.uuid4().hex),
        "username": norm(data.get("username"), norm(ns.username)),
        "nama": norm(data.get("nama"), norm(ns.nama)),
        "nim": norm(data.get("nim"), norm(ns.nim)),
        "tujuan": norm(data.get("tujuan"), norm(ns.tujuan)),
        "keterangan": norm(data.get("keterangan"), norm(ns.keterangan)),
        "session_type": norm(data.get("session_type"), norm(ns.session_type)),
        "source": norm(data.get("source"), norm(ns.source)),
        "session_id": norm(data.get("session_id"), norm(ns.session_id)),
        "windows_user": norm(data.get("windows_user"), norm(ns.windows_user)),
        "hostname": norm(data.get("hostname"), norm(ns.hostname, socket.gethostname())),
        "client_ip": norm(data.get("client_ip"), norm(ns.client_ip)),
        "anydesk_detected": truthy(data.get("anydesk_detected", ns.anydesk_detected)),
        # Defaults to self_declared because that is what an ordinary START is:
        # relaying what the person typed at the sign-in popup. Only the
        # fail-open path passes anything else.
        "identity_source": norm(data.get("identity_source"), "self_declared"),
        "person_role": norm(data.get("person_role"), ""),
        "raw_json": ns.raw_json or json.dumps(data if data else {
            "argv_source": "log_physical.py",
            "env_user": os.environ.get("USER"),
            "ssh_connection": os.environ.get("SSH_CONNECTION"),
            "pwd": os.environ.get("PWD"),
        }, ensure_ascii=False),
    }

    if not payload["timestamp"]:
        payload["timestamp"] = now_iso()
    if not payload["event"]:
        payload["event"] = "START"
    if not payload["username"]:
        payload["username"] = os.environ.get("USER") or os.environ.get("USERNAME") or getpass.getuser()
    if not payload["hostname"]:
        payload["hostname"] = socket.gethostname()
    return payload


def values_from_payload(payload: dict[str, Any], cols: list[str]) -> list[Any]:
    vals = []
    for c in cols:
        v = payload.get(c)
        if v is None or v == "":
            if BASE_COLUMNS[c].upper().startswith("INTEGER"):
                v = 0
            else:
                v = ""
        vals.append(v)
    return vals


def insert_event(con: sqlite3.Connection, payload: dict[str, Any]) -> int:
    cols = list(BASE_COLUMNS.keys())
    cols.remove("id")
    placeholders = ",".join("?" for _ in cols)
    sql = f"INSERT INTO physical_log ({','.join(cols)}) VALUES ({placeholders})"
    vals = values_from_payload(payload, cols)
    try:
        cur = con.execute(sql, vals)
        con.commit()
        return int(cur.lastrowid)
    except sqlite3.IntegrityError as exc:
        msg = str(exc)
        if "session_id" not in msg:
            raise
        drop_bad_unique_session_indexes(con)
        try:
            cur = con.execute(sql, vals)
            con.commit()
            return int(cur.lastrowid)
        except sqlite3.IntegrityError:
            payload = dict(payload)
            base = norm(payload.get("session_id"), "session")
            payload["session_id"] = f"{base}-{datetime.now().strftime('%H%M%S%f')}"
            vals = values_from_payload(payload, cols)
            cur = con.execute(sql, vals)
            con.commit()
            return int(cur.lastrowid)

def open_workstation_sessions(con: sqlite3.Connection) -> list[sqlite3.Row]:
    """Return workstation START rows without any closing event.

    This is the key guard against the previous bug: multiple START stacks stayed active
    when Windows lock/disconnect did not fire cleanly. New START now auto-closes older ones.
    """
    if not existing_columns(con, "physical_log"):
        return []
    return con.execute(
        """
        SELECT s.*
          FROM physical_log s
         WHERE UPPER(COALESCE(s.event,''))='START'
           AND UPPER(COALESCE(s.session_type,'')) IN ('PHYSICAL','ANYDESK')
           AND COALESCE(s.session_id,'') <> ''
           AND NOT EXISTS (
                SELECT 1 FROM physical_log e
                 WHERE e.session_id = s.session_id
                   AND UPPER(COALESCE(e.event,'')) IN ('END','LOCK','AUTO_FINISH','AUTO_CLOSE','DISCONNECT','LOGOFF')
           )
         ORDER BY s.timestamp ASC, s.id ASC
        """
    ).fetchall()


def coalesce(*vals: Any) -> str:
    for v in vals:
        t = norm(v)
        if t:
            return t
    return ""


def close_open_workstation_sessions(con: sqlite3.Connection, closing_payload: dict[str, Any], reason: str = "AUTO_FINISH") -> int:
    current_sid = norm(closing_payload.get("session_id"))
    count = 0
    for row in open_workstation_sessions(con):
        sid = norm(row["session_id"])
        if not sid or sid == current_sid:
            continue
        payload = dict(closing_payload)
        payload.update({
            "event": reason,
            "session_id": sid,
            "session_type": coalesce(row["session_type"], closing_payload.get("session_type"), "Physical"),
            "source": "auto_close_before_new_start",
            "username": coalesce(row["username"], closing_payload.get("username")),
            "nama": coalesce(row["nama"], closing_payload.get("nama")),
            "nim": coalesce(row["nim"], closing_payload.get("nim")),
            "tujuan": coalesce(row["tujuan"], closing_payload.get("tujuan")),
            "keterangan": coalesce(row["keterangan"], closing_payload.get("keterangan"), "Auto-closed by new workstation session"),
            "windows_user": coalesce(row["windows_user"], closing_payload.get("windows_user")),
            "hostname": coalesce(row["hostname"], closing_payload.get("hostname"), socket.gethostname()),
            "anydesk_detected": row["anydesk_detected"] if row["anydesk_detected"] is not None else closing_payload.get("anydesk_detected", 0),
            "raw_json": json.dumps({
                "auto_close": True,
                "reason": reason,
                "closed_session_id": sid,
                "new_session_id": current_sid,
                "source_start_id": row["id"],
            }, ensure_ascii=False),
        })
        insert_event(con, payload)
        count += 1
    return count


def repair_active_from_session(con: sqlite3.Connection, session_path: Path = DEFAULT_SESSION_JSON) -> int:
    """Repair current active Windows row from session.json.

    Conservative but stronger than v5.5: it updates blank identity fields for the exact
    session_id and also fixes the newest blank workstation START row.
    """
    if not session_path.exists():
        return 0
    data = json.loads(session_path.read_text(encoding="utf-8-sig"))
    sid = norm(data.get("session_id"))
    if not sid:
        return 0
    vals = {
        "timestamp": norm(data.get("start_time"), now_iso()),
        "event": "START",
        "username": norm(data.get("username"), norm(data.get("windows_user"))),
        "nama": norm(data.get("nama")),
        "nim": norm(data.get("nim")),
        "tujuan": norm(data.get("tujuan")),
        "keterangan": norm(data.get("keterangan")),
        "session_type": norm(data.get("session_type"), "Physical"),
        "source": "windows_wpf_repair",
        "session_id": sid,
        "windows_user": norm(data.get("windows_user")),
        "hostname": norm(data.get("hostname"), socket.gethostname()),
        "client_ip": norm(data.get("client_ip")),
        "anydesk_detected": truthy(data.get("anydesk_detected")),
        "raw_json": json.dumps(data, ensure_ascii=False),
    }
    cur = con.execute(
        """
        UPDATE physical_log
           SET timestamp = CASE WHEN COALESCE(timestamp,'')='' THEN :timestamp ELSE timestamp END,
               event = CASE WHEN COALESCE(event,'')='' THEN :event ELSE event END,
               username = CASE WHEN COALESCE(username,'')='' THEN :username ELSE username END,
               nama = CASE WHEN COALESCE(nama,'')='' THEN :nama ELSE nama END,
               nim = CASE WHEN COALESCE(nim,'')='' THEN :nim ELSE nim END,
               tujuan = CASE WHEN COALESCE(tujuan,'')='' THEN :tujuan ELSE tujuan END,
               keterangan = CASE WHEN COALESCE(keterangan,'')='' THEN :keterangan ELSE keterangan END,
               session_type = CASE WHEN COALESCE(session_type,'')='' THEN :session_type ELSE session_type END,
               source = CASE WHEN COALESCE(source,'')='' THEN :source ELSE source END,
               windows_user = CASE WHEN COALESCE(windows_user,'')='' THEN :windows_user ELSE windows_user END,
               hostname = CASE WHEN COALESCE(hostname,'')='' THEN :hostname ELSE hostname END,
               anydesk_detected = :anydesk_detected,
               raw_json = :raw_json
         WHERE session_id = :session_id
        """,
        vals,
    )
    changed = cur.rowcount if cur.rowcount is not None else 0
    if changed == 0:
        row = con.execute(
            """
            SELECT id FROM physical_log
             WHERE (COALESCE(timestamp,'')='' OR COALESCE(nama,'')='' OR COALESCE(tujuan,'')='')
               AND UPPER(COALESCE(session_type,'')) IN ('PHYSICAL','ANYDESK')
             ORDER BY id DESC LIMIT 1
            """
        ).fetchone()
        if row:
            vals["id"] = row["id"]
            cur = con.execute(
                """
                UPDATE physical_log
                   SET timestamp=:timestamp, event=:event, username=:username, nama=:nama, nim=:nim,
                       tujuan=:tujuan, keterangan=:keterangan, session_type=:session_type,
                       source=:source, session_id=:session_id, windows_user=:windows_user,
                       hostname=:hostname, client_ip=:client_ip, anydesk_detected=:anydesk_detected,
                       raw_json=:raw_json
                 WHERE id=:id
                """,
                vals,
            )
            changed = cur.rowcount if cur.rowcount is not None else 0
    con.commit()
    return int(changed or 0)


import time
import urllib.request
import urllib.error


def unsynced_log_rows(con: sqlite3.Connection) -> list[sqlite3.Row]:
    return con.execute("SELECT * FROM physical_log WHERE COALESCE(synced, 0) = 0 ORDER BY id ASC").fetchall()


def preview_sync(con: sqlite3.Connection) -> int:
    """--sync-preview: report what WOULD be sent, without sending it.
    Deliberately prints only timestamp/event/hostname/session_type -- a
    preview command run at a terminal shouldn't itself become a way to
    print nama/nim/keterangan to a screen or log file."""
    rows = unsynced_log_rows(con)
    mode = paths.privacy_mode()
    if mode != "admin_full_sync":
        print(
            f"{len(rows)} unsynced event(s) exist, but none would actually be sent: "
            f"LOGIX_PRIVACY_MODE={mode!r} (must be 'admin_full_sync' for /api/log). "
            "See docs/PRIVACY.md."
        )
        return len(rows)
    print(f"{len(rows)} unsynced event(s) would be sent to {paths.server_url() or '(no server configured)'}:")
    for r in rows:
        print(f"  #{r['id']} {r['timestamp']} {r['event']} host={r['hostname']} type={r['session_type']}")
    return len(rows)


def sync_unsynced_logs(con: sqlite3.Connection, timeout: int = 10, max_attempts: int = 1) -> int:
    """POST unsynced rows to /api/log. max_attempts=1 (the default) is a
    single fire-and-forget attempt -- used for the inline post-insert call,
    which must stay non-blocking for the interactive lock/popup flow; a
    failure there just waits for the next sync opportunity. A higher
    max_attempts (used by the explicit --sync-to-server CLI path, where the
    operator/scheduled task is already committing to waiting) retries with
    exponential backoff (1s, 2s, 4s, ...), but only on network-level
    failures -- an HTTP error status (4xx/5xx) means the server actively
    rejected the request, which won't fix itself by retrying."""
    url = paths.server_url()
    if not url:
        return 0

    # Privacy-mode enforcement at the agent boundary (docs/PRIVACY.md,
    # "default = safest"): /api/log carries full-detail rows (nama, nim,
    # keterangan, client_ip, raw_json -- exactly what redacted_sync
    # excludes), so it's only ever reachable under admin_full_sync. This is
    # deliberately not "send a reshaped/redacted version instead" -- that
    # would invent an undocumented variant of /api/log's contract.
    # redacted_sync's actual, already-built, already-tested delivery path
    # is logix/gsheet_sync.py's redact() whitelist gate, unaffected by this
    # check. A server URL being configured but privacy_mode left at its
    # local_only default is loud, not silent -- this is a real behavior
    # change for any install that was syncing before this existed.
    mode = paths.privacy_mode()
    if mode != "admin_full_sync":
        print(
            f"Sync skipped: LOGIX_PRIVACY_MODE={mode!r} (default local_only). "
            "No session data leaves this device unless privacy mode is "
            "explicitly set to admin_full_sync. See docs/PRIVACY.md.",
            file=sys.stderr,
        )
        return 0

    # Per-device key takes priority once enrolled; mirrors verify_api_key's
    # fallback order on the server.
    api_key = paths.device_api_key() or paths.server_api_key()

    rows = unsynced_log_rows(con)
    if not rows:
        return 0

    payload = []
    for r in rows:
        d = dict(r)
        d.pop("id", None)
        d.pop("synced", None)
        if d.get("anydesk_detected") is not None:
            d["anydesk_detected"] = int(d["anydesk_detected"])
        payload.append(d)

    req = urllib.request.Request(
        f"{url.rstrip('/')}/api/log",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "X-API-Key": api_key
        },
        method="POST"
    )

    backoff = 1
    for attempt in range(1, max(1, max_attempts) + 1):
        try:
            with urllib.request.urlopen(req, timeout=timeout) as response:
                if response.status in (200, 201):
                    row_ids = [r["id"] for r in rows]
                    placeholders = ",".join("?" for _ in row_ids)
                    con.execute(f"UPDATE physical_log SET synced = 1 WHERE id IN ({placeholders})", row_ids)
                    con.commit()
                    return len(row_ids)
            break  # unexpected non-200/201 without an exception -- not retryable
        except urllib.error.HTTPError as e:
            print(f"Sync to server failed (HTTP {e.code}, not retrying): {e}", file=sys.stderr)
            break
        except Exception as e:
            print(f"Sync to server failed (attempt {attempt}/{max_attempts}): {e}", file=sys.stderr)
            if attempt < max_attempts:
                time.sleep(backoff)
                backoff *= 2

    return 0


def main(argv: list[str]) -> int:
    ns = parse_args(argv)
    db_path = Path(ns.db)
    try:
        con = connect(db_path)
        migrate(con)
        if ns.migrate:
            print(f"OK migrated: {db_path}")
            return 0
        if ns.sync_preview:
            preview_sync(con)
            return 0
        if ns.sync_to_server:
            n = sync_unsynced_logs(con, max_attempts=3)
            print(f"OK synced logs to server: {n}")
            return 0
        if ns.repair_active:
            n = repair_active_from_session(con)
            print(f"OK repaired active rows: {n}")
            return 0
        payload = payload_from_args(ns)
        if ns.close_open:
            n = close_open_workstation_sessions(con, payload, payload.get("event") or "AUTO_FINISH")
            print(f"OK closed open workstation sessions: {n}")
            return 0
        if payload["event"] == "START" and payload.get("session_type", "").strip().upper() in WORKSTATION_TYPES:
            close_open_workstation_sessions(con, payload, "AUTO_FINISH")
        rowid = insert_event(con, payload)
        print(f"OK logged {payload['event']} id={rowid} -> {db_path}")
        
        # Proactively attempt inline synchronization with a short timeout
        if paths.server_url():
            try:
                sync_unsynced_logs(con, timeout=3)
            except Exception:
                pass
                
        return 0
    except Exception as exc:
        print(f"ERROR log_physical.py: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
