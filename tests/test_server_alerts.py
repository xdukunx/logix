"""Tests for the System Alerts subsystem (roadmap item I): lazy
reconciliation of device/action conditions into the alerts table, dedup by
category+device_id+unresolved status, auto-resolve on recovery, and the
GET/acknowledge/resolve API. See reconcile_alerts() in server/main.py.
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


def _make_stale(module, hostname, category="lab_workstation", seconds=90):
    """lab_workstation's heartbeat_interval_seconds is 30 -> online <=60s,
    stale <=180s. 90s lands in the stale window."""
    conn = module.get_db()
    conn.execute("UPDATE devices SET category = ? WHERE hostname = ?", (category, hostname))
    conn.commit()
    conn.close()
    module.HEARTBEATS[hostname]["last_seen"] = datetime.now() - timedelta(seconds=seconds)


def test_stale_device_creates_warning_alert(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        client.post("/api/heartbeat", json={"hostname": "LAB-PC-01", "status": "ACTIVE"})
        _make_stale(module, "LAB-PC-01", seconds=90)

        res = client.get("/api/alerts?active=true", headers=headers)

    body = res.json()
    assert body["total"] == 1
    alert = body["alerts"][0]
    assert alert["category"] == "device_stale"
    assert alert["severity"] == "warning"
    assert alert["status"] == "active"


def test_offline_device_creates_critical_alert(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        client.post("/api/heartbeat", json={"hostname": "LAB-PC-02", "status": "ACTIVE"})
        # lab_workstation offline window is > 6x30s = 180s.
        _make_stale(module, "LAB-PC-02", seconds=300)

        res = client.get("/api/alerts?active=true", headers=headers)

    body = res.json()
    assert body["total"] == 1
    alert = body["alerts"][0]
    assert alert["category"] == "device_offline"
    assert alert["severity"] == "critical"


def test_no_duplicate_unresolved_alert_on_repeated_refresh(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        client.post("/api/heartbeat", json={"hostname": "LAB-PC-03", "status": "ACTIVE"})
        _make_stale(module, "LAB-PC-03", seconds=300)

        # Poll GET /api/alerts (which reconciles) three times, simulating
        # the dashboard's periodic refresh while the device stays offline.
        client.get("/api/alerts?active=true", headers=headers)
        client.get("/api/alerts?active=true", headers=headers)
        res = client.get("/api/alerts?active=true", headers=headers)

    assert res.json()["total"] == 1


def test_alert_resolved_when_device_recovers(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        client.post("/api/heartbeat", json={"hostname": "LAB-PC-04", "status": "ACTIVE"})
        _make_stale(module, "LAB-PC-04", seconds=300)
        client.get("/api/alerts?active=true", headers=headers)  # creates device_offline

        # Device comes back online.
        client.post("/api/heartbeat", json={"hostname": "LAB-PC-04", "status": "ACTIVE"})
        active = client.get("/api/alerts?active=true", headers=headers).json()
        resolved = client.get("/api/alerts?active=false", headers=headers).json()

    assert active["total"] == 0
    assert resolved["total"] == 1
    assert resolved["alerts"][0]["category"] == "device_offline"
    assert resolved["alerts"][0]["status"] == "resolved"
    assert resolved["alerts"][0]["resolved_at"]


def test_recurrence_after_resolution_creates_new_alert(monkeypatch, tmp_path):
    """Spec requirement: once resolved, the same condition happening again
    must create a fresh row, not silently stay resolved."""
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        client.post("/api/heartbeat", json={"hostname": "LAB-PC-05", "status": "ACTIVE"})
        _make_stale(module, "LAB-PC-05", seconds=300)
        client.get("/api/alerts", headers=headers)  # create + resolve cycle 1
        client.post("/api/heartbeat", json={"hostname": "LAB-PC-05", "status": "ACTIVE"})
        client.get("/api/alerts", headers=headers)  # resolves it

        _make_stale(module, "LAB-PC-05", seconds=300)
        res = client.get("/api/alerts?category=device_offline", headers=headers)

    body = res.json()
    assert body["total"] == 2  # original resolved row + the new recurrence
    statuses = {a["status"] for a in body["alerts"]}
    assert statuses == {"active", "resolved"}


def test_get_alerts_response_shape(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        res = client.get("/api/alerts", headers=headers)

    assert res.status_code == 200
    body = res.json()
    assert set(body.keys()) == {"total", "alerts"}
    assert body["total"] == 0
    assert body["alerts"] == []


def test_get_alerts_requires_auth(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        res = client.get("/api/alerts")
    assert res.status_code == 401


def test_acknowledge_updates_acknowledged_at(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        client.post("/api/heartbeat", json={"hostname": "LAB-PC-06", "status": "ACTIVE"})
        _make_stale(module, "LAB-PC-06", seconds=90)
        alert_id = client.get("/api/alerts", headers=headers).json()["alerts"][0]["id"]

        ack_res = client.post(f"/api/alerts/{alert_id}/acknowledge", headers=headers)
        assert ack_res.status_code == 200

        alerts = client.get("/api/alerts?active=true", headers=headers).json()["alerts"]

    assert alerts[0]["status"] == "acknowledged"
    assert alerts[0]["acknowledged_at"]


def test_acknowledge_unknown_alert_404(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        res = client.post("/api/alerts/99999/acknowledge", headers=headers)
    assert res.status_code == 404


def test_resolve_endpoint_manually_closes_alert(monkeypatch, tmp_path):
    """Manual resolve is only stable for action_failed -- the one category
    with no auto-clear condition to re-evaluate. (Resolving a still-true
    condition alert like device_stale would just get recreated by the very
    next reconcile_alerts() pass, since the alert reflects live state, not
    an admin's dismissal of it -- that's what acknowledge is for.)"""
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        client.post("/api/heartbeat", json={"hostname": "LAB-PC-07", "status": "ACTIVE"})
        client.post("/api/control/lock", json={"hostname": "LAB-PC-07"}, headers=headers)
        delivered = client.post("/api/heartbeat", json={"hostname": "LAB-PC-07", "status": "ACTIVE"}).json()
        command_id = delivered["commands"][0]["command_id"]
        client.post("/api/heartbeat", json={
            "hostname": "LAB-PC-07", "status": "ACTIVE",
            "acks": [{"command_id": command_id, "status": "failed", "detail": "boom"}],
        })
        alert_id = client.get("/api/alerts?category=action_failed", headers=headers).json()["alerts"][0]["id"]

        res = client.post(f"/api/alerts/{alert_id}/resolve", headers=headers)
        assert res.status_code == 200

        # Poll twice more (simulating the dashboard's periodic refresh) --
        # the same already-resolved failure must not resurrect itself.
        client.get("/api/alerts?active=true", headers=headers)
        active = client.get("/api/alerts?active=true", headers=headers).json()

    assert active["total"] == 0


def test_new_failure_after_resolve_creates_fresh_action_failed_alert(monkeypatch, tmp_path):
    """The flip side of the above: a genuinely new failure for the same
    device, after the previous one was resolved, must still alert."""
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        client.post("/api/heartbeat", json={"hostname": "LAB-PC-10", "status": "ACTIVE"})

        client.post("/api/control/lock", json={"hostname": "LAB-PC-10"}, headers=headers)
        cmd1 = client.post("/api/heartbeat", json={"hostname": "LAB-PC-10", "status": "ACTIVE"}).json()["commands"][0]["command_id"]
        client.post("/api/heartbeat", json={
            "hostname": "LAB-PC-10", "status": "ACTIVE",
            "acks": [{"command_id": cmd1, "status": "failed", "detail": "first failure"}],
        })
        first_alert_id = client.get("/api/alerts?category=action_failed", headers=headers).json()["alerts"][0]["id"]
        client.post(f"/api/alerts/{first_alert_id}/resolve", headers=headers)

        client.post("/api/control/broadcast", json={"hostname": "LAB-PC-10"}, headers=headers)
        cmd2 = client.post("/api/heartbeat", json={"hostname": "LAB-PC-10", "status": "ACTIVE"}).json()["commands"][0]["command_id"]
        client.post("/api/heartbeat", json={
            "hostname": "LAB-PC-10", "status": "ACTIVE",
            "acks": [{"command_id": cmd2, "status": "failed", "detail": "second failure"}],
        })

        res = client.get("/api/alerts?category=action_failed", headers=headers)

    body = res.json()
    assert body["total"] == 2
    active_ones = [a for a in body["alerts"] if a["status"] != "resolved"]
    assert len(active_ones) == 1


def test_failed_remote_action_creates_critical_alert(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        # Device must exist (heartbeat) before the command is queued, so
        # log_remote_action can resolve target_device_id -- see its comment.
        client.post("/api/heartbeat", json={"hostname": "LAB-PC-08", "status": "ACTIVE"})
        client.post("/api/control/lock", json={"hostname": "LAB-PC-08"}, headers=headers)
        delivered = client.post("/api/heartbeat", json={"hostname": "LAB-PC-08", "status": "ACTIVE"}).json()
        command_id = delivered["commands"][0]["command_id"]
        client.post("/api/heartbeat", json={
            "hostname": "LAB-PC-08", "status": "ACTIVE",
            "acks": [{"command_id": command_id, "status": "failed", "detail": "access denied"}],
        })

        res = client.get("/api/alerts?category=action_failed", headers=headers)

    body = res.json()
    assert body["total"] == 1
    assert body["alerts"][0]["severity"] == "critical"
    assert body["alerts"][0]["status"] == "active"


@pytest.mark.parametrize("role,permitted", [
    ("super_admin", True),
    ("faculty_admin", True),
    ("lab_admin", True),
    ("viewer", True),
    ("instructor", False),
    ("auditor", False),
])
def test_alerts_read_permission(monkeypatch, tmp_path, role, permitted):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        token = f"test-token-{role}"
        module.ACTIVE_TOKENS[token] = {
            "email": f"{role}@test.org",
            "expires": datetime.now() + timedelta(hours=8),
            "role": role,
        }
        res = client.get("/api/alerts", headers={"Authorization": f"Bearer {token}"})

    if permitted:
        assert res.status_code == 200, f"{role} should be permitted 'alerts_read', got {res.status_code}"
    else:
        assert res.status_code == 403, f"{role} should be forbidden 'alerts_read', got {res.status_code}"


@pytest.mark.parametrize("role,permitted", [
    ("super_admin", True),
    ("faculty_admin", True),
    ("lab_admin", True),
    ("viewer", False),
    ("instructor", False),
    ("auditor", False),
])
def test_alerts_write_permission(monkeypatch, tmp_path, role, permitted):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        boot_token = "test-token-super_admin-boot"
        module.ACTIVE_TOKENS[boot_token] = {
            "email": "boot@test.org", "expires": datetime.now() + timedelta(hours=8), "role": "super_admin",
        }
        boot_headers = {"Authorization": f"Bearer {boot_token}"}
        client.post("/api/heartbeat", json={"hostname": "LAB-PC-09", "status": "ACTIVE"})
        _make_stale(module, "LAB-PC-09", seconds=90)
        alert_id = client.get("/api/alerts", headers=boot_headers).json()["alerts"][0]["id"]

        token = f"test-token-{role}"
        module.ACTIVE_TOKENS[token] = {
            "email": f"{role}@test.org", "expires": datetime.now() + timedelta(hours=8), "role": role,
        }
        res = client.post(f"/api/alerts/{alert_id}/acknowledge", headers={"Authorization": f"Bearer {token}"})

    if permitted:
        assert res.status_code == 200, f"{role} should be permitted 'alerts_write', got {res.status_code}"
    else:
        assert res.status_code == 403, f"{role} should be forbidden 'alerts_write', got {res.status_code}"
