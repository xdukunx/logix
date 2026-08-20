"""Tests for logix/report_server.py -- the device's own report UI.

The point of this module is that a Logix Device is a complete product without
a server: sessions are logged locally, so they must be READABLE locally, by
someone who has never opened a terminal. That makes two properties worth
testing hard, because both are the kind that fail silently:

  * it serves personal data (names, student IDs), so it must be unreachable
    without the launch token and must not serve arbitrary files;
  * the numbers on screen and the numbers in the exported .xlsx must come from
    the same code that the CLI report uses, or the lab ends up with two
    "official" answers to the same question.

Imports happen inside the tests, matching the note in test_log_physical.py:
these modules compute DEFAULT_DB at import time from paths.default_db(), and a
top-level import would freeze that before any monkeypatch fixture runs.
"""
from __future__ import annotations

import json
import sqlite3
import threading
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta
from pathlib import Path

import pytest


def _seed_db(path: Path) -> None:
    """Two finished sessions and one still running, written straight to the
    schema log_physical.py creates."""
    import log_physical

    con = log_physical.connect(path)
    log_physical.migrate(con)
    now = datetime.now()

    def ev(session_id, event, when, **extra):
        payload = {
            "timestamp": when.isoformat(),
            "event": event,
            "session_id": session_id,
            "username": "dhana",
            "nama": extra.get("nama", "Mahasiswa Uji"),
            "nim": extra.get("nim", "000000000"),
            "tujuan": "Maintenance",
            "keterangan": "kalibrasi",
            "session_type": extra.get("session_type", "Physical"),
            "hostname": "WS-01",
            "event_uid": f"{session_id}-{event}",
        }
        cols = log_physical.existing_columns(con, "physical_log")
        keys = [k for k in payload if k in cols]
        con.execute(
            f"INSERT INTO physical_log ({','.join(keys)}) VALUES ({','.join('?' * len(keys))})",
            [payload[k] for k in keys],
        )

    ev("s1", "START", now - timedelta(hours=3))
    ev("s1", "END", now - timedelta(hours=2))
    ev("s2", "START", now - timedelta(minutes=90), nama="Orang Kedua", nim="000000001")
    ev("s2", "END", now - timedelta(minutes=30), nama="Orang Kedua", nim="000000001")
    ev("s3", "START", now - timedelta(minutes=10))  # still open
    con.commit()
    con.close()


@pytest.fixture()
def server(tmp_path, monkeypatch):
    """A live report server over a synthetic database, on a free port."""
    monkeypatch.setenv("LOGIX_DB", str(tmp_path / "logix.db"))
    # Keep exports inside tmp_path. Without this they go to the system-wide
    # reports directory, which is root-owned on macOS (EACCES) and a real
    # write onto the host everywhere else.
    monkeypatch.setenv("LOGBOOK_REPORT_DIR", str(tmp_path / "reports"))
    db = tmp_path / "logix.db"
    _seed_db(db)

    import report_server as rs

    # The real construction path, so the fixture cannot drift away from what
    # the launcher actually starts.
    httpd, url, state = rs.create_server(db, port=0, device="WS-TEST")
    port = httpd.server_address[1]
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{port}", state.token, db
    finally:
        httpd.shutdown()
        httpd.server_close()
        thread.join(timeout=10)


def _get(url):
    try:
        resp = urllib.request.urlopen(url, timeout=60)
        return resp.status, resp.read(), resp.headers
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read(), exc.headers


# ---- access control ---------------------------------------------------------

def test_no_token_is_refused(server):
    base, _, _ = server
    status, _, _ = _get(f"{base}/api/sessions?range=all")
    assert status == 403


def test_wrong_token_is_refused(server):
    base, _, _ = server
    status, _, _ = _get(f"{base}/api/sessions?range=all&t=nope")
    assert status == 403


def test_page_requires_the_token_too(server):
    """The HTML itself is gated, not just the JSON. On a shared workstation
    another signed-in user can reach a loopback port, so 'it's only localhost'
    is not an access control."""
    base, token, _ = server
    assert _get(f"{base}/")[0] == 403
    assert _get(f"{base}/?t={token}")[0] == 200


def test_download_cannot_escape_to_arbitrary_files(server):
    """The download endpoint serves from a dict this process filled in, never
    from a path the request supplies."""
    base, token, _ = server
    for probe in ("../../../../Windows/win.ini", "..%2f..%2fboot.ini", "logix.db"):
        status, _, _ = _get(f"{base}/download?t={token}&f={urllib.parse.quote(probe)}")
        assert status == 404, probe


def test_security_headers_present(server):
    base, token, _ = server
    _, _, headers = _get(f"{base}/?t={token}")
    assert headers.get("X-Content-Type-Options") == "nosniff"
    assert headers.get("X-Frame-Options") == "DENY"
    assert headers.get("Cache-Control") == "no-store"


# ---- the data itself --------------------------------------------------------

def test_all_range_lists_every_session(server):
    base, token, _ = server
    status, body, _ = _get(f"{base}/api/sessions?range=all&t={token}")
    assert status == 200
    data = json.loads(body)
    assert data["summary"]["sessions"] == 3
    assert data["summary"]["people"] == 2
    assert data["summary"]["active"] == 1


def test_newest_session_is_listed_first(server):
    """A person opening this is asking about the session they just had."""
    base, token, _ = server
    data = json.loads(_get(f"{base}/api/sessions?range=all&t={token}")[1])
    starts = [s["start"] for s in data["sessions"]]
    assert starts == sorted(starts, reverse=True)


def test_running_session_is_marked_active(server):
    base, token, _ = server
    data = json.loads(_get(f"{base}/api/sessions?range=all&t={token}")[1])
    active = [s for s in data["sessions"] if s["active"]]
    assert len(active) == 1
    assert active[0]["end"] == ""
    assert active[0]["status"] == "Aktif"


def test_unknown_range_falls_back_rather_than_erroring(server):
    base, token, _ = server
    status, body, _ = _get(f"{base}/api/sessions?range=../etc&t={token}")
    assert status == 200
    assert json.loads(body)["label"] == "Hari ini"


@pytest.mark.parametrize("name", ["today", "week", "month", "all"])
def test_every_range_answers(server, name):
    base, token, _ = server
    status, body, _ = _get(f"{base}/api/sessions?range={name}&t={token}")
    assert status == 200
    assert "sessions" in json.loads(body)


def test_ranges_narrow_monotonically(server):
    """today <= week <= month <= all. Not an arbitrary invariant: a report
    period that is not a subset of the wider one means the range arithmetic
    disagrees with itself."""
    base, token, _ = server
    counts = {}
    for name in ("today", "week", "month", "all"):
        counts[name] = json.loads(
            _get(f"{base}/api/sessions?range={name}&t={token}")[1]
        )["summary"]["sessions"]
    assert counts["today"] <= counts["week"] <= counts["month"] <= counts["all"]


# ---- export -----------------------------------------------------------------

def test_export_produces_the_same_workbook_the_cli_writes(server):
    """Export hands off to logbook_report.build(). If this ever stops being
    true, the lab has two different answers to 'what happened today'."""
    import zipfile
    import io

    base, token, _ = server
    status, body, _ = _get(f"{base}/api/export?range=all&t={token}")
    assert status == 200
    payload = json.loads(body)
    assert payload["ok"], payload
    name = payload["name"]

    status, data, headers = _get(f"{base}/download?t={token}&f={urllib.parse.quote(name)}")
    assert status == 200
    assert "spreadsheetml" in headers.get("Content-Type", "")
    assert f'filename="{name}"' in headers.get("Content-Disposition", "")
    # An .xlsx is a zip container; opening it proves a real workbook, not an
    # error page with a spreadsheet's content type.
    assert data[:2] == b"PK"
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        assert any("worksheets" in n for n in z.namelist())


def test_export_is_read_only_for_the_database(server):
    """Nothing this UI exposes may write session data. The device's own log is
    the source of truth for what happened; a report is a view of it."""
    base, token, db = server
    with sqlite3.connect(db) as con:
        before = con.execute("SELECT count(*) FROM physical_log").fetchone()[0]
    _get(f"{base}/api/export?range=all&t={token}")
    _get(f"{base}/api/sessions?range=all&t={token}")
    with sqlite3.connect(db) as con:
        after = con.execute("SELECT count(*) FROM physical_log").fetchone()[0]
    assert after == before


# ---- range arithmetic (no server needed) ------------------------------------

def test_week_starts_on_monday():
    import report_server as rs

    start, end, label = rs.resolve_range("week")
    assert start.weekday() == 0
    assert end >= start
    assert label == "Minggu ini"


def test_all_range_has_no_bounds():
    import report_server as rs

    start, end, label = rs.resolve_range("all")
    assert start is None and end is None
    assert label == "Semua"


def test_month_starts_on_the_first():
    import report_server as rs

    start, _, _ = rs.resolve_range("month")
    assert start.day == 1


# ---- the launcher handoff ---------------------------------------------------

def test_url_file_is_written_and_removed(tmp_path):
    """windows/logix_reports.ps1 learns the tokenised URL from this file.

    It must not learn it by reading the server's stdout: doing so keeps the
    launcher attached to a process that runs for as long as someone is reading
    reports, and the first version of that launcher hung outright because a
    blocking pipe read cannot be given up on. The file is also removed on
    shutdown -- the token dies with the process, so a file still naming it is a
    stale invitation.
    """
    import threading
    import time

    import report_server as rs

    db = tmp_path / "logix.db"
    _seed_db(db)
    url_file = tmp_path / "state" / "report_url"

    httpd, url, _ = rs.create_server(db, port=0, url_file=str(url_file))
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        assert url_file.exists(), "the launcher would have nothing to poll for"
        written = url_file.read_text(encoding="utf-8").strip()
        assert written == url
        assert written.startswith("http://127.0.0.1:"), written
        assert "?t=" in written, "the URL must carry the launch token"
        # Loopback only. Binding 0.0.0.0 would put names and student IDs on
        # the lab network, which is the one thing this must never do.
        assert "0.0.0.0" not in written
        # It really is the live server, not just a plausible-looking string.
        assert _get(written)[0] == 200
    finally:
        httpd.shutdown()
        httpd.server_close()
        thread.join(timeout=10)


def test_idle_server_shuts_itself_down_and_takes_its_url_file_with_it(tmp_path, monkeypatch):
    """Left alone, this must stop listening on its own.

    Two things are being checked at once, and both matter for privacy rather
    than tidiness: a forgotten browser tab must not leave an endpoint serving
    names and student IDs for the rest of the day, and the URL file must not
    outlive the token it names. Runs the REAL watchdog path with its two
    timings shrunk, rather than asserting on the constants.
    """
    import threading
    import time

    import report_server as rs

    monkeypatch.setattr(rs, "IDLE_SHUTDOWN_SECONDS", 0.2)
    monkeypatch.setattr(rs, "IDLE_POLL_SECONDS", 0.1)

    db = tmp_path / "logix.db"
    _seed_db(db)
    url_file = tmp_path / "report_url"

    thread = threading.Thread(
        target=rs.serve,
        kwargs=dict(db=db, port=0, open_browser=False, url_file=str(url_file)),
        daemon=True,
    )
    thread.start()

    deadline = time.time() + 20
    while time.time() < deadline and not url_file.exists():
        time.sleep(0.02)
    assert url_file.exists()
    url = url_file.read_text(encoding="utf-8").strip()
    port = int(url.split("127.0.0.1:")[1].split("/")[0])

    thread.join(timeout=30)
    assert not thread.is_alive(), "the idle server never stopped serving"
    assert not url_file.exists(), "the URL file outlived the server it points at"

    # And the port is genuinely released, not merely un-advertised.
    import socket as _socket

    with _socket.socket() as probe:
        probe.settimeout(5)
        assert probe.connect_ex(("127.0.0.1", port)) != 0
