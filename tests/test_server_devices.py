"""Tests for the persisted devices registry (Logix Control, Milestone 2).

devices is the durable source of truth for "what devices exist and were ever
seen" -- distinct from HEARTBEATS, the in-memory "online in the last 5
minutes" cache that /api/active already served before this milestone. See
docs/LOGIX_CONTROL.md §5.
"""
import importlib
import sys
from datetime import datetime, timedelta

import pytest
from fastapi.testclient import TestClient


def _load_main(monkeypatch, tmp_path):
    monkeypatch.setenv("LOGIX_DEV_MODE", "1")
    monkeypatch.setenv("LOGIX_INGEST_API_KEY", "")
    monkeypatch.setenv("LOGIX_ALLOWED_ORIGINS", "")
    monkeypatch.setenv("GOOGLE_CLIENT_ID", "")
    monkeypatch.setenv("GOOGLE_CLIENT_SECRET", "")
    monkeypatch.setenv("ADMIN_EMAILS", "admin@example.org")

    if "main" in sys.modules:
        module = importlib.reload(sys.modules["main"])
    else:
        module = importlib.import_module("main")

    module.DB_PATH = tmp_path / "test.db"
    module.CONFIG_PATH = tmp_path / "server_config.json"
    module.REPORTS_DIR = tmp_path / "reports"
    module.ACTIVE_TOKENS.clear()
    module.HEARTBEATS.clear()
    module.PENDING_COMMANDS.clear()
    return module


def _login(client):
    res = client.post("/api/auth/dev-login")
    token = res.json()["token"]
    return {"Authorization": f"Bearer {token}"}


def test_heartbeat_creates_device_row(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        client.post("/api/heartbeat", json={"hostname": "LAB-PC-01", "status": "ACTIVE", "device_name": "Lab PC 1"})
        res = client.get("/api/devices", headers=headers)
    assert res.status_code == 200
    devices = res.json()
    assert len(devices) == 1
    d = devices[0]
    assert d["hostname"] == "LAB-PC-01"
    assert d["display_name"] == "Lab PC 1"
    assert d["category"] == "custom"
    assert d["policy_profile"] == "lab_standard"
    assert d["device_id"]  # a uuid was assigned
    assert d["currently_online"] is True


def test_repeated_heartbeats_update_not_duplicate(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        client.post("/api/heartbeat", json={"hostname": "LAB-PC-02", "status": "ACTIVE", "device_name": "Old Name"})
        first = client.get("/api/devices", headers=headers).json()
        first_id = first[0]["device_id"]

        client.post("/api/heartbeat", json={"hostname": "LAB-PC-02", "status": "ACTIVE", "device_name": "New Name"})
        second = client.get("/api/devices", headers=headers).json()

    assert len(second) == 1
    assert second[0]["device_id"] == first_id  # same row, not a duplicate
    assert second[0]["display_name"] == "New Name"


def test_api_devices_requires_auth(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        res = client.get("/api/devices")
    assert res.status_code == 401


def test_devices_persists_beyond_5_minute_live_window(monkeypatch, tmp_path):
    """The key behavioral difference from /api/active: a device that hasn't
    heartbeated recently still appears in the registry (persisted), just
    marked not currently_online, whereas /api/active would drop it entirely.
    """
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        client.post("/api/heartbeat", json={"hostname": "LAB-PC-03", "status": "ACTIVE"})

        # Simulate a stale heartbeat by rewriting HEARTBEATS' last_seen directly.
        module.HEARTBEATS["LAB-PC-03"]["last_seen"] = datetime.now() - timedelta(minutes=10)

        active = client.get("/api/active", headers=headers).json()
        devices = client.get("/api/devices", headers=headers).json()

    assert active == []  # dropped from the live cache
    assert len(devices) == 1  # still in the persisted registry
    assert devices[0]["currently_online"] is False


def test_sync_status_buckets_by_category_heartbeat_interval(monkeypatch, tmp_path):
    """Staleness is category-aware (roadmap item G), not a flat 5-minute cutoff.
    lab_workstation's heartbeat_interval_seconds is 30, so online <= 60s,
    stale <= 180s, else offline -- a 90s-old heartbeat should read "stale",
    not "online" (a flat 5-minute check would still call this online)."""
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        client.post("/api/heartbeat", json={"hostname": "LAB-PC-05", "status": "ACTIVE"})

        conn = module.get_db()
        conn.execute("UPDATE devices SET category = 'lab_workstation' WHERE hostname = ?", ("LAB-PC-05",))
        conn.commit()
        conn.close()
        module.HEARTBEATS["LAB-PC-05"]["last_seen"] = datetime.now() - timedelta(seconds=90)

        devices = client.get("/api/devices", headers=headers).json()

    assert devices[0]["sync_status"] == "stale"
    assert devices[0]["currently_online"] is False


def test_heartbeat_db_failure_does_not_break_response(monkeypatch, tmp_path):
    """upsert_device failures must never block the heartbeat response the
    agent is waiting on."""
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        # Point DB_PATH at a directory (guaranteed to fail to open as a DB file).
        module.DB_PATH = tmp_path  # a directory, not a file
        res = client.post("/api/heartbeat", json={"hostname": "LAB-PC-04", "status": "ACTIVE"})
    assert res.status_code == 200
    assert res.json()["status"] == "ok"
