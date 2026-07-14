"""Tests for roadmap item J: command queue reliability -- DB-wide TTL
expiration (reconcile_expired_actions), manual retry, command_expired
alerts, and restart-safe reconciliation (rehydrate_pending_commands). See
server/main.py's comments on these functions for the design rationale.
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


def _backdate_command(module, command_id, minutes):
    """Simulate a command having sat 'queued' for `minutes` -- backdates the
    DB row's timestamp, the actual source of truth reconcile_expired_actions
    reads (see test_server_command_ack.py's regression fix)."""
    stale = (datetime.now() - timedelta(minutes=minutes)).isoformat()
    conn = module.get_db()
    conn.execute("UPDATE remote_actions SET timestamp = ? WHERE command_id = ?", (stale, command_id))
    conn.commit()
    conn.close()


def _queue_and_backdate(client, module, headers, hostname, minutes):
    client.post("/api/heartbeat", json={"hostname": hostname, "status": "ACTIVE"})
    client.post("/api/control/lock", json={"hostname": hostname}, headers=headers)
    command_id = module.PENDING_COMMANDS[hostname][0]["command_id"]
    _backdate_command(module, command_id, minutes)
    device_id = client.get("/api/devices", headers=headers).json()[0]["device_id"]
    return command_id, device_id


# --- 1 & 2: TTL expiration + exclusion from delivery, via lazy reconcile ---

def test_pending_command_older_than_ttl_becomes_expired_via_alerts_poll(monkeypatch, tmp_path):
    """Expiration must happen even when triggered from GET /api/alerts, not
    only from that specific device's own heartbeat -- this is the gap
    roadmap item J closes (see reconcile_expired_actions's docstring)."""
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        command_id, device_id = _queue_and_backdate(
            client, module, headers, "LAB-PC-01", module.COMMAND_TTL_MINUTES + 1
        )

        client.get("/api/alerts", headers=headers)  # triggers reconcile_expired_actions
        actions = client.get("/api/audit-log", headers=headers).json()["actions"]

    assert actions[0]["command_id"] == command_id
    assert actions[0]["status"] == "expired"
    assert actions[0]["executed_at"]


def test_expired_command_purged_from_pending_commands(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        command_id, _ = _queue_and_backdate(client, module, headers, "LAB-PC-02", module.COMMAND_TTL_MINUTES + 1)
        assert any(c["command_id"] == command_id for c in module.PENDING_COMMANDS["LAB-PC-02"])

        client.get("/api/alerts", headers=headers)

    assert not any(c["command_id"] == command_id for c in module.PENDING_COMMANDS.get("LAB-PC-02", []))


# --- 3 & 4: device detail visibility ---------------------------------------

def test_expired_command_appears_in_device_detail_recent_actions(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        command_id, device_id = _queue_and_backdate(
            client, module, headers, "LAB-PC-03", module.COMMAND_TTL_MINUTES + 1
        )

        detail = client.get(f"/api/devices/{device_id}", headers=headers).json()

    action = next(a for a in detail["recent_actions"] if a["command_id"] == command_id)
    assert action["status"] == "expired"


def test_sync_health_includes_expired_count(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        _, device_id = _queue_and_backdate(client, module, headers, "LAB-PC-04", module.COMMAND_TTL_MINUTES + 1)

        detail = client.get(f"/api/devices/{device_id}", headers=headers).json()

    assert detail["sync_health"]["expired"] == 1
    assert detail["sync_health"]["total"] == 1


# --- 5 & 6: command_expired alert + no duplication --------------------------

def test_expired_command_creates_alert(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        _queue_and_backdate(client, module, headers, "LAB-PC-05", module.COMMAND_TTL_MINUTES + 1)

        res = client.get("/api/alerts?category=command_expired", headers=headers)

    body = res.json()
    assert body["total"] == 1
    assert body["alerts"][0]["severity"] == "warning"
    assert body["alerts"][0]["status"] == "active"


def test_repeated_reconciliation_does_not_duplicate_expired_alerts_or_rows(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        _queue_and_backdate(client, module, headers, "LAB-PC-06", module.COMMAND_TTL_MINUTES + 1)

        client.get("/api/alerts", headers=headers)
        client.get("/api/alerts", headers=headers)
        alerts = client.get("/api/alerts?category=command_expired", headers=headers).json()
        actions = client.get("/api/audit-log", headers=headers).json()

    assert alerts["total"] == 1
    assert actions["total"] == 1  # no duplicate remote_actions row was created


# --- 7, 8, 9: manual retry ---------------------------------------------------

def test_manual_retry_creates_queued_child_action(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        command_id, device_id = _queue_and_backdate(
            client, module, headers, "LAB-PC-07", module.COMMAND_TTL_MINUTES + 1
        )
        client.get("/api/alerts", headers=headers)  # expire it
        original = client.get(f"/api/devices/{device_id}", headers=headers).json()["recent_actions"][0]
        assert original["status"] == "expired"
        assert original["retryable"] is True

        res = client.post(f"/api/devices/{device_id}/actions/{original['action_id']}/retry", headers=headers)
        assert res.status_code == 200
        assert res.json()["retry_count"] == 1

        detail = client.get(f"/api/devices/{device_id}", headers=headers).json()

    statuses = {a["action_id"]: a["status"] for a in detail["recent_actions"]}
    assert statuses[original["action_id"]] == "expired"  # original untouched
    new_row = next(a for a in detail["recent_actions"] if a["retry_of_action_id"] == original["action_id"])
    assert new_row["status"] == "queued"
    assert new_row["retry_count"] == 1
    assert new_row["command_id"] in {c["command_id"] for c in module.PENDING_COMMANDS["LAB-PC-07"]}


def test_retry_exhausted_after_max_retries(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        command_id, device_id = _queue_and_backdate(
            client, module, headers, "LAB-PC-08", module.COMMAND_TTL_MINUTES + 1
        )
        client.get("/api/alerts", headers=headers)
        action_id = client.get(f"/api/devices/{device_id}", headers=headers).json()["recent_actions"][0]["action_id"]

        first = client.post(f"/api/devices/{device_id}/actions/{action_id}/retry", headers=headers)
        assert first.status_code == 200
        # DEFAULT_MAX_RETRIES is 1, so the original (retry_count=0) may retry
        # once; retrying the newly-created retry row (retry_count=1) again
        # must be refused once it reaches max_retries.
        new_action_id = client.get(f"/api/devices/{device_id}", headers=headers).json()["recent_actions"][0]["action_id"]

        client.post("/api/control/lock", json={"hostname": "LAB-PC-08"}, headers=headers)  # noop setup
        _backdate_command(module, first.json()["command_id"], module.COMMAND_TTL_MINUTES + 1)
        client.get("/api/alerts", headers=headers)  # expire the retry too

        second = client.post(f"/api/devices/{device_id}/actions/{new_action_id}/retry", headers=headers)

    assert second.status_code == 400


def test_retry_blocked_for_non_retryable_action_type(monkeypatch, tmp_path):
    """RENAME and REVOKE_API_KEY are synchronous, always 'done' immediately
    -- and REVOKE_API_KEY is explicitly security-sensitive -- neither should
    ever be offered a retry, matching RETRYABLE_ACTION_TYPES."""
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        client.post("/api/heartbeat", json={"hostname": "LAB-PC-09", "status": "ACTIVE"})
        device_id = client.get("/api/devices", headers=headers).json()[0]["device_id"]
        client.put("/api/devices/rename", json={"hostname": "LAB-PC-09", "display_name": "X"}, headers=headers)

        rename_action_id = client.get(f"/api/devices/{device_id}", headers=headers).json()["recent_actions"][0]["action_id"]
        res = client.post(f"/api/devices/{device_id}/actions/{rename_action_id}/retry", headers=headers)

    assert res.status_code == 400


def test_retry_blocked_for_action_not_failed_or_expired(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        client.post("/api/heartbeat", json={"hostname": "LAB-PC-10", "status": "ACTIVE"})
        client.post("/api/control/lock", json={"hostname": "LAB-PC-10"}, headers=headers)
        device_id = client.get("/api/devices", headers=headers).json()[0]["device_id"]
        action_id = client.get(f"/api/devices/{device_id}", headers=headers).json()["recent_actions"][0]["action_id"]

        res = client.post(f"/api/devices/{device_id}/actions/{action_id}/retry", headers=headers)

    assert res.status_code == 400


def test_retry_unknown_action_404(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        client.post("/api/heartbeat", json={"hostname": "LAB-PC-11", "status": "ACTIVE"})
        device_id = client.get("/api/devices", headers=headers).json()[0]["device_id"]

        res = client.post(f"/api/devices/{device_id}/actions/99999/retry", headers=headers)

    assert res.status_code == 404


@pytest.mark.parametrize("role,permitted", [
    ("super_admin", True),
    ("faculty_admin", True),
    ("lab_admin", True),
    ("viewer", False),
    ("instructor", False),
    ("auditor", False),
])
def test_retry_permission_follows_devices_write(monkeypatch, tmp_path, role, permitted):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        boot_headers = _login(client)
        command_id, device_id = _queue_and_backdate(
            client, module, headers=boot_headers, hostname="LAB-PC-12", minutes=module.COMMAND_TTL_MINUTES + 1
        )
        client.get("/api/alerts", headers=boot_headers)
        action_id = client.get(f"/api/devices/{device_id}", headers=boot_headers).json()["recent_actions"][0]["action_id"]

        token = f"test-token-{role}"
        module.ACTIVE_TOKENS[token] = {
            "email": f"{role}@test.org", "expires": datetime.now() + timedelta(hours=8), "role": role,
        }
        res = client.post(
            f"/api/devices/{device_id}/actions/{action_id}/retry",
            headers={"Authorization": f"Bearer {token}"},
        )

    if permitted:
        assert res.status_code == 200, f"{role} should be permitted 'devices_write', got {res.status_code}"
    else:
        assert res.status_code == 403, f"{role} should be forbidden 'devices_write', got {res.status_code}"


# --- 10: restart / reconciliation simulation --------------------------------

def test_rehydrate_restores_deliverable_command_after_simulated_restart(monkeypatch, tmp_path):
    """PENDING_COMMANDS is memory-only and wiped by a real restart; the DB
    row survives. A command queued before the 'restart', still within its
    TTL, must still be delivered on the device's next heartbeat."""
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        client.post("/api/heartbeat", json={"hostname": "LAB-PC-13", "status": "ACTIVE"})
        client.post("/api/control/lock", json={"hostname": "LAB-PC-13"}, headers=headers)
        command_id = module.PENDING_COMMANDS["LAB-PC-13"][0]["command_id"]

        module.PENDING_COMMANDS.clear()  # simulate the in-memory state a restart wipes
        module.rehydrate_pending_commands()

        res = client.post("/api/heartbeat", json={"hostname": "LAB-PC-13", "status": "ACTIVE"})

    delivered = res.json()["commands"]
    assert len(delivered) == 1
    assert delivered[0]["command_id"] == command_id


def test_rehydrate_then_reconcile_expires_a_command_overdue_before_restart(monkeypatch, tmp_path):
    """If the command should already have expired *before* the restart, the
    next reconciliation must mark it expired, not silently redeliver it."""
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        client.post("/api/heartbeat", json={"hostname": "LAB-PC-14", "status": "ACTIVE"})
        client.post("/api/control/lock", json={"hostname": "LAB-PC-14"}, headers=headers)
        command_id = module.PENDING_COMMANDS["LAB-PC-14"][0]["command_id"]
        _backdate_command(module, command_id, module.COMMAND_TTL_MINUTES + 1)

        module.PENDING_COMMANDS.clear()
        module.rehydrate_pending_commands()

        res = client.post("/api/heartbeat", json={"hostname": "LAB-PC-14", "status": "ACTIVE"})
        actions = client.get("/api/audit-log", headers=headers).json()["actions"]

    assert res.json()["commands"] == []
    assert actions[0]["command_id"] == command_id
    assert actions[0]["status"] == "expired"


def test_rehydrate_is_idempotent(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        headers = _login(client)
        client.post("/api/heartbeat", json={"hostname": "LAB-PC-15", "status": "ACTIVE"})
        client.post("/api/control/lock", json={"hostname": "LAB-PC-15"}, headers=headers)

        module.rehydrate_pending_commands()
        module.rehydrate_pending_commands()

    assert len(module.PENDING_COMMANDS["LAB-PC-15"]) == 1
