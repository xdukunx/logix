"""Tests for the device-reply system: the person at a workstation answers an
admin broadcast from the session-timer widget (windows/logbook_timer.ps1),
the agent POSTs it to /api/replies with its ingest credential, and the
dashboard reads/marks it via the replies_read/replies_write permissions.
"""
import importlib
import sys
from datetime import datetime, timedelta

import pytest
from fastapi.testclient import TestClient

API_KEY = "shared-dev-key"


def _load_main(monkeypatch, tmp_path):
    monkeypatch.setenv("LOGIX_DEV_MODE", "1")
    monkeypatch.setenv("LOGIX_INGEST_API_KEY", API_KEY)
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
    res = client.get("/api/auth/google/login", follow_redirects=False)
    token = res.headers["location"].split("token=")[1]
    return {"Authorization": f"Bearer {token}"}


def _heartbeat(client, hostname):
    return client.post(
        "/api/heartbeat",
        json={"hostname": hostname, "status": "ACTIVE"},
        headers={"X-API-Key": API_KEY},
    )


def _post_reply(client, hostname, message, command_id=""):
    return client.post(
        "/api/replies",
        json={"hostname": hostname, "message": message, "command_id": command_id},
        headers={"X-API-Key": API_KEY},
    )


def test_full_broadcast_reply_roundtrip(monkeypatch, tmp_path):
    """Admin sends a message; the delivered command's command_id comes back
    attached to the user's reply; the dashboard sees the reply linked to the
    original broadcast text."""
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        _heartbeat(client, "LAB-PC-1")
        client.post(
            "/api/control/broadcast",
            json={"hostname": "LAB-PC-1", "param": "Tolong tutup aplikasi berat"},
            headers=headers,
        )
        delivered = _heartbeat(client, "LAB-PC-1").json()["commands"]
        command_id = delivered[0]["command_id"]

        res = _post_reply(client, "LAB-PC-1", "Baik pak, sudah saya tutup", command_id)
        assert res.status_code == 200

        replies = client.get("/api/replies", headers=headers).json()

    assert replies["total"] == 1
    assert replies["unread"] == 1
    reply = replies["replies"][0]
    assert reply["message"] == "Baik pak, sudah saya tutup"
    assert reply["hostname"] == "LAB-PC-1"
    assert reply["command_id"] == command_id
    assert reply["in_reply_to"] == "Tolong tutup aplikasi berat"
    assert reply["read_at"] is None


def test_reply_without_command_id(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        _heartbeat(client, "LAB-PC-2")
        res = _post_reply(client, "LAB-PC-2", "Printer lab mati, mohon dicek")
        assert res.status_code == 200
        replies = client.get("/api/replies", headers=headers).json()
    assert replies["total"] == 1
    assert replies["replies"][0]["in_reply_to"] is None


def test_reply_requires_api_key(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        res = client.post("/api/replies", json={"hostname": "LAB-PC-3", "message": "hi"})
    assert res.status_code == 401


def test_reply_validation(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        empty = _post_reply(client, "LAB-PC-4", "   ")
        too_long = _post_reply(client, "LAB-PC-4", "x" * (module.REPLY_MAX_LENGTH + 1))
    assert empty.status_code == 400
    assert too_long.status_code == 400


def test_mark_reply_read(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        _heartbeat(client, "LAB-PC-5")
        _post_reply(client, "LAB-PC-5", "siap")
        reply_id = client.get("/api/replies", headers=headers).json()["replies"][0]["id"]

        res = client.post(f"/api/replies/{reply_id}/read", headers=headers)
        assert res.status_code == 200

        after = client.get("/api/replies", headers=headers).json()
    assert after["unread"] == 0
    assert after["replies"][0]["read_at"]


def test_mark_unknown_reply_404(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        res = client.post("/api/replies/99999/read", headers=headers)
    assert res.status_code == 404


def test_unread_filter(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        _heartbeat(client, "LAB-PC-6")
        _post_reply(client, "LAB-PC-6", "pertama")
        _post_reply(client, "LAB-PC-6", "kedua")
        first_id = client.get("/api/replies", headers=headers).json()["replies"][-1]["id"]
        client.post(f"/api/replies/{first_id}/read", headers=headers)

        unread = client.get("/api/replies?unread=true", headers=headers).json()
        read = client.get("/api/replies?unread=false", headers=headers).json()
    assert unread["total"] == 1
    assert unread["replies"][0]["message"] == "kedua"
    assert read["total"] == 1
    assert read["replies"][0]["message"] == "pertama"


@pytest.mark.parametrize("role,read_ok,write_ok", [
    ("super_admin", True, True),
    ("faculty_admin", True, True),
    ("lab_admin", True, True),
    ("instructor", True, False),
    ("viewer", True, False),
    ("auditor", False, False),
])
def test_replies_permissions(monkeypatch, tmp_path, role, read_ok, write_ok):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        _heartbeat(client, "LAB-PC-7")
        _post_reply(client, "LAB-PC-7", "halo admin")
        token = f"test-token-{role}"
        module.ACTIVE_TOKENS[token] = {
            "email": f"{role}@test.org", "expires": datetime.now() + timedelta(hours=8), "role": role,
        }
        headers = {"Authorization": f"Bearer {token}"}
        read = client.get("/api/replies", headers=headers)
        write = client.post("/api/replies/1/read", headers=headers)
    assert (read.status_code == 200) == read_ok, f"{role}: read got {read.status_code}"
    assert (write.status_code == 200) == write_ok, f"{role}: write got {write.status_code}"
