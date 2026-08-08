"""Data-integrity guards: abandoned sessions, clock skew, retention, identity.

These cover the failure modes that do NOT announce themselves. A crashed
workstation, a wrong clock and an over-long retention window all leave the
dashboard green while the numbers underneath quietly stop meaning what an
admin reads them to mean.
"""
import importlib
import sqlite3
import sys
from datetime import datetime, timedelta

import pytest
from fastapi.testclient import TestClient


def _load_main(monkeypatch, tmp_path):
    # DB_PATH is rebound on the module rather than set via env: that is the
    # convention the rest of the suite uses, and pointing at the real
    # central_logix.db instead gets "database is locked" whenever a dev server
    # happens to be running.
    monkeypatch.setenv("LOGIX_DEV_MODE", "1")
    monkeypatch.setenv("LOGIX_INGEST_API_KEY", "")
    monkeypatch.setenv("LOGIX_ALLOWED_ORIGINS", "")
    monkeypatch.setenv("ADMIN_EMAILS", "admin@example.org")

    if "main" in sys.modules:
        module = importlib.reload(sys.modules["main"])
    else:
        module = importlib.import_module("main")

    module.DB_PATH = tmp_path / "test.db"
    module.CONFIG_PATH = tmp_path / "server_config.json"
    module.REPORTS_DIR = tmp_path / "reports"
    module.REPORTS_DIR.mkdir(parents=True, exist_ok=True)
    module.ACTIVE_TOKENS.clear()
    module.HEARTBEATS.clear()
    module.PENDING_COMMANDS.clear()
    return module


def _login(client):
    token = client.post("/api/auth/dev-login").json()["token"]
    return {"Authorization": f"Bearer {token}"}


def _log(client, headers, **row):
    payload = {"event": "START", "hostname": "WS-01", "session_type": "SSH", **row}
    res = client.post("/api/log", json=[payload], headers=headers)
    assert res.status_code in (200, 201), res.text


def _iso(dt):
    return dt.isoformat()


# --- abandoned sessions -------------------------------------------------------

def test_a_dead_workstation_gets_its_session_closed_at_its_last_sign_of_life(monkeypatch, tmp_path):
    """The BSOD case. Without this the session stays open forever and, because
    the summary sums `duration or 0`, contributes ZERO hours -- the report
    looks fine and silently under-counts."""
    module = _load_main(monkeypatch, tmp_path)
    now = datetime.now()
    started = now - timedelta(hours=3)
    died = now - timedelta(hours=2)

    with TestClient(module.app) as client:
        headers = _login(client)
        _log(client, headers, session_id="dead", event="START", timestamp=_iso(started),
             nama="Dhana", nim="111", tujuan="Komputasi DFT")

        # The device existed and reported, then went quiet an hour ago.
        conn = module.get_db()
        module.upsert_device(conn, "WS-01", "WS-01")
        conn.execute("UPDATE devices SET last_seen = ? WHERE hostname = ?", (_iso(died), "WS-01"))
        conn.commit()
        conn.close()
        module.HEARTBEATS.clear()

        body = client.get("/api/sessions/summary", headers=headers).json()

    # Closed at the last evidence of life, not at "now" -- that would invent an
    # extra two hours nobody worked.
    assert body["auto_closed_sessions"] == 1
    assert body["open_sessions"] == 0
    assert body["hours"] == pytest.approx(1.0, abs=0.05)


def test_reconciliation_is_idempotent(monkeypatch, tmp_path):
    """It runs on every summary read; a second pass must not stack a second
    AUTO_CLOSE onto the same session."""
    module = _load_main(monkeypatch, tmp_path)
    now = datetime.now()
    with TestClient(module.app) as client:
        headers = _login(client)
        _log(client, headers, session_id="dead", event="START",
             timestamp=_iso(now - timedelta(hours=3)), nama="Dhana", nim="111")
        conn = module.get_db()
        module.upsert_device(conn, "WS-01", "WS-01")
        conn.execute("UPDATE devices SET last_seen = ? WHERE hostname = ?",
                     (_iso(now - timedelta(hours=2)), "WS-01"))
        conn.commit()
        conn.close()
        module.HEARTBEATS.clear()

        first = client.get("/api/sessions/summary", headers=headers).json()
        second = client.get("/api/sessions/summary", headers=headers).json()

    assert first == second
    conn = module.get_db()
    (n,) = conn.execute(
        "SELECT COUNT(*) FROM physical_log WHERE session_id = 'dead' AND event = 'AUTO_CLOSE'"
    ).fetchone()
    conn.close()
    assert n == 1


def test_a_live_workstation_mid_session_is_left_alone(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    now = datetime.now()
    with TestClient(module.app) as client:
        headers = _login(client)
        _log(client, headers, session_id="live", event="START",
             timestamp=_iso(now - timedelta(hours=2)), nama="Dhana", nim="111")
        conn = module.get_db()
        module.upsert_device(conn, "WS-01", "WS-01")  # last_seen = now
        conn.close()

        body = client.get("/api/sessions/summary", headers=headers).json()

    assert body["auto_closed_sessions"] == 0
    assert body["open_sessions"] == 1


def test_an_unknown_device_is_never_given_a_fabricated_end_time(monkeypatch, tmp_path):
    """Absence of heartbeat data is not evidence of death. A device that never
    enrolled, or was deleted, tells us nothing about whether its session ended
    -- writing an AUTO_CLOSE on that basis would be inventing history."""
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        _log(client, headers, session_id="orphan", event="START",
             timestamp="2026-01-15T08:00:00", nama="Agus", nim="333")
        body = client.get("/api/sessions/summary", headers=headers).json()
        spans = client.get("/api/sessions/spans", headers=headers).json()

    assert body["auto_closed_sessions"] == 0
    # Counted and visible, rather than a silent zero.
    assert body["open_sessions"] == 1
    assert spans["sessions"][0]["duration_seconds"] is None


def test_a_clock_that_jumped_mid_session_cannot_book_a_fortnight(monkeypatch, tmp_path):
    """A CONSTANT offset cancels out of end - start. A clock that jumps does
    not, and an uncapped duration would poison the utilisation total."""
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        _log(client, headers, session_id="jump", event="START", timestamp="2026-03-02T09:00:00")
        _log(client, headers, session_id="jump", event="END", timestamp="2026-03-16T09:00:00")
        spans = client.get("/api/sessions/spans", headers=headers).json()

    span = spans["sessions"][0]
    assert span["duration_capped"] is True
    assert span["duration_seconds"] == module.MAX_SESSION_HOURS * 3600


# --- clock skew ---------------------------------------------------------------

def test_skew_is_measured_from_the_heartbeat_and_raises_an_alert(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    behind = datetime.now() - timedelta(minutes=10)
    with TestClient(module.app) as client:
        headers = _login(client)
        res = client.post("/api/heartbeat", json={
            "hostname": "WS-SKEW", "status": "ACTIVE", "device_name": "WS-SKEW",
            "client_time": _iso(behind), "agent_version": "9.9.9", "agent_os": "windows",
        })
        assert res.status_code in (200, 201), res.text

        device = next(d for d in client.get("/api/devices", headers=headers).json()
                      if d["hostname"] == "WS-SKEW")
        alerts = client.get("/api/alerts", headers=headers).json()

    assert device["clock_skew_seconds"] == pytest.approx(600, abs=30)
    assert device["agent_version"] == "9.9.9"
    categories = {a["category"] for a in alerts["alerts"]}
    assert "clock_skew" in categories


def test_not_measuring_skew_is_not_the_same_as_measuring_zero(monkeypatch, tmp_path):
    """An older agent omits client_time. That must leave the column NULL, not
    write a 0.0 that would silently resolve a real skew alert."""
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        client.post("/api/heartbeat", json={"hostname": "WS-OLD", "status": "ACTIVE"})
        headers = _login(client)
        device = next(d for d in client.get("/api/devices", headers=headers).json()
                      if d["hostname"] == "WS-OLD")
    assert device["clock_skew_seconds"] is None
    assert module.measure_clock_skew(None) is None
    assert module.measure_clock_skew("not a timestamp") is None


def test_an_older_agent_does_not_blank_a_known_agent_version(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        client.post("/api/heartbeat", json={"hostname": "WS-1", "status": "ACTIVE",
                                            "agent_version": "1.2.3"})
        client.post("/api/heartbeat", json={"hostname": "WS-1", "status": "ACTIVE"})
        device = next(d for d in client.get("/api/devices", headers=headers).json()
                      if d["hostname"] == "WS-1")
    assert device["agent_version"] == "1.2.3"


# --- retention ----------------------------------------------------------------

def test_retention_redacts_personal_fields_but_keeps_the_session_shape(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    old = datetime.now() - timedelta(days=400)
    with TestClient(module.app) as client:
        headers = _login(client)
        _log(client, headers, session_id="old", event="START", timestamp=_iso(old),
             nama="Dhana", nim="000000000", username="dhana", keterangan="rahasia",
             tujuan="Komputasi DFT")
        _log(client, headers, session_id="old", event="END",
             timestamp=_iso(old + timedelta(hours=2)), nama="Dhana", nim="000000000")

        conn = module.get_db()
        redacted = module.purge_expired_personal_data(conn, retention_days=365)
        conn.close()
        spans = client.get("/api/sessions/spans", headers=headers).json()

    assert redacted == 2
    span = spans["sessions"][0]
    # The personal data is gone...
    assert span["nama"] == module.REDACTED_MARKER
    assert span["nim"] == module.REDACTED_MARKER
    # ...and everything utilisation reporting actually needs survives.
    assert span["duration_seconds"] == 7200
    assert span["tujuan"] == "Komputasi DFT"
    assert span["hostname"] == "WS-01"


def test_retention_leaves_recent_sessions_alone_and_is_idempotent(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        _log(client, headers, session_id="recent", event="START",
             timestamp=_iso(datetime.now() - timedelta(days=3)), nama="Dhana", nim="111")
        def purge():
            conn = module.get_db()
            try:
                return module.purge_expired_personal_data(conn, retention_days=365)
            finally:
                conn.close()

        assert purge() == 0
        _log(client, headers, session_id="old", event="START",
             timestamp=_iso(datetime.now() - timedelta(days=400)), nama="Agus", nim="333")
        assert purge() == 1
        # Second pass over already-redacted rows must be a no-op.
        assert purge() == 0


def test_retention_zero_means_disabled_not_purge_everything(monkeypatch, tmp_path):
    """The dangerous misreading. 0 must never be treated as a zero-day window."""
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        _log(client, headers, session_id="old", event="START",
             timestamp=_iso(datetime.now() - timedelta(days=4000)), nama="Dhana", nim="111")
        conn = module.get_db()
        assert module.purge_expired_personal_data(conn, retention_days=0) == 0
        row = conn.execute("SELECT nama FROM physical_log WHERE session_id = 'old'").fetchone()
        conn.close()
    assert row["nama"] == "Dhana"


# --- identity seam ------------------------------------------------------------

def test_identity_source_defaults_to_self_declared_and_round_trips(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        _log(client, headers, session_id="typed", event="START",
             timestamp=_iso(datetime.now()), nama="Dhana", nim="111")
        _log(client, headers, session_id="failopen", event="START",
             timestamp=_iso(datetime.now()), nama="", nim="",
             identity_source="unverified")
        spans = {s["session_id"]: s
                 for s in client.get("/api/sessions/spans", headers=headers).json()["sessions"]}

    assert spans["typed"]["identity_source"] == "self_declared"
    assert spans["failopen"]["identity_source"] == "unverified"


def test_the_insert_column_order_matches_base_columns(monkeypatch, tmp_path):
    """/api/log builds its INSERT from BASE_COLUMNS but supplies values as a
    positional list. Adding a column in one place and not the other would write
    data into the wrong field silently -- SQLite only catches a COUNT mismatch,
    not a reordering. Assert the values actually landed where they belong."""
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        _log(client, headers, session_id="sid", event="START", timestamp="2026-05-01T08:00:00",
             username="winuser", nama="Nama", nim="NIM", tujuan="Tujuan",
             keterangan="Ket", session_type="SSH", source="agent", windows_user="WU",
             hostname="HOST", client_ip="10.0.0.1", event_uid="uid-1",
             identity_source="self_declared", person_role="mahasiswa")
    conn = module.get_db()
    conn.row_factory = sqlite3.Row
    row = conn.execute("SELECT * FROM physical_log WHERE event_uid = 'uid-1'").fetchone()
    conn.close()
    assert row["nama"] == "Nama" and row["nim"] == "NIM"
    assert row["hostname"] == "HOST" and row["client_ip"] == "10.0.0.1"
    assert row["person_role"] == "mahasiswa"
    assert row["session_type"] == "SSH" and row["source"] == "agent"
    assert row["server_received_at"]
