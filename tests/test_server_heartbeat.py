"""Tests for the device_name field on /api/heartbeat and /api/active.

Lets a workstation report a human-assigned display name (set at install via
windows/logbook_setup.ps1, LOGIX_DEVICE_NAME) alongside its hostname, so the
admin dashboard can show "Lab PC 3" instead of a raw machine name. Falls back
to hostname when no display name was configured.
"""
import importlib
import sys

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
    res = client.get("/api/auth/google/login", follow_redirects=False)
    token = res.headers["location"].split("token=")[1]
    return {"Authorization": f"Bearer {token}"}


def test_heartbeat_stores_device_name(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        client.post("/api/heartbeat", json={
            "hostname": "LAB-PC-03", "status": "ACTIVE", "device_name": "Lab PC 3 (dekat pintu)"
        })
        res = client.get("/api/active", headers=headers)
    assert res.status_code == 200
    pcs = res.json()
    assert len(pcs) == 1
    assert pcs[0]["hostname"] == "LAB-PC-03"
    assert pcs[0]["device_name"] == "Lab PC 3 (dekat pintu)"


def test_heartbeat_device_name_falls_back_to_hostname(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        client.post("/api/heartbeat", json={"hostname": "LAB-PC-04", "status": "ACTIVE"})
        res = client.get("/api/active", headers=headers)
    pcs = res.json()
    assert pcs[0]["device_name"] == "LAB-PC-04"


def test_heartbeat_device_name_updates_on_resend(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        client.post("/api/heartbeat", json={"hostname": "LAB-PC-05", "status": "ACTIVE", "device_name": "Old Name"})
        client.post("/api/heartbeat", json={"hostname": "LAB-PC-05", "status": "ACTIVE", "device_name": "New Name"})
        res = client.get("/api/active", headers=headers)
    pcs = res.json()
    assert len(pcs) == 1
    assert pcs[0]["device_name"] == "New Name"
