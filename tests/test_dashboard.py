"""The local dashboard, driven over real HTTP (Phase D).

Not a template test. The server is started, the endpoints are fetched the
way the browser fetches them, and the assertions ask whether the numbers on
the page could have come from anywhere other than this device's own
database.

The rule the whole dashboard is built on is that nothing is invented. An
absent GPU, an absent job id and an absent session each have to be reported
as absent, rather than as a zero, an empty card, or a plausible-looking
placeholder that nobody looking at the screen could tell from a real one.
"""
from __future__ import annotations

import importlib
import json
import sys
import threading
import urllib.error
import urllib.request

import pytest


def _mod(name):
    if name in sys.modules:
        return importlib.reload(sys.modules[name])
    return importlib.import_module(name)


def _isolate(monkeypatch, tmp_path):
    """Cut this test off from the developer machine it runs on.

    Three separate leaks, all of which produced confusing failures before
    being closed:

      * paths reads config.env from the system data home, so a real paired
        install supplies LOGIX_SERVER_URL even when the variable is unset.
        An EMPTY config file that exists wins the lookup.
      * paths caches those values at module level, so the file has to be in
        place before paths is (re)imported.
      * report_server repairs an active session from session.json only when
        the served database IS the default one. Pointing LOGIX_DB at the
        served tmp database makes that guard true, and the live session of
        whoever is using this machine gets injected into the fixture.
    """
    cfg = tmp_path / "config.env"
    cfg.write_text("", encoding="utf-8")
    monkeypatch.setenv("LOGIX_CONFIG", str(cfg))
    monkeypatch.setenv("LOGIX_SERVER_URL", "")
    monkeypatch.setenv("LOGIX_PRIVACY_MODE", "local_only")
    monkeypatch.setenv("LOGIX_DB", str(tmp_path / "not-the-served.db"))
    # Exports otherwise land in the SYSTEM reports directory -- a real
    # write outside tmp_path, onto whatever machine runs the suite. It
    # only looked harmless because that path happens to be writable on
    # Windows and on the Linux runner; on macOS it is root-owned and six
    # export tests failed with EACCES.
    monkeypatch.setenv("LOGBOOK_REPORT_DIR", str(tmp_path / "reports"))
    _mod("paths")


def _seed(lp, con, event, sid, ts, **kw):
    args = ["--event", event, "--session-id", sid, "--hostname", "LAB-03"]
    for k, v in kw.items():
        args += ["--" + k.replace("_", "-"), v]
    payload = lp.payload_from_args(lp.parse_args(args))
    payload["timestamp"] = ts
    lp.insert_event(con, payload)


def _start(db, device):
    rs = _mod("report_server")
    # create_server returns (httpd, url, State) -- the token lives on State.
    httpd, _url, state = rs.create_server(db, port=0, device=device)
    token = state.token
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd, f"http://127.0.0.1:{httpd.server_address[1]}", token


def _get(base, token, path):
    sep = "&" if "?" in path else "?"
    with urllib.request.urlopen(base + path + sep + "t=" + token, timeout=15) as r:
        return json.loads(r.read().decode("utf-8"))


@pytest.fixture
def dash(monkeypatch, tmp_path):
    db = tmp_path / "device.db"
    _isolate(monkeypatch, tmp_path)

    lp = _mod("log_physical")
    con = lp.connect(db)
    lp.migrate(con)
    # Dated RELATIVE to today, not to a fixed calendar day. /api/overview
    # asks for the "today" range, so a hardcoded date makes these tests pass
    # on the day they were written and fail every day after -- which is
    # exactly what happened when the date rolled over mid-session.
    from datetime import date
    d = date.today().isoformat()
    _seed(lp, con, "START", "s1", f"{d}T08:41:00+07:00",
          nama="Rani", nim="000000000", tujuan="DFTB Parameterization",
          job_type="Simulation", job_id="258026",
          keterangan="Slater-Koster parameter validation.")
    _seed(lp, con, "END", "s1", f"{d}T11:15:00+07:00")
    _seed(lp, con, "START", "s2", f"{d}T12:00:00+07:00",
          nama="Alya", nim="000000001", tujuan="Molecular Dynamics")
    con.commit()
    con.close()

    httpd, base, token = _start(db, "LAB-03")
    yield base, token, db
    httpd.shutdown()
    httpd.server_close()


# ---- authentication is not optional -------------------------------------

def test_endpoints_require_the_token(dash):
    """On a shared workstation, localhost is not a security boundary:
    another signed-in user can reach a loopback port."""
    base, _token, _db = dash
    with pytest.raises(urllib.error.HTTPError) as e:
        urllib.request.urlopen(base + "/api/overview", timeout=10)
    assert e.value.code == 403


# ---- overview -----------------------------------------------------------

def test_overview_reports_the_real_workstation(dash):
    base, token, _ = dash
    d = _get(base, token, "/api/overview")
    assert d["workstation"]["display"] == "LAB-03"
    assert d["workstation"]["hostname"]


def test_active_session_is_the_open_one(dash):
    """s1 was closed, s2 was not. The card must show whoever is actually
    here, not simply the most recent row."""
    base, token, _ = dash
    a = _get(base, token, "/api/overview")["active"]
    assert a is not None
    assert a["nama"] == "Alya"
    assert a["tujuan"] == "Molecular Dynamics"


def test_job_metadata_reaches_the_dashboard(dash):
    base, token, _ = dash
    rows = _get(base, token, "/api/sessions?range=all")["sessions"]
    s1 = [r for r in rows if r["nim"] == "000000000"][0]
    assert s1["job_type"] == "Simulation"
    assert s1["job_id"] == "258026"


def test_absent_job_metadata_stays_absent(dash):
    """The session with no job must arrive empty, so the page renders an em
    dash. Nothing may substitute a value here."""
    base, token, _ = dash
    a = _get(base, token, "/api/overview")["active"]
    assert a["job_type"] == "" and a["job_id"] == ""


def test_description_is_carried_for_the_details_sheet(dash):
    base, token, _ = dash
    rows = _get(base, token, "/api/sessions?range=all")["sessions"]
    s1 = [r for r in rows if r["nim"] == "000000000"][0]
    assert "Slater-Koster" in s1["keterangan"]


def test_recent_stays_short(dash):
    base, token, _ = dash
    assert len(_get(base, token, "/api/overview")["recent"]) <= 5


def test_idle_workstation_reports_no_active_session(monkeypatch, tmp_path):
    """An idle machine says so, rather than rendering a card that looks like
    a session with every field missing."""
    db = tmp_path / "empty.db"
    _isolate(monkeypatch, tmp_path)
    lp = _mod("log_physical")
    con = lp.connect(db)
    lp.migrate(con)
    con.close()

    httpd, base, token = _start(db, "LAB-09")
    try:
        d = _get(base, token, "/api/overview")
        assert d["active"] is None
        assert d["recent"] == []
    finally:
        httpd.shutdown()
        httpd.server_close()


# ---- telemetry ----------------------------------------------------------

def test_telemetry_endpoint_has_every_key(dash):
    base, token, _ = dash
    d = _get(base, token, "/api/telemetry")
    for k in ("cpu", "memory", "storage", "gpu"):
        assert k in d


def test_telemetry_is_separate_from_history(dash):
    """The cards refresh every few seconds. If that endpoint also ran the
    session queries, the refresh rate would become a database load."""
    base, token, _ = dash
    d = _get(base, token, "/api/telemetry")
    assert "sessions" not in d and "recent" not in d


def test_storage_needs_no_optional_dependency(dash):
    """shutil.disk_usage is stdlib, so the metric answering "can this machine
    still record" is never Unavailable for want of an install."""
    base, token, _ = dash
    st = _get(base, token, "/api/telemetry")["storage"]
    assert st is not None and st["total_bytes"] > 0


# ---- sync state ---------------------------------------------------------

def test_local_only_device_is_not_pending(dash):
    """The point of the seven-state model. A device with no server has
    nothing queued, and the UI must never be handed a pending count."""
    base, token, _ = dash
    s = _get(base, token, "/api/overview")["sync"]
    assert s["connection_state"] == "disabled"
    assert s["last_error"] is None


def test_policy_blocked_is_distinguishable_from_local_only(monkeypatch, tmp_path):
    """A server IS configured here, and policy forbids sending. That is a
    different sentence on screen from having no server at all."""
    db = tmp_path / "blocked.db"
    _isolate(monkeypatch, tmp_path)
    monkeypatch.setenv("LOGIX_SERVER_URL", "http://127.0.0.1:1")
    lp = _mod("log_physical")
    con = lp.connect(db)
    lp.migrate(con)
    con.close()

    httpd, base, token = _start(db, "LAB-04")
    try:
        s = _get(base, token, "/api/overview")["sync"]
        assert s["connection_state"] == "blocked"
    finally:
        httpd.shutdown()
        httpd.server_close()


# ---- export -------------------------------------------------------------

def test_export_needs_no_network(dash):
    """No LOGIX_SERVER_URL is set in this fixture, so an export that
    succeeds here provably needed nothing off the machine."""
    base, token, _ = dash
    d = _get(base, token, "/api/export?range=all")
    assert d["ok"] is True, d
    assert d["format"] in ("xlsx", "csv")
    assert d["name"]


def test_exported_file_downloads(dash):
    base, token, _ = dash
    d = _get(base, token, "/api/export?range=all")
    url = base + "/download?t=" + token + "&f=" + d["name"]
    with urllib.request.urlopen(url, timeout=20) as r:
        body = r.read()
    assert len(body) > 0
    if d["format"] == "xlsx":
        assert body[:2] == b"PK", "a real xlsx is a zip container"


def test_download_refuses_a_path_it_did_not_create(dash):
    """The download map is filled by this process. A handler that joined
    request input onto a directory would be a traversal hole."""
    base, token, _ = dash
    with pytest.raises(urllib.error.HTTPError) as e:
        urllib.request.urlopen(
            base + "/download?t=" + token + "&f=../../secrets.txt", timeout=10)
    assert e.value.code == 404
