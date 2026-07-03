"""Tests for command_id identity, TTL expiry, and agent-reported execution
outcomes (Logix Control Milestone 3, "command queue hardening"). See
docs/LOGIX_CONTROL.md §6: a 'queued' remote_actions row now progresses to
'done'/'failed' (an ack on a later heartbeat) or 'expired' (TTL elapsed
before delivery) -- this is what makes that transition real.
"""
import importlib
import sys
from datetime import datetime, timedelta

from fastapi.testclient import TestClient


def _load_main(monkeypatch, tmp_path):
    monkeypatch.setenv("LOGIX_DEV_MODE", "1")
    monkeypatch.setenv("LOGIX_INGEST_API_KEY", "dev-test-key")
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


def _heartbeat(client, hostname, acks=None):
    body = {"hostname": hostname, "status": "ACTIVE"}
    if acks is not None:
        body["acks"] = acks
    return client.post("/api/heartbeat", json=body, headers={"X-API-Key": "dev-test-key"})


def test_command_id_present_on_delivery(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        client.post("/api/control/lock", json={"hostname": "LAB-PC-01"}, headers=headers)
        res = _heartbeat(client, "LAB-PC-01")

    cmds = res.json()["commands"]
    assert len(cmds) == 1
    assert cmds[0]["command"] == "LOCK"
    assert cmds[0]["command_id"]


def test_ack_updates_status_and_executed_at(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        client.post("/api/control/lock", json={"hostname": "LAB-PC-02"}, headers=headers)
        delivered = _heartbeat(client, "LAB-PC-02").json()["commands"]
        command_id = delivered[0]["command_id"]

        _heartbeat(client, "LAB-PC-02", acks=[{"command_id": command_id, "status": "done", "detail": "locked"}])
        actions = client.get("/api/audit-log", headers=headers).json()["actions"]

    assert len(actions) == 1
    assert actions[0]["command_id"] == command_id
    assert actions[0]["status"] == "done"
    assert actions[0]["result_summary"] == "locked"
    assert actions[0]["executed_at"]


def test_ack_failed_sets_error_message(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        client.post("/api/control/lock", json={"hostname": "LAB-PC-03"}, headers=headers)
        command_id = _heartbeat(client, "LAB-PC-03").json()["commands"][0]["command_id"]

        _heartbeat(client, "LAB-PC-03", acks=[{"command_id": command_id, "status": "failed", "detail": "access denied"}])
        actions = client.get("/api/audit-log", headers=headers).json()["actions"]

    assert actions[0]["status"] == "failed"
    assert actions[0]["error_message"] == "access denied"


def test_ack_is_idempotent_against_resend(monkeypatch, tmp_path):
    """The agent resends unconfirmed acks at-least-once (see
    windows/logbook_common.ps1's pending_acks.json) -- a repeat ack for an
    already-terminal command_id must be a no-op, not overwrite a later
    correction with a stale duplicate."""
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        client.post("/api/control/lock", json={"hostname": "LAB-PC-04"}, headers=headers)
        command_id = _heartbeat(client, "LAB-PC-04").json()["commands"][0]["command_id"]

        _heartbeat(client, "LAB-PC-04", acks=[{"command_id": command_id, "status": "done", "detail": "locked"}])
        first_actions = client.get("/api/audit-log", headers=headers).json()["actions"]
        first_executed_at = first_actions[0]["executed_at"]

        # Resent ack, and a contradictory one -- neither should change anything.
        _heartbeat(client, "LAB-PC-04", acks=[{"command_id": command_id, "status": "done", "detail": "locked"}])
        _heartbeat(client, "LAB-PC-04", acks=[{"command_id": command_id, "status": "failed", "detail": "late retry"}])
        final_actions = client.get("/api/audit-log", headers=headers).json()["actions"]

    assert len(final_actions) == 1
    assert final_actions[0]["status"] == "done"
    assert final_actions[0]["executed_at"] == first_executed_at


def test_ack_for_unknown_command_id_is_silently_ignored(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        res = _heartbeat(client, "LAB-PC-05", acks=[{"command_id": "does-not-exist", "status": "done", "detail": ""}])
    assert res.status_code == 200
    assert res.json()["status"] == "ok"


def test_malformed_ack_does_not_break_heartbeat(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        res = _heartbeat(client, "LAB-PC-06", acks=[{"status": "bogus"}, {"command_id": "x"}])
    assert res.status_code == 200


def test_expired_command_never_delivered_and_marked_expired(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        client.post("/api/control/lock", json={"hostname": "LAB-PC-07"}, headers=headers)
        command_id = module.PENDING_COMMANDS["LAB-PC-07"][0]["command_id"]

        # Simulate the command having sat in the queue past the TTL.
        stale = (datetime.now() - timedelta(minutes=module.COMMAND_TTL_MINUTES + 1)).isoformat()
        module.PENDING_COMMANDS["LAB-PC-07"][0]["queued_at"] = stale

        res = _heartbeat(client, "LAB-PC-07")
        actions = client.get("/api/audit-log", headers=headers).json()["actions"]

    assert res.json()["commands"] == []  # withheld, not delivered
    assert actions[0]["status"] == "expired"
    assert actions[0]["executed_at"]


def test_fresh_command_still_delivered_within_ttl(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        client.post("/api/control/lock", json={"hostname": "LAB-PC-08"}, headers=headers)
        res = _heartbeat(client, "LAB-PC-08")
    assert len(res.json()["commands"]) == 1


def test_broadcast_all_fan_out_shares_one_command_id(monkeypatch, tmp_path):
    """One admin action, one audit row (existing precedent) -- all fanned-out
    per-device commands must carry that same command_id so any one device's
    ack can resolve the shared row."""
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        _heartbeat(client, "LAB-PC-09")
        _heartbeat(client, "LAB-PC-10")
        client.post("/api/control/broadcast", json={"hostname": "ALL", "param": "hi"}, headers=headers)

        cmd_a = _heartbeat(client, "LAB-PC-09").json()["commands"][0]["command_id"]
        cmd_b = _heartbeat(client, "LAB-PC-10").json()["commands"][0]["command_id"]

    assert cmd_a == cmd_b
