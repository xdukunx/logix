"""Logs and Server, driven over real HTTP.

The Logs page stopped being a rendering problem and became a query one:
at 10,000 sessions the old path cost 290ms and shipped 2.01MB, because
build_sessions pairs every START with every END. Paging at the session
level takes that to ~20ms.

Search had to follow it into SQL as a consequence -- once the browser holds
one page instead of the whole history, a client-side filter searches only
the page, which looks like it works and quietly is not a search. Several
tests below exist specifically to catch that regression, by asserting that
a match OUTSIDE the first page is still found.
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
    """Cut the test off from this developer machine: a real paired install
    supplies a server URL and a device key through config.env and
    device.json, and both change what the Server page reports."""
    cfg = tmp_path / "config.env"
    cfg.write_text("", encoding="utf-8")
    monkeypatch.setenv("LOGIX_CONFIG", str(cfg))
    monkeypatch.setenv("LOGIX_SERVER_URL", "")
    monkeypatch.setenv("LOGIX_PRIVACY_MODE", "local_only")
    monkeypatch.setenv("LOGIX_DB", str(tmp_path / "not-the-served.db"))
    monkeypatch.setenv("LOGIX_DEVICE_IDENTITY_FILE", str(tmp_path / "no-device.json"))
    # Exports otherwise land in the SYSTEM reports directory -- a real
    # write outside tmp_path, onto whatever machine runs the suite. It
    # only looked harmless because that path happens to be writable on
    # Windows and on the Linux runner; on macOS it is root-owned and six
    # export tests failed with EACCES.
    monkeypatch.setenv("LOGBOOK_REPORT_DIR", str(tmp_path / "reports"))
    _mod("paths")


def _start(db, device="LAB-03"):
    rs = _mod("report_server")
    httpd, _url, state = rs.create_server(db, port=0, device=device)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd, f"http://127.0.0.1:{httpd.server_address[1]}", state.token


def _get(base, token, path):
    sep = "&" if "?" in path else "?"
    with urllib.request.urlopen(base + path + sep + "t=" + token, timeout=30) as r:
        return json.loads(r.read().decode("utf-8"))


def _seed(lp, con, sid, ts_start, ts_end=None, **kw):
    def ev(event, ts):
        args = ["--event", event, "--session-id", sid,
                "--hostname", kw.pop("hostname", "LAB-03") if event == "START" else "LAB-03"]
        for k, v in kw.items():
            args += ["--" + k.replace("_", "-"), v]
        payload = lp.payload_from_args(lp.parse_args(args))
        payload["timestamp"] = ts
        lp.insert_event(con, payload)
    ev("START", ts_start)
    if ts_end:
        ev("END", ts_end)


@pytest.fixture
def logs(monkeypatch, tmp_path):
    """120 sessions, so paging is real rather than theoretical: the default
    page is 50, which means a correct search has to reach past two pages to
    find the deliberately-unique row seeded at the far end."""
    db = tmp_path / "device.db"
    _isolate(monkeypatch, tmp_path)
    lp = _mod("log_physical")
    con = lp.connect(db)
    lp.migrate(con)

    for i in range(120):
        day = 1 + (i % 28)
        _seed(lp, con, f"s{i:03d}",
              f"2026-06-{day:02d}T08:00:00", f"2026-06-{day:02d}T10:00:00",
              nama=f"User{i % 6}", nim=f"{i % 6:09d}",
              tujuan=["DFTB Parameterization", "Molecular Dynamics", "Literature Review"][i % 3],
              job_type=["Simulation", "Analysis"][i % 2], job_id=str(500 + i))
    # The needle: unique, and OLDEST, so it can only be found by a query
    # that reaches the whole history rather than the loaded page.
    _seed(lp, con, "needle", "2020-01-01T08:00:00", "2020-01-01T09:00:00",
          nama="Zulaikha", nim="999999999", tujuan="Cryogenic Annealing",
          job_type="Maintenance", job_id="777",
          keterangan="A description that exists only on this one session.")
    # An open session: no END row at all.
    _seed(lp, con, "live", "2026-07-01T08:00:00",
          nama="Rani", nim="000000000", tujuan="Ongoing Work")
    con.commit()
    con.close()

    httpd, base, token = _start(db)
    yield base, token, db
    httpd.shutdown()
    httpd.server_close()


# ---- paging -------------------------------------------------------------

def test_a_page_is_returned_not_the_whole_history(logs):
    base, token, _ = logs
    d = _get(base, token, "/api/logs?range=all")
    assert d["returned"] == 50
    assert d["total"] == 122, "total counts everything that matched, not the page"


def test_offset_advances_without_repeating(logs):
    base, token, _ = logs
    p1 = _get(base, token, "/api/logs?range=all&limit=20&offset=0")["sessions"]
    p2 = _get(base, token, "/api/logs?range=all&limit=20&offset=20")["sessions"]
    ids1 = {s["session_id"] for s in p1}
    ids2 = {s["session_id"] for s in p2}
    assert len(ids1) == 20 and len(ids2) == 20
    assert not (ids1 & ids2), "pages must not overlap"


def test_pages_are_newest_first(logs):
    base, token, _ = logs
    rows = _get(base, token, "/api/logs?range=all&limit=10")["sessions"]
    starts = [r["start"] for r in rows]
    assert starts == sorted(starts, reverse=True)


# ---- search reaches the whole history, not the loaded page --------------

def test_search_finds_a_match_beyond_the_first_page(logs):
    """The regression this whole architecture risks. The needle is the
    OLDEST session, so it is nowhere near page one -- a client-side filter
    over the loaded rows would return nothing and look like it worked."""
    base, token, _ = logs
    d = _get(base, token, "/api/logs?range=all&q=Cryogenic")
    assert d["total"] == 1
    assert d["sessions"][0]["nama"] == "Zulaikha"


def test_search_covers_every_declared_field(logs):
    base, token, _ = logs
    for term in ("Zulaikha", "999999999", "Cryogenic", "Maintenance", "777",
                 "only on this one session"):
        d = _get(base, token, "/api/logs?range=all&q=" + urllib.request.quote(term))
        assert d["total"] >= 1, f"search failed for {term!r}"


def test_search_is_case_insensitive(logs):
    base, token, _ = logs
    assert _get(base, token, "/api/logs?range=all&q=cryogenic")["total"] == 1


# ---- filters ------------------------------------------------------------

def test_user_filter_narrows_the_total(logs):
    base, token, _ = logs
    d = _get(base, token, "/api/logs?range=all&user=User1")
    assert 0 < d["total"] < 122
    assert all(s["nama"] == "User1" for s in d["sessions"])


def test_job_type_filter_narrows_the_total(logs):
    base, token, _ = logs
    d = _get(base, token, "/api/logs?range=all&job_type=Maintenance")
    assert d["total"] == 1


def test_filter_options_come_from_the_database(logs):
    """A dropdown offering job types nobody has recorded is noise."""
    base, token, _ = logs
    d = _get(base, token, "/api/logs/filters")
    assert "Zulaikha" in d["users"]
    assert set(d["job_types"]) == {"Simulation", "Analysis", "Maintenance"}


# ---- ranges -------------------------------------------------------------

def test_seven_and_thirty_day_ranges_are_real_ranges(logs):
    """range=7 and range=30 were not in RANGES, so both silently fell back
    to "today" -- the two buttons rendered today's sessions under a 7-day
    and a 30-day label."""
    base, token, _ = logs
    rs = _mod("report_server")
    assert "7" in rs.RANGES and "30" in rs.RANGES
    assert rs.resolve_range("7")[0] != rs.resolve_range("today")[0]
    assert rs.resolve_range("30")[0] != rs.resolve_range("7")[0]


# ---- the active session -------------------------------------------------

def test_active_session_has_no_fabricated_end(logs):
    base, token, _ = logs
    d = _get(base, token, "/api/logs?range=all&q=Ongoing")
    s = d["sessions"][0]
    assert s["active"] is True
    assert s["end"] == "", "an unfinished session must not be given an end time"
    assert s["sync"] == "active"


def test_finished_sessions_report_a_real_sync_state(logs):
    """Not hardcoded: derived from the synced column on every row of the
    session, so a half-synced session does not claim to be central."""
    base, token, _ = logs
    d = _get(base, token, "/api/logs?range=all&q=Cryogenic")
    assert d["sessions"][0]["sync"] == "pending"


# ---- export follows the view -------------------------------------------

def test_export_respects_the_active_filter(logs):
    """Exporting the whole period while the screen shows a search result is
    the kind of quiet mismatch that makes a report untrustworthy."""
    openpyxl = pytest.importorskip("openpyxl")
    base, token, _ = logs

    full = _get(base, token, "/api/export?range=all")
    assert full["ok"], full
    one = _get(base, token, "/api/export?range=all&q=Cryogenic")
    assert one["ok"], one

    rep = _mod("logbook_report")
    from pathlib import Path
    def rows_in(name):
        wb = openpyxl.load_workbook(Path(rep.DEFAULT_OUTDIR) / name)
        return wb["Report Logbook"].max_row - 4

    assert rows_in(one["name"]) == 1
    assert rows_in(full["name"]) > rows_in(one["name"])


def test_export_needs_no_network(logs):
    """LOGIX_SERVER_URL is empty in this fixture, so an export that
    succeeded provably needed nothing off the machine."""
    base, token, _ = logs
    assert _get(base, token, "/api/export?range=all")["ok"] is True


# ---- server page --------------------------------------------------------

def test_local_only_is_a_success_state_with_no_pending_count(logs):
    """On a device that does not sync, rows are finished, not waiting. A
    zero there would imply a queue that happens to be empty."""
    base, token, _ = logs
    d = _get(base, token, "/api/server")
    assert d["state"] == "LOCAL_ONLY"
    assert d["pending"] is None
    assert d["can_sync"] is False, "nothing to fix means no button"


def test_policy_blocked_is_distinct_from_local_only(monkeypatch, tmp_path):
    db = tmp_path / "blocked.db"
    _isolate(monkeypatch, tmp_path)
    monkeypatch.setenv("LOGIX_SERVER_URL", "http://127.0.0.1:1")
    lp = _mod("log_physical")
    con = lp.connect(db)
    lp.migrate(con)
    con.close()
    httpd, base, token = _start(db)
    try:
        d = _get(base, token, "/api/server")
        assert d["state"] == "SYNC_BLOCKED"
        assert d["pending"] is None
        assert "policy" in d["detail"].lower()
    finally:
        httpd.shutdown()
        httpd.server_close()


def test_error_text_comes_from_the_failure_class_not_a_string_parse(monkeypatch, tmp_path):
    """The structured classification exists so the UI never has to guess
    from English prose. Each class must map to its own sentence."""
    _isolate(monkeypatch, tmp_path)
    rs = _mod("report_server")
    assert set(rs._ERROR_TEXT) == {"network", "auth", "rejected", "server", "unknown"}
    assert len(set(rs._ERROR_TEXT.values())) == 5, "each class says something different"
    assert "reach" in rs._ERROR_TEXT["network"].lower()
    assert "credential" in rs._ERROR_TEXT["auth"].lower()


def test_server_page_does_not_block_on_an_unreachable_server(monkeypatch, tmp_path):
    """Port 1 never listens. The page must still answer -- reading state is
    a local operation, and only the explicit actions touch the network."""
    import time
    db = tmp_path / "unreachable.db"
    _isolate(monkeypatch, tmp_path)
    monkeypatch.setenv("LOGIX_SERVER_URL", "http://127.0.0.1:1")
    monkeypatch.setenv("LOGIX_PRIVACY_MODE", "admin_full_sync")
    lp = _mod("log_physical")
    con = lp.connect(db)
    lp.migrate(con)
    con.close()
    httpd, base, token = _start(db)
    try:
        t0 = time.perf_counter()
        d = _get(base, token, "/api/server")
        elapsed = time.perf_counter() - t0
        assert elapsed < 5, f"reading server state took {elapsed:.1f}s -- it made a network call"
        assert d["state"] in ("SYNC_PENDING", "SYNC_ERROR", "SERVER_UNAVAILABLE", "SYNCED")
    finally:
        httpd.shutdown()
        httpd.server_close()


# ---- Logs works with no server at all ----------------------------------

def test_logs_works_with_no_server_configured(logs):
    """Every Logs operation is local. None of these may need a network."""
    base, token, _ = logs
    assert _get(base, token, "/api/logs?range=all")["total"] == 122
    assert _get(base, token, "/api/logs?range=all&q=Cryogenic")["total"] == 1
    assert _get(base, token, "/api/logs/filters")["users"]
    assert _get(base, token, "/api/export?range=all")["ok"]
