"""Tests for GET /api/conversations: one admin<->device thread per device,
assembled from the BROADCAST rows in remote_actions (admin -> device) and
device_replies (device -> admin). See server/main.py's comment above
get_conversations for why this exists alongside GET /api/replies.
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
    token = client.post("/api/auth/dev-login").json()["token"]
    return {"Authorization": f"Bearer {token}"}


def _heartbeat(client, hostname, acks=None):
    body = {"hostname": hostname, "status": "ACTIVE"}
    if acks is not None:
        body["acks"] = acks
    return client.post("/api/heartbeat", json=body, headers={"X-API-Key": API_KEY})


def _reply(client, hostname, message, command_id="", key=API_KEY):
    return client.post(
        "/api/replies",
        json={"hostname": hostname, "message": message, "command_id": command_id},
        headers={"X-API-Key": key},
    )


def _send(client, headers, hostname, text):
    res = client.post("/api/control/broadcast",
                      json={"hostname": hostname, "param": text, "reason": "Direction Message"},
                      headers=headers)
    assert res.status_code == 200, res.text


def _conversations(client, headers):
    res = client.get("/api/conversations", headers=headers)
    assert res.status_code == 200, res.text
    return res.json()


def test_a_back_and_forth_reads_as_one_thread_in_order(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        _heartbeat(client, "LAB-PC-1")
        _send(client, headers, "LAB-PC-1", "Tolong simpan pekerjaanmu")
        command_id = _heartbeat(client, "LAB-PC-1").json()["commands"][0]["command_id"]
        _reply(client, "LAB-PC-1", "Butuh 10 mnt", command_id)
        _send(client, headers, "LAB-PC-1", "Oke, ditunggu")
        _reply(client, "LAB-PC-1", "Sudah, terima kasih", "")

        body = _conversations(client, headers)

    assert len(body["threads"]) == 1
    thread = body["threads"][0]
    assert thread["hostname"] == "LAB-PC-1"
    assert [(m["direction"], m["text"]) for m in thread["messages"]] == [
        ("out", "Tolong simpan pekerjaanmu"),
        ("in", "Butuh 10 mnt"),
        ("out", "Oke, ditunggu"),
        ("in", "Sudah, terima kasih"),
    ]
    assert thread["unread"] == 2
    assert body["unread"] == 2
    assert thread["last_at"] == thread["messages"][-1]["at"]


def test_an_admin_message_carries_its_delivery_status(monkeypatch, tmp_path):
    """'queued' until the device's ack arrives, then 'done' -- what the
    dashboard shows as terkirim vs. menunggu."""
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        _heartbeat(client, "LAB-PC-2")
        _send(client, headers, "LAB-PC-2", "Halo")
        queued = _conversations(client, headers)["threads"][0]["messages"][0]

        command_id = _heartbeat(client, "LAB-PC-2").json()["commands"][0]["command_id"]
        _heartbeat(client, "LAB-PC-2", acks=[{"command_id": command_id, "status": "done",
                                              "detail": "delivered to device inbox"}])
        delivered = _conversations(client, headers)["threads"][0]["messages"][0]

    assert queued["status"] == "queued"
    assert queued["actor"] == "admin@example.org"
    assert delivered["status"] == "done"
    assert delivered["to_all"] is False


def test_a_message_with_no_reply_yet_still_opens_a_thread(monkeypatch, tmp_path):
    """The admin must be able to see what they sent before anyone answers --
    the old inbox only existed once a reply did."""
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        _heartbeat(client, "LAB-PC-3")
        _send(client, headers, "LAB-PC-3", "Ada yang bisa dibantu?")
        body = _conversations(client, headers)

    assert [t["hostname"] for t in body["threads"]] == ["LAB-PC-3"]
    assert body["threads"][0]["unread"] == 0


def test_answer_to_an_all_broadcast_brings_its_question_into_that_thread_only(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        _heartbeat(client, "LAB-PC-4")
        _heartbeat(client, "LAB-PC-5")
        client.post("/api/control/broadcast",
                    json={"hostname": "ALL", "param": "Lab tutup jam 16:00", "reason": "Emergency Alert"},
                    headers=headers)
        command_id = _heartbeat(client, "LAB-PC-4").json()["commands"][0]["command_id"]
        _heartbeat(client, "LAB-PC-5")
        _reply(client, "LAB-PC-4", "Siap", command_id)

        body = _conversations(client, headers)

    assert [t["hostname"] for t in body["threads"]] == ["LAB-PC-4"], \
        "a device that did not answer the ALL broadcast gets no thread for it"
    question, answer = body["threads"][0]["messages"]
    assert question["direction"] == "out" and question["text"] == "Lab tutup jam 16:00"
    assert question["to_all"] is True
    # One shared audit row for the whole fan-out -- not this device's status.
    assert question["status"] is None
    assert answer["text"] == "Siap"


def test_hostname_case_does_not_split_a_thread(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        _heartbeat(client, "LAB-PC-6")
        _send(client, headers, "lab-pc-6", "Halo")
        _reply(client, "LAB-PC-6", "Ya?")
        body = _conversations(client, headers)

    assert len(body["threads"]) == 1
    assert len(body["threads"][0]["messages"]) == 2


def test_reading_a_reply_clears_it_from_unread(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        _heartbeat(client, "LAB-PC-7")
        _reply(client, "LAB-PC-7", "Monitor kedua mati")
        reply_id = _conversations(client, headers)["threads"][0]["messages"][0]["reply_id"]
        client.post(f"/api/replies/{reply_id}/read", headers=headers)
        body = _conversations(client, headers)

    assert body["unread"] == 0
    assert body["threads"][0]["messages"][0]["read_at"]


def test_unread_threads_sort_before_more_recent_read_ones(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        _heartbeat(client, "LAB-PC-8")
        _heartbeat(client, "LAB-PC-9")
        _reply(client, "LAB-PC-8", "Tolong bantu")
        _send(client, headers, "LAB-PC-9", "Pesan terbaru, sudah tidak ada yang belum dibaca")
        body = _conversations(client, headers)

    assert [t["hostname"] for t in body["threads"]] == ["LAB-PC-8", "LAB-PC-9"]


def test_a_deleted_device_has_no_thread(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        _heartbeat(client, "LAB-PC-10")
        _send(client, headers, "LAB-PC-10", "Halo")
        device_id = client.get("/api/devices", headers=headers).json()[0]["device_id"]
        res = client.delete(f"/api/devices/{device_id}", headers=headers)
        assert res.status_code == 200, res.text
        body = _conversations(client, headers)

    assert body["threads"] == []


def test_thread_is_trimmed_to_the_most_recent_messages(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    monkeypatch.setattr(module, "CONVERSATION_MESSAGES_PER_THREAD", 3)
    with TestClient(module.app) as client:
        headers = _login(client)
        _heartbeat(client, "LAB-PC-11")
        for i in range(5):
            _reply(client, "LAB-PC-11", f"pesan {i}")
        messages = _conversations(client, headers)["threads"][0]["messages"]

    assert [m["text"] for m in messages] == ["pesan 2", "pesan 3", "pesan 4"]


@pytest.mark.parametrize("role,permitted", [
    ("instructor", True),
    ("viewer", True),
    ("auditor", False),
])
def test_conversations_follow_replies_read(monkeypatch, tmp_path, role, permitted):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        token = f"test-token-{role}"
        module.ACTIVE_TOKENS[token] = {
            "email": f"{role}@test.org", "expires": datetime.now() + timedelta(hours=8), "role": role,
        }
        res = client.get("/api/conversations", headers={"Authorization": f"Bearer {token}"})

    assert res.status_code == (200 if permitted else 403)


# --- POST /api/replies device scope -----------------------------------------

def _enrol(client, headers, hostname):
    invite = client.post("/api/enroll/invite", headers=headers, json={
        "category": "lab_workstation", "display_name": hostname, "hostname": hostname,
    })
    assert invite.status_code in (200, 201), invite.text
    res = client.post("/api/enroll", json={
        "invite_code": invite.json()["invite_code"], "hostname": hostname, "os": "windows",
        "agent_version": "1.2.1",
    })
    assert res.status_code in (200, 201), res.text
    return res.json()["api_key"]


def test_a_device_key_cannot_reply_as_another_device(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        key_1 = _enrol(client, headers, "WS-01")
        _enrol(client, headers, "WS-02")

        forged = _reply(client, "WS-02", "bukan saya yang nulis", key=key_1)
        own = _reply(client, "WS-01", "ini dari WS-01", key=key_1)
        body = _conversations(client, headers)

    assert forged.status_code == 403
    assert own.status_code == 200, own.text
    assert [t["hostname"] for t in body["threads"]] == ["WS-01"]
