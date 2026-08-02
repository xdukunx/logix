"""Tests for the Riwayat (v3) surface: session spans, the inline summary
numbers, period filtering, and the CSV exports.

Riwayat replaced the Analytics page and has zero charts, so these endpoints are
the whole of what the screen shows -- the three headline numbers must always
agree with the table beneath them, and an export must agree with both.
"""
import importlib
import sys

from fastapi.testclient import TestClient


def _load_main(monkeypatch, tmp_path):
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
    # /api/log takes a batch, matching how the agent flushes its queue.
    payload = {"event": "START", "hostname": "WS-01", "session_type": "SSH", **row}
    res = client.post("/api/log", json=[payload], headers=headers)
    assert res.status_code in (200, 201), res.text


def _seed(client, headers):
    """Two closed sessions (60 and 30 minutes) plus one still running."""
    _log(client, headers, session_id="s1", event="START", timestamp="2026-03-02T09:00:00",
         nama="Dhana", nim="111", tujuan="Komputasi DFT")
    _log(client, headers, session_id="s1", event="END", timestamp="2026-03-02T10:00:00",
         nama="Dhana", nim="111")
    _log(client, headers, session_id="s2", event="START", timestamp="2026-03-02T11:00:00",
         hostname="WS-02", nama="Rizka", nim="222", tujuan="Praktikum")
    _log(client, headers, session_id="s2", event="END", timestamp="2026-03-02T11:30:00",
         hostname="WS-02", nama="Rizka", nim="222")
    # Different month, so the period filter has something to exclude.
    _log(client, headers, session_id="s3", event="START", timestamp="2026-01-15T08:00:00",
         nama="Agus", nim="333", tujuan="Training")


def test_spans_pair_start_with_close_and_compute_duration(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        _seed(client, headers)
        res = client.get("/api/sessions/spans", headers=headers)
    assert res.status_code == 200
    body = res.json()
    assert body["total"] == 3
    by_id = {s["session_id"]: s for s in body["sessions"]}
    assert by_id["s1"]["duration_seconds"] == 3600
    assert by_id["s2"]["duration_seconds"] == 1800
    # A session with no close event is still running, not zero-length.
    assert by_id["s3"]["duration_seconds"] is None
    assert by_id["s1"]["tujuan"] == "Komputasi DFT"


def test_summary_matches_a_manual_aggregation_of_the_table(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        _seed(client, headers)
        summary = client.get("/api/sessions/summary", headers=headers).json()
        spans = client.get("/api/sessions/spans?limit=1000", headers=headers).json()

    manual_hours = round(sum(s["duration_seconds"] or 0 for s in spans["sessions"]) / 3600, 1)
    manual_users = len({s["nim"] or s["nama"] or s["username"] for s in spans["sessions"]} - {""})
    assert summary["sessions"] == spans["total"] == 3
    assert summary["hours"] == manual_hours == 1.5
    assert summary["users"] == manual_users == 3


def test_period_filter_narrows_both_summary_and_table(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        _seed(client, headers)
        window = "start_date=2026-03-01&end_date=2026-03-31"
        summary = client.get(f"/api/sessions/summary?{window}", headers=headers).json()
        spans = client.get(f"/api/sessions/spans?{window}", headers=headers).json()
    assert summary["sessions"] == spans["total"] == 2  # January session excluded
    assert summary["hours"] == 1.5


def test_spans_paginate(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        _seed(client, headers)
        page = client.get("/api/sessions/spans?limit=2&offset=0", headers=headers).json()
        rest = client.get("/api/sessions/spans?limit=2&offset=2", headers=headers).json()
    assert page["total"] == rest["total"] == 3
    assert len(page["sessions"]) == 2
    assert len(rest["sessions"]) == 1
    # Newest first, and no row appears on both pages.
    ids = {s["session_id"] for s in page["sessions"]} & {s["session_id"] for s in rest["sessions"]}
    assert ids == set()


def test_csv_export_matches_the_table(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        _seed(client, headers)
        res = client.get("/api/reports?format=csv", headers=headers)
    assert res.status_code == 200
    assert res.headers["content-type"].startswith("text/csv")
    assert "attachment" in res.headers["content-disposition"]
    # utf-8-sig so Excel on Windows reads Indonesian names correctly.
    text = res.content.decode("utf-8-sig")
    lines = [ln for ln in text.splitlines() if ln.strip()]
    assert lines[0].startswith("Waktu,Perangkat,Pengguna,NIM")
    assert len(lines) == 4  # header + 3 sessions
    assert "Komputasi DFT" in text


def test_per_user_export_rolls_up_by_person(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        _seed(client, headers)
        # Dhana gets a second session so the roll-up has something to sum.
        _log(client, headers, session_id="s4", event="START", timestamp="2026-03-03T09:00:00",
             nama="Dhana", nim="111", tujuan="Komputasi DFT")
        _log(client, headers, session_id="s4", event="END", timestamp="2026-03-03T10:00:00",
             nama="Dhana", nim="111")
        res = client.get("/api/reports?format=per_user", headers=headers)
    text = res.content.decode("utf-8-sig")
    lines = [ln for ln in text.splitlines() if ln.strip()]
    assert lines[0] == "Nama,NIM,Jumlah sesi,Total jam"
    dhana = next(ln for ln in lines if ln.startswith("Dhana,"))
    assert dhana == "Dhana,111,2,2.0"


def test_bad_period_and_format_are_rejected(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        assert client.get("/api/sessions/spans?start_date=03-2026", headers=headers).status_code == 400
        assert client.get("/api/sessions?end_date=nope", headers=headers).status_code == 400
        assert client.get("/api/audit-log?start_date=nope", headers=headers).status_code == 400
        assert client.get("/api/reports?format=exe", headers=headers).status_code == 400


def test_heartbeat_carries_session_context_to_monitoring(monkeypatch, tmp_path):
    """The station card's second line needs a start time and an access type;
    an older agent that sends neither must still produce a usable row."""
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        client.post("/api/heartbeat", json={
            "hostname": "WS-07", "status": "ACTIVE", "username": "Dhana",
            "session_started_at": "2026-03-02T09:00:00",
            "access_type": "SSH", "purpose": "Komputasi DFT",
        })
        client.post("/api/heartbeat", json={"hostname": "WS-08", "status": "ACTIVE"})
        rows = {r["hostname"]: r for r in client.get("/api/active", headers=headers).json()}

    assert rows["WS-07"]["session_started_at"] == "2026-03-02T09:00:00"
    assert rows["WS-07"]["access_type"] == "SSH"
    assert rows["WS-07"]["purpose"] == "Komputasi DFT"
    assert rows["WS-07"]["status_since"] is not None
    # Legacy agent: fields absent rather than fabricated.
    assert rows["WS-08"]["session_started_at"] is None
    assert rows["WS-08"]["access_type"] is None


def test_status_since_holds_while_status_is_unchanged(monkeypatch, tmp_path):
    """"Dikunci admin 14:02" must be when the lock happened, not the last
    heartbeat -- otherwise the timestamp creeps forward every few seconds."""
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        client.post("/api/heartbeat", json={"hostname": "WS-04", "status": "LOCKED"})
        first = client.get("/api/active", headers=headers).json()[0]["status_since"]
        client.post("/api/heartbeat", json={"hostname": "WS-04", "status": "LOCKED"})
        second = client.get("/api/active", headers=headers).json()[0]["status_since"]
        client.post("/api/heartbeat", json={"hostname": "WS-04", "status": "ACTIVE"})
        third = client.get("/api/active", headers=headers).json()[0]["status_since"]

    assert first == second        # unchanged status keeps the original moment
    assert third != first         # a real transition resets it
