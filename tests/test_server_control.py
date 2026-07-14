"""Tests for Logix Control's enforced capabilities: policy/command-allowlist
enforcement (enforce_command_policy), power actions (POST /api/control/power),
and on-demand screen view (POST /api/control/screenshot + the agent upload +
admin read endpoints). See docs/LOGIX_CONTROL.md §5-§7.
"""
import base64
import importlib
import sys
from datetime import datetime, timedelta

import pytest
from fastapi.testclient import TestClient

API_KEY = "shared-dev-key"


def _load_main(monkeypatch, tmp_path, *, admin_emails="admin@example.org"):
    monkeypatch.setenv("LOGIX_DEV_MODE", "1")
    monkeypatch.setenv("LOGIX_INGEST_API_KEY", API_KEY)
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
    module._ENROLL_ATTEMPTS.clear()
    return module


def _login(client):
    res = client.post("/api/auth/dev-login")
    token = res.json()["token"]
    return {"Authorization": f"Bearer {token}"}


def _heartbeat(client, hostname):
    return client.post(
        "/api/heartbeat",
        json={"hostname": hostname, "status": "ACTIVE"},
        headers={"X-API-Key": API_KEY},
    )


def _set_policy(module, hostname, policy):
    conn = module.get_db()
    conn.execute("UPDATE devices SET policy_profile = ? WHERE hostname = ?", (policy, hostname))
    conn.commit()
    conn.close()


# --- Policy enforcement -------------------------------------------------------

def test_lock_allowed_by_default_policy(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        _heartbeat(client, "LAB-PC-1")
        res = client.post("/api/control/lock", json={"hostname": "LAB-PC-1"}, headers=headers)
    assert res.status_code == 200


def test_lock_allowed_for_unknown_device_backward_compat(monkeypatch, tmp_path):
    """A hostname the registry has never seen keeps the pre-enforcement
    behavior for the two legacy commands."""
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        res = client.post("/api/control/lock", json={"hostname": "GHOST-PC"}, headers=headers)
    assert res.status_code == 200


def test_power_denied_for_unknown_device_fails_closed(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        res = client.post(
            "/api/control/power",
            json={"hostname": "GHOST-PC", "action": "shutdown", "reason": "maintenance"},
            headers=headers,
        )
    assert res.status_code == 403


def test_policy_disallows_command(monkeypatch, tmp_path):
    """strict_privacy permits no power actions at all."""
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        _heartbeat(client, "LAB-PC-2")
        _set_policy(module, "LAB-PC-2", "strict_privacy")
        res = client.post(
            "/api/control/power",
            json={"hostname": "LAB-PC-2", "action": "restart", "reason": "maintenance"},
            headers=headers,
        )
    assert res.status_code == 403


def test_policy_requires_reason(monkeypatch, tmp_path):
    """lab_standard allows SHUTDOWN but only with a stated reason."""
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        _heartbeat(client, "LAB-PC-3")

        missing = client.post(
            "/api/control/power", json={"hostname": "LAB-PC-3", "action": "shutdown"}, headers=headers,
        )
        given = client.post(
            "/api/control/power",
            json={"hostname": "LAB-PC-3", "action": "shutdown", "reason": "listrik mati terjadwal"},
            headers=headers,
        )
    assert missing.status_code == 400
    assert given.status_code == 200


def test_server_monitoring_policy_drops_lock(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        _heartbeat(client, "SRV-1")
        _set_policy(module, "SRV-1", "server_monitoring")
        res = client.post("/api/control/lock", json={"hostname": "SRV-1"}, headers=headers)
    assert res.status_code == 403


def test_broadcast_all_skips_hosts_disallowed_by_policy(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        _heartbeat(client, "LAB-PC-4")
        _heartbeat(client, "SRV-2")
        _set_policy(module, "SRV-2", "server_monitoring")
        res = client.post(
            "/api/control/broadcast", json={"hostname": "ALL", "param": "halo"}, headers=headers,
        )
        assert res.status_code == 200
        lab_cmds = _heartbeat(client, "LAB-PC-4").json()["commands"]
        srv_cmds = _heartbeat(client, "SRV-2").json()["commands"]
    assert [c["command"] for c in lab_cmds] == ["BROADCAST"]
    assert srv_cmds == []


# --- Power actions ------------------------------------------------------------

def test_power_action_queued_and_audit_logged(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        _heartbeat(client, "LAB-PC-5")
        res = client.post(
            "/api/control/power",
            json={"hostname": "LAB-PC-5", "action": "restart", "reason": "update driver"},
            headers=headers,
        )
        assert res.status_code == 200
        delivered = _heartbeat(client, "LAB-PC-5").json()["commands"]
        audit = client.get("/api/audit-log?target_device=LAB-PC-5", headers=headers).json()
    assert [c["command"] for c in delivered] == ["RESTART"]
    actions = [a for a in audit["actions"] if a["action_type"] == "RESTART"]
    assert len(actions) == 1
    assert actions[0]["status"] == "queued"
    assert actions[0]["reason"] == "update driver"


def test_power_rejects_unknown_action(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        _heartbeat(client, "LAB-PC-6")
        res = client.post(
            "/api/control/power",
            json={"hostname": "LAB-PC-6", "action": "explode", "reason": "x"},
            headers=headers,
        )
    assert res.status_code == 400


# --- Screenshot flow ----------------------------------------------------------

def _fake_image_b64():
    return base64.b64encode(b"\xff\xd8\xff fake jpeg bytes").decode()


def _request_screenshot(client, headers, hostname, reason="cek penggunaan"):
    res = client.post(
        "/api/control/screenshot", json={"hostname": hostname, "reason": reason}, headers=headers,
    )
    assert res.status_code == 200, res.text
    return res.json()["command_id"]


def test_screenshot_roundtrip(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        _heartbeat(client, "LAB-PC-7")
        command_id = _request_screenshot(client, headers, "LAB-PC-7")

        delivered = _heartbeat(client, "LAB-PC-7").json()["commands"]
        assert [c["command"] for c in delivered] == ["SCREENSHOT"]

        up = client.post(
            "/api/control/screenshot/upload",
            json={"hostname": "LAB-PC-7", "command_id": command_id, "image_base64": _fake_image_b64()},
            headers={"X-API-Key": API_KEY},
        )
        assert up.status_code == 200

        conn = module.get_db()
        device_id = conn.execute(
            "SELECT device_id FROM devices WHERE hostname = 'LAB-PC-7'"
        ).fetchone()["device_id"]
        conn.close()

        shot = client.get(f"/api/devices/{device_id}/screenshot", headers=headers)
    assert shot.status_code == 200
    body = shot.json()
    assert body["hostname"] == "LAB-PC-7"
    assert body["image_base64"] == _fake_image_b64()
    assert body["captured_at"]


def test_screenshot_upload_rejects_unknown_command_id(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        _heartbeat(client, "LAB-PC-8")
        res = client.post(
            "/api/control/screenshot/upload",
            json={"hostname": "LAB-PC-8", "command_id": "not-a-real-id", "image_base64": _fake_image_b64()},
            headers={"X-API-Key": API_KEY},
        )
    assert res.status_code == 400


def test_screenshot_only_latest_kept(monkeypatch, tmp_path):
    """Privacy commitment: one row per device, replaced on every capture --
    no screen-content history accumulates server-side."""
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        _heartbeat(client, "LAB-PC-9")
        for i in range(2):
            command_id = _request_screenshot(client, headers, "LAB-PC-9")
            _heartbeat(client, "LAB-PC-9")  # consume the queued command
            client.post(
                "/api/control/screenshot/upload",
                json={"hostname": "LAB-PC-9", "command_id": command_id,
                      "image_base64": base64.b64encode(f"capture-{i}".encode()).decode()},
                headers={"X-API-Key": API_KEY},
            )
        conn = module.get_db()
        count = conn.execute("SELECT COUNT(*) FROM device_screenshots").fetchone()[0]
        row = conn.execute("SELECT image_base64 FROM device_screenshots").fetchone()
        conn.close()
    assert count == 1
    assert base64.b64decode(row["image_base64"]) == b"capture-1"


def test_screenshot_denied_by_privacy_policy(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        _heartbeat(client, "LAPTOP-1")
        _set_policy(module, "LAPTOP-1", "loaned_laptop")
        res = client.post(
            "/api/control/screenshot", json={"hostname": "LAPTOP-1", "reason": "x"}, headers=headers,
        )
    assert res.status_code == 403


# --- RBAC for the new permissions ----------------------------------------------

@pytest.mark.parametrize("role,power_ok,screenshot_ok", [
    ("super_admin", True, True),
    ("faculty_admin", True, True),
    ("lab_admin", True, True),
    ("instructor", False, True),
    ("viewer", False, False),
    ("auditor", False, False),
])
def test_power_and_screenshot_permissions(monkeypatch, tmp_path, role, power_ok, screenshot_ok):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        _heartbeat(client, "LAB-PC-10")
        _set_policy(module, "LAB-PC-10", "exam_mode")  # everything allowed, no reason needed
        token = f"test-token-{role}"
        module.ACTIVE_TOKENS[token] = {
            "email": f"{role}@test.org", "expires": datetime.now() + timedelta(hours=8), "role": role,
        }
        headers = {"Authorization": f"Bearer {token}"}
        power = client.post(
            "/api/control/power", json={"hostname": "LAB-PC-10", "action": "restart"}, headers=headers,
        )
        shot = client.post(
            "/api/control/screenshot", json={"hostname": "LAB-PC-10"}, headers=headers,
        )
    assert (power.status_code == 200) == power_ok, f"{role}: power got {power.status_code}"
    assert (shot.status_code == 200) == screenshot_ok, f"{role}: screenshot got {shot.status_code}"
