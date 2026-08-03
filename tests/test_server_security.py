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
               allowed_origins="", admin_password=""):
    monkeypatch.setenv("LOGIX_DEV_MODE", dev_mode)
    monkeypatch.setenv("LOGIX_INGEST_API_KEY", ingest_key)
    monkeypatch.setenv("LOGIX_ALLOWED_ORIGINS", allowed_origins)
    monkeypatch.setenv("LOGIX_ADMIN_PASSWORD", admin_password)
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
    res = client.post("/api/auth/dev-login")
    token = res.json()["token"]
    return {"Authorization": f"Bearer {token}"}


# --- Fix #1: local admin auth (email + password) ----------------------------
# Google OAuth was replaced by a self-contained email + password login. The
# password lives in LOGIX_ADMIN_PASSWORD (env / .env, never in source or DB).
# Login is closed unless BOTH the email is on the ADMIN_EMAILS allowlist AND the
# password matches; an unconfigured password in production can never match.

def test_login_closed_in_prod_without_password(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path, dev_mode="0", admin_password="")
    with TestClient(module.app) as client:
        res = client.post("/api/auth/login", json={"email": "admin@example.org", "password": "anything"})
    assert res.status_code == 401
    assert module.ACTIVE_TOKENS == {}  # no backdoor when no password configured


def test_login_succeeds_with_correct_password(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path, dev_mode="0", admin_password="s3cret-pass")
    with TestClient(module.app) as client:
        res = client.post("/api/auth/login", json={"email": "admin@example.org", "password": "s3cret-pass"})
    assert res.status_code == 200
    body = res.json()
    assert body["token"] and body["email"] == "admin@example.org" and body["role"]
    assert len(module.ACTIVE_TOKENS) == 1


def test_login_rejects_wrong_password(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path, dev_mode="0", admin_password="s3cret-pass")
    with TestClient(module.app) as client:
        res = client.post("/api/auth/login", json={"email": "admin@example.org", "password": "nope"})
    assert res.status_code == 401
    assert module.ACTIVE_TOKENS == {}


def test_login_rejects_non_allowlisted_email(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path, dev_mode="0", admin_password="s3cret-pass")
    with TestClient(module.app) as client:
        res = client.post("/api/auth/login", json={"email": "attacker@example.net", "password": "s3cret-pass"})
    assert res.status_code == 401
    assert module.ACTIVE_TOKENS == {}


def test_login_rate_limited_after_repeated_failures(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path, dev_mode="0", admin_password="s3cret-pass")
    with TestClient(module.app) as client:
        for _ in range(module.LOGIN_MAX_FAILURES):
            client.post("/api/auth/login", json={"email": "admin@example.org", "password": "wrong"})
        # Even the correct password is now refused with 429 until the window passes.
        res = client.post("/api/auth/login", json={"email": "admin@example.org", "password": "s3cret-pass"})
    assert res.status_code == 429
    assert module.ACTIVE_TOKENS == {}


def test_dev_login_blocked_outside_dev_mode(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path, dev_mode="0")
    with TestClient(module.app) as client:
        res = client.post("/api/auth/dev-login")
    assert res.status_code == 404
    assert module.ACTIVE_TOKENS == {}


def test_dev_login_works_in_dev_mode(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path, dev_mode="1")
    with TestClient(module.app) as client:
        res = client.post("/api/auth/dev-login")
    assert res.status_code == 200
    assert res.json()["token"]
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

def test_google_oauth_code_removed(monkeypatch, tmp_path):
    # Google OAuth was replaced by local email + password auth. The old
    # endpoints and credential globals must be gone (no dead auth paths), and
    # the password-login replacement must be present.
    module = _load_main(monkeypatch, tmp_path)
    assert not hasattr(module, "google_login")
    assert not hasattr(module, "google_callback")
    assert not hasattr(module, "GOOGLE_CLIENT_ID")
    assert hasattr(module, "LoginRequest")


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


def test_config_read_requires_a_credential(monkeypatch, tmp_path):
    """GET /api/config must not be readable anonymously.

    It has two legitimate callers with different credentials -- the dashboard
    (admin bearer token) and the agent (X-API-Key) -- so it accepts either, but
    an unauthenticated caller gets 401. This endpoint was wide open; nothing
    secret is in the config today, but it describes the lab's setup and is
    exactly the kind of blob that later grows a webhook URL or an SMTP
    password.
    """
    module = _load_main(monkeypatch, tmp_path, dev_mode="1", ingest_key="ingest-secret",
                        admin_password="pw")
    # verify_api_key checks the devices table for a per-device key before
    # falling back to the shared one, so the Control schema has to exist too
    # (devices lives in init_control_tables, not init_db).
    module.init_db()
    module.init_control_tables()
    client = TestClient(module.app)

    assert client.get("/api/config").status_code == 401
    assert client.get("/api/config", headers={"X-API-Key": "wrong"}).status_code == 401

    # Agent credential.
    assert client.get("/api/config", headers={"X-API-Key": "ingest-secret"}).status_code == 200

    # Dashboard credential.
    token = client.post("/api/auth/dev-login").json()["token"]
    assert client.get("/api/config", headers={"Authorization": f"Bearer {token}"}).status_code == 200

    # Writing still needs an admin session specifically -- a device key must
    # never be able to rewrite lab policy.
    assert client.put("/api/config", json={}, headers={"X-API-Key": "ingest-secret"}).status_code == 401
