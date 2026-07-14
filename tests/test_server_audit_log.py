"""Tests for the Control audit log retrofit onto /api/control/lock and
/api/control/broadcast (Logix Control, Milestone 2). See
docs/LOGIX_CONTROL.md §6: this proves an admin *queued* a command, not that
the device executed it -- status is 'queued' or 'failed', never 'done'.
"""
import importlib
import sys

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


def test_lock_command_creates_audit_row(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        client.post("/api/control/lock", json={"hostname": "LAB-PC-01", "reason": "end of shift"}, headers=headers)
        res = client.get("/api/audit-log", headers=headers)

    actions = res.json()["actions"]
    assert len(actions) == 1
    a = actions[0]
    assert a["actor_email"] == "admin@example.org"
    assert a["target_device"] == "LAB-PC-01"
    assert a["action_type"] == "LOCK"
    assert a["status"] == "queued"
    assert a["reason"] == "end of shift"


def test_broadcast_to_specific_host_creates_one_row(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        client.post("/api/control/broadcast", json={"hostname": "LAB-PC-02", "param": "hello"}, headers=headers)
        res = client.get("/api/audit-log", headers=headers)

    actions = res.json()["actions"]
    assert len(actions) == 1
    assert actions[0]["target_device"] == "LAB-PC-02"
    assert actions[0]["action_type"] == "BROADCAST"
    assert actions[0]["param"] == "hello"


def test_broadcast_to_all_creates_exactly_one_row(monkeypatch, tmp_path):
    """An admin took one action; the audit log should reflect one action,
    not fan out into one row per device that happened to be online."""
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        client.post("/api/heartbeat", json={"hostname": "LAB-PC-03", "status": "ACTIVE"})
        client.post("/api/heartbeat", json={"hostname": "LAB-PC-04", "status": "ACTIVE"})
        client.post("/api/control/broadcast", json={"hostname": "ALL", "param": "attention"}, headers=headers)
        res = client.get("/api/audit-log", headers=headers)

    actions = res.json()["actions"]
    assert len(actions) == 1
    assert actions[0]["target_device"] == "ALL"


def test_audit_log_requires_auth(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        res = client.get("/api/audit-log")
    assert res.status_code == 401


def test_audit_log_ordered_newest_first(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        client.post("/api/control/lock", json={"hostname": "PC-A"}, headers=headers)
        client.post("/api/control/lock", json={"hostname": "PC-B"}, headers=headers)
        res = client.get("/api/audit-log", headers=headers)

    actions = res.json()["actions"]
    assert len(actions) == 2
    assert actions[0]["target_device"] == "PC-B"  # most recent first
    assert actions[1]["target_device"] == "PC-A"


def test_audit_log_failure_does_not_block_the_real_command(monkeypatch, tmp_path):
    """A DB failure while writing the audit row must never prevent the
    actual lock command from being queued -- that already happened before
    the audit-log call is even attempted."""
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        # Make log_remote_action fail deterministically without touching the
        # real command-queueing path above it.
        module.log_remote_action = lambda *a, **kw: (_ for _ in ()).throw(RuntimeError("boom"))
        res = client.post("/api/control/lock", json={"hostname": "LAB-PC-05"}, headers=headers)

    assert res.status_code == 200
    assert res.json()["status"] == "success"
    assert "LAB-PC-05" in module.PENDING_COMMANDS
    queued = module.PENDING_COMMANDS["LAB-PC-05"]
    assert len(queued) == 1
    assert queued[0]["command"] == "LOCK"
    assert queued[0]["param"] == ""
    assert queued[0]["command_id"]  # a uuid was assigned
