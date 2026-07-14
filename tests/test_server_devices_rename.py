"""Tests for PUT /api/devices/rename (admin dashboard right-click menu).

The load-bearing case here isn't the rename call itself -- it's that a
rename actually sticks. display_name is otherwise set from the agent's own
heartbeat-reported name every ~30s; without display_name_set_by_admin
guarding upsert_device(), an admin rename would silently revert on the
device's next heartbeat. See server/main.py's upsert_device() and the
devices_write permission comment near ROLE_PERMISSIONS.
"""
import importlib
import sys
from datetime import datetime, timedelta

import pytest
from fastapi.testclient import TestClient


def _load_main(monkeypatch, tmp_path, *, admin_emails="admin@example.org"):
    monkeypatch.setenv("LOGIX_DEV_MODE", "1")
    monkeypatch.setenv("LOGIX_INGEST_API_KEY", "")
    monkeypatch.setenv("LOGIX_ALLOWED_ORIGINS", "")
    monkeypatch.setenv("GOOGLE_CLIENT_ID", "")
    monkeypatch.setenv("GOOGLE_CLIENT_SECRET", "")
    monkeypatch.setenv("ADMIN_EMAILS", admin_emails)

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


def test_rename_updates_display_name(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        client.post("/api/heartbeat", json={"hostname": "LAB-PC-01", "status": "ACTIVE", "device_name": "Old Name"})

        res = client.put("/api/devices/rename", json={"hostname": "LAB-PC-01", "display_name": "Renamed PC"}, headers=headers)
        assert res.status_code == 200
        assert res.json()["display_name"] == "Renamed PC"

        devices = client.get("/api/devices", headers=headers).json()
    assert devices[0]["display_name"] == "Renamed PC"


def test_rename_survives_a_later_heartbeat(monkeypatch, tmp_path):
    """The actual bug this feature depends on not having: a later heartbeat
    reporting the agent's own (different) name must NOT revert the rename."""
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        client.post("/api/heartbeat", json={"hostname": "LAB-PC-02", "status": "ACTIVE", "device_name": "Agent Name"})
        client.put("/api/devices/rename", json={"hostname": "LAB-PC-02", "display_name": "Admin Renamed"}, headers=headers)

        # Simulates the device's next heartbeat, 30s later, still reporting
        # its own locally-configured name.
        client.post("/api/heartbeat", json={"hostname": "LAB-PC-02", "status": "ACTIVE", "device_name": "Agent Name"})

        devices = client.get("/api/devices", headers=headers).json()
    assert devices[0]["display_name"] == "Admin Renamed"


def test_rename_reflected_immediately_in_active_workstations(monkeypatch, tmp_path):
    """/api/active (what the Monitoring tab actually polls) is backed by the
    separate in-memory HEARTBEATS cache, not the devices table GET /api/devices
    reads from. A rename must show up there immediately, not just in the
    persisted registry, and must not need a subsequent heartbeat to appear."""
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        client.post("/api/heartbeat", json={"hostname": "LAB-PC-07", "status": "ACTIVE", "device_name": "Old"})
        client.put("/api/devices/rename", json={"hostname": "LAB-PC-07", "display_name": "Renamed"}, headers=headers)

        active = client.get("/api/active", headers=headers).json()
    assert active[0]["device_name"] == "Renamed"


def test_rename_survives_heartbeat_from_active_view_too(monkeypatch, tmp_path):
    """Same as test_rename_survives_a_later_heartbeat but asserted against
    /api/active specifically, since that's a separate cache from the devices
    table and was the one that actually broke during manual verification."""
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        client.post("/api/heartbeat", json={"hostname": "LAB-PC-08", "status": "ACTIVE", "device_name": "Agent Name"})
        client.put("/api/devices/rename", json={"hostname": "LAB-PC-08", "display_name": "Admin Renamed"}, headers=headers)

        client.post("/api/heartbeat", json={"hostname": "LAB-PC-08", "status": "ACTIVE", "device_name": "Agent Name"})

        active = client.get("/api/active", headers=headers).json()
    assert active[0]["device_name"] == "Admin Renamed"


def test_rename_unknown_hostname_404(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        res = client.put("/api/devices/rename", json={"hostname": "NOPE", "display_name": "X"}, headers=headers)
    assert res.status_code == 404


def test_rename_empty_name_400(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        client.post("/api/heartbeat", json={"hostname": "LAB-PC-03", "status": "ACTIVE"})
        res = client.put("/api/devices/rename", json={"hostname": "LAB-PC-03", "display_name": "   "}, headers=headers)
    assert res.status_code == 400


def test_rename_requires_auth(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        res = client.put("/api/devices/rename", json={"hostname": "LAB-PC-04", "display_name": "X"})
    assert res.status_code == 401


def test_rename_creates_audit_row(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        client.post("/api/heartbeat", json={"hostname": "LAB-PC-05", "status": "ACTIVE"})
        client.put("/api/devices/rename", json={"hostname": "LAB-PC-05", "display_name": "New Name"}, headers=headers)
        actions = client.get("/api/audit-log", headers=headers).json()["actions"]
    assert len(actions) == 1
    assert actions[0]["action_type"] == "RENAME"
    assert actions[0]["status"] == "done"


@pytest.mark.parametrize("role,permitted", [
    ("super_admin", True),
    ("faculty_admin", True),
    ("lab_admin", True),
    ("instructor", False),
    ("viewer", False),
    ("auditor", False),
])
def test_devices_write_permission(monkeypatch, tmp_path, role, permitted):
    module = _load_main(monkeypatch, tmp_path, admin_emails=f"bootstrap@test.org:super_admin")
    with TestClient(module.app) as client:
        boot_headers = _login(client)
        client.post("/api/heartbeat", json={"hostname": "LAB-PC-06", "status": "ACTIVE"})

        token = f"test-token-{role}"
        module.ACTIVE_TOKENS[token] = {
            "email": f"{role}@test.org",
            "expires": datetime.now() + timedelta(hours=8),
            "role": role,
        }
        headers = {"Authorization": f"Bearer {token}"}

        res = client.put("/api/devices/rename", json={"hostname": "LAB-PC-06", "display_name": "X"}, headers=headers)

    if permitted:
        assert res.status_code == 200, f"{role} should be permitted 'devices_write', got {res.status_code}"
    else:
        assert res.status_code == 403, f"{role} should be forbidden 'devices_write', got {res.status_code}"
