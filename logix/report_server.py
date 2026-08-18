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
  * it is read-only: there is no endpoint here that writes to the database;
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
from datetime import date, datetime, timedelta
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

RANGES = ("today", "week", "month", "all")


def resolve_range(name: str):
    """Map a UI range onto the date pair the existing report code expects.

    Deliberately returns the same (start, end) shape `logbook_report.build`
    takes, so the table on screen and the exported .xlsx can never be computed
    from two different periods.
    """
    today = date.today()
    if name == "today":
        return today, today, "Hari ini"
    if name == "week":
        # Monday-based, matching how a lab week is actually discussed.
        start = today - timedelta(days=today.weekday())
        return start, today, "Minggu ini"
    if name == "month":
        return today.replace(day=1), today, "Bulan ini"
    return None, None, "Semua"


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




def _export_csv(db_path, start_d, end_d):
    """Fallback when openpyxl is absent. Same rows, same columns, same
    source -- build_sessions -- so the CSV cannot disagree with the xlsx."""
    import csv
    con = report.connect(db_path)
    try:
        rows = report.fetch_physical(con, start_d, end_d)
    finally:
        con.close()
    sessions = report.build_sessions(rows)
    outdir = Path(report.DEFAULT_OUTDIR)
    outdir.mkdir(parents=True, exist_ok=True)
    out = outdir / f"logix-sessions-{time.strftime('%Y%m%d-%H%M%S')}.csv"
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
   Light is the default. A shared lab workstation is used briefly, by many
   people, in a room lit for working. Dark is opt-in and gets its own
   contrast ladder with a re-picked accent -- it is not a filter. */
:root{
  --bg:#F6F5F2; --surface:#FFFFFF; --surface-subtle:#FBFAF8;
  --surface-accent:#EEF4F6; --border:#E3E0DA; --border-strong:#CFCBC3;
  --text:#14161A; --text-muted:#565C63; --text-faint:#8A9098;
  --accent:#1A5D6E; --accent-hover:#144A58; --accent-ink:#FFFFFF;
  --ok:#2E6F4E; --warn:#8A5A12; --err:#A33A2A;

  --font:-apple-system,BlinkMacSystemFont,"Segoe UI",Inter,system-ui,sans-serif;
  --mono:ui-monospace,"Cascadia Mono","SF Mono",Menlo,Consolas,monospace;

  --space-1:4px; --space-2:8px; --space-3:12px; --space-4:16px;
  --space-5:24px; --space-6:32px; --space-7:48px;
  --radius-sm:4px; --radius-md:8px; --radius-lg:12px;
  --duration-fast:120ms; --duration-normal:180ms;
  --ease:cubic-bezier(.2,.6,.2,1);
}
:root[data-theme="dark"]{
  --bg:#0F1113; --surface:#16191C; --surface-subtle:#1B1F23;
  --surface-accent:#12272E; --border:#262B30; --border-strong:#373D44;
  --text:#E8EAEC; --text-muted:#9AA1A9; --text-faint:#6B727A;
  --accent:#4FB3C9; --accent-hover:#6BC6D9; --accent-ink:#0F1113;
  --ok:#5FB98A; --warn:#D4A257; --err:#E0796A;
}
@media (prefers-color-scheme:dark){
  :root:not([data-theme="light"]){
    --bg:#0F1113; --surface:#16191C; --surface-subtle:#1B1F23;
    --surface-accent:#12272E; --border:#262B30; --border-strong:#373D44;
    --text:#E8EAEC; --text-muted:#9AA1A9; --text-faint:#6B727A;
    --accent:#4FB3C9; --accent-hover:#6BC6D9; --accent-ink:#0F1113;
    --ok:#5FB98A; --warn:#D4A257; --err:#E0796A;
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
/* Block meter -- a row of LEDs, not a dial. Filled count is a REAL
   percentage (CPU/memory/storage/GPU utilisation) rounded to the nearest
   block; there is no second colour, no "of 100" framing, nothing a lit
   block could be mistaken for besides "this much of this machine is in
   use right now". A metric with no reading renders no row at all -- same
   rule the gauge it replaces followed: absence is never drawn as a
   measurement, full or empty. */
.blocks{display:flex;gap:2px;margin-top:var(--space-3)}
.blocks i{flex:1;height:14px;border-radius:1px;background:var(--border-strong);
  min-width:0}
.blocks i.on{background:var(--accent)}

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
      <div class="after"><button onclick="go('logs')">View all logs</button></div>
    </section>

    <!-- LOGS -->
    <section id="v-logs" class="hide">
      <h2 class="sec">Logs</h2>
      <div class="toolbar">
        <div class="field">
          <input id="q" type="search" placeholder="Search sessions"
                 aria-label="Search sessions" oninput="renderLogs()">
          <kbd id="kbd">Ctrl+K</kbd>
        </div>
        <div class="seg" id="seg" role="group" aria-label="Time range"></div>
        <select id="fstate" onchange="renderLogs()" aria-label="Session state">
          <option value="">All states</option>
          <option value="Aktif">Active</option>
          <option value="Selesai / Finish">Finished</option>
          <option value="Auto Finish">Auto finish</option>
        </select>
        <span class="spacer"></span>
        <button class="primary" onclick="doExport()">Export</button>
      </div>
      <div id="exportNote" class="note"></div>
      <div id="logs"></div>
      <div class="tally" id="tally"></div>
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
  if(v==="logs"&&!ROWS.length)loadLogs();
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
/* A row of 18 LEDs, not a dial -- a dashboard of four dials read as "wall of
   gauges" (a generic-analytics tell), where a hardware-monitor utility
   just lights up the blocks that are true right now. Filled count is
   percent/100 rounded to the nearest block, the same real reading the
   gauge it replaces used; nothing else changed about what this represents. */
function blockRow(p){
  var n=18, filled=Math.round(p/100*n), out="";
  for(var i=0;i<n;i++) out+='<i class="'+(i<filled?"on":"")+'"></i>';
  return out;
}
function metric(label,value,sub,p){
  var pClamped=(p==null)?null:Math.max(0,Math.min(100,p));
  return '<div class="metric"><div class="lbl">'+esc(label)+'</div>'
   +(value==null
      ? '<div class="val na">Unavailable</div><div class="sub">'+esc(sub)+'</div>'
      : '<div class="val">'+esc(value)+'</div><div class="sub">'+esc(sub)+'</div>')
   +(pClamped==null?'':'<div class="blocks">'+blockRow(pClamped)+'</div>')
   +'</div>';
}
function paintHealth(tl){
  if(!tl)return;
  var c=tl.cpu,m=tl.memory,g=tl.gpu,s=tl.storage;
  document.getElementById("health").innerHTML=
     metric("CPU", c?pct(c.percent):null,
            c?((c.cores_physical?c.cores_physical+" cores":c.cores_logical+" threads")):"psutil not installed",
            c?c.percent:null)
   + metric("Memory", m?gb(m.used_bytes):null,
            m?"of "+gb(m.total_bytes):"psutil not installed", m?m.percent:null)
   + metric("GPU", g?pct(g.percent):null,
            g?gb(g.vram_used_bytes)+" / "+gb(g.vram_total_bytes)+" VRAM":"No supported GPU was detected.",
            g?g.percent:null)
   + metric("Storage", s?gb(s.free_bytes)+" free":null,
            s?"of "+gb(s.total_bytes):"Unavailable", s?s.percent:null);
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

function paintServer(s){
  var v=syncView(s), quiet=!!v.quiet;
  var acts="";
  if(v.sync)acts+='<button class="primary" onclick="syncNow()">Sync now</button>';
  if(v.retry)acts+='<button onclick="syncNow()">Retry</button>';
  document.getElementById("server").innerHTML='<div class="card">'
   +'<div class="st '+v.cls+'" style="margin-bottom:var(--space-1)">'
   +'<span class="mk"></span><span class="head">'+esc(v.txt)+'</span></div>'
   +'<div class="line">'+esc(v.line)+'</div>'
   +'<dl class="kv">'
   +'<dt>Server</dt><dd>'+((s&&s.server_configured)?"configured":"not configured")+'</dd>'
   +'<dt>Privacy mode</dt><dd>'+esc(dash(s&&s.privacy_mode))+'</dd>'
   /* An em dash, never 0: a zero implies a queue that happens to be empty,
      where the truth is that the question does not apply. */
   +'<dt>Pending</dt><dd>'+(quiet?"—":esc(dash(s&&s.pending_count)))+'</dd>'
   +'<dt>Last success</dt><dd>'+esc(dash(s&&s.last_success))+'</dd>'
   +'<dt>Last error</dt><dd>'+esc(dash(s&&s.last_error))+'</dd></dl>'
   +'<div class="actions">'+acts+'</div></div>';
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

/* ── logs ────────────────────────────────────────────────────────────── */
function paintSeg(){
  document.getElementById("seg").innerHTML=RANGES.map(function(r){
    return '<button aria-pressed="'+(r[0]===RANGE)+'" data-r="'+r[0]+'">'
      +r[1]+'</button>'}).join("");
}
function setRange(r){RANGE=r;paintSeg();loadLogs()}
function loadLogs(){
  fetch(t("/api/sessions?range="+encodeURIComponent(RANGE)))
    .then(function(x){return x.json()})
    .then(function(d){ROWS=d.sessions||[];renderLogs()}).catch(function(){});
}
function renderLogs(){
  var q=(document.getElementById("q").value||"").toLowerCase();
  var fs=document.getElementById("fstate").value;
  SHOWN=ROWS.filter(function(r){
    if(fs&&r.status!==fs)return false;
    if(!q)return true;
    return [r.nama,r.nim,r.tujuan,r.job_type,r.job_id].join(" ").toLowerCase().indexOf(q)>=0;
  });
  var el=document.getElementById("logs"), tally=document.getElementById("tally");
  if(!SHOWN.length){
    var empty=ROWS.length
      ? ['No matching sessions','No session matches this filter.']
      : ['No sessions in this period','Try a wider date range.'];
    el.innerHTML='<div class="empty"><b>'+empty[0]+'</b><span>'+empty[1]+'</span></div>';
    tally.textContent=""; return;
  }
  var h='<table><thead><tr><th>Start</th><th>End</th><th>Name</th>'
   +'<th class="opt">NIM</th><th>Purpose</th><th class="opt">Job</th>'
   +'<th class="r">Duration</th><th>State</th></tr></thead><tbody>';
  SHOWN.forEach(function(r,i){
    var job=[r.job_type,r.job_id].filter(Boolean).join(" · ")||"—";
    h+='<tr tabindex="0" data-i="'+i+'">'
     +'<td class="num">'+esc(r.start)+'</td>'
     +'<td class="num mut">'+esc(dash(r.end))+'</td>'
     +'<td>'+esc(r.nama)+'</td>'
     +'<td class="num mut opt">'+esc(dash(r.nim))+'</td>'
     +'<td>'+esc(dash(r.tujuan))+'</td>'
     +'<td class="mut opt">'+esc(job)+'</td>'
     +'<td class="num r">'+esc(r.durasi)+'</td>'
     +'<td class="mut">'+esc(r.status)+'</td></tr>';
  });
  el.innerHTML=h+'</tbody></table>';
  tally.textContent=SHOWN.length+(SHOWN.length===1?" session":" sessions");
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

function doExport(){
  var note=document.getElementById("exportNote");
  note.textContent="Preparing export…";
  fetch(t("/api/export?range="+encodeURIComponent(RANGE)))
   .then(function(x){return x.json()})
   .then(function(d){
     if(d.ok){note.textContent=d.note||("Exported "+d.name);
              window.location=t("/download?f="+encodeURIComponent(d.name))}
     else{note.textContent="Export failed. "+d.error}
   }).catch(function(){note.textContent="Export failed."});
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
delegate("seg", function(t){
  var b=t.closest?t.closest("button[data-r]"):null;
  return b?function(){setRange(b.dataset.r)}:null; });

paintSeg();
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
                self._send(200, json.dumps(
                    workstation.snapshot(force_gpu=force)).encode("utf-8"))
            except Exception as exc:
                self._send(200, json.dumps({"error": str(exc), "cpu": None,
                                            "memory": None, "storage": None,
                                            "gpu": None}).encode("utf-8"))
            return

        if route == "/api/sessions":
            name = (qs.get("range") or ["today"])[0]
            if name not in RANGES:
                name = "today"
            try:
                sessions, label = load_sessions(self.state.db, name)
            except Exception as exc:  # a broken DB must not take the page down
                self._send(500, json.dumps({"error": str(exc)}).encode("utf-8"))
                return
            payload = {
                "label": label,
                "device": self.state.device,
                "db": str(self.state.db),
                "summary": _summarize(sessions),
                "sessions": [
                    {
                        "start": report.fmt_ts(s.get("start_ts")),
                        "end": report.fmt_ts(s.get("end_ts")) if s.get("end_ts") else "",
                        "durasi": s.get("durasi") or "-",
                        "nama": s.get("nama") or "",
                        "nim": s.get("nim") or "",
                        "tujuan": s.get("tujuan") or "",
                        "tipe": s.get("tipe") or "",
                        "status": s.get("status") or "",
                        # Carried for the details sheet and the job column.
                        # Empty is the ordinary case and must stay empty --
                        # the page renders an em dash rather than a value.
                        "keterangan": s.get("keterangan") or "",
                        "job_type": s.get("job_type") or "",
                        "job_id": s.get("job_id") or "",
                        "active": bool(s.get("_active")),
                    }
                    for s in sessions
                ],
            }
            self._send(200, json.dumps(payload).encode("utf-8"))
            return

        if route == "/api/export":
            name = (qs.get("range") or ["today"])[0]
            if name not in RANGES:
                name = "today"
            start_d, end_d, _ = resolve_range(name)
            try:
                # Straight to the existing generator: the download is the same
                # file the CLI produces, not a second implementation of it.
                out = report.build(start_date=start_d, end_date=end_d,
                                   full=(start_d is None), db=self.state.db)
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
                    p = _export_csv(self.state.db, start_d, end_d)
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
