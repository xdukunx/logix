#!/usr/bin/env python3
"""Local reports for a Logix Device, without a server and without a terminal.

WHY THIS EXISTS
---------------
Reporting already worked -- but only as `python logbook_report.py`, which is a
sentence you cannot say to the person who actually uses a lab workstation. A
feature reachable only by opening a terminal, knowing which interpreter to use
and which file to point it at, is a feature that exists for the maintainer, not
for the user. Device mode is supposed to be a complete product on its own; a
product does not ask you to run a script.

WHAT IT IS
----------
A small localhost-only web UI over the reporting code that was already here.
It does NOT reimplement any reporting: `fetch_physical` + `build_sessions`
produce the rows, and Export hands straight off to `logbook_report.build()`,
so the .xlsx a user downloads here is byte-for-byte the file the CLI writes.
One source of truth for what a session IS.

WHY A LOCAL WEB UI AND NOT A WINDOW
-----------------------------------
The client is WPF/PowerShell and the report core is Python. Rendering this in
WPF would mean either reimplementing the queries in PowerShell (a second source
of truth for the same numbers, which is how two reports start disagreeing) or
shelling out per interaction. The browser is already installed, already handles
tables/scrolling/printing, and costs this project no new dependency: stdlib
http.server, no framework, no CDN, no build step.

PRIVACY
-------
This serves names, student IDs and activity -- the exact data this project
treats as first-class. So:
  * it binds 127.0.0.1 ONLY, never 0.0.0.0, so nothing is exposed to the lab
    network even by accident;
  * it requires a token minted at launch, because on a shared workstation
    "localhost" is not a security boundary -- another signed-in user can reach
    a loopback port;
  * it is read-only with two deliberate exceptions: /api/server/sync and
    /api/server/test, which run the existing sync path. They take no
    parameters and can do nothing else, so there is still no way to write
    arbitrary data through this server -- but "read-only" on its own would
    now be untrue, and a docstring that quietly stops matching the code is
    worse than one that admits the seam;
  * it exits on its own after an idle period, so a forgotten browser tab does
    not leave a PII endpoint listening for the rest of the day.
"""
from __future__ import annotations

import argparse
import http.server
import json
import os
import secrets
import socket
import sys
import threading
import time
import urllib.parse
import webbrowser
from datetime import date, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import paths  # noqa: E402
import logbook_report as report  # noqa: E402

DEFAULT_DB = paths.default_db()

# A tab left open must not keep a PII endpoint alive forever. The UI polls
# nothing, so any gap this long means nobody is looking.
IDLE_SHUTDOWN_SECONDS = 30 * 60
# How often the watchdog checks. Named rather than inlined so a test can run
# the real shutdown path in a second instead of half a minute -- a timeout
# whose only observable behaviour takes 30s to appear is a timeout nobody
# tests, and this one is the thing that stops a PII endpoint being left open.
IDLE_POLL_SECONDS = 30

# "7" and "30" are day counts, not names, because that is what the segmented
# control in the UI actually offers. They were missing here, so range=7 and
# range=30 both failed the membership check below and silently fell back to
# "today" -- the two buttons rendered today's sessions under a 7-day and a
# 30-day label. "week" and "month" stay for any caller still using them.
RANGES = ("today", "7", "30", "week", "month", "all")


def resolve_range(name: str):
    """Map a UI range onto the date pair the existing report code expects.

    Deliberately returns the same (start, end) shape `logbook_report.build`
    takes, so the table on screen and the exported .xlsx can never be computed
    from two different periods.
    """
    today = date.today()
    if name == "today":
        return today, today, "Hari ini"
    if name == "7":
        # Rolling window, inclusive of today: "the last 7 days" as a person
        # means it, not the calendar week.
        return today - timedelta(days=6), today, "7 hari terakhir"
    if name == "30":
        return today - timedelta(days=29), today, "30 hari terakhir"
    if name == "week":
        # Monday-based, matching how a lab week is actually discussed.
        start = today - timedelta(days=today.weekday())
        return start, today, "Minggu ini"
    if name == "month":
        return today.replace(day=1), today, "Bulan ini"
    return None, None, "Semua"


def _render_session(s: dict) -> dict:
    """One session, shaped for the table and the details sheet.

    Empty stays empty. The page renders an em dash for a missing job or a
    missing end time; substituting anything here would put a value in the
    export and the API that the database does not hold.
    """
    active = bool(s.get("_active"))
    return {
        "session_id": s.get("session_id") or "",
        "start": report.fmt_ts(s.get("start_ts")),
        # An active session has no end. Not "now", not a guess -- an em dash
        # is rendered client-side from this empty string.
        "end": report.fmt_ts(s.get("end_ts")) if s.get("end_ts") else "",
        "durasi": s.get("durasi") or "-",
        "nama": s.get("nama") or "",
        "nim": s.get("nim") or "",
        "tujuan": s.get("tujuan") or "",
        "tipe": s.get("tipe") or "",
        "status": s.get("status") or "",
        "keterangan": s.get("keterangan") or "",
        "job_type": s.get("job_type") or "",
        "job_id": s.get("job_id") or "",
        "active": active,
        # Whether THIS session has reached the server. Distinct from the
        # device-wide connection state on the Server page: a device can be
        # connected and still have older rows unsent.
        "sync": "active" if active else ("synced" if s.get("_synced") else "pending"),
    }


def _repair_if_default_db(con, db_path: Path) -> None:
    """Rebuild an active session whose START row never landed in SQLite.

    Scoped to the DEFAULT database only, exactly as logbook_report.build()
    scopes its own call: session.json describes THIS workstation's live
    session, and repairing it into whatever database was passed via --db
    would inject the running session into an unrelated file. Extracted here
    so the paged query and load_sessions share one copy of that rule rather
    than two that can drift.
    """
    try:
        if db_path.resolve() == DEFAULT_DB.expanduser().resolve():
            report.repair_active_session_from_windows_state(con)
    except Exception:
        # A repair that fails must never take the page down with it; the
        # rest of the history is still perfectly readable.
        pass


# ---- Paged session queries ------------------------------------------------
#
# Measured against a seeded 10,000-session database (see
# docs/OFFLINE_CLIENT_UI_SPEC.md, "Logs and Server"): loading every session
# and pairing it cost 290ms and shipped 2.01MB to the browser, and the
# majority of the time was build_sessions walking every event to match
# STARTs with ENDs. Selecting the page of session IDs first is 14ms, because
# idx_physical_log_session already exists -- then only that page's rows are
# read and paired, which is 2ms more.
#
# Search lives in SQL as a CONSEQUENCE of that, not as a preference: once
# the browser holds one page instead of the whole history, a client-side
# filter would search only the page. It would look like it worked.

SEARCHABLE = ("nama", "nim", "tujuan", "keterangan", "job_type", "job_id", "hostname")


def _session_filter_sql(q, user, job_type):
    """WHERE fragments and args selecting the session_ids that match.

    Each condition is a subquery over the events, because a session matches
    if ANY of its rows does -- identity is on the START row while a later
    row may carry the job, and matching only one of them would drop real
    results without saying so.
    """
    where, args = [], []
    if q:
        blob = "||".join(f"lower(COALESCE({c},''))" for c in SEARCHABLE)
        where.append(f"session_id IN (SELECT session_id FROM physical_log "
                     f"WHERE {blob} LIKE ?)")
        args.append(f"%{q.strip().lower()}%")
    if user:
        where.append("session_id IN (SELECT session_id FROM physical_log "
                     "WHERE nama = ?)")
        args.append(user)
    if job_type:
        where.append("session_id IN (SELECT session_id FROM physical_log "
                     "WHERE job_type = ?)")
        args.append(job_type)
    return where, args


def load_sessions_page(db_path: Path, range_name: str, q: str = "", user: str = "",
                       job_type: str = "", limit: int = 50, offset: int = 0):
    """One page of sessions, newest first, plus the total that matched.

    The total is a separate COUNT rather than len() of the page, because the
    UI has to be able to say "50 of 1,284" -- and a page that cannot tell
    the reader whether more exists is not an audit surface.
    """
    start_d, end_d, label = resolve_range(range_name)
    where, args = _session_filter_sql(q, user, job_type)
    if start_d:
        where.append("session_id IN (SELECT session_id FROM physical_log "
                     "WHERE timestamp >= ? AND timestamp <= ?)")
        args += [f"{start_d.isoformat()}T00:00:00", f"{end_d.isoformat()}T23:59:59"]

    clause = (" WHERE " + " AND ".join(where)) if where else ""
    con = report.connect(db_path)
    try:
        report.ensure_physical_schema(con)
        _repair_if_default_db(con, db_path)

        total = con.execute(
            f"SELECT COUNT(*) FROM (SELECT session_id FROM physical_log{clause} "
            f"GROUP BY session_id)", args).fetchone()[0]

        ids = [r[0] for r in con.execute(
            f"SELECT session_id FROM physical_log{clause} GROUP BY session_id "
            f"ORDER BY MAX(timestamp) DESC LIMIT ? OFFSET ?",
            args + [max(1, limit), max(0, offset)]).fetchall()]

        sessions = []
        if ids:
            ph = ",".join("?" for _ in ids)
            rows = con.execute(
                f"SELECT * FROM physical_log WHERE session_id IN ({ph}) "
                f"ORDER BY timestamp", ids).fetchall()
            by_id = {sid: i for i, sid in enumerate(ids)}
            sessions = report.build_sessions(rows)
            # build_sessions returns dict order, not the ordering the page
            # was selected in. Re-sort to the ID order the query established,
            # or the page arrives shuffled relative to its own pagination.
            sessions.sort(key=lambda x: by_id.get(x.get("session_id"), 1 << 30))
    finally:
        con.close()
    return sessions, label, total


def distinct_values(db_path: Path, column: str) -> list[str]:
    """Filter options, taken from what the database actually contains. A
    dropdown offering job types nobody has ever recorded is noise."""
    if column not in ("nama", "job_type"):
        return []
    con = report.connect(db_path)
    try:
        report.ensure_physical_schema(con)
        return [r[0] for r in con.execute(
            f"SELECT DISTINCT {column} FROM physical_log "
            f"WHERE {column} IS NOT NULL AND {column} != '' ORDER BY {column}"
        ).fetchall()]
    except Exception:
        return []
    finally:
        con.close()


def _summarize(sessions: list[dict]) -> dict:
    """Counts worth putting at the top of a report. Duration is summed from the
    timestamps rather than from the formatted 'durasi' string, because that
    string is for humans and parsing it back would be inventing a second
    format to keep in sync."""
    total_seconds = 0
    active = 0
    people = set()
    for s in sessions:
        if s.get("_active"):
            active += 1
        nim = (s.get("nim") or "").strip()
        nama = (s.get("nama") or "").strip()
        if nim or nama:
            people.add(nim or nama)
        start = report.parse_ts(s.get("start_ts"))
        end = report.parse_ts(s.get("end_ts")) if s.get("end_ts") else None
        if start and end:
            delta = (end - start).total_seconds()
            if delta > 0:
                total_seconds += delta
    hours = int(total_seconds // 3600)
    minutes = int((total_seconds % 3600) // 60)
    return {
        "sessions": len(sessions),
        "active": active,
        "people": len(people),
        "duration": f"{hours}j {minutes}m" if hours else f"{minutes}m",
    }


def load_sessions(db_path: Path, range_name: str):
    start_d, end_d, label = resolve_range(range_name)
    start_s = f"{start_d.isoformat()}T00:00:00" if start_d else None
    end_s = f"{end_d.isoformat()}T23:59:59" if end_d else None
    con = report.connect(db_path)
    try:
        report.ensure_physical_schema(con)
        # Same self-heal logbook_report.build() performs before every export:
        # if the client has an active session whose START row never landed in
        # SQLite, rebuild it from session.json. Without this the table on
        # screen and the .xlsx exported from the button beside it could
        # disagree about whether the session the user is CURRENTLY in exists
        # -- and the START row is written by a detached process now, so
        # "not there yet" is a normal, momentary state rather than a fault.
        #
        # Scoped to the DEFAULT database only, exactly as logbook_report.build()
        # scopes its own call. session.json describes THIS workstation's live
        # session; repairing it into whatever database happened to be passed
        # via --db would inject the running session into an unrelated file.
        # Caught immediately by the tests, which serve a tmp_path database.
        try:
            if db_path.resolve() == DEFAULT_DB.expanduser().resolve():
                report.repair_active_session_from_windows_state(con)
        except Exception:
            # A repair that fails must never take the report down with it;
            # the rest of the history is still perfectly readable.
            pass
        rows = report.fetch_physical(con, start_s, end_s)
        sessions = report.build_sessions(rows)
    finally:
        con.close()
    sessions.reverse()  # newest first: the last session is the one being asked about
    return sessions, label




def _export_csv(db_path, start_d, end_d, only_ids=None):
    """Fallback when openpyxl is absent. Same rows, same columns, same
    source -- build_sessions -- so the CSV cannot disagree with the xlsx,
    including when the view was filtered."""
    import csv
    con = report.connect(db_path)
    try:
        rows = report.fetch_physical(con, start_d, end_d)
    finally:
        con.close()
    sessions = report.build_sessions(rows)
    if only_ids is not None:
        keep = set(only_ids)
        sessions = [x for x in sessions if x.get("session_id") in keep]
    # Not report.DEFAULT_OUTDIR directly: that is the system-wide reports
    # directory, which an ordinary user cannot create on macOS or Linux, and
    # this dashboard runs as an ordinary user by design.
    outdir = paths.writable_reports_dir()
    out = outdir / f"logix-sessions-{time.strftime('%Y%m%d-%H%M%S')}.csv"
    # Same collision guard as the xlsx path: two exports in one second must
    # not resolve to one file.
    if out.exists():
        for n in range(2, 100):
            alt = out.with_name(out.stem + f"-{n}" + out.suffix)
            if not alt.exists():
                out = alt
                break
    cols = ["start_ts", "end_ts", "nama", "nim", "tujuan", "job_type",
            "job_id", "durasi", "tipe", "status", "keterangan"]
    with out.open("w", newline="", encoding="utf-8-sig") as fh:
        wr = csv.writer(fh)
        wr.writerow(["Start", "End", "Name", "NIM", "Purpose", "Job Type",
                     "Job ID", "Duration", "Type", "Status", "Description"])
        for s in sessions:
            wr.writerow([s.get(c, "") for c in cols])
    return out

# ---- Overview -----------------------------------------------------------
#
# Everything here comes from a source that already existed. Nothing on this
# page is computed twice or invented: identity and history come from
# logbook_report's own queries, sync state from log_physical.sync_status,
# and telemetry from workstation.py -- which returns None, never a zero,
# for anything this machine cannot actually report.

def _sync_snapshot(db_path):
    """Sync state for the seven-state indicator in the UX contract. Returns
    the raw connection_state plus the failure class, and lets the browser do
    the mapping -- the contract's table lives in one place, not two."""
    try:
        import log_physical as lp
        con = lp.connect(db_path)
        try:
            return lp.sync_status(con)
        finally:
            con.close()
    except Exception as exc:
        return {"connection_state": "unknown", "error": str(exc),
                "pending_count": None, "last_error_class": None}


# The seven contract states, resolved server-side from the structured
# classification rather than by the browser parsing an error string. The UI
# renders what it is told; it does not interpret.
_ERROR_TEXT = {
    "network": "Server could not be reached.",
    "auth": "The server rejected this workstation's credentials.",
    "rejected": "The server rejected the data sent.",
    "server": "The server reported an internal error.",
    "unknown": "Synchronization failed.",
}


def _server_state(db_path: Path) -> dict:
    """Everything the Server page renders, already resolved to one state.

    connection_state from sync_status is device-wide and does not on its own
    say whether anything is queued, so pending_count decides between SYNCED
    and SYNC_PENDING. local_only and blocked are terminal and carry no
    pending count at all -- on a device that does not sync, rows are
    finished, not waiting, and a number there would be a lie about what the
    product is doing.
    """
    snap = _sync_snapshot(db_path)
    st = snap.get("connection_state")
    pending = snap.get("pending_count")
    cls = snap.get("last_error_class")

    if st == "disabled":
        state, detail = "LOCAL_ONLY", "Session data is stored on this workstation."
    elif st == "blocked":
        state, detail = "SYNC_BLOCKED", "Synchronization is disabled by policy."
    elif st == "offline" and cls == "network":
        state, detail = "SERVER_UNAVAILABLE", _ERROR_TEXT["network"]
    elif st == "offline":
        state, detail = "SYNC_ERROR", _ERROR_TEXT.get(cls or "unknown", _ERROR_TEXT["unknown"])
    elif pending:
        state, detail = "SYNC_PENDING", f"{pending} change(s) waiting to synchronize."
    elif st == "connected":
        state, detail = "SYNCED", "All changes synchronized."
    else:
        state, detail = "SYNC_PENDING", "No synchronization has run on this workstation yet."

    quiet = state in ("LOCAL_ONLY", "SYNC_BLOCKED")
    return {
        "state": state,
        "detail": detail,
        "server_url": paths.server_url() or "",
        "server_configured": bool(snap.get("server_configured")),
        "privacy_mode": snap.get("privacy_mode") or "",
        # None, never 0, when the question does not apply -- a zero implies a
        # queue that happens to be empty.
        "pending": None if quiet else pending,
        "last_success": snap.get("last_success"),
        "last_attempt": snap.get("last_attempt"),
        "error_class": cls,
        # The human sentence is above; this is for whoever is debugging, and
        # is often the same person reading the page.
        "diagnostic": snap.get("last_error"),
        "can_sync": state in ("SYNC_PENDING", "SYNC_ERROR", "SERVER_UNAVAILABLE"),
        "can_test": bool(snap.get("server_configured")),
    }


def _server_action(db_path: Path, action: str) -> dict:
    """Run the real sync, or just re-read state for a connection test.

    Deliberately shells out to log_physical rather than importing and
    calling it in-process: the sync path opens its own connection, writes,
    and retries, and running that inside the request thread of a server
    whose own docstring promises to stay out of the way is how a hung
    socket becomes a hung page.
    """
    import subprocess
    py = sys.executable
    script = str(Path(__file__).resolve().parent / "log_physical.py")
    flag = "--sync-to-server" if action == "sync" else "--sync-status"
    try:
        out = subprocess.run([py, script, flag, "--db", str(db_path)],
                             capture_output=True, text=True, timeout=90)
        after = _server_state(db_path)
        # NOT the exit code. log_physical exits 0 after a failed sync -- it
        # prints "synced 0" and returns cleanly, because a sync that could
        # not reach the server is not a crash. Reporting that as success put
        # "Synchronization finished." on screen directly above "Server
        # unavailable". The resulting STATE is what actually happened.
        ok = out.returncode == 0 and after["state"] not in (
            "SERVER_UNAVAILABLE", "SYNC_ERROR")
        return {"ok": ok, "action": action, "state": after,
                "output": (out.stdout or out.stderr or "").strip()[-400:]}
    except subprocess.TimeoutExpired:
        return {"ok": False, "action": action,
                "error": "The server did not respond in time.",
                "state": _server_state(db_path)}


def _active_session(sessions):
    for s in sessions:
        if s.get("_active"):
            return s
    return None


def _overview(state):
    try:
        sessions, _label = load_sessions(state.db, "today")
    except Exception:
        sessions = []
    active = _active_session(sessions)

    try:
        import workstation
        telemetry = workstation.snapshot()
    except Exception:
        # The module is optional in the same sense psutil is: a dashboard
        # that cannot read a sensor still has a logbook to show.
        telemetry = {"cpu": None, "memory": None, "storage": None,
                     "gpu": None, "psutil_available": False}

    recent = [
        {
            "start": report.fmt_ts(s.get("start_ts")),
            "nama": s.get("nama") or "",
            "nim": s.get("nim") or "",
            "tujuan": s.get("tujuan") or "",
            "durasi": s.get("durasi") or "-",
            "active": bool(s.get("_active")),
        }
        for s in sessions[:5]
    ]

    return {
        "workstation": {
            "hostname": socket.gethostname(),
            "display": state.device or socket.gethostname(),
        },
        "telemetry": telemetry,
        "active": None if not active else {
            "nama": active.get("nama") or "",
            "nim": active.get("nim") or "",
            "tujuan": active.get("tujuan") or "",
            "keterangan": active.get("keterangan") or "",
            "job_type": active.get("job_type") or "",
            "job_id": active.get("job_id") or "",
            "tipe": active.get("tipe") or "",
            "start": report.fmt_ts(active.get("start_ts")),
            "start_iso": str(active.get("start_ts") or ""),
            "durasi": active.get("durasi") or "-",
        },
        "recent": recent,
        "sync": _sync_snapshot(state.db),
    }


PAGE = """<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Logix</title>
<style>
/* ── tokens ─────────────────────────────────────────────────────────────
   Values mirror frontend/src/tokens.css -- the LogiX v3 "Clean Calibration"
   ramp the server dashboard already ships. Not merely similar: the same
   hex, so a person moving between the admin dashboard and this local
   console is looking at one product rather than two that resemble each
   other. The names differ (that file prefixes --lx-) because this page is
   standalone and has no build step; the VALUES are the contract.

   That file encodes the same rules this page arrived at independently:
   status colour exists only as a dot or a hairline edge, never a tinted
   background, and the accent is reserved for links, focus rings and
   primary buttons. Nothing else. */
:root{
  --bg:#f4f5f7; --surface:#ffffff; --surface-subtle:#f4f5f7;
  --surface-accent:#f4f5f7; --border:#e6e9ef; --border-strong:#d9dde3;
  --text:#14181f; --text-muted:#6a7382; --text-faint:#8a94a6;
  --accent:#2563eb; --accent-hover:#1d4ed8; --accent-ink:#ffffff;
  --ok:#16a34a; --warn:#d97706; --err:#dc2626;

  --font:-apple-system,BlinkMacSystemFont,"Segoe UI",Inter,system-ui,sans-serif;
  --mono:ui-monospace,"Cascadia Mono","SF Mono",Menlo,Consolas,monospace;

  --space-1:4px; --space-2:8px; --space-3:12px; --space-4:16px;
  --space-5:24px; --space-6:32px; --space-7:48px;
  --radius-sm:4px; --radius-md:10px; --radius-lg:16px;
  --duration-fast:120ms; --duration-normal:180ms;
  --ease:cubic-bezier(.2,.6,.2,1);
}
:root[data-theme="dark"]{
  --bg:#0b0f16; --surface:#111722; --surface-subtle:#0b0f16;
  --surface-accent:#0b0f16; --border:#1e2836; --border-strong:#2a3648;
  --text:#edf1f7; --text-muted:#8a94a6; --text-faint:#6b7280;
  --accent:#2563eb; --accent-hover:#3b82f6; --accent-ink:#ffffff;
  --ok:#22c55e; --warn:#f59e0b; --err:#ef4444;
}
@media (prefers-color-scheme:dark){
  :root:not([data-theme="light"]){
    --bg:#0b0f16; --surface:#111722; --surface-subtle:#0b0f16;
    --surface-accent:#0b0f16; --border:#1e2836; --border-strong:#2a3648;
    --text:#edf1f7; --text-muted:#8a94a6; --text-faint:#6b7280;
    --accent:#2563eb; --accent-hover:#3b82f6; --accent-ink:#ffffff;
    --ok:#22c55e; --warn:#f59e0b; --err:#ef4444;
  }
}

*{box-sizing:border-box}
html,body{height:100%}
body{margin:0;background:var(--bg);color:var(--text);font:400 13px/1.55 var(--font);
  -webkit-font-smoothing:antialiased;font-variant-numeric:tabular-nums}
:focus-visible{outline:2px solid var(--accent);outline-offset:2px;border-radius:2px}

/* ── shell ───────────────────────────────────────────────────────────── */
.shell{display:grid;grid-template-columns:208px 1fr;min-height:100vh}
.side{border-right:1px solid var(--border);padding:var(--space-5) var(--space-3);
  display:flex;flex-direction:column;position:sticky;top:0;height:100vh}
.mark{font-size:12px;font-weight:700;letter-spacing:.16em;color:var(--text);
  padding:0 var(--space-2) var(--space-6)}
.nav{display:flex;flex-direction:column;gap:2px}
.nav a{display:block;padding:var(--space-2) var(--space-3);color:var(--text-muted);
  text-decoration:none;border-radius:var(--radius-sm);cursor:pointer;
  border-left:2px solid transparent;transition:background var(--duration-fast) var(--ease)}
.nav a:hover{background:var(--surface-subtle);color:var(--text)}
.nav a[aria-current="page"]{background:var(--surface-accent);color:var(--text);
  border-left-color:var(--accent)}
.nav-rule{height:1px;background:var(--border);margin:var(--space-3) var(--space-2)}
.side-foot{margin-top:auto;padding-top:var(--space-4)}
.chip{border:1px solid var(--border);border-radius:var(--radius-sm);
  padding:var(--space-2) var(--space-3);background:var(--surface)}
.chip b{display:block;font-size:13px;font-weight:600;letter-spacing:-.01em}
.chip span{font-size:11px;color:var(--text-faint)}

main{padding:var(--space-7) var(--space-6) var(--space-7);max-width:1180px;width:100%}

/* ── workstation context ─────────────────────────────────────────────── */
.ctx{display:flex;justify-content:space-between;align-items:flex-start;gap:var(--space-5);
  padding-bottom:var(--space-5);border-bottom:1px solid var(--border);margin-bottom:var(--space-6)}
.eyebrow{font-size:11px;font-weight:600;letter-spacing:.08em;text-transform:uppercase;
  color:var(--text-faint)}
.station{font-size:26px;font-weight:640;letter-spacing:-.02em;margin:var(--space-1) 0 0}
.station-sub{font-size:12px;color:var(--text-muted)}
.station-sub:empty{display:none}

/* ── status: mark + words, never colour alone ────────────────────────── */
.st{display:inline-flex;align-items:center;gap:var(--space-1);font-size:12px;
  color:var(--text-muted);white-space:nowrap}
.st .mk{width:7px;height:7px;border-radius:50%;background:var(--text-faint);flex:none}
.st.ok .mk{background:var(--ok)} .st.warn .mk{background:var(--warn)}
.st.err .mk{background:var(--err)} .st.act .mk{background:var(--accent)}
.st.hollow .mk{background:transparent;border:1.5px solid var(--warn)}

h2.sec{font-size:11px;font-weight:600;letter-spacing:.08em;text-transform:uppercase;
  color:var(--text-faint);margin:0 0 var(--space-3)}
.sec-row{display:flex;justify-content:space-between;align-items:baseline;margin-bottom:var(--space-3)}
.sec-row h2{margin:0}
.stamp{font-size:11px;color:var(--text-faint)}

/* ── health: ONE panel, four readings of one machine ─────────────────── */
.health{border:1px solid var(--border);border-radius:var(--radius-md);
  background:var(--surface);display:grid;grid-template-columns:repeat(4,1fr);
  margin-bottom:var(--space-5)}
.metric{padding:var(--space-4);border-left:1px solid var(--border)}
.metric:first-child{border-left:0}
.metric .lbl{font-size:11px;font-weight:600;letter-spacing:.08em;text-transform:uppercase;
  color:var(--text-faint);margin-bottom:var(--space-2)}
.metric .val{font-size:26px;font-weight:640;letter-spacing:-.02em;line-height:1.15}
.metric .val.na{font-size:13px;font-weight:400;color:var(--text-faint);line-height:1.55;
  padding:6px 0 5px}
.metric .sub{font-size:12px;color:var(--text-muted);margin-top:2px}
/* Three shapes, because the four readings are three different shapes of
   data -- not variety for its own sake:
     CPU      countable discrete units  -> one block PER REAL CORE
     Mem/Disk continuous magnitude      -> a bar
     GPU      a single utilisation %    -> a dial
   A row of 18 arbitrary blocks under "28.3 GB free" implied storage came
   in 18 countable units. It does not. Cores do. */

/* One block per logical CPU, each filled from the bottom by THAT core's
   own load -- psutil.cpu_percent(percpu=True), not the aggregate split
   into equal parts. A block is a core, so the row is only meaningful at
   the real core count. */
.cores{display:flex;gap:2px;margin-top:var(--space-3);align-items:flex-end;height:22px}
.cores .c{flex:1;min-width:0;height:100%;background:var(--border-strong);
  border-radius:1px;position:relative;overflow:hidden}
.cores .c i{position:absolute;left:0;right:0;bottom:0;background:var(--accent);
  display:block}

/* Continuous magnitude. Same 3px hairline the rest of the page uses. */
.bar{height:4px;background:var(--border-strong);border-radius:2px;
  margin-top:var(--space-3);overflow:hidden}
.bar i{display:block;height:100%;background:var(--accent);border-radius:2px}

/* A moving line over the samples this process has actually taken while the
   page was open. Not a trend, not a forecast, and not persisted -- if the
   page has only been open ten seconds the line is ten seconds long, which
   is the honest thing for it to be. */
.spark{margin-top:var(--space-3);height:34px;position:relative}
.spark svg{width:100%;height:100%;display:block;overflow:visible}
.spark .fill{fill:var(--accent);opacity:.10}
.spark .line{fill:none;stroke:var(--accent);stroke-width:1.5;
  stroke-linejoin:round;stroke-linecap:round;vector-effect:non-scaling-stroke}
.spark .warming{position:absolute;inset:0;display:flex;align-items:center;
  font-size:11px;color:var(--text-faint)}

/* Secondary readings that only exist for some hardware -- shown when the
   machine reports them, absent otherwise, never zero-filled. */
.aux{display:flex;gap:var(--space-3);flex-wrap:wrap;margin-top:var(--space-2);
  font-size:11px;color:var(--text-muted);font-variant-numeric:tabular-nums}
.aux b{font-weight:600;color:var(--text)}

/* One utilisation percentage, one dial. */
.gauge{position:relative;width:64px;height:64px;flex:none;margin-top:var(--space-2)}
.gauge svg{width:100%;height:100%;display:block}
.gauge .gv{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;
  font-family:var(--mono);font-size:13px;font-weight:600;color:var(--text)}
.metric.has-gauge{display:flex;align-items:flex-start;justify-content:space-between;
  gap:var(--space-3)}

/* ── current usage: the one accented object ──────────────────────────── */
/* Plain, same surface and same 1px border as every other panel on the page
   -- WireGuard's own tunnel panel carries no colour anywhere except its
   status dot, and that discipline is the point. The tinted fill and accent
   edge this had before were the one thing on the page that read as "SaaS
   card" rather than "readout"; colour now lives only in the ACTIVE dot. */
.usage{background:var(--surface);border:1px solid var(--border);
  border-radius:var(--radius-md);
  padding:var(--space-4) var(--space-5);margin-bottom:var(--space-6)}
.usage-top{display:flex;justify-content:space-between;align-items:baseline;
  margin-bottom:var(--space-4)}
.usage-body{display:flex;justify-content:space-between;align-items:flex-start;
  gap:var(--space-5);flex-wrap:wrap}
.purpose{font-size:20px;font-weight:600;letter-spacing:-.01em;margin:0 0 var(--space-1)}
.who{font-size:15px;font-weight:600}
.who span{color:var(--text-muted);font-weight:400}
.meta{font-size:12px;color:var(--text-muted);margin-top:var(--space-1)}
.clock{font-family:var(--mono);font-size:34px;font-weight:600;letter-spacing:-.01em;
  line-height:1.05}
.usage-foot{display:flex;justify-content:space-between;align-items:center;
  margin-top:var(--space-4);gap:var(--space-3);flex-wrap:wrap}

/* ── recent: rows on the page, not a card ────────────────────────────── */
.recent{border-top:1px solid var(--border)}
.rrow{display:grid;grid-template-columns:74px 1fr auto;gap:var(--space-3);
  padding:var(--space-3) var(--space-2);border-bottom:1px solid var(--border);
  cursor:pointer;align-items:baseline;transition:background var(--duration-fast) var(--ease)}
.rrow:hover{background:var(--surface-subtle)}
.rrow .t{font-family:var(--mono);font-size:12px;color:var(--text-muted)}
.rrow .n{font-weight:600}
.rrow .p{color:var(--text-muted)}
.rrow .d{font-family:var(--mono);font-size:12px;text-align:right}
.after{display:flex;justify-content:flex-end;margin-top:var(--space-4)}

/* ── controls ────────────────────────────────────────────────────────── */
button{font:inherit;font-size:13px;padding:6px 12px;border:1px solid var(--border);
  border-radius:var(--radius-sm);background:var(--surface);color:var(--text);cursor:pointer;
  transition:background var(--duration-fast) var(--ease)}
button:hover{background:var(--surface-subtle)}
button.primary{background:var(--accent);border-color:var(--accent);color:var(--accent-ink)}
button.primary:hover{background:var(--accent-hover)}
button.quiet{border-color:transparent;background:none;color:var(--text-muted)}
button.quiet:hover{background:var(--surface-subtle);color:var(--text)}

.toolbar{display:flex;gap:var(--space-3);align-items:center;flex-wrap:wrap;
  margin-bottom:var(--space-4)}
.field{position:relative;width:260px}
.field input{width:100%;font:inherit;font-size:13px;padding:6px 62px 6px 10px;
  border:1px solid var(--border);border-radius:var(--radius-sm);
  background:var(--surface);color:var(--text)}
.field kbd{position:absolute;right:6px;top:50%;transform:translateY(-50%);
  font:inherit;font-size:11px;color:var(--text-faint);border:1px solid var(--border);
  border-radius:3px;padding:1px 5px;background:var(--surface-subtle);pointer-events:none}
select{font:inherit;font-size:13px;padding:6px 10px;border:1px solid var(--border);
  border-radius:var(--radius-sm);background:var(--surface);color:var(--text)}

.seg{display:inline-flex;border:1px solid var(--border);border-radius:var(--radius-sm);
  overflow:hidden}
.seg button{border:0;border-left:1px solid var(--border);border-radius:0;
  padding:5px 11px;font-size:12px;background:var(--surface);color:var(--text-muted)}
.seg button:first-child{border-left:0}
.seg button[aria-pressed="true"]{background:var(--accent);color:var(--accent-ink)}
.spacer{flex:1}

/* ── table ───────────────────────────────────────────────────────────── */
table{width:100%;border-collapse:collapse;background:var(--surface);
  border:1px solid var(--border);border-radius:var(--radius-md);overflow:hidden}
th{text-align:left;font-size:11px;font-weight:600;letter-spacing:.08em;text-transform:uppercase;
  color:var(--text-faint);padding:var(--space-3);border-bottom:1px solid var(--border-strong);
  white-space:nowrap}
td{padding:var(--space-3);border-bottom:1px solid var(--border);vertical-align:top}
tbody tr:last-child td{border-bottom:0}
tbody tr{cursor:pointer;transition:background var(--duration-fast) var(--ease)}
tbody tr:hover{background:var(--surface-subtle)}
tbody tr:focus-visible{outline:2px solid var(--accent);outline-offset:-2px}
.num{font-family:var(--mono);font-size:12px;white-space:nowrap}
.r{text-align:right}
.mut{color:var(--text-muted)}
.faint{color:var(--text-faint)}
.tally{margin-top:var(--space-3);font-size:12px;color:var(--text-muted)}

/* NIM under the name, job id under the job type: present for audit,
   never competing with the value above it. */
.sub2{font-size:11px;color:var(--text-faint);margin-top:1px;
  font-variant-numeric:tabular-nums}
/* Group headings on the Server page. Quieter than a section rule -- this
   page is a settings surface, not a console. */
.grp-h{font-size:11px;font-weight:600;letter-spacing:.08em;text-transform:uppercase;
  color:var(--text-faint);margin:var(--space-5) 0 var(--space-2)}
.okline{color:var(--ok)}
.diag{font-family:var(--mono);font-size:11px;color:var(--text-muted);
  word-break:break-word}
/* ── server ──────────────────────────────────────────────────────────── */
.card{border:1px solid var(--border);border-radius:var(--radius-md);
  background:var(--surface);padding:var(--space-5);max-width:560px}
.card .head{font-size:15px;font-weight:600;margin-bottom:2px}
.card .line{font-size:13px;color:var(--text-muted)}
.kv{display:grid;grid-template-columns:132px 1fr;gap:var(--space-2) var(--space-4);
  font-size:13px;margin-top:var(--space-5)}
.kv dt{color:var(--text-faint)} .kv dd{margin:0;word-break:break-word}
.actions{display:flex;gap:var(--space-2);margin-top:var(--space-5)}
.actions:empty{display:none}

/* ── empty ───────────────────────────────────────────────────────────── */
.empty{border:1px dashed var(--border);border-radius:var(--radius-md);
  background:var(--surface);padding:var(--space-7) var(--space-5);text-align:center}
.empty b{display:block;font-size:15px;font-weight:600;margin-bottom:var(--space-1)}
.empty span{font-size:13px;color:var(--text-muted)}

/* ── details sheet: the only shadow in the product ───────────────────── */
.scrim{position:fixed;inset:0;background:rgba(20,22,26,.28);display:none;z-index:20}
.scrim.open{display:block}
.sheet{position:absolute;right:0;top:0;bottom:0;width:min(420px,100vw);
  background:var(--surface);border-left:1px solid var(--border);
  border-radius:var(--radius-lg) 0 0 var(--radius-lg);
  box-shadow:-16px 0 40px rgba(20,22,26,.16);
  padding:var(--space-5);overflow:auto;
  animation:slide var(--duration-normal) var(--ease)}
@keyframes slide{from{transform:translateX(16px);opacity:.6}to{transform:none;opacity:1}}
.sheet h3{margin:0 0 var(--space-5);font-size:15px;font-weight:600}
.grp{margin-bottom:var(--space-5)}
.grp h4{font-size:11px;font-weight:600;letter-spacing:.08em;text-transform:uppercase;
  color:var(--text-faint);margin:0 0 var(--space-2)}
.grp dl{display:grid;grid-template-columns:112px 1fr;gap:var(--space-2) var(--space-3);
  margin:0;font-size:13px}
.grp dt{color:var(--text-faint)} .grp dd{margin:0;word-break:break-word}
.prose{font-size:13px;color:var(--text);white-space:pre-wrap}
.x{position:absolute;top:var(--space-4);right:var(--space-4);border:0;background:none;
  padding:4px;color:var(--text-faint);line-height:0}
.x:hover{background:var(--surface-subtle);color:var(--text)}
.note{font-size:12px;color:var(--text-muted);margin-top:var(--space-2)}
.hide{display:none!important}

/* ── responsive ──────────────────────────────────────────────────────── */
@media(max-width:1100px){
  .health{grid-template-columns:repeat(2,1fr)}
  .metric:nth-child(3){border-left:0}
  .metric:nth-child(n+3){border-top:1px solid var(--border)}
}
@media(max-width:900px){
  .shell{grid-template-columns:1fr}
  .side{position:static;height:auto;flex-direction:row;align-items:center;gap:var(--space-3);
    border-right:0;border-bottom:1px solid var(--border);padding:var(--space-3) var(--space-4)}
  .mark{padding:0 var(--space-2) 0 0}
  .nav{flex-direction:row;gap:var(--space-1)}
  .nav a{border-left:0;border-bottom:2px solid transparent}
  .nav a[aria-current="page"]{border-left-color:transparent;border-bottom-color:var(--accent)}
  .nav-rule,.side-foot{display:none}
  main{padding:var(--space-5) var(--space-4) var(--space-7)}
  th.opt,td.opt{display:none}
}
@media(max-width:560px){
  .health{grid-template-columns:1fr}
  .metric{border-left:0;border-top:1px solid var(--border)}
  .metric:first-child{border-top:0}
  .field{width:100%}
  .rrow{grid-template-columns:64px 1fr auto}
  .rrow .p{display:none}
}
@media (prefers-reduced-motion:reduce){
  *{animation:none!important;transition:none!important}
}
</style>

<div class="shell">
  <aside class="side">
    <div class="mark">LOGIX</div>
    <nav class="nav" aria-label="Sections">
      <a id="nav-overview" aria-current="page" onclick="go('overview')" tabindex="0">Overview</a>
      <a id="nav-logs" onclick="go('logs')" tabindex="0">Logs</a>
      <a id="nav-server" onclick="go('server')" tabindex="0">Server</a>
    </nav>
    <div class="side-foot">
      <div class="chip"><b id="chipName">&mdash;</b><span id="chipSub"></span></div>
    </div>
  </aside>

  <main>
    <header class="ctx">
      <div>
        <div class="eyebrow">You are using workstation</div>
        <h1 class="station" id="station">&mdash;</h1>
        <div class="station-sub" id="stationSub"></div>
      </div>
      <span class="st" id="hdrSt"><span class="mk"></span><span id="hdrTxt">Checking</span></span>
    </header>

    <!-- OVERVIEW -->
    <section id="v-overview">
      <div class="sec-row">
        <h2 class="sec">Workstation health</h2>
        <span class="stamp" id="stamp"></span>
      </div>
      <div class="health" id="health"></div>

      <div id="usage"></div>

      <div class="sec-row"><h2 class="sec">Recent</h2></div>
      <div id="recent"></div>
      <!-- Export sits here as well as on Logs. Exporting is one of the two
           things a device owner actually comes to this page to do, and
           having it only behind a nav hop made it feel like a buried
           feature rather than a button. Same handler, same local data. -->
      <div class="after">
        <button onclick="go('logs')">View all logs</button>
        <button class="primary" onclick="doExport()">Export report</button>
      </div>
      <div id="exportNoteOverview" class="note"></div>
    </section>

    <!-- LOGS -->
    <section id="v-logs" class="hide">
      <h2 class="sec">Logs</h2>
      <div class="toolbar">
        <div class="field">
          <input id="q" type="search" placeholder="Search sessions"
                 aria-label="Search sessions">
          <kbd id="kbd">Ctrl+K</kbd>
        </div>
        <div class="seg" id="seg" role="group" aria-label="Time range"></div>
        <select id="fuser" aria-label="User"><option value="">All users</option></select>
        <select id="fjob" aria-label="Job type"><option value="">All jobs</option></select>
        <select id="fsync" aria-label="Sync state">
          <option value="">All sync states</option>
          <option value="synced">Synced</option>
          <option value="pending">Pending</option>
          <option value="active">Active</option>
        </select>
        <span class="spacer"></span>
        <button class="primary" onclick="doExport()">Export</button>
      </div>
      <div id="exportNote" class="note"></div>
      <div id="logs"></div>
      <div class="tally" id="tally"></div>
      <div class="after" id="morewrap"></div>
    </section>

    <!-- SERVER -->
    <section id="v-server" class="hide">
      <h2 class="sec">Central server</h2>
      <div id="server"></div>
    </section>
  </main>
</div>

<div class="scrim" id="scrim" onclick="if(event.target.id==='scrim')closeSheet()">
  <div class="sheet" role="dialog" aria-modal="true" aria-label="Session details">
    <button class="x" onclick="closeSheet()" aria-label="Close">
      <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor"
           stroke-width="1.5" stroke-linecap="round"><path d="M4 4l8 8M12 4l-8 8"/></svg>
    </button>
    <h3 id="sheetTitle">Session</h3>
    <div id="sheetBody"></div>
  </div>
</div>

<script>
var TOKEN=new URLSearchParams(location.search).get("t")||"";
var OV=null, ROWS=[], SHOWN=[], VIEW="overview", RANGE="all", LASTFOCUS=null;
var RANGES=[["today","Today"],["7","7 days"],["30","30 days"],["all","All"]];

function t(u){return u+(u.indexOf("?")<0?"?":"&")+"t="+encodeURIComponent(TOKEN)}
var ENT={"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"};
function esc(s){return String(s==null?"":s).replace(/[&<>"]/g,function(c){return ENT[c]})}
function dash(s){return (s===null||s===undefined||s==="")?"—":s}
function gb(n){if(n==null)return null;var v=n/1073741824;return (v>=100?v.toFixed(0):v.toFixed(1))+" GB"}
function pct(n){return n==null?null:Math.round(n)+"%"}

function go(v){
  VIEW=v;
  ["overview","logs","server"].forEach(function(k){
    document.getElementById("v-"+k).classList.toggle("hide",k!==v);
    var a=document.getElementById("nav-"+k);
    if(k===v)a.setAttribute("aria-current","page"); else a.removeAttribute("aria-current");
  });
  if(v==="logs"&&!ROWS.length)loadLogs(true);
  if(v==="server")loadServer();
}

/* ── the seven contract states, never collapsed ─────────────────────────
   local_only and sync_blocked are calm and successful: on a device with no
   server nothing is waiting, and a pending count there would be a lie. */
function syncView(s){
  if(!s)return{cls:"",txt:"Unknown",line:"Sync state could not be read."};
  var st=s.connection_state,n=s.pending_count,cls=s.last_error_class;
  if(st==="disabled")return{cls:"ok",txt:"Local only",quiet:1,
    line:"Stored on this workstation. Nothing needs to be uploaded."};
  if(st==="blocked")return{cls:"",txt:"Synchronization disabled",quiet:1,
    line:"Disabled by policy. Data is stored complete on this workstation."};
  if(st==="offline"&&cls==="network")return{cls:"hollow warn",txt:"Server unavailable",retry:1,
    line:(n?n+" change(s) ":"")+"stored safely on this workstation."};
  if(st==="offline")return{cls:"err",txt:"Synchronization failed",retry:1,
    line:"The server rejected the last attempt. Local data is safe."};
  if(n>0)return{cls:"warn",txt:n+" waiting to synchronize",sync:1,
    line:n+" change(s) waiting to synchronize. Local data is safe."};
  if(st==="connected")return{cls:"ok",txt:"All changes synchronized",
    line:"All changes synchronized."};
  return{cls:"",txt:"Not yet synchronized",
    line:"No synchronization has run on this workstation yet."};
}

/* ── telemetry: absent is smaller, quieter, and has NO meter ─────────── */
function clamp(p){return Math.max(0,Math.min(100,p))}

/* A polyline over real samples. maxV lets a rate series (bytes/sec, which
   has no ceiling) scale to its own peak, while a percentage series is
   pinned to 0-100 so the line does not appear to rescale itself every
   time the machine goes quiet.

   Under two points there is nothing to draw a line between, and saying so
   beats drawing a flat line that looks like a measured idle. */
function sparkline(series,maxV){
  var pts=series.filter(function(v){return typeof v==="number"});
  if(pts.length<2)
    return '<div class="spark"><div class="warming">collecting…</div></div>';
  var top=maxV||Math.max.apply(null,pts)||1;
  var W=100,H=30,n=pts.length;
  var xy=pts.map(function(v,i){
    var x=(n===1)?W:(i/(n-1)*W);
    var y=H-(clampTo(v,top)/top*H);
    return x.toFixed(2)+","+y.toFixed(2);
  });
  var area="0,"+H+" "+xy.join(" ")+" "+W+","+H;
  return '<div class="spark"><svg viewBox="0 0 '+W+' '+H+'" preserveAspectRatio="none">'
    +'<polygon class="fill" points="'+area+'"/>'
    +'<polyline class="line" points="'+xy.join(" ")+'"/></svg></div>';
}
function clampTo(v,top){return Math.max(0,Math.min(top,v))}

function rate(bps){
  if(bps==null)return null;
  if(bps>=1048576)return (bps/1048576).toFixed(1)+" MB/s";
  if(bps>=1024)return Math.round(bps/1024)+" KB/s";
  return Math.round(bps)+" B/s";
}

/* One block per REAL logical CPU, each filled by that core's own load. The
   count is len(per_core), never a round number chosen for looks: a block
   IS a core, so 16 cores draw 16 blocks and 32 draw 32. */
function coreRow(perCore){
  return perCore.map(function(v){
    return '<div class="c"><i style="height:'+clamp(v)+'%"></i></div>';
  }).join("");
}

/* 24 ticks over a 270-degree sweep. Kept for GPU alone: it is one
   utilisation percentage with no countable units behind it and no second
   dimension, which is the only place a dial says more than a bar would. */
function gaugeTicks(p){
  var n=24, start=135, sweep=270, filled=Math.round(p/100*n), out="";
  for(var i=0;i<n;i++){
    var ang=(start+sweep*i/(n-1)).toFixed(1);
    var col=(i<filled)?"var(--accent)":"var(--border-strong)";
    out+='<line x1="50" y1="13" x2="50" y2="22" stroke="'+col+'" stroke-width="4.5" '
      +'stroke-linecap="round" transform="rotate('+ang+' 50 50)"/>';
  }
  return out;
}

/* shape: "cores" | "bar" | "gauge" | null. null renders no indicator at
   all -- absence is never drawn as a measurement, in any of the three.
   opts.spark adds the moving line; opts.aux adds secondary readings the
   hardware may or may not report. */
function metric(label,value,sub,shape,data,opts){
  opts=opts||{};
  var body='<div class="lbl">'+esc(label)+'</div>'
   +(value==null
      ? '<div class="val na">Unavailable</div><div class="sub">'+esc(sub)+'</div>'
      : '<div class="val">'+esc(value)+'</div><div class="sub">'+esc(sub)+'</div>');

  var aux="";
  if(opts.aux && opts.aux.length){
    aux='<div class="aux">'+opts.aux.map(function(a){
      return esc(a[0])+" <b>"+esc(a[1])+"</b>";
    }).join("")+'</div>';
  }
  var spark=opts.spark ? sparkline(opts.spark,opts.sparkMax) : "";

  if(shape==="cores" && data && data.length)
    return '<div class="metric">'+body+'<div class="cores">'+coreRow(data)+'</div>'
      +spark+aux+'</div>';
  if(shape==="bar" && data!=null)
    return '<div class="metric">'+body
      +'<div class="bar"><i style="width:'+clamp(data)+'%"></i></div>'+spark+aux+'</div>';
  if(shape==="gauge" && data!=null)
    return '<div class="metric has-gauge"><div style="flex:1;min-width:0">'+body+spark+aux+'</div>'
      +'<div class="gauge"><svg viewBox="0 0 100 100">'+gaugeTicks(clamp(data))+'</svg>'
      +'<div class="gv">'+Math.round(clamp(data))+'%</div></div></div>';
  return '<div class="metric">'+body+aux+'</div>';
}
function paintHealth(tl){
  if(!tl)return;
  var c=tl.cpu,m=tl.memory,g=tl.gpu,s=tl.storage;
  /* The sub-line names BOTH counts when they differ. per_core comes back
     one entry per LOGICAL cpu, so on a 10-core/16-thread part the row is
     16 blocks -- and saying only "10 cores" over 16 blocks would leave the
     viewer counting and finding the label wrong. */
  var cpuSub="psutil not installed";
  if(c){
    cpuSub=(c.cores_physical && c.cores_physical!==c.cores_logical)
      ? c.cores_logical+" threads on "+c.cores_physical+" cores"
      : (c.cores_logical||0)+" cores";
  }
  var h=tl.history||[];
  function series(key){return h.map(function(x){return x[key]})}

  /* Only what this hardware actually reported. nvidia-smi answers [N/A]
     for anything the card does not expose, and workstation.py drops those
     keys rather than zero-filling -- so an absent sensor shows no chip at
     all instead of a convincing 0. */
  var gpuAux=[];
  if(g&&g.temp_c!=null)   gpuAux.push(["temp", Math.round(g.temp_c)+"°C"]);
  if(g&&g.power_w!=null)  gpuAux.push(["power", g.power_w.toFixed(1)+" W"]);
  if(g&&g.clock_mhz!=null)gpuAux.push(["clock", Math.round(g.clock_mhz)+" MHz"]);

  var io=tl.io||null;
  var diskAux=[], memAux=[];
  if(io){
    diskAux.push(["read", rate(io.disk_read_bps)]);
    diskAux.push(["write", rate(io.disk_write_bps)]);
    memAux.push(["net", rate(io.net_recv_bps+io.net_sent_bps)]);
  }

  document.getElementById("health").innerHTML=
     metric("CPU", c?pct(c.percent):null, cpuSub, "cores", c?c.per_core:null,
            {spark:series("cpu"), sparkMax:100})
   + metric("Memory", m?gb(m.used_bytes):null,
            m?"of "+gb(m.total_bytes):"psutil not installed",
            "bar", m?m.percent:null,
            {spark:series("memory"), sparkMax:100, aux:memAux})
   + metric("GPU", g?pct(g.percent):null,
            g?gb(g.vram_used_bytes)+" / "+gb(g.vram_total_bytes)+" VRAM":"No supported GPU was detected.",
            "gauge", g?g.percent:null,
            {spark:series("gpu"), sparkMax:100, aux:gpuAux})
   + metric("Storage", s?gb(s.free_bytes)+" free":null,
            s?"of "+gb(s.total_bytes):"Unavailable",
            "bar", s?s.percent:null,
            /* Throughput, not capacity -- a disk that is 90% full is not
               a disk that is busy, and the line has to answer the second
               question since the bar already answers the first. */
            {spark:series("disk_bps"), aux:diskAux});
  document.getElementById("stamp").textContent="refreshed just now";
}

function paintUsage(a){
  var el=document.getElementById("usage");
  if(!a){el.innerHTML='<div class="empty" style="margin-bottom:var(--space-6)">'
    +'<b>No active usage</b><span>This workstation is currently idle.</span></div>';return}
  var job=[a.job_type,a.job_id?"Job "+a.job_id:"",a.tipe].filter(Boolean).join(" · ")||"—";
  el.innerHTML='<div class="usage">'
   +'<div class="usage-top"><span class="eyebrow">Current usage</span>'
   +'<span class="st act"><span class="mk"></span>ACTIVE</span></div>'
   +'<div class="usage-body"><div>'
   +'<h3 class="purpose">'+esc(dash(a.tujuan))+'</h3>'
   +'<div class="who">'+esc(a.nama||"Unknown")
   +(a.nim?' <span>· '+esc(a.nim)+'</span>':'')+'</div>'
   +'<div class="meta">'+esc(job)+'</div></div>'
   +'<div class="clock">'+esc(a.durasi)+'</div></div>'
   +'<div class="usage-foot"><span class="meta">started '+esc(a.start)+'</span>'
   +'<button onclick="detailActive()">Details</button></div></div>';
}

function paintRecent(list){
  var el=document.getElementById("recent");
  if(!list||!list.length){el.innerHTML='<div class="empty"><b>No sessions recorded</b>'
    +'<span>No sessions have been recorded on this workstation yet.</span></div>';return}
  el.innerHTML='<div class="recent">'+list.map(function(r,i){
    return '<div class="rrow" tabindex="0" data-i="'+i+'">'
      +'<span class="t">'+esc(r.start)+'</span>'
      +'<span><span class="n">'+esc(r.nama)+'</span> <span class="p">'+esc(dash(r.tujuan))+'</span></span>'
      +'<span class="d">'+esc(r.durasi)+'</span></div>';
  }).join("")+'</div>';
}

var SERVER=null;

/* The seven states are resolved SERVER-side from the structured failure
   class (see _server_state). This renders what it is told; it does not
   parse an error string to work out what happened. */
var SERVER_TONE={LOCAL_ONLY:"ok",SYNC_BLOCKED:"",SYNC_PENDING:"warn",
                 SYNCING:"act",SYNCED:"ok",SERVER_UNAVAILABLE:"hollow warn",
                 SYNC_ERROR:"err"};
var SERVER_TITLE={LOCAL_ONLY:"Local only",SYNC_BLOCKED:"Synchronization disabled",
                  SYNC_PENDING:"Waiting to synchronize",SYNCING:"Synchronizing",
                  SYNCED:"All changes synchronized",
                  SERVER_UNAVAILABLE:"Server unavailable",SYNC_ERROR:"Synchronization failed"};

function loadServer(){
  fetch(t("/api/server")).then(function(x){return x.json()})
    .then(function(d){SERVER=d;paintServer(d)}).catch(function(){});
}

function paintServer(d){
  if(!d){return}
  var tone=SERVER_TONE[d.state]||"", title=SERVER_TITLE[d.state]||d.state;
  var acts="";
  /* data-act + delegation, not an inline handler: this page lives inside a
     Python triple-quoted string where a backslash escape does not survive,
     so a nested quote silently becomes a real one and takes out the script. */
  if(d.can_sync)acts+='<button class="primary" data-act="sync">'
    +(d.state==="SYNC_PENDING"?"Sync now":"Retry")+'</button>';
  if(d.can_test)acts+='<button data-act="test">Test connection</button>';

  /* Local logging is stated explicitly whenever the server is not reachable.
     The whole point of the page is that a server problem is not a Logix
     problem, and saying so beats leaving the reader to infer it. */
  var reassure=(d.state==="SERVER_UNAVAILABLE"||d.state==="SYNC_ERROR")
    ? '<dt>Local logging</dt><dd class="okline">Working normally</dd>' : "";

  document.getElementById("server").innerHTML=
    '<div class="card">'
   +'<div class="st '+tone+'" style="margin-bottom:var(--space-1)">'
   +'<span class="mk"></span><span class="head">'+esc(title)+'</span></div>'
   +'<div class="line">'+esc(d.detail||"")+'</div>'

   +'<h3 class="grp-h">Connection</h3><dl class="kv">'
   +'<dt>Server URL</dt><dd>'+esc(d.server_url||"not configured")+'</dd>'
   +'<dt>Last contact</dt><dd>'+esc(dash(d.last_success))+'</dd>'
   +reassure+'</dl>'

   +'<h3 class="grp-h">Synchronization</h3><dl class="kv">'
   +'<dt>Privacy mode</dt><dd>'+esc(dash(d.privacy_mode))+'</dd>'
   /* null, never 0: on a device that does not sync, rows are finished, not
      waiting, and a number here would misdescribe the product. */
   +'<dt>Pending</dt><dd>'+(d.pending==null?"—":esc(d.pending))+'</dd>'
   +'<dt>Last attempt</dt><dd>'+esc(dash(d.last_attempt))+'</dd>'
   +(d.diagnostic?'<dt>Diagnostic</dt><dd class="diag">'+esc(d.diagnostic)+'</dd>':"")
   +'</dl>'

   +'<div class="actions">'+acts+'</div>'
   +'<div class="note" id="serverNote"></div></div>';
}

function serverAction(kind){
  var note=document.getElementById("serverNote");
  if(note)note.textContent=(kind==="sync"?"Synchronizing…":"Testing connection…");
  fetch(t("/api/server/"+kind),{method:"GET"})
    .then(function(x){return x.json()})
    .then(function(d){
      if(d.state){SERVER=d.state;paintServer(d.state)}
      var n=document.getElementById("serverNote");
      /* The sentence follows the resulting STATE, not the exit code: a sync
         that could not reach the server exits cleanly, and calling that
         "finished" contradicted the "Server unavailable" line above it. */
      if(n)n.textContent=d.ok
        ? (kind==="sync"?"Synchronization finished.":"Server reachable.")
        : (d.error||(d.state&&d.state.detail)||"That did not succeed.");
    }).catch(function(){
      var n=document.getElementById("serverNote");
      if(n)n.textContent="Could not run that action.";
    });
}
function syncNow(){ loadOverview(); }

function loadOverview(){
  fetch(t("/api/overview")).then(function(r){return r.json()}).then(function(d){
    OV=d;
    var w=d.workstation, sub=(w.display!==w.hostname)?w.hostname:"";
    document.getElementById("station").textContent=w.display;
    document.getElementById("stationSub").textContent=sub;
    document.getElementById("chipName").textContent=w.display;
    var v=syncView(d.sync);
    document.getElementById("chipSub").textContent=v.txt;
    document.getElementById("hdrTxt").textContent=v.txt;
    document.getElementById("hdrSt").className="st "+v.cls;
    paintHealth(d.telemetry); paintUsage(d.active); paintRecent(d.recent); paintServer(d.sync);
  }).catch(function(){});
}
function loadTelemetry(){
  fetch(t("/api/telemetry")).then(function(r){return r.json()}).then(paintHealth).catch(function(){});
}

/* ── logs ──────────────────────────────────────────────────────────────
   Search, filters and paging all run in SQL. That is not a preference:
   the browser now holds one page instead of the whole history, so a
   client-side filter would search only the page -- which looks like it
   works and quietly is not a search. */
var TOTAL=0, OFFSET=0, PAGE_SIZE=50, LOADING=false, SEARCH_TIMER=null;

function paintSeg(){
  document.getElementById("seg").innerHTML=RANGES.map(function(r){
    return '<button aria-pressed="'+(r[0]===RANGE)+'" data-r="'+r[0]+'">'
      +r[1]+'</button>'}).join("");
}
function setRange(r){RANGE=r;paintSeg();loadLogs(true)}

function logsQuery(extra){
  var p="range="+encodeURIComponent(RANGE);
  var q=document.getElementById("q").value.trim();
  var u=document.getElementById("fuser").value;
  var j=document.getElementById("fjob").value;
  var sy=document.getElementById("fsync").value;
  if(q)p+="&q="+encodeURIComponent(q);
  if(u)p+="&user="+encodeURIComponent(u);
  if(j)p+="&job_type="+encodeURIComponent(j);
  if(sy)p+="&sync="+encodeURIComponent(sy);
  return p+(extra||"");
}

/* reset=true starts a new result set; otherwise this appends the next
   page to what is already on screen. */
function loadLogs(reset){
  if(LOADING)return;
  LOADING=true;
  if(reset){OFFSET=0;ROWS=[]}
  fetch(t("/api/logs?"+logsQuery("&limit="+PAGE_SIZE+"&offset="+OFFSET)))
    .then(function(x){return x.json()})
    .then(function(d){
      TOTAL=d.total||0;
      ROWS=reset?(d.sessions||[]):ROWS.concat(d.sessions||[]);
      OFFSET=ROWS.length;
      LOADING=false;
      renderLogs();
    }).catch(function(){LOADING=false});
}

function loadFilterOptions(){
  fetch(t("/api/logs/filters")).then(function(x){return x.json()}).then(function(d){
    function fill(id,label,vals){
      var el=document.getElementById(id);
      el.innerHTML='<option value="">'+label+'</option>'+(vals||[]).map(function(v){
        return '<option value="'+esc(v)+'">'+esc(v)+'</option>'}).join("");
    }
    fill("fuser","All users",d.users);
    /* An empty job list means nothing has ever recorded one. Disabling the
       control says that, where an empty dropdown just looks broken. */
    fill("fjob","All jobs",d.job_types);
    document.getElementById("fjob").disabled=!(d.job_types&&d.job_types.length);
  }).catch(function(){});
}

var SYNC_LABEL={synced:"Synced",pending:"Pending",active:"Active"};

function renderLogs(){
  SHOWN=ROWS;
  var el=document.getElementById("logs"), tally=document.getElementById("tally");
  var more=document.getElementById("morewrap");
  if(!SHOWN.length){
    var filtered=document.getElementById("q").value.trim()||
                 document.getElementById("fuser").value||
                 document.getElementById("fjob").value||
                 document.getElementById("fsync").value;
    var empty=filtered
      ? ['No matching sessions','No session matches this search or filter.']
      : ['No sessions in this period','Try a wider date range.'];
    el.innerHTML='<div class="empty"><b>'+empty[0]+'</b><span>'+empty[1]+'</span></div>';
    tally.textContent=""; more.innerHTML=""; return;
  }
  var h='<table><thead><tr><th>Date</th><th>Start</th><th>User</th>'
   +'<th>Purpose</th><th class="opt">Job</th>'
   +'<th class="r">Duration</th><th>Sync</th></tr></thead><tbody>';
  SHOWN.forEach(function(r,i){
    /* NIM sits UNDER the name: present for audit, never competing with it. */
    var who=esc(r.nama||"—")+(r.nim?'<div class="sub2">'+esc(r.nim)+'</div>':"");
    var job=r.job_type||r.job_id
      ? esc(r.job_type||"—")+(r.job_id?'<div class="sub2">'+esc(r.job_id)+'</div>':"")
      : "—";
    var d=(r.start||"").split(" ")[0], tm=(r.start||"").split(" ")[1]||"";
    var syncCls=r.sync==="synced"?"ok":(r.sync==="active"?"act":"warn");
    h+='<tr tabindex="0" data-i="'+i+'">'
     +'<td class="num">'+esc(d)+'</td>'
     +'<td class="num mut">'+esc(tm)+'</td>'
     +'<td>'+who+'</td>'
     +'<td>'+esc(dash(r.tujuan))+'</td>'
     +'<td class="mut opt">'+job+'</td>'
     +'<td class="num r">'+esc(r.durasi)+'</td>'
     +'<td><span class="st '+syncCls+'"><span class="mk"></span>'
       +esc(SYNC_LABEL[r.sync]||r.sync)+'</span></td></tr>';
  });
  el.innerHTML=h+'</tbody></table>';
  tally.textContent=SHOWN.length+" of "+TOTAL+(TOTAL===1?" session":" sessions");
  /* An explicit control, not infinite scroll: someone auditing history
     needs to know whether they have reached the end. */
  more.innerHTML=(SHOWN.length<TOTAL)
    ? '<button onclick="loadLogs(false)">Load '+Math.min(PAGE_SIZE,TOTAL-SHOWN.length)+' more</button>'
    : "";
}

/* ── details sheet ───────────────────────────────────────────────────── */
function group(title,pairs){
  return '<div class="grp"><h4>'+esc(title)+'</h4><dl>'+pairs.map(function(p){
    return '<dt>'+esc(p[0])+'</dt><dd>'+esc(dash(p[1]))+'</dd>'}).join("")+'</dl></div>';
}
function sheet(title,html){
  LASTFOCUS=document.activeElement;
  document.getElementById("sheetTitle").textContent=title;
  document.getElementById("sheetBody").innerHTML=html;
  document.getElementById("scrim").classList.add("open");
  document.querySelector(".sheet .x").focus();
}
function closeSheet(){
  document.getElementById("scrim").classList.remove("open");
  if(LASTFOCUS&&LASTFOCUS.focus)LASTFOCUS.focus();
}
document.addEventListener("keydown",function(e){if(e.key==="Escape")closeSheet()});

function body(r,station,syncTxt,localTxt){
  return group("Identity",[["Name",r.nama],["NIM",r.nim]])
   +group("Workstation",[["Station",station]])
   +group("Session",[["Purpose",r.tujuan],["Job type",r.job_type],["Job ID",r.job_id],
                     ["Access",r.tipe],["Start",r.start],["End",r.end],["Duration",r.durasi]])
   +'<div class="grp"><h4>Description</h4><div class="prose">'
     +esc(dash(r.keterangan))+'</div></div>'
   +group("State",[["Local",localTxt],["Sync",syncTxt]]);
}
function detailActive(){
  var a=OV&&OV.active; if(!a)return;
  sheet("Current session", body(a, OV.workstation.display,
        syncView(OV.sync).txt, "Stored on this workstation"));
}
function detailRow(i){
  var r=SHOWN[i]; if(!r)return;
  sheet("Session", body(r, OV?OV.workstation.display:"",
        syncView(OV&&OV.sync).txt, "Stored on this workstation"));
}
function detailRecent(i){
  var r=(OV&&OV.recent||[])[i]; if(!r)return;
  sheet("Session", group("Identity",[["Name",r.nama],["NIM",r.nim]])
    +group("Session",[["Purpose",r.tujuan],["Start",r.start],["Duration",r.durasi]]));
}

/* Writes to whichever note element belongs to the view the user is on, so
   feedback appears where they clicked rather than on the other page. */
function exportNote(msg){
  var ids=["exportNote","exportNoteOverview"];
  for(var i=0;i<ids.length;i++){
    var el=document.getElementById(ids[i]);
    if(el) el.textContent=msg;
  }
}
function doExport(){
  exportNote("Preparing export…");
  fetch(t("/api/export?range="+encodeURIComponent(RANGE)))
   .then(function(x){return x.json()})
   .then(function(d){
     if(d.ok){
       /* Say where it went, not just that it happened -- the browser drops
          it in the download folder and a bare "Exported" leaves the person
          hunting for a filename they never saw. */
       exportNote("Saved "+d.name+(d.note?" — "+d.note:""));
       window.location=t("/download?f="+encodeURIComponent(d.name));
     }
     else{exportNote("Export failed. "+d.error)}
   }).catch(function(){exportNote("Export failed.")});
}

/* Shortcut hint reflects the platform. Displayed only -- the binding ships
   when the binding ships. */
if(/Mac|iPhone|iPad/.test(navigator.platform||""))
  document.getElementById("kbd").textContent="⌘K";

/* Delegated rather than inline. An inline handler needs nested quotes, and
   this page lives inside a Python triple-quoted string where a backslash
   escape does not survive -- it silently became a real quote and took the
   whole script out. Delegation keeps the markup free of both. */
function delegate(id, pick){
  var el=document.getElementById(id);
  function run(e){ var hit=pick(e.target); if(hit!==null&&hit!==undefined) hit(); }
  el.addEventListener("click", run);
  el.addEventListener("keydown", function(e){ if(e.key==="Enter"){e.preventDefault();run(e)} });
}
delegate("recent", function(t){
  var r=t.closest?t.closest(".rrow"):null;
  return r?function(){detailRecent(+r.dataset.i)}:null; });
delegate("logs", function(t){
  var r=t.closest?t.closest("tr[data-i]"):null;
  return r?function(){detailRow(+r.dataset.i)}:null; });
delegate("server", function(t){
  var b=t.closest?t.closest("button[data-act]"):null;
  return b?function(){serverAction(b.dataset.act)}:null; });
delegate("seg", function(t){
  var b=t.closest?t.closest("button[data-r]"):null;
  return b?function(){setRange(b.dataset.r)}:null; });

/* Debounced: each keystroke is a SQL query, and firing one per character
   would queue requests faster than they return. 250ms is below the
   threshold where typing feels laggy and well above a fast typist s gap
   between keys. */
document.getElementById("q").addEventListener("input",function(){
  clearTimeout(SEARCH_TIMER);
  SEARCH_TIMER=setTimeout(function(){loadLogs(true)},250);
});
["fuser","fjob","fsync"].forEach(function(id){
  document.getElementById(id).addEventListener("change",function(){loadLogs(true)});
});
/* The hint has been on screen since the Overview work; this is the binding
   it was promising. */
document.addEventListener("keydown",function(e){
  if((e.ctrlKey||e.metaKey)&&e.key.toLowerCase()==="k"){
    e.preventDefault(); go("logs");
    var q=document.getElementById("q"); q.focus(); q.select();
  }
});

paintSeg();
loadFilterOptions();
loadOverview();
/* Telemetry refreshes on its own timer; the session queries deliberately do
   not run with it. Nothing animates on refresh -- numerals are tabular so a
   changing digit moves nothing. */
setInterval(function(){if(VIEW==="overview")loadTelemetry()},2500);
setInterval(loadOverview,30000);
</script>
"""


class State:
    """Shared between the handler instances http.server creates per request."""

    def __init__(self, db: Path, token: str, device: str):
        self.db = db
        self.token = token
        self.device = device
        self.last_seen = time.time()
        self.exports: dict[str, Path] = {}


class Handler(http.server.BaseHTTPRequestHandler):
    state: State = None  # set by serve()
    server_version = "Logix"
    sys_version = ""

    def log_message(self, fmt, *args):  # noqa: A003
        # The default handler prints every request to stderr, which on a report
        # UI means printing a running log of who looked at what. Silence is the
        # privacy-preserving default here.
        pass

    def _send(self, code, body: bytes, ctype="application/json; charset=utf-8", extra=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        # This page renders only its own data; nothing here should be framed,
        # sniffed into another type, or leak a referrer to anywhere.
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra or {}):
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def _authed(self, qs) -> bool:
        got = (qs.get("t") or [""])[0]
        # compare_digest: a token check that leaks its answer through timing is
        # not much of a token check.
        return secrets.compare_digest(got, self.state.token)

    def do_GET(self):  # noqa: N802
        self.state.last_seen = time.time()
        parsed = urllib.parse.urlparse(self.path)
        qs = urllib.parse.parse_qs(parsed.query)
        route = parsed.path

        if not self._authed(qs):
            self._send(403, b'{"error":"forbidden"}')
            return

        if route == "/":
            self._send(200, PAGE.encode("utf-8"), "text/html; charset=utf-8")
            return

        if route == "/api/overview":
            try:
                self._send(200, json.dumps(_overview(self.state)).encode("utf-8"))
            except Exception as exc:
                self._send(500, json.dumps({"error": str(exc)}).encode("utf-8"))
            return

        if route == "/api/telemetry":
            # Split from /api/overview on purpose. The cards refresh every
            # couple of seconds; re-running the day's session queries at that
            # rate to redraw a CPU number would be pure waste.
            try:
                import workstation
                force = (qs.get("gpu") or [""])[0] == "force"
                payload = workstation.snapshot(force_gpu=force)
                # The samples this process has taken so far, so the page can
                # draw a moving line rather than re-deriving one client-side
                # from readings it would have to remember itself. In memory
                # only -- see workstation.history().
                payload["history"] = workstation.history()
                self._send(200, json.dumps(payload).encode("utf-8"))
            except Exception as exc:
                self._send(200, json.dumps({"error": str(exc), "cpu": None,
                                            "memory": None, "storage": None,
                                            "gpu": None}).encode("utf-8"))
            return

        if route in ("/api/sessions", "/api/logs"):
            name = (qs.get("range") or ["today"])[0]
            if name not in RANGES:
                name = "today"
            q = (qs.get("q") or [""])[0]
            user = (qs.get("user") or [""])[0]
            job_type = (qs.get("job_type") or [""])[0]
            sync_f = (qs.get("sync") or [""])[0]
            try:
                limit = min(500, max(1, int((qs.get("limit") or ["50"])[0])))
                offset = max(0, int((qs.get("offset") or ["0"])[0]))
            except ValueError:
                limit, offset = 50, 0
            try:
                sessions, label, total = load_sessions_page(
                    self.state.db, name, q=q, user=user, job_type=job_type,
                    limit=limit, offset=offset)
            except Exception as exc:  # a broken DB must not take the page down
                self._send(500, json.dumps({"error": str(exc)}).encode("utf-8"))
                return

            rendered = [_render_session(s) for s in sessions]
            # Sync is a per-ROW column rather than a session-level one, so it
            # cannot be pushed into the session-id query above without
            # changing what a "matching session" means. Filtered here, on the
            # page -- which is why the total below is the unfiltered-by-sync
            # count and the UI labels it as the range total, not the match
            # count.
            if sync_f:
                rendered = [r for r in rendered if r["sync"] == sync_f]

            payload = {
                "label": label,
                "device": self.state.device,
                "db": str(self.state.db),
                "summary": _summarize(sessions),
                "total": total,
                "limit": limit,
                "offset": offset,
                "returned": len(rendered),
                "sessions": rendered,
            }
            self._send(200, json.dumps(payload).encode("utf-8"))
            return

        if route == "/api/server":
            try:
                self._send(200, json.dumps(_server_state(self.state.db)).encode("utf-8"))
            except Exception as exc:
                self._send(200, json.dumps({"error": str(exc)}).encode("utf-8"))
            return

        if route in ("/api/server/test", "/api/server/sync"):
            # These are the ONLY endpoints on this server that are not
            # read-only, and they take no parameters: they can run the
            # existing sync path and nothing else. See this module's
            # docstring, which is updated rather than left to mislead.
            try:
                self._send(200, json.dumps(
                    _server_action(self.state.db, route.rsplit("/", 1)[1])
                ).encode("utf-8"))
            except Exception as exc:
                self._send(200, json.dumps({"ok": False, "error": str(exc)}).encode("utf-8"))
            return

        if route == "/api/logs/filters":
            # Options taken from what the database actually contains. A
            # dropdown offering job types nobody has ever recorded is noise.
            try:
                self._send(200, json.dumps({
                    "users": distinct_values(self.state.db, "nama"),
                    "job_types": distinct_values(self.state.db, "job_type"),
                }).encode("utf-8"))
            except Exception as exc:
                self._send(200, json.dumps(
                    {"users": [], "job_types": [], "error": str(exc)}).encode("utf-8"))
            return

        if route == "/api/export":
            name = (qs.get("range") or ["today"])[0]
            if name not in RANGES:
                name = "today"
            start_d, end_d, _ = resolve_range(name)
            # Export what the VIEW is showing, not the whole period. The
            # filters are resolved through the same paged query the table
            # uses, with no limit, so the workbook and the screen can never
            # disagree about which sessions matched.
            q = (qs.get("q") or [""])[0]
            user = (qs.get("user") or [""])[0]
            job_type = (qs.get("job_type") or [""])[0]
            only_ids = None
            if q or user or job_type:
                try:
                    matched, _lbl, _tot = load_sessions_page(
                        self.state.db, name, q=q, user=user, job_type=job_type,
                        limit=100000, offset=0)
                    only_ids = [m.get("session_id") for m in matched]
                except Exception:
                    only_ids = None
            try:
                # Straight to the existing generator: the download is the same
                # file the CLI produces, not a second implementation of it.
                out = report.build(start_date=start_d, end_date=end_d,
                                   full=(start_d is None), db=self.state.db,
                                   session_ids=only_ids)
                p = Path(out)
                self.state.exports[p.name] = p
                self._send(200, json.dumps({"ok": True, "name": p.name,
                                            "format": "xlsx"}).encode("utf-8"))
            except SystemExit as exc:
                # openpyxl is an OPTIONAL dependency, and logbook_report
                # signals its absence with SystemExit -- which is a
                # BaseException, so the general handler below never saw it and
                # the request died without a reply. Export degrades to CSV
                # rather than the page appearing to hang.
                try:
                    p = _export_csv(self.state.db, start_d, end_d, only_ids)
                    self.state.exports[p.name] = p
                    self._send(200, json.dumps({
                        "ok": True, "name": p.name, "format": "csv",
                        "note": "openpyxl is not installed; exported CSV instead.",
                    }).encode("utf-8"))
                except Exception as inner:
                    self._send(200, json.dumps(
                        {"ok": False, "error": f"{exc} / {inner}"}).encode("utf-8"))
            except Exception as exc:
                self._send(200, json.dumps({"ok": False, "error": str(exc)}).encode("utf-8"))
            return

        if route == "/download":
            name = (qs.get("f") or [""])[0]
            # Served from a dict this process filled in, never from a path the
            # request supplies: a download endpoint that joins user input onto
            # a directory is a directory-traversal hole with a friendly name.
            p = self.state.exports.get(name)
            if not p or not p.is_file():
                self._send(404, b'{"error":"not found"}')
                return
            data = p.read_bytes()
            self._send(
                200, data,
                "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
                extra=[("Content-Disposition", f'attachment; filename="{p.name}"')],
            )
            return

        self._send(404, b'{"error":"not found"}')


def _idle_watchdog(state: State, httpd):
    while True:
        time.sleep(IDLE_POLL_SECONDS)
        if time.time() - state.last_seen > IDLE_SHUTDOWN_SECONDS:
            httpd.shutdown()
            return


def create_server(db: Path, host="127.0.0.1", port=0, device="", url_file=None):
    """Bind the server and publish its URL, without entering the serve loop.

    Split out from serve() so that the thing which STARTS a server and the
    thing which BLOCKS on one are separable: tests need to stop it again, and
    anything embedding this needs a handle. A helper whose only interface is
    "runs forever" cannot be verified, only observed.

    Returns (httpd, url, state).
    """
    token = secrets.token_urlsafe(24)
    state = State(db, token, device or socket.gethostname())
    handler = type("BoundHandler", (Handler,), {"state": state})
    # Loopback only, and never a caller-supplied host: binding 0.0.0.0 would
    # put names and student IDs on the lab network.
    httpd = http.server.ThreadingHTTPServer((host, port), handler)
    actual = httpd.server_address[1]
    url = f"http://{host}:{actual}/?t={token}"
    # flush: anything reading this back gets it now rather than at exit, since
    # Python buffers stdout whenever it is a pipe rather than a console.
    print(f"Logix reports: {url}", flush=True)

    # The launcher learns the URL from a FILE, not from this process's stdout.
    # Reading a child's pipe means holding that pipe open, and a launcher whose
    # whole job is to fire and forget must not stay attached to the thing it
    # started -- doing so hangs the shortcut for as long as the server lives.
    # Written temp-then-rename so a reader polling for it cannot catch a
    # half-written line, the same way bar_status.json is written.
    if url_file:
        try:
            uf = Path(url_file)
            uf.parent.mkdir(parents=True, exist_ok=True)
            tmp = uf.with_suffix(uf.suffix + ".tmp")
            tmp.write_text(url, encoding="utf-8")
            os.replace(tmp, uf)
        except Exception:
            pass

    return httpd, url, state


def serve(db: Path, host="127.0.0.1", port=0, open_browser=True, device="", url_file=None):
    httpd, url, state = create_server(db, host=host, port=port, device=device, url_file=url_file)
    threading.Thread(target=_idle_watchdog, args=(state, httpd), daemon=True).start()
    if open_browser:
        threading.Timer(0.4, lambda: webbrowser.open(url)).start()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()
        # The token dies with the process, so a file still naming it is a
        # stale invitation. Remove it on the way out.
        if url_file:
            try:
                Path(url_file).unlink()
            except Exception:
                pass
    return url


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description="Local Logix report UI (this machine only)")
    p.add_argument("--db", default=str(DEFAULT_DB))
    p.add_argument("--port", type=int, default=0, help="0 picks a free port")
    p.add_argument("--no-browser", action="store_true")
    p.add_argument("--device", default="", help="label shown in the header")
    p.add_argument("--url-file", default="",
                   help="write the tokenised URL here for a launcher to read")
    ns = p.parse_args(argv)
    db = Path(ns.db).expanduser()
    if not db.exists():
        print(f"No Logix database at {db} yet -- start a session first.", file=sys.stderr)
        return 2
    serve(db, port=ns.port, open_browser=not ns.no_browser, device=ns.device,
          url_file=(ns.url_file or None))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
