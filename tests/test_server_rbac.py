"""Tests for the RBAC permission model (Logix Control Milestone 3). See
docs/LOGIX_CONTROL.md §4 for the role table this implements. Permissions
only -- no faculty/lab/room scope enforcement (see server/main.py's
ROLE_PERMISSIONS comment for why that's explicitly out of scope).
"""
import importlib
import sys
from datetime import datetime, timedelta

import pytest
from fastapi.testclient import TestClient


def _load_main(monkeypatch, tmp_path, *, admin_emails="admin@example.org"):
    monkeypatch.setenv("LOGIX_DEV_MODE", "1")
    monkeypatch.setenv("LOGIX_INGEST_API_KEY", "shared-dev-key")
    monkeypatch.setenv("LOGIX_ALLOWED_ORIGINS", "")
    monkeypatch.setenv("GOOGLE_CLIENT_ID", "")
    monkeypatch.setenv("GOOGLE_CLIENT_SECRET", "")
    monkeypatch.setenv("ADMIN_EMAILS", admin_emails)

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
    res = client.post("/api/auth/dev-login")
    token = res.json()["token"]
    return {"Authorization": f"Bearer {token}"}


# --- ADMIN_EMAILS backward compatibility ------------------------------------
# The single most important test here: every live deployment's flat
# comma-separated email list must keep working exactly as before.

def test_bare_email_defaults_to_super_admin(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path, admin_emails="admin@example.org")
    roles = module.get_admin_roles()
    assert roles == {"admin@example.org": "super_admin"}


def test_multiple_bare_emails_all_super_admin(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path, admin_emails="a@x.org, b@x.org ,c@x.org")
    roles = module.get_admin_roles()
    assert roles == {"a@x.org": "super_admin", "b@x.org": "super_admin", "c@x.org": "super_admin"}


def test_get_allowed_admins_unchanged_for_existing_callers(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path, admin_emails="a@x.org,b@x.org")
    assert module.get_allowed_admins() == ["a@x.org", "b@x.org"]


def test_email_role_pair_parsing(monkeypatch, tmp_path):
    module = _load_main(
        monkeypatch, tmp_path,
        admin_emails="super@x.org:super_admin, viewer@x.org:viewer,Auditor@X.org:AUDITOR",
    )
    roles = module.get_admin_roles()
    assert roles == {
        "super@x.org": "super_admin",
        "viewer@x.org": "viewer",
        "auditor@x.org": "auditor",
    }


def test_malformed_role_suffix_fails_fast(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path, admin_emails="a@x.org:not_a_real_role")
    with pytest.raises(RuntimeError):
        module.get_admin_roles()


def test_bare_email_logs_in_as_before(monkeypatch, tmp_path):
    """Backward-compat regression: a bare ADMIN_EMAILS entry (no :role) must
    still authenticate successfully via the dev-mode mock login."""
    module = _load_main(monkeypatch, tmp_path, admin_emails="admin@example.org")
    with TestClient(module.app) as client:
        headers = _login(client)
        res = client.get("/api/auth/verify", headers=headers)
    assert res.status_code == 200
    assert res.json()["email"] == "admin@example.org"


def test_session_role_assigned_at_mock_login(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path, admin_emails="viewer@x.org:viewer")
    with TestClient(module.app) as client:
        headers = _login(client)
    token = headers["Authorization"].split("Bearer ")[1]
    assert module.ACTIVE_TOKENS[token]["role"] == "viewer"


# --- verify_token's external contract is unchanged --------------------------

def test_verify_token_endpoints_ignore_role(monkeypatch, tmp_path):
    """/api/auth/verify and /api/active only need identity, not a specific
    permission -- any role, including the most restricted, must reach them."""
    module = _load_main(monkeypatch, tmp_path, admin_emails="auditor@x.org:auditor")
    with TestClient(module.app) as client:
        headers = _login(client)
        verify_res = client.get("/api/auth/verify", headers=headers)
        active_res = client.get("/api/active", headers=headers)
    assert verify_res.status_code == 200
    assert active_res.status_code == 200


# --- Fail closed on an unrecognized role ------------------------------------

def test_unknown_role_fails_closed_not_500(monkeypatch, tmp_path):
    module = _load_main(monkeypatch, tmp_path, admin_emails="admin@example.org")
    with TestClient(module.app) as client:
        headers = _login(client)
        token = headers["Authorization"].split("Bearer ")[1]
        # Simulate a role that existed once but was removed/renamed.
        module.ACTIVE_TOKENS[token]["role"] = "ghost_role"
        res = client.get("/api/devices", headers=headers)
    assert res.status_code == 403


# --- Permission matrix -------------------------------------------------------
# One row per (role, permission) pair from docs/LOGIX_CONTROL.md §4. Each
# case hits one representative endpoint gated by that permission and
# confirms the call is let through (not 403) or rejected (403) accordingly.

ROLE_PERMISSIONS_UNDER_TEST = {
    "super_admin": {
        "config_write", "devices_read", "lock", "broadcast", "sessions_read",
        "audit_log_read", "analytics_read", "reports_read", "invite_create",
    },
    "faculty_admin": {
        "devices_read", "lock", "broadcast", "sessions_read",
        "audit_log_read", "analytics_read", "reports_read", "invite_create",
    },
    "lab_admin": {
        "devices_read", "lock", "broadcast", "sessions_read",
        "audit_log_read", "analytics_read", "reports_read", "invite_create",
    },
    "instructor": {"lock", "broadcast"},
    "viewer": {"devices_read", "sessions_read", "audit_log_read", "analytics_read", "reports_read"},
    "auditor": {"audit_log_read", "reports_read"},
}

# permission -> (method, path, kwargs) for a representative endpoint. Chosen
# so a permitted call never returns 403/401/404 for reasons unrelated to
# RBAC (e.g. /api/reports uses a malformed date to short-circuit before
# spawning the report subprocess; a permitted role still reaches that 400).
ENDPOINTS_BY_PERMISSION = {
    "config_write": ("put", "/api/config", {"json": {}}, 200),
    "devices_read": ("get", "/api/devices", {}, 200),
    "lock": ("post", "/api/control/lock", {"json": {"hostname": "LAB-PC-1"}}, 200),
    "broadcast": ("post", "/api/control/broadcast", {"json": {"hostname": "LAB-PC-1"}}, 200),
    "sessions_read": ("get", "/api/sessions", {}, 200),
    "audit_log_read": ("get", "/api/audit-log", {}, 200),
    "analytics_read": ("get", "/api/analytics", {}, 200),
    "reports_read": ("get", "/api/reports", {"params": {"start_date": "not-a-date"}}, 400),
    "invite_create": ("post", "/api/enroll/invite", {"json": {"category": "custom"}}, 201),
}

_MATRIX_CASES = [
    (role, permission)
    for role in ROLE_PERMISSIONS_UNDER_TEST
    for permission in ENDPOINTS_BY_PERMISSION
]


@pytest.mark.parametrize("role,permission", _MATRIX_CASES)
def test_permission_matrix(monkeypatch, tmp_path, role, permission):
    email = f"{role}@test.org"
    module = _load_main(monkeypatch, tmp_path, admin_emails=f"{email}:{role}")
    method, path, kwargs, expect_ok_status = ENDPOINTS_BY_PERMISSION[permission]
    with TestClient(module.app) as client:
        headers = _login(client)
        res = getattr(client, method)(path, headers=headers, **kwargs)

    permitted = permission in ROLE_PERMISSIONS_UNDER_TEST[role]
    if permitted:
        assert res.status_code == expect_ok_status, (
            f"{role} should be permitted '{permission}' on {method.upper()} {path}, got {res.status_code}"
        )
    else:
        assert res.status_code == 403, (
            f"{role} should be forbidden '{permission}' on {method.upper()} {path}, got {res.status_code}"
        )


# --- devices_revoke (needs a pre-enrolled device, tested separately) --------

@pytest.mark.parametrize("role", list(ROLE_PERMISSIONS_UNDER_TEST))
def test_devices_revoke_permission(monkeypatch, tmp_path, role):
    permitted = role in ("super_admin", "faculty_admin", "lab_admin")
    # A super_admin bootstrap account sets up the fixture device (roles
    # without invite_create can't create their own invite); the role under
    # test then gets its own session seeded directly into ACTIVE_TOKENS --
    # the dev-mode mock login only ever authenticates as ADMIN_EMAILS[0],
    # so this is the reliable way to test a second, non-first role.
    module = _load_main(monkeypatch, tmp_path, admin_emails="su@test.org:super_admin")
    with TestClient(module.app) as client:
        su_headers = _login(client)
        invite = client.post("/api/enroll/invite", json={"category": "custom"}, headers=su_headers)
        enrolled = client.post(
            "/api/enroll",
            json={"invite_code": invite.json()["invite_code"], "hostname": "LAB-PC-1"},
        )
        device_id = enrolled.json()["device_id"]

        token = f"test-token-{role}"
        module.ACTIVE_TOKENS[token] = {
            "email": f"{role}@test.org",
            "expires": datetime.now() + timedelta(hours=8),
            "role": role,
        }
        headers = {"Authorization": f"Bearer {token}"}

        res = client.post(f"/api/devices/{device_id}/revoke", headers=headers)

    if permitted:
        assert res.status_code == 200, f"{role} should be permitted 'devices_revoke', got {res.status_code}"
    else:
        assert res.status_code == 403, f"{role} should be forbidden 'devices_revoke', got {res.status_code}"
