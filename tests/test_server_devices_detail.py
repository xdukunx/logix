"""Tests for GET /api/devices/{device_id} (Dashboard roadmap item G: Device
Detail + Sync Health). Joins the devices registry row with its assigned
policy and rolls up its remote_actions history into per-status counts.
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


def test_device_detail_unknown_id_404(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        res = client.get("/api/devices/does-not-exist", headers=headers)
    assert res.status_code == 404


def test_device_detail_requires_auth(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        client.post("/api/heartbeat", json={"hostname": "LAB-PC-01", "status": "ACTIVE"})
        # Need a device_id, but not an authenticated request to fetch it.
        headers = _login(client)
        device_id = client.get("/api/devices", headers=headers).json()[0]["device_id"]
        res = client.get(f"/api/devices/{device_id}")
    assert res.status_code == 401


def test_device_detail_shape(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        client.post("/api/heartbeat", json={"hostname": "LAB-PC-02", "status": "ACTIVE", "device_name": "Lab PC 2"})
        device_id = client.get("/api/devices", headers=headers).json()[0]["device_id"]

        res = client.get(f"/api/devices/{device_id}", headers=headers)

    assert res.status_code == 200
    body = res.json()
    assert set(body.keys()) == {"device", "policy", "recent_actions", "sync_health"}
    assert body["device"]["hostname"] == "LAB-PC-02"
    assert body["device"]["sync_status"] == "online"
    assert body["device"]["currently_online"] is True
    assert "api_key" not in body["device"]
    # devices default to policy_profile "lab_standard", seeded as a system policy.
    assert body["policy"]["policy_name"] == "lab_standard"
    assert body["recent_actions"] == []
    assert body["sync_health"] == {"queued": 0, "done": 0, "failed": 0, "expired": 0, "total": 0}


def test_device_detail_sync_health_counts_match_remote_actions(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        client.post("/api/heartbeat", json={"hostname": "LAB-PC-03", "status": "ACTIVE"})
        device_id = client.get("/api/devices", headers=headers).json()[0]["device_id"]

        # Two queued commands against this device -- log_remote_action()
        # resolves target_device_id from the hostname automatically.
        client.post("/api/control/lock", json={"hostname": "LAB-PC-03"}, headers=headers)
        client.post("/api/control/broadcast", json={"hostname": "LAB-PC-03", "param": "hi"}, headers=headers)

        res = client.get(f"/api/devices/{device_id}", headers=headers)

    body = res.json()
    assert len(body["recent_actions"]) == 2
    assert body["sync_health"] == {"queued": 2, "done": 0, "failed": 0, "expired": 0, "total": 2}


def test_device_detail_shows_revoke_in_recent_actions(monkeypatch, tmp_path):
    """Roadmap item H: revoking a device from the Detail modal must show up
    in that same modal's Recent Commands / sync_health, just like rename
    already does -- otherwise an admin sees no trace of their own action."""
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        client.post("/api/heartbeat", json={"hostname": "LAB-PC-07", "status": "ACTIVE"})
        device_id = client.get("/api/devices", headers=headers).json()[0]["device_id"]

        client.post(f"/api/devices/{device_id}/revoke", headers=headers)
        res = client.get(f"/api/devices/{device_id}", headers=headers)

    body = res.json()
    assert len(body["recent_actions"]) == 1
    assert body["recent_actions"][0]["action_type"] == "REVOKE_API_KEY"
    assert body["recent_actions"][0]["status"] == "done"
    assert body["sync_health"]["done"] == 1
    assert body["sync_health"]["total"] == 1


@pytest.mark.parametrize("role,permitted", [
    ("super_admin", True),
    ("faculty_admin", True),
    ("lab_admin", True),
    ("instructor", False),
    ("viewer", True),
    ("auditor", False),
])
def test_device_detail_permission(monkeypatch, tmp_path, role, permitted):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        boot_headers = _login(client)
        client.post("/api/heartbeat", json={"hostname": "LAB-PC-04", "status": "ACTIVE"})
        device_id = client.get("/api/devices", headers=boot_headers).json()[0]["device_id"]

        token = f"test-token-{role}"
        module.ACTIVE_TOKENS[token] = {
            "email": f"{role}@test.org",
            "expires": datetime.now() + timedelta(hours=8),
            "role": role,
        }
        headers = {"Authorization": f"Bearer {token}"}

        res = client.get(f"/api/devices/{device_id}", headers=headers)

    if permitted:
        assert res.status_code == 200, f"{role} should be permitted 'devices_read', got {res.status_code}"
    else:
        assert res.status_code == 403, f"{role} should be forbidden 'devices_read', got {res.status_code}"


def test_audit_log_status_filter(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        client.post("/api/control/lock", json={"hostname": "LAB-PC-05"}, headers=headers)
        client.post("/api/control/lock", json={"hostname": "LAB-PC-06"}, headers=headers)

        res = client.get("/api/audit-log?status=queued&limit=1", headers=headers)

    body = res.json()
    assert body["total"] == 2  # count reflects the filter, independent of limit
    assert len(body["actions"]) == 1
    assert body["actions"][0]["status"] == "queued"
