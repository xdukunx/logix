"""DELETE /api/devices/{id} -- removal that actually removes.

The Devices tab's "Hapus" button used to call POST .../revoke, which only set
api_key = NULL. The row stayed in the registry with its old last_seen and
status 'active', so the dashboard kept showing the device as merely stale --
and if the fleet still had a shared LOGIX_INGEST_API_KEY, the agent's next
heartbeat put it straight back to 'active'. These tests pin the behaviour that
replaced it, including the resurrection path, which is the one that made the
bug look like the delete had silently failed.
"""
import importlib
import sys

from fastapi.testclient import TestClient


def _load_main(monkeypatch, tmp_path, *, shared_key="shared-key"):
    # Deliberately NOT dev mode for most of this: dev mode makes verify_api_key
    # accept anything, and the resurrection bug specifically needs a working
    # SHARED key -- the credential a deleted device still holds.
    monkeypatch.setenv("LOGIX_DEV_MODE", "1")
    monkeypatch.setenv("LOGIX_INGEST_API_KEY", shared_key)
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
    return {"Authorization": f"Bearer {client.post('/api/auth/dev-login').json()['token']}"}


def _seed_device(client, hostname="LAB-PC-01", device_name="Lab PC 1"):
    client.post("/api/heartbeat", json={"hostname": hostname, "status": "ACTIVE",
                                        "device_name": device_name},
                headers={"X-API-Key": "shared-key"})


def test_delete_removes_the_device_from_every_read_surface(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        _seed_device(client)
        device_id = client.get("/api/devices", headers=headers).json()[0]["device_id"]

        res = client.delete(f"/api/devices/{device_id}", headers=headers)
        assert res.status_code == 200

        assert client.get("/api/devices", headers=headers).json() == []
        assert client.get("/api/active", headers=headers).json() == []
        assert client.get(f"/api/devices/{device_id}", headers=headers).status_code == 404


def test_a_deleted_device_cannot_heartbeat_itself_back_with_the_shared_key(monkeypatch, tmp_path):
    """The actual reported bug: "sudah dihapus tapi masih aktif"."""
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        _seed_device(client)
        device_id = client.get("/api/devices", headers=headers).json()[0]["device_id"]
        client.delete(f"/api/devices/{device_id}", headers=headers)

        # The agent still holds a perfectly valid SHARED ingest key.
        res = client.post("/api/heartbeat",
                          json={"hostname": "LAB-PC-01", "status": "ACTIVE"},
                          headers={"X-API-Key": "shared-key"})
        assert res.status_code == 403
        assert "removed" in res.json()["detail"].lower()

        assert client.get("/api/devices", headers=headers).json() == []
        assert client.get("/api/active", headers=headers).json() == []


def test_delete_is_idempotent_and_404s_the_second_time(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        _seed_device(client)
        device_id = client.get("/api/devices", headers=headers).json()[0]["device_id"]
        assert client.delete(f"/api/devices/{device_id}", headers=headers).status_code == 200
        assert client.delete(f"/api/devices/{device_id}", headers=headers).status_code == 404


def test_control_commands_for_a_deleted_device_are_refused(monkeypatch, tmp_path):
    """A queued command for a device that can no longer heartbeat would sit
    'queued' until it expired, while the dashboard reported it as sent."""
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        _seed_device(client)
        device_id = client.get("/api/devices", headers=headers).json()[0]["device_id"]
        client.delete(f"/api/devices/{device_id}", headers=headers)

        for path, body in (
            ("/api/control/lock", {"hostname": "LAB-PC-01"}),
            ("/api/control/broadcast", {"hostname": "LAB-PC-01", "param": "halo"}),
            ("/api/control/screenshot", {"hostname": "LAB-PC-01", "reason": "cek"}),
            ("/api/control/power", {"hostname": "LAB-PC-01", "action": "restart"}),
        ):
            assert client.post(path, json=body, headers=headers).status_code == 404, path


def test_delete_purges_the_screenshot_and_the_unread_replies(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        _seed_device(client)
        device_id = client.get("/api/devices", headers=headers).json()[0]["device_id"]

        shot = client.post("/api/control/screenshot",
                           json={"hostname": "LAB-PC-01", "reason": "cek"}, headers=headers)
        client.post("/api/control/screenshot/upload",
                    json={"hostname": "LAB-PC-01", "command_id": shot.json()["command_id"],
                          "image_base64": "AAAA", "content_type": "image/jpeg"},
                    headers={"X-API-Key": "shared-key"})
        client.post("/api/replies", json={"hostname": "LAB-PC-01", "message": "OK"},
                    headers={"X-API-Key": "shared-key"})
        assert client.get(f"/api/devices/{device_id}/screenshot", headers=headers).status_code == 200
        assert client.get("/api/replies", headers=headers).json()["total"] == 1

        client.delete(f"/api/devices/{device_id}", headers=headers)

        assert client.get(f"/api/devices/{device_id}/screenshot", headers=headers).status_code == 404
        assert client.get("/api/replies", headers=headers).json()["total"] == 0


def test_re_enrolling_brings_a_deleted_hostname_back(monkeypatch, tmp_path):
    """Deleting is not a permanent ban -- a fresh invite is the way back in,
    and it must restore the SAME hostname rather than being refused."""
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        _seed_device(client)
        device_id = client.get("/api/devices", headers=headers).json()[0]["device_id"]
        client.delete(f"/api/devices/{device_id}", headers=headers)

        code = client.post("/api/enroll/invite", json={"category": "lab_workstation"},
                           headers=headers).json()["invite_code"]
        enrolled = client.post("/api/enroll", json={"invite_code": code, "hostname": "LAB-PC-01",
                                                    "device_name": "Lab PC 1"})
        assert enrolled.status_code == 200

        devices = client.get("/api/devices", headers=headers).json()
        assert [d["hostname"] for d in devices] == ["LAB-PC-01"]
        assert devices[0]["status"] == "active"

        # And it can heartbeat again, with its own key this time.
        res = client.post("/api/heartbeat", json={"hostname": "LAB-PC-01", "status": "ACTIVE"},
                          headers={"X-API-Key": enrolled.json()["api_key"]})
        assert res.status_code == 200


def test_delete_keeps_the_audit_trail(monkeypatch, tmp_path):
    """Session history and the remote_actions log survive; only the "this
    device is present" record goes."""
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        _seed_device(client)
        device_id = client.get("/api/devices", headers=headers).json()[0]["device_id"]
        client.delete(f"/api/devices/{device_id}", headers=headers)

        actions = client.get("/api/audit-log", headers=headers).json()
        types = [a["action_type"] for a in actions["actions"]]
        assert "DELETE_DEVICE" in types
