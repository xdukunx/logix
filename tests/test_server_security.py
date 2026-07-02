"""Smoke tests for the server/main.py hardening pass (Batch 2).

Covers: auth-bypass gate behind LOGIX_DEV_MODE, ingest X-API-Key enforcement,
CORS origin allowlist, and the /api/reports path fix. The server reads its
config from module-level globals at import time, so each test reloads the
module after setting env vars via monkeypatch, then repoints DB_PATH /
CONFIG_PATH / REPORTS_DIR at a tmp_path so nothing touches real server files.
"""
import importlib
import sys

import pytest
from fastapi.testclient import TestClient


def _load_main(monkeypatch, tmp_path, *, dev_mode="0", ingest_key="",
               allowed_origins="", google_client_id=""):
    monkeypatch.setenv("LOGIX_DEV_MODE", dev_mode)
    monkeypatch.setenv("LOGIX_INGEST_API_KEY", ingest_key)
    monkeypatch.setenv("LOGIX_ALLOWED_ORIGINS", allowed_origins)
    monkeypatch.setenv("GOOGLE_CLIENT_ID", google_client_id)
    monkeypatch.setenv("GOOGLE_CLIENT_SECRET", "")
    monkeypatch.setenv("ADMIN_EMAILS", "admin@example.org")

    if "main" in sys.modules:
        module = importlib.reload(sys.modules["main"])
    else:
        module = importlib.import_module("main")

    # Redirect all filesystem side effects into tmp_path.
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


# --- Fix #1: auth-bypass gate ------------------------------------------------

def test_google_login_mock_blocked_outside_dev_mode(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path, dev_mode="0", google_client_id="")
    with TestClient(module.app) as client:
        res = client.get("/api/auth/google/login", follow_redirects=False)
    assert res.status_code == 503
    assert module.ACTIVE_TOKENS == {}


def test_google_login_mock_allowed_in_dev_mode(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path, dev_mode="1", google_client_id="")
    with TestClient(module.app) as client:
        res = client.get("/api/auth/google/login", follow_redirects=False)
    assert res.status_code in (302, 307)
    assert "token=" in res.headers["location"]
    assert len(module.ACTIVE_TOKENS) == 1


# --- Fix #2: ingest API key validation --------------------------------------

def test_heartbeat_rejects_when_key_unconfigured_in_prod(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path, dev_mode="0", ingest_key="")
    with TestClient(module.app) as client:
        res = client.post("/api/heartbeat", json={"hostname": "pc1", "status": "ACTIVE"})
    assert res.status_code == 503


def test_heartbeat_rejects_missing_key(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path, dev_mode="0", ingest_key="secret123")
    with TestClient(module.app) as client:
        res = client.post("/api/heartbeat", json={"hostname": "pc1", "status": "ACTIVE"})
    assert res.status_code == 401


def test_heartbeat_rejects_wrong_key(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path, dev_mode="0", ingest_key="secret123")
    with TestClient(module.app) as client:
        res = client.post(
            "/api/heartbeat",
            json={"hostname": "pc1", "status": "ACTIVE"},
            headers={"X-API-Key": "wrong"},
        )
    assert res.status_code == 401


def test_heartbeat_accepts_correct_key(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path, dev_mode="0", ingest_key="secret123")
    with TestClient(module.app) as client:
        res = client.post(
            "/api/heartbeat",
            json={"hostname": "pc1", "status": "ACTIVE"},
            headers={"X-API-Key": "secret123"},
        )
    assert res.status_code == 200
    assert "pc1" in module.HEARTBEATS


def test_heartbeat_allows_missing_key_in_dev_mode(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path, dev_mode="1", ingest_key="")
    with TestClient(module.app) as client:
        res = client.post("/api/heartbeat", json={"hostname": "pc1", "status": "ACTIVE"})
    assert res.status_code == 200


def test_log_endpoint_requires_api_key(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path, dev_mode="0", ingest_key="secret123")
    with TestClient(module.app) as client:
        res = client.post("/api/log", json=[{"timestamp": "2026-01-01T00:00:00", "event": "START"}])
    assert res.status_code == 401


# --- Fix #4: CORS allowlist --------------------------------------------------

def test_cors_rejects_unlisted_origin_in_prod(monkeypatch, tmp_path):
    module = _load_main(
        monkeypatch, tmp_path, dev_mode="0", allowed_origins="https://logix.example.org"
    )
    with TestClient(module.app) as client:
        res = client.get("/api/config", headers={"Origin": "https://evil.example.com"})
    assert "access-control-allow-origin" not in {k.lower() for k in res.headers}


def test_cors_allows_configured_origin_in_prod(monkeypatch, tmp_path):
    module = _load_main(
        monkeypatch, tmp_path, dev_mode="0", allowed_origins="https://logix.example.org"
    )
    with TestClient(module.app) as client:
        res = client.get("/api/config", headers={"Origin": "https://logix.example.org"})
    assert res.headers.get("access-control-allow-origin") == "https://logix.example.org"


def test_cors_is_not_wildcard_with_credentials_in_prod(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path, dev_mode="0", allowed_origins="https://a.example.org")
    assert "*" not in module._cors_origins


# --- Fix #5: dead code removed -----------------------------------------------

def test_dead_login_code_removed(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    assert not hasattr(module, "LoginRequest")
    assert not hasattr(module, "get_admin_password")


# --- Fix #7: /api/reports path ----------------------------------------------

def test_report_script_path_exists_on_disk(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    script = module.BASE_DIR.parent / "logix" / "logbook_report.py"
    assert script.exists(), f"expected report script at {script}"


# --- Report date-range params (dashboard redesign) --------------------------

def test_reports_rejects_malformed_date(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path, dev_mode="1")
    with TestClient(module.app) as client:
        headers = _login(client)
        res = client.get("/api/reports", params={"start_date": "not-a-date"}, headers=headers)
    assert res.status_code == 400


def test_reports_requires_auth(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path)
    with TestClient(module.app) as client:
        res = client.get("/api/reports")
    assert res.status_code == 401
