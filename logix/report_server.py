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
<title>Logix</title>
<style>
:root{
  --bg:#F7F6F3; --surface:#FFFFFF; --ink:#17161C; --ink-2:#55525E;
  --ink-3:#8B8896; --line:#E4E2DC; --line-2:#EFEDE8;
  --accent:#2F5BEA; --ok:#2E7D5B; --warn:#9A6B12; --err:#B4442E;
  --mono:ui-monospace,"Cascadia Mono","SF Mono",Menlo,Consolas,monospace;
}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);
  font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Inter,system-ui,sans-serif;
  -webkit-font-smoothing:antialiased}
.app{display:grid;grid-template-columns:196px 1fr;min-height:100vh}
nav{border-right:1px solid var(--line);padding:22px 14px;position:sticky;top:0;height:100vh}
.brand{font-size:13px;font-weight:680;letter-spacing:.14em;padding:0 10px 20px}
nav a{display:block;padding:8px 10px;margin-bottom:2px;border-radius:6px;
  color:var(--ink-2);text-decoration:none;font-size:13px;cursor:pointer}
nav a:hover{background:var(--line-2);color:var(--ink)}
nav a.on{background:var(--ink);color:#fff}
nav a:focus-visible,button:focus-visible,input:focus-visible,select:focus-visible{
  outline:2px solid var(--accent);outline-offset:2px}
main{padding:30px 34px 60px;max-width:1180px}
header.top{display:flex;justify-content:space-between;align-items:flex-end;
  gap:20px;padding-bottom:22px;border-bottom:1px solid var(--line);margin-bottom:26px}
.eyebrow{font-size:11px;letter-spacing:.1em;text-transform:uppercase;color:var(--ink-3)}
h1{margin:4px 0 2px;font-size:27px;font-weight:640;letter-spacing:-.02em}
.sub{color:var(--ink-2);font-size:13px}
.pill{display:inline-flex;align-items:center;gap:7px;padding:5px 11px;
  border:1px solid var(--line);border-radius:999px;background:var(--surface);
  font-size:12px;white-space:nowrap}
.dot{width:7px;height:7px;border-radius:50%;background:var(--ink-3);flex:none}
.dot.ok{background:var(--ok)} .dot.warn{background:var(--warn)}
.dot.err{background:var(--err)}
h2{font-size:11px;letter-spacing:.1em;text-transform:uppercase;color:var(--ink-3);
  margin:32px 0 12px;font-weight:600}
h2:first-of-type{margin-top:0}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(178px,1fr));gap:12px}
.card{background:var(--surface);border:1px solid var(--line);border-radius:9px;padding:15px 16px}
.metric{font-size:25px;font-weight:620;letter-spacing:-.02em;font-variant-numeric:tabular-nums}
.metric.na{font-size:15px;font-weight:500;color:var(--ink-3)}
.label{font-size:11px;letter-spacing:.08em;text-transform:uppercase;color:var(--ink-3);margin-bottom:9px}
.foot{font-size:12px;color:var(--ink-2);margin-top:5px;font-variant-numeric:tabular-nums}
.bar{height:3px;background:var(--line-2);border-radius:2px;margin-top:11px;overflow:hidden}
.bar i{display:block;height:100%;background:var(--ink);border-radius:2px}
.usage{background:var(--surface);border:1px solid var(--line);border-radius:9px;padding:20px 22px}
.usage .who{font-size:17px;font-weight:620}
.usage .what{font-size:20px;font-weight:600;letter-spacing:-.01em;margin:12px 0 4px}
.usage .meta{color:var(--ink-2);font-size:13px}
.clock{font-family:var(--mono);font-size:30px;font-weight:600;font-variant-numeric:tabular-nums}
.row{display:flex;justify-content:space-between;align-items:flex-end;gap:20px;flex-wrap:wrap}
.empty{background:var(--surface);border:1px dashed var(--line);border-radius:9px;
  padding:30px;text-align:center;color:var(--ink-2)}
.empty b{display:block;color:var(--ink);font-weight:600;margin-bottom:4px}
table{width:100%;border-collapse:collapse;background:var(--surface);
  border:1px solid var(--line);border-radius:9px;overflow:hidden}
th{text-align:left;font-size:11px;letter-spacing:.07em;text-transform:uppercase;
  color:var(--ink-3);font-weight:600;padding:11px 13px;border-bottom:1px solid var(--line)}
td{padding:11px 13px;border-bottom:1px solid var(--line-2);font-size:13px;vertical-align:top}
tr:last-child td{border-bottom:0}
tbody tr{cursor:pointer}
tbody tr:hover{background:#FBFAF8}
.num{font-variant-numeric:tabular-nums;white-space:nowrap}
.mut{color:var(--ink-3)}
.tools{display:flex;gap:8px;flex-wrap:wrap;margin-bottom:13px}
input,select{font:inherit;padding:7px 10px;border:1px solid var(--line);
  border-radius:6px;background:var(--surface);color:var(--ink)}
input[type=search]{min-width:220px}
button{font:inherit;font-size:13px;padding:7px 13px;border:1px solid var(--line);
  border-radius:6px;background:var(--surface);color:var(--ink);cursor:pointer}
button:hover{background:var(--line-2)}
button.primary{background:var(--ink);color:#fff;border-color:var(--ink)}
.sheet{position:fixed;inset:0;background:rgba(23,22,28,.28);display:none;z-index:9}
.sheet.open{display:block}
.sheet .panel{position:absolute;right:0;top:0;bottom:0;width:min(430px,94vw);
  background:var(--surface);border-left:1px solid var(--line);
  padding:26px 26px 40px;overflow:auto}
.sheet h3{margin:0 0 18px;font-size:17px;font-weight:640}
.kv{display:grid;grid-template-columns:112px 1fr;gap:7px 14px;font-size:13px}
.kv dt{color:var(--ink-3)} .kv dd{margin:0}
.close{position:absolute;top:18px;right:20px;border:0;background:none;font-size:20px;
  line-height:1;color:var(--ink-3);padding:4px 8px}
.note{font-size:12px;color:var(--ink-2);margin-top:6px}
.hide{display:none}
@media(max-width:820px){
  .app{grid-template-columns:1fr}
  nav{position:static;height:auto;display:flex;gap:4px;overflow-x:auto;
    border-right:0;border-bottom:1px solid var(--line);padding:12px}
  .brand{padding:0 8px 0 4px;align-self:center}
  main{padding:20px 16px 50px}
}
</style>

<div class="app">
<nav>
  <div class="brand">LOGIX</div>
  <a id="nav-overview" class="on" onclick="go('overview')" tabindex="0">Overview</a>
  <a id="nav-logs" onclick="go('logs')" tabindex="0">Logs</a>
  <a id="nav-server" onclick="go('server')" tabindex="0">Server</a>
</nav>

<main>
  <header class="top">
    <div>
      <div class="eyebrow">You are using workstation</div>
      <h1 id="station">&mdash;</h1>
      <div class="sub" id="stationSub"></div>
    </div>
    <span class="pill"><span class="dot" id="syncDot"></span><span id="syncPill">Checking</span></span>
  </header>

  <section id="v-overview">
    <h2>Current workstation</h2>
    <div class="grid" id="tele"></div>
    <h2>Current usage</h2>
    <div id="usage"></div>
    <h2>Recent logs</h2>
    <div id="recent"></div>
    <div style="margin-top:12px"><button onclick="go('logs')">View all logs</button></div>
  </section>

  <section id="v-logs" class="hide">
    <h2>Logs</h2>
    <div class="tools">
      <input type="search" id="q" placeholder="Search name, NIM, purpose" oninput="renderLogs()">
      <select id="range" onchange="loadLogs()">
        <option value="today">Today</option>
        <option value="7">Last 7 days</option>
        <option value="30">Last 30 days</option>
        <option value="all" selected>All time</option>
      </select>
      <select id="fstate" onchange="renderLogs()">
        <option value="">All states</option>
        <option value="Aktif">Active</option>
        <option value="Selesai / Finish">Finished</option>
        <option value="Auto Finish">Auto finish</option>
      </select>
      <button class="primary" onclick="doExport()">Export</button>
    </div>
    <div id="exportNote" class="note"></div>
    <div id="logs"></div>
  </section>

  <section id="v-server" class="hide">
    <h2>Central server</h2>
    <div class="card" id="serverCard"></div>
  </section>
</main>
</div>

<div class="sheet" id="sheet" onclick="if(event.target.id==='sheet')closeSheet()">
  <div class="panel" role="dialog" aria-label="Session details">
    <button class="close" onclick="closeSheet()" aria-label="Close">&times;</button>
    <h3 id="sheetTitle">Session</h3>
    <dl class="kv" id="sheetBody"></dl>
  </div>
</div>

<script>
var TOKEN=new URLSearchParams(location.search).get("t")||"";
var OV=null, ROWS=[], SHOWN=[], VIEW="overview";
function t(u){return u+(u.indexOf("?")<0?"?":"&")+"t="+encodeURIComponent(TOKEN)}
var ENT={"&":"&amp;","<":"&lt;",">":"&gt;"};
function esc(s){return String(s==null?"":s).replace(/[&<>]/g,function(c){return ENT[c]})}
function fgb(n){if(n==null)return "—";var v=n/1073741824;
  return (v>=100?v.toFixed(0):v.toFixed(1))+" GB"}

function go(v){
  VIEW=v;
  ["overview","logs","server"].forEach(function(k){
    document.getElementById("v-"+k).classList.toggle("hide",k!==v);
    document.getElementById("nav-"+k).classList.toggle("on",k===v);
  });
  if(v==="logs"&&!ROWS.length)loadLogs();
}

/* The seven states the UX contract defines, never collapsed into "offline".
   local_only and sync_blocked are calm and successful: nothing is waiting. */
function syncView(s){
  if(!s)return{dot:"",txt:"Unknown",line:"Sync state could not be read."};
  var st=s.connection_state, n=s.pending_count, cls=s.last_error_class;
  if(st==="disabled")return{k:"local",dot:"ok",txt:"Local only",
    line:"Stored on this workstation. Nothing needs to be uploaded."};
  if(st==="blocked")return{k:"blocked",dot:"",txt:"Local only",
    line:"Synchronization is disabled by policy. Data is stored complete on this workstation."};
  if(st==="offline"&&cls==="network")return{k:"unavail",dot:"warn",txt:"Server unavailable",
    line:(n?n+" change(s) ":"")+"stored safely on this workstation."};
  if(st==="offline")return{k:"error",dot:"err",txt:"Sync failed",
    line:"The server rejected the last attempt. Local data is safe."};
  if(n>0)return{k:"pending",dot:"warn",txt:n+" pending",
    line:n+" change(s) waiting to synchronize. Local data is safe."};
  if(st==="connected")return{k:"synced",dot:"ok",txt:"Synced",line:"All changes synchronized."};
  return{k:"pending",dot:"",txt:"Not yet synced",
    line:"No synchronization has run on this workstation yet."};
}

function card(label,value,foot,pct,title){
  return '<div class="card"'+(title?' title="'+esc(title)+'"':'')+'>'
    +'<div class="label">'+esc(label)+'</div>'
    +(value==null?'<div class="metric na">Unavailable</div>'
                 :'<div class="metric">'+esc(value)+'</div>')
    +'<div class="foot">'+esc(foot)+'</div>'
    +(pct==null?'':'<div class="bar"><i style="width:'+Math.max(0,Math.min(100,pct))+'%"></i></div>')
    +'</div>';
}
function paintTele(tl){
  if(!tl)return;
  var c=tl.cpu,m=tl.memory,g=tl.gpu,st=tl.storage,h="";
  h+=card("CPU", c?Math.round(c.percent)+"%":null,
      c?(c.cores_physical?c.cores_physical+" cores · "+c.cores_logical+" threads"
                         :c.cores_logical+" threads")
       :"psutil not installed", c?c.percent:null);
  h+=card("Memory", m?fgb(m.used_bytes):null,
      m?"of "+fgb(m.total_bytes):"psutil not installed", m?m.percent:null);
  h+=card("GPU", g?Math.round(g.percent)+"%":null,
      g?fgb(g.vram_used_bytes)+" / "+fgb(g.vram_total_bytes)+" VRAM":"No GPU detected",
      g?g.percent:null, g?g.name:"");
  h+=card("Storage", st?fgb(st.free_bytes)+" free":null,
      st?"of "+fgb(st.total_bytes):"Unavailable", st?st.percent:null);
  document.getElementById("tele").innerHTML=h;
}

function paintUsage(a){
  var el=document.getElementById("usage");
  if(!a){el.innerHTML='<div class="empty"><b>No active usage</b>'
    +'This workstation is currently idle.</div>';return}
  var job=[a.job_type,a.job_id?"Job "+a.job_id:""].filter(Boolean).join(" · ")||"—";
  el.innerHTML='<div class="usage"><div class="row">'
   +'<div><div class="who">'+esc(a.nama||"Unknown")
   +(a.nim?' <span class="mut">· '+esc(a.nim)+'</span>':'')+'</div>'
   +'<div class="what">'+esc(a.tujuan||"—")+'</div>'
   +'<div class="meta">'+esc(job)+'</div></div>'
   +'<div style="text-align:right"><div class="clock">'+esc(a.durasi)+'</div>'
   +'<div class="meta">started '+esc(a.start)+'</div></div></div>'
   +'<div style="margin-top:16px"><button onclick="detailActive()">Details</button></div></div>';
}

function paintRecent(list){
  var el=document.getElementById("recent");
  if(!list||!list.length){el.innerHTML='<div class="empty"><b>No sessions yet</b>'
    +'No sessions recorded on this workstation yet.</div>';return}
  var h='<table><tbody>';
  list.forEach(function(r,i){
    h+='<tr onclick="detailRecent('+i+')">'
      +'<td class="num mut" style="width:78px">'+esc(r.start)+'</td>'
      +'<td style="width:160px">'+esc(r.nama)+'</td>'
      +'<td>'+esc(r.tujuan||"—")+'</td>'
      +'<td class="num" style="text-align:right">'+esc(r.durasi)+'</td></tr>';
  });
  el.innerHTML=h+'</tbody></table>';
}

function paintServer(s){
  var v=syncView(s);
  var quiet=(v.k==="local"||v.k==="blocked");
  document.getElementById("serverCard").innerHTML=
    '<div class="row" style="align-items:center"><div>'
   +'<div class="metric" style="font-size:19px">'+esc(v.txt)+'</div>'
   +'<div class="foot">'+esc(v.line)+'</div></div>'
   +'<span class="pill"><span class="dot '+v.dot+'"></span>'+esc(v.txt)+'</span></div>'
   +'<div class="kv" style="margin-top:20px">'
   +'<dt>Server</dt><dd>'+((s&&s.server_configured)?"configured":"not configured")+'</dd>'
   +'<dt>Privacy mode</dt><dd>'+esc((s&&s.privacy_mode)||"—")+'</dd>'
   +'<dt>Pending</dt><dd>'+(quiet?"—":esc(s&&s.pending_count!=null?s.pending_count:"—"))+'</dd>'
   +'<dt>Last success</dt><dd>'+esc((s&&s.last_success)||"—")+'</dd>'
   +'<dt>Last error</dt><dd>'+esc((s&&s.last_error)||"—")+'</dd></div>';
}

function loadOverview(){
  fetch(t("/api/overview")).then(function(r){return r.json()}).then(function(d){
    OV=d;
    document.getElementById("station").textContent=d.workstation.display;
    document.getElementById("stationSub").textContent=
      (d.workstation.display!==d.workstation.hostname)?d.workstation.hostname:"";
    var v=syncView(d.sync);
    document.getElementById("syncPill").textContent=v.txt;
    document.getElementById("syncDot").className="dot "+v.dot;
    paintTele(d.telemetry); paintUsage(d.active); paintRecent(d.recent); paintServer(d.sync);
  }).catch(function(){});
}
function loadTelemetry(){
  fetch(t("/api/telemetry")).then(function(r){return r.json()}).then(paintTele).catch(function(){});
}
function loadLogs(){
  var r=document.getElementById("range").value;
  fetch(t("/api/sessions?range="+encodeURIComponent(r))).then(function(x){return x.json()})
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
  var el=document.getElementById("logs");
  if(!SHOWN.length){el.innerHTML='<div class="empty"><b>No matching sessions</b>'
    +'Nothing recorded for this filter.</div>';return}
  var h='<table><thead><tr><th>Start</th><th>End</th><th>Name</th><th>NIM</th>'
   +'<th>Purpose</th><th>Job</th><th style="text-align:right">Duration</th>'
   +'<th>State</th></tr></thead><tbody>';
  SHOWN.forEach(function(r,i){
    var job=[r.job_type,r.job_id].filter(Boolean).join(" · ")||"—";
    h+='<tr onclick="detailRow('+i+')">'
     +'<td class="num">'+esc(r.start)+'</td>'
     +'<td class="num mut">'+esc(r.end||"—")+'</td>'
     +'<td>'+esc(r.nama)+'</td><td class="num mut">'+esc(r.nim)+'</td>'
     +'<td>'+esc(r.tujuan||"—")+'</td><td class="mut">'+esc(job)+'</td>'
     +'<td class="num" style="text-align:right">'+esc(r.durasi)+'</td>'
     +'<td class="mut">'+esc(r.status)+'</td></tr>';
  });
  el.innerHTML=h+'</tbody></table>';
}

function sheet(title,pairs){
  document.getElementById("sheetTitle").textContent=title;
  document.getElementById("sheetBody").innerHTML=pairs.map(function(p){
    return "<dt>"+esc(p[0])+"</dt><dd>"+esc(p[1]||"—")+"</dd>"}).join("");
  document.getElementById("sheet").classList.add("open");
}
function closeSheet(){document.getElementById("sheet").classList.remove("open")}
document.addEventListener("keydown",function(e){if(e.key==="Escape")closeSheet()});

function detailActive(){
  var a=OV&&OV.active; if(!a)return;
  sheet("Current session",[
    ["Name",a.nama],["NIM",a.nim],["Workstation",OV.workstation.display],
    ["Purpose",a.tujuan],["Job type",a.job_type],["Job ID",a.job_id],
    ["Access",a.tipe],["Started",a.start],["Duration",a.durasi],
    ["Description",a.keterangan],["Local status","Stored on this workstation"],
    ["Sync",syncView(OV.sync).txt]]);
}
function detailRow(i){
  var r=SHOWN[i]; if(!r)return;
  sheet("Session",[
    ["Name",r.nama],["NIM",r.nim],["Workstation",OV?OV.workstation.display:""],
    ["Purpose",r.tujuan],["Job type",r.job_type],["Job ID",r.job_id],
    ["Access",r.tipe],["Start",r.start],["End",r.end],["Duration",r.durasi],
    ["Description",r.keterangan],["State",r.status]]);
}
function detailRecent(i){
  var r=(OV&&OV.recent||[])[i]; if(!r)return;
  sheet("Session",[["Name",r.nama],["NIM",r.nim],["Purpose",r.tujuan],
    ["Start",r.start],["Duration",r.durasi]]);
}

function doExport(){
  var note=document.getElementById("exportNote");
  note.textContent="Preparing export…";
  var r=document.getElementById("range").value;
  fetch(t("/api/export?range="+encodeURIComponent(r))).then(function(x){return x.json()})
   .then(function(d){
     if(d.ok){note.textContent=d.note||("Exported "+d.name);
              window.location=t("/download?f="+encodeURIComponent(d.name))}
     else{note.textContent="Export failed: "+d.error}
   }).catch(function(){note.textContent="Export failed."});
}

loadOverview();
/* Telemetry refreshes on its own timer; the session queries deliberately do
   not re-run with it -- redrawing a CPU number must not re-query the day. */
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
