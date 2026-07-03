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
               allowed_origins="", google_client_id="", google_client_secret=""):
    monkeypatch.setenv("LOGIX_DEV_MODE", dev_mode)
    monkeypatch.setenv("LOGIX_INGEST_API_KEY", ingest_key)
    monkeypatch.setenv("LOGIX_ALLOWED_ORIGINS", allowed_origins)
    monkeypatch.setenv("GOOGLE_CLIENT_ID", google_client_id)
    monkeypatch.setenv("GOOGLE_CLIENT_SECRET", google_client_secret)
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


# --- Google OAuth: real-credential flow --------------------------------------
# The mock-gating tests above cover the no-credential paths; these cover what
# happens once real GOOGLE_CLIENT_ID/SECRET are configured: the outbound
# redirect must carry the right params, and the callback must enforce the
# ADMIN_EMAILS allowlist (Google's endpoints are mocked -- the decision logic
# under test is entirely ours).

def _fake_google(monkeypatch, module, email):
    """Mock urllib so the callback's token exchange + userinfo fetch succeed."""
    import io
    import json as _json

    class FakeResponse(io.BytesIO):
        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

    def fake_urlopen(req, *a, **k):
        url = req.full_url if hasattr(req, "full_url") else str(req)
        if "oauth2.googleapis.com/token" in url:
            return FakeResponse(_json.dumps({"access_token": "fake-access"}).encode())
        if "userinfo" in url:
            return FakeResponse(_json.dumps({"email": email}).encode())
        raise AssertionError(f"unexpected outbound call: {url}")

    monkeypatch.setattr(module.urllib.request, "urlopen", fake_urlopen)


def test_google_login_redirects_to_google_when_configured(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path, dev_mode="0",
                        google_client_id="123-abc.apps.googleusercontent.com",
                        google_client_secret="s3cret")
    with TestClient(module.app) as client:
        res = client.get("/api/auth/google/login", follow_redirects=False)
    assert res.status_code in (302, 307)
    loc = res.headers["location"]
    assert loc.startswith("https://accounts.google.com/o/oauth2/v2/auth?")
    assert "client_id=123-abc.apps.googleusercontent.com" in loc
    assert "response_type=code" in loc
    assert "scope=openid+email+profile" in loc
    assert "redirect_uri=" in loc
    assert module.ACTIVE_TOKENS == {}  # no session minted before Google answers


def test_callback_accepts_allowlisted_email(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path, dev_mode="0",
                        google_client_id="123-abc.apps.googleusercontent.com",
                        google_client_secret="s3cret")
    _fake_google(monkeypatch, module, "admin@example.org")
    with TestClient(module.app) as client:
        res = client.get("/api/auth/callback?code=fake-code", follow_redirects=False)
    assert res.status_code in (302, 307)
    assert "token=" in res.headers["location"]
    assert len(module.ACTIVE_TOKENS) == 1
    session = next(iter(module.ACTIVE_TOKENS.values()))
    assert session["email"] == "admin@example.org"
    assert session["role"]


def test_callback_rejects_non_allowlisted_email(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path, dev_mode="0",
                        google_client_id="123-abc.apps.googleusercontent.com",
                        google_client_secret="s3cret")
    _fake_google(monkeypatch, module, "attacker@example.net")
    with TestClient(module.app) as client:
        res = client.get("/api/auth/callback?code=fake-code", follow_redirects=False)
    assert res.status_code == 403
    assert module.ACTIVE_TOKENS == {}  # no session for a non-allowlisted account


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
