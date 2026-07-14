"""Tests for real device enrollment (Logix Control): POST /api/enroll/invite,
POST /api/enroll, per-device API key auth, and revocation. See
API_CONTRACT.md for the locked design this implements.
"""
import importlib
import sys
from datetime import datetime, timedelta

from fastapi.testclient import TestClient


def _load_main(monkeypatch, tmp_path):
    monkeypatch.setenv("LOGIX_DEV_MODE", "1")
    monkeypatch.setenv("LOGIX_INGEST_API_KEY", "shared-dev-key")
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
    module._ENROLL_ATTEMPTS.clear()
    return module


def _login(client):
    res = client.post("/api/auth/dev-login")
    token = res.json()["token"]
    return {"Authorization": f"Bearer {token}"}


def test_invite_requires_auth(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        res = client.post("/api/enroll/invite", json={"category": "lab_workstation"})
    assert res.status_code == 401


def test_invite_rejects_unknown_category(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        res = client.post("/api/enroll/invite", json={"category": "not_a_real_category"}, headers=headers)
    assert res.status_code == 400


def test_invite_creates_code_with_ttl(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        res = client.post("/api/enroll/invite", json={"category": "lab_workstation"}, headers=headers)
    assert res.status_code == 201
    body = res.json()
    assert body["category"] == "lab_workstation"
    assert "-" in body["invite_code"]  # grouped, not a short PIN
    expires = datetime.fromisoformat(body["expires_at"])
    assert expires > datetime.now()
    assert expires < datetime.now() + timedelta(minutes=16)


def test_enroll_with_valid_code_returns_contract_shape(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        invite = client.post("/api/enroll/invite", json={"category": "lab_workstation"}, headers=headers).json()

        res = client.post("/api/enroll", json={
            "invite_code": invite["invite_code"],
            "hostname": "LAB-PC-10",
            "os": "windows",
            "os_version": "10.0.19045",
            "agent_version": "0.2.0",
        })

    assert res.status_code == 200
    body = res.json()
    assert body["category"] == "lab_workstation"
    assert body["profile"] == {"heartbeat_interval_seconds": 30, "popup_frequency": "every_unlock"}
    assert len(body["device_id"]) > 0
    assert len(body["api_key"]) >= 32
    assert "server_time" in body


def test_enroll_unknown_code_returns_400(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        res = client.post("/api/enroll", json={"invite_code": "NOPE-NOPE-NOPE-NOPE", "hostname": "X"})
    assert res.status_code == 400


def test_enroll_expired_code_returns_410(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        invite = client.post("/api/enroll/invite", json={"category": "custom"}, headers=headers).json()

        # Simulate expiry by rewriting expires_at directly in the DB.
        conn = module.get_db()
        try:
            past = (datetime.now() - timedelta(minutes=1)).isoformat()
            conn.execute("UPDATE enrollment_invites SET expires_at = ? WHERE invite_code = ?",
                         (past, invite["invite_code"]))
            conn.commit()
        finally:
            conn.close()

        res = client.post("/api/enroll", json={"invite_code": invite["invite_code"], "hostname": "X"})
    assert res.status_code == 410


def test_enroll_already_used_code_returns_400(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        invite = client.post("/api/enroll/invite", json={"category": "custom"}, headers=headers).json()

        first = client.post("/api/enroll", json={"invite_code": invite["invite_code"], "hostname": "PC-A"})
        assert first.status_code == 200

        second = client.post("/api/enroll", json={"invite_code": invite["invite_code"], "hostname": "PC-B"})
    assert second.status_code == 400


def test_enroll_rate_limit_returns_429(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        for _ in range(module.ENROLL_RATE_LIMIT_MAX_ATTEMPTS):
            client.post("/api/enroll", json={"invite_code": "BAD-BAD-BAD-BAD", "hostname": "X"})
        res = client.post("/api/enroll", json={"invite_code": "BAD-BAD-BAD-BAD", "hostname": "X"})
    assert res.status_code == 429


def test_devices_list_never_contains_api_key(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        invite = client.post("/api/enroll/invite", json={"category": "custom"}, headers=headers).json()
        client.post("/api/enroll", json={"invite_code": invite["invite_code"], "hostname": "LAB-PC-11"})

        res = client.get("/api/devices", headers=headers)
    devices = res.json()
    assert len(devices) == 1
    assert "api_key" not in devices[0]


def test_enrolled_device_can_heartbeat_with_its_own_key(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        invite = client.post("/api/enroll/invite", json={"category": "custom"}, headers=headers).json()
        enrolled = client.post("/api/enroll", json={"invite_code": invite["invite_code"], "hostname": "LAB-PC-12"}).json()

        res = client.post("/api/heartbeat",
                           json={"hostname": "LAB-PC-12", "status": "ACTIVE"},
                           headers={"X-API-Key": enrolled["api_key"]})
    assert res.status_code == 200


def test_shared_key_still_works_after_enrollment_ships(monkeypatch, tmp_path):
    """Backward-compat regression: the shared LOGIX_INGEST_API_KEY must keep
    working for devices that haven't enrolled."""
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        res = client.post("/api/heartbeat",
                           json={"hostname": "UNENROLLED-PC", "status": "ACTIVE"},
                           headers={"X-API-Key": "shared-dev-key"})
    assert res.status_code == 200


def test_revoke_requires_auth(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        res = client.post("/api/devices/some-id/revoke")
    assert res.status_code == 401


def test_revoke_unknown_device_404(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        res = client.post("/api/devices/does-not-exist/revoke", headers=headers)
    assert res.status_code == 404


def test_revoke_creates_audit_row(monkeypatch, tmp_path):
    """Mirrors rename_device's existing audit trail (roadmap item H) --
    revoking a device's ingest credential is exactly as auditable as
    renaming it, and should show up in that device's Recent Commands."""
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        client.post("/api/heartbeat", json={"hostname": "LAB-PC-14", "status": "ACTIVE"},
                    headers={"X-API-Key": "shared-dev-key"})
        device_id = client.get("/api/devices", headers=headers).json()[0]["device_id"]

        res = client.post(f"/api/devices/{device_id}/revoke", headers=headers)
        assert res.status_code == 200

        actions = client.get("/api/audit-log", headers=headers).json()["actions"]
    assert len(actions) == 1
    assert actions[0]["target_device"] == "LAB-PC-14"
    assert actions[0]["action_type"] == "REVOKE_API_KEY"
    assert actions[0]["status"] == "done"


def test_revoke_actually_breaks_the_old_key(monkeypatch, tmp_path):
    """The load-bearing behavioral test: revoke must make the OLD key
    actually fail on the next real request, not just look revoked in the DB."""
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        invite = client.post("/api/enroll/invite", json={"category": "custom"}, headers=headers).json()
        enrolled = client.post("/api/enroll", json={"invite_code": invite["invite_code"], "hostname": "LAB-PC-13"}).json()

        # Confirm the key works before revoking.
        pre = client.post("/api/heartbeat",
                           json={"hostname": "LAB-PC-13", "status": "ACTIVE"},
                           headers={"X-API-Key": enrolled["api_key"]})
        assert pre.status_code == 200

        revoke_res = client.post(f"/api/devices/{enrolled['device_id']}/revoke", headers=headers)
        assert revoke_res.status_code == 200

        # The exact same key must now be rejected. Point DB_PATH's shared
        # key check away too, so this can't accidentally pass via fallback.
        monkeypatch.setenv("LOGIX_INGEST_API_KEY", "a-totally-different-key")
        module.LOGIX_DEV_MODE = False  # force real key checking, not the dev-mode bypass
        post = client.post("/api/heartbeat",
                            json={"hostname": "LAB-PC-13", "status": "ACTIVE"},
                            headers={"X-API-Key": enrolled["api_key"]})
    assert post.status_code == 401
