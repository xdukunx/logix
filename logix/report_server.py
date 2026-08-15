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


PAGE = """<!doctype html>
<html lang="id"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Logix - Laporan</title>
<style>
:root{
  --surface:#070C15; --elevated:#0E1626; --widget:#0B1017; --hairline:#223451;
  --text:#EEF3FB; --muted:#93A1B8; --accent:#2563EB; --active:#22C55E;
}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--surface);color:var(--text);
  font-family:"Segoe UI",system-ui,-apple-system,sans-serif;font-size:14px;
  padding:28px 22px 60px;-webkit-font-smoothing:antialiased}
.wrap{max-width:1040px;margin:0 auto}
header{display:flex;align-items:baseline;gap:12px;margin-bottom:22px}
h1{font-size:19px;font-weight:600;letter-spacing:-0.01em}
.device{font-family:Consolas,monospace;font-size:12px;color:var(--muted)}
.tabs{display:flex;gap:6px;margin-bottom:18px;flex-wrap:wrap}
.tab{padding:7px 15px;border-radius:999px;border:1px solid var(--hairline);
  background:var(--widget);color:var(--muted);cursor:pointer;font-size:12.5px}
.tab:hover{border-color:#2E4468;color:var(--text)}
.tab.on{background:var(--accent);border-color:var(--accent);color:#fff}
.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));
  gap:10px;margin-bottom:18px}
.stat{background:var(--elevated);border:1px solid var(--hairline);
  border-radius:14px;padding:14px 16px}
.stat .k{font-size:11px;color:var(--muted);text-transform:uppercase;letter-spacing:.06em}
.stat .v{font-family:Consolas,monospace;font-size:23px;margin-top:5px}
.card{background:var(--elevated);border:1px solid var(--hairline);
  border-radius:16px;overflow:hidden}
.tablewrap{overflow-x:auto}
table{width:100%;border-collapse:collapse;font-size:13px}
th{text-align:left;font-weight:500;font-size:11px;color:var(--muted);
  text-transform:uppercase;letter-spacing:.05em;padding:12px 14px;
  border-bottom:1px solid var(--hairline);white-space:nowrap}
td{padding:11px 14px;border-bottom:1px solid rgba(34,52,81,.5);vertical-align:top}
tr:last-child td{border-bottom:0}
.mono{font-family:Consolas,monospace;font-size:12.5px}
.dot{display:inline-block;width:7px;height:7px;border-radius:50%;
  background:var(--muted);margin-right:7px;vertical-align:middle}
.dot.on{background:var(--active)}
.muted{color:var(--muted)}
.empty{padding:46px 20px;text-align:center;color:var(--muted)}
.bar{display:flex;justify-content:space-between;align-items:center;
  gap:12px;margin:20px 0 0;flex-wrap:wrap}
button.exp{padding:9px 17px;border-radius:999px;border:1px solid var(--accent);
  background:var(--accent);color:#fff;font-size:12.5px;cursor:pointer;font-family:inherit}
button.exp:hover{filter:brightness(1.1)}
button.exp:disabled{opacity:.55;cursor:default}
footer{margin-top:26px;font-size:11.5px;color:var(--muted);line-height:1.7}
</style></head>
<body><div class="wrap">
<header><h1>Laporan Logix</h1><span class="device" id="dev"></span></header>
<div class="tabs" id="tabs"></div>
<div class="stats" id="stats"></div>
<div class="card"><div class="tablewrap"><table>
<thead><tr><th>Mulai</th><th>Selesai</th><th>Durasi</th><th>Nama</th><th>NIM</th>
<th>Tujuan</th><th>Akses</th><th>Status</th></tr></thead>
<tbody id="rows"></tbody></table></div></div>
<div class="bar"><span class="muted" id="period"></span>
<button class="exp" id="exp">Export .xlsx</button></div>
<footer id="foot"></footer>
</div><script>
var TOKEN=new URLSearchParams(location.search).get("t")||"";
var cur="today";
var LABELS={today:"Hari ini",week:"Minggu ini",month:"Bulan ini",all:"Semua"};
function esc(s){var d=document.createElement("span");d.textContent=s==null?"":String(s);return d.innerHTML}
function tabs(){
  var h="";for(var k in LABELS){h+='<div class="tab'+(k===cur?" on":"")+'" data-r="'+k+'">'+LABELS[k]+'</div>'}
  document.getElementById("tabs").innerHTML=h;
  Array.prototype.forEach.call(document.querySelectorAll(".tab"),function(t){
    t.onclick=function(){cur=t.getAttribute("data-r");tabs();load()}})}
function load(){
  fetch("/api/sessions?range="+cur+"&t="+encodeURIComponent(TOKEN))
   .then(function(r){return r.json()}).then(function(d){
    document.getElementById("dev").textContent=d.device||"";
    document.getElementById("period").textContent=d.label+" \\u00b7 "+d.summary.sessions+" sesi";
    var s=d.summary,st="";
    st+='<div class="stat"><div class="k">Sesi</div><div class="v">'+s.sessions+'</div></div>';
    st+='<div class="stat"><div class="k">Berjalan</div><div class="v">'+s.active+'</div></div>';
    st+='<div class="stat"><div class="k">Pengguna</div><div class="v">'+s.people+'</div></div>';
    st+='<div class="stat"><div class="k">Total durasi</div><div class="v">'+esc(s.duration)+'</div></div>';
    document.getElementById("stats").innerHTML=st;
    var b="";
    d.sessions.forEach(function(r){
      b+="<tr><td class='mono'>"+esc(r.start)+"</td><td class='mono'>"+esc(r.end||"-")+"</td>"+
         "<td class='mono'>"+esc(r.durasi)+"</td><td>"+esc(r.nama)+"</td>"+
         "<td class='mono'>"+esc(r.nim)+"</td><td>"+esc(r.tujuan)+"</td>"+
         "<td class='muted'>"+esc(r.tipe)+"</td><td><span class='dot"+(r.active?" on":"")+
         "'></span>"+esc(r.status)+"</td></tr>"});
    document.getElementById("rows").innerHTML=b||
      "<tr><td colspan='8' class='empty'>Belum ada sesi pada periode ini.</td></tr>";
    document.getElementById("foot").innerHTML=
      "Data dibaca langsung dari basis data lokal perangkat ini: <span class='mono'>"+esc(d.db)+
      "</span><br>Halaman ini hanya dapat diakses dari komputer ini dan akan berhenti sendiri saat tidak dipakai.";
  })}
document.getElementById("exp").onclick=function(){
  var b=this;b.disabled=true;b.textContent="Menyiapkan...";
  fetch("/api/export?range="+cur+"&t="+encodeURIComponent(TOKEN))
   .then(function(r){return r.json()}).then(function(d){
    b.disabled=false;b.textContent="Export .xlsx";
    if(d.ok){window.location="/download?t="+encodeURIComponent(TOKEN)+"&f="+encodeURIComponent(d.name)}
    else{alert("Export gagal: "+(d.error||"tidak diketahui"))}})
   .catch(function(e){b.disabled=false;b.textContent="Export .xlsx";alert("Export gagal: "+e)})};
tabs();load();
</script></body></html>
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
                self._send(200, json.dumps({"ok": True, "name": p.name}).encode("utf-8"))
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
