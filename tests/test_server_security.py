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


def _load_main(monkeypatch, tmp_path, *, dev_mode="0", ingest_key="test-ingest-key",
               allowed_origins="", admin_password="test-admin-password"):
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
    """No password configured in production is now caught before serving.

    This used to assert that login merely returned 401. The preflight makes
    that stronger: the server refuses to start at all, so an operator finds
    out immediately instead of discovering a permanently-locked dashboard.
    The underlying "empty password can never match" property is asserted
    directly below, so the no-backdoor guarantee is still covered even if the
    preflight were ever bypassed.
    """
    module = _load_main(monkeypatch, tmp_path, dev_mode="0", admin_password="")
    with pytest.raises(module.InsecureConfiguration, match="LOGIX_ADMIN_PASSWORD"):
        module.assert_safe_posture()
    assert module.ADMIN_PASSWORD == ""
    assert module.ACTIVE_TOKENS == {}


def test_short_admin_password_refuses_to_start(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path, dev_mode="0", admin_password="short")
    with pytest.raises(module.InsecureConfiguration, match="at least 12"):
        module.assert_safe_posture()


def test_dev_mode_warns_but_starts(monkeypatch, tmp_path):
    """Dev mode is how you develop, so it must not be fatal -- but it must be
    impossible to leave on without a warning, since it enables passwordless
    login and can bypass ingest auth."""
    module = _load_main(monkeypatch, tmp_path, dev_mode="1", admin_password="", ingest_key="")
    warnings = module.assert_safe_posture()
    assert any("LOGIX_DEV_MODE" in w for w in warnings)


def test_login_succeeds_with_correct_password(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path, dev_mode="0", admin_password="s3cret-pass-long")
    with TestClient(module.app) as client:
        res = client.post("/api/auth/login", json={"email": "admin@example.org", "password": "s3cret-pass-long"})
    assert res.status_code == 200
    body = res.json()
    assert body["token"] and body["email"] == "admin@example.org" and body["role"]
    assert len(module.ACTIVE_TOKENS) == 1


def test_login_rejects_wrong_password(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path, dev_mode="0", admin_password="s3cret-pass-long")
    with TestClient(module.app) as client:
        res = client.post("/api/auth/login", json={"email": "admin@example.org", "password": "nope"})
    assert res.status_code == 401
    assert module.ACTIVE_TOKENS == {}


def test_login_rejects_non_allowlisted_email(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path, dev_mode="0", admin_password="s3cret-pass-long")
    with TestClient(module.app) as client:
        res = client.post("/api/auth/login", json={"email": "attacker@example.net", "password": "s3cret-pass-long"})
    assert res.status_code == 401
    assert module.ACTIVE_TOKENS == {}


def test_login_rate_limited_after_repeated_failures(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path, dev_mode="0", admin_password="s3cret-pass-long")
    with TestClient(module.app) as client:
        for _ in range(module.LOGIN_MAX_FAILURES):
            client.post("/api/auth/login", json={"email": "admin@example.org", "password": "wrong"})
        # Even the correct password is now refused with 429 until the window passes.
        res = client.post("/api/auth/login", json={"email": "admin@example.org", "password": "s3cret-pass-long"})
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
    # Starting like this is refused outright now; the 503 below is the
    # belt-and-braces runtime behaviour if the preflight is ever bypassed.
    with pytest.raises(module.InsecureConfiguration, match="LOGIX_INGEST_API_KEY"):
        module.assert_safe_posture()
    # The dependency is exercised directly rather than through TestClient,
    # because starting the app in this posture is exactly what is now refused.
    with pytest.raises(module.HTTPException) as exc:
        module.verify_api_key(x_api_key=None)
    assert exc.value.status_code == 503


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


# --- Device-key-only posture + hostname-pinned enrolment --------------------

def _enrol(client, headers, hostname, pin=None):
    body = {"category": "lab_workstation", "display_name": hostname}
    if pin is not None:
        body["hostname"] = pin
    code = client.post("/api/enroll/invite", json=body, headers=headers).json()["invite_code"]
    return client.post("/api/enroll", json={"invite_code": code, "hostname": hostname})


def test_require_device_key_rejects_the_shared_key(monkeypatch, tmp_path):
    """Once every device holds its own key, the shared bootstrap key must stop
    working -- otherwise leaking LOGIX_INGEST_API_KEY still lets anything post
    as a device forever."""
    monkeypatch.setenv("LOGIX_REQUIRE_DEVICE_KEY", "1")
    module = _load_main(monkeypatch, tmp_path, dev_mode="1", ingest_key="shared-key")
    with TestClient(module.app) as client:
        headers = _login(client)
        res = _enrol(client, headers, "WS-01")
        device_key = res.json()["api_key"]

        beat = lambda k: client.post(
            "/api/heartbeat", json={"hostname": "WS-01", "status": "ACTIVE"}, headers={"X-API-Key": k}
        ).status_code

        assert beat("shared-key") == 401       # the shared key is now inert
        assert beat(device_key) == 200         # a real handshake still works
    monkeypatch.delenv("LOGIX_REQUIRE_DEVICE_KEY", raising=False)


def test_shared_key_still_works_when_not_in_strict_mode(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path, dev_mode="0", ingest_key="shared-key-123")
    with TestClient(module.app) as client:
        res = client.post(
            "/api/heartbeat",
            json={"hostname": "WS-01", "status": "ACTIVE"},
            headers={"X-API-Key": "shared-key-123"},
        )
    assert res.status_code == 200


def test_invite_pinned_to_a_hostname_rejects_other_machines(monkeypatch, tmp_path):
    """A code read off an admin's screen must not enrol some other box."""
    module = _load_main(monkeypatch, tmp_path, dev_mode="1")
    with TestClient(module.app) as client:
        headers = _login(client)
        code = client.post(
            "/api/enroll/invite",
            json={"category": "lab_workstation", "display_name": "WS-07", "hostname": "WS-07"},
            headers=headers,
        ).json()["invite_code"]

        wrong = client.post("/api/enroll", json={"invite_code": code, "hostname": "ATTACKER-PC"})
        assert wrong.status_code == 400
        # Same generic message as an unknown code -- must not confirm which
        # hostnames an admin has registered.
        assert "Invalid" in wrong.json()["detail"]

        right = client.post("/api/enroll", json={"invite_code": code, "hostname": "WS-07"})
        assert right.status_code == 200
        assert right.json()["api_key"]


def test_unpinned_invite_still_accepts_any_hostname(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path, dev_mode="1")
    with TestClient(module.app) as client:
        headers = _login(client)
        assert _enrol(client, headers, "ANY-PC").status_code == 200
