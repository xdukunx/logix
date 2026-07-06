"""Tests for the policy-profile and command-allowlist data model (Logix
Control, Milestone 2). Data only -- nothing in server/main.py reads or
enforces this yet. See docs/LOGIX_CONTROL.md §5.
"""
import importlib
import json
import sys

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


def test_seeds_exactly_seven_policy_profiles(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app):
        conn = module.get_db()
        try:
            rows = conn.execute("SELECT * FROM device_policies").fetchall()
        finally:
            conn.close()

    names = {r["policy_name"] for r in rows}
    assert names == {
        "strict_privacy", "lab_standard", "exam_mode", "instructor_demo",
        "office_device", "loaned_laptop", "server_monitoring",
    }
    for r in rows:
        assert r["is_system_default"] == 1
        caps = json.loads(r["allowed_capabilities"])
        assert isinstance(caps, list) and len(caps) > 0


def test_seeds_allowlist_rows_mirroring_policy_command_rules(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app):
        conn = module.get_db()
        try:
            rows = conn.execute("SELECT * FROM command_allowlist").fetchall()
        finally:
            conn.close()

    assert len(rows) == 42  # 7 policies x 6 commands
    # Every (policy, command) row must carry exactly the (allowed,
    # requires_reason) pair from POLICY_COMMAND_RULES -- including the
    # privacy-first profiles where SCREENSHOT/power commands are NOT allowed.
    seeded = {
        (r["policy_name"], r["command_type"]): (r["allowed"], r["requires_reason"])
        for r in rows
    }
    expected = {
        (policy, command): rule
        for policy, commands in module.POLICY_COMMAND_RULES.items()
        for command, rule in commands.items()
    }
    assert seeded == expected


def test_reseeding_on_restart_is_idempotent(monkeypatch, tmp_path):
    """startup_event() runs on every process start -- re-running
    init_control_tables() must not duplicate or clobber seeded rows."""
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app):
        pass  # first startup

    module.init_control_tables()  # simulate a second startup against the same DB
    module.init_control_tables()  # and a third, for good measure

    conn = module.get_db()
    try:
        policy_count = conn.execute("SELECT COUNT(*) FROM device_policies").fetchone()[0]
        allowlist_count = conn.execute("SELECT COUNT(*) FROM command_allowlist").fetchone()[0]
    finally:
        conn.close()

    assert policy_count == 7
    assert allowlist_count == 42


def test_allowlist_references_only_existing_policies(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app):
        conn = module.get_db()
        try:
            policy_names = {r["policy_name"] for r in conn.execute("SELECT policy_name FROM device_policies")}
            allowlist_policy_names = {r["policy_name"] for r in conn.execute("SELECT DISTINCT policy_name FROM command_allowlist")}
        finally:
            conn.close()

    assert allowlist_policy_names.issubset(policy_names)
