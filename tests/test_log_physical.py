"""Tests for logix/log_physical.py -- event_uid generation (roadmap item D)
and, once added, --sync-preview / retry-backoff.

Deliberately import log_physical INSIDE each test function, not at module
top-level -- log_physical.DEFAULT_DB is a module-level constant computed
once at import time from paths.default_db(), and tests/test_gsheet_sync.py
depends on being the first importer (after its own monkeypatch sets
LOGIX_DB) so that constant reflects its synthetic tmp_path DB. A top-level
import here would run during pytest's collection phase, before any
monkeypatch fixture executes, permanently poisoning that constant for the
rest of the test session.
"""

import json  # stdlib only -- safe at module scope, no log_physical/paths state involved


def test_payload_from_args_generates_event_uid_when_absent():
    import log_physical
    ns = log_physical.parse_args(["--event", "START", "--hostname", "PC-1"])
    payload = log_physical.payload_from_args(ns)
    assert payload["event_uid"]
    assert len(payload["event_uid"]) == 32  # uuid4().hex


def test_payload_from_args_generates_different_uids_each_call():
    import log_physical
    ns = log_physical.parse_args(["--event", "START"])
    a = log_physical.payload_from_args(ns)
    b = log_physical.payload_from_args(ns)
    assert a["event_uid"] != b["event_uid"]


def test_payload_from_args_preserves_event_uid_from_json_file(tmp_path):
    """The JSON file is the unit of retry -- a crashed/retried process
    re-reads the same file, so an existing event_uid must be kept, not
    regenerated (that's what makes a retry actually idempotent)."""
    import log_physical
    json_path = tmp_path / "payload.json"
    json_path.write_text(
        '{"event": "START", "hostname": "PC-1", "event_uid": "fixed-uid-123"}',
        encoding="utf-8",
    )
    ns = log_physical.parse_args(["--json-file", str(json_path)])
    payload = log_physical.payload_from_args(ns)
    assert payload["event_uid"] == "fixed-uid-123"


def test_event_uid_column_in_base_columns():
    import log_physical
    assert "event_uid" in log_physical.BASE_COLUMNS


def test_migrate_adds_event_uid_to_pre_existing_table(tmp_path):
    """A DB created before event_uid shipped must still migrate cleanly."""
    import sqlite3
    import log_physical

    db_path = tmp_path / "legacy.db"
    con = sqlite3.connect(str(db_path))
    con.row_factory = sqlite3.Row
    pre_migration_columns = {k: v for k, v in log_physical.BASE_COLUMNS.items() if k != "event_uid"}
    col_defs = ",\n        ".join(f"{k} {v}" for k, v in pre_migration_columns.items())
    con.execute(f"CREATE TABLE physical_log (\n        {col_defs}\n    )")
    con.commit()
    con.close()

    con = log_physical.connect(db_path)
    try:
        log_physical.migrate(con)  # must not raise
        cols = log_physical.existing_columns(con, "physical_log")
        assert "event_uid" in cols
    finally:
        con.close()


def test_insert_event_stores_event_uid(tmp_path):
    import log_physical
    db_path = tmp_path / "test.db"
    con = log_physical.connect(db_path)
    try:
        log_physical.migrate(con)
        ns = log_physical.parse_args(["--event", "START", "--hostname", "PC-1"])
        payload = log_physical.payload_from_args(ns)
        row_id = log_physical.insert_event(con, payload)
        row = con.execute("SELECT event_uid FROM physical_log WHERE id = ?", (row_id,)).fetchone()
        assert row["event_uid"] == payload["event_uid"]
    finally:
        con.close()


def _seed_one_unsynced_row(log_physical, con):
    ns = log_physical.parse_args(["--event", "START", "--hostname", "PC-1"])
    payload = log_physical.payload_from_args(ns)
    log_physical.insert_event(con, payload)


def test_sync_preview_makes_no_network_call(tmp_path, monkeypatch, capsys):
    import log_physical
    monkeypatch.setenv("LOGIX_SERVER_URL", "http://example.invalid")

    def _fail_if_called(*a, **kw):
        raise AssertionError("--sync-preview must never open a network connection")
    monkeypatch.setattr(log_physical.urllib.request, "urlopen", _fail_if_called)

    con = log_physical.connect(tmp_path / "test.db")
    try:
        log_physical.migrate(con)
        _seed_one_unsynced_row(log_physical, con)
        count = log_physical.preview_sync(con)
        out = capsys.readouterr().out
    finally:
        con.close()

    assert count == 1
    assert "1 unsynced event" in out
    # The preview must not leak PII fields into terminal output.
    assert "nama" not in out.lower()


def test_sync_default_max_attempts_is_one(tmp_path, monkeypatch):
    """The inline post-insert call relies on this staying a single
    fire-and-forget attempt -- must never silently start blocking longer."""
    import log_physical
    monkeypatch.setenv("LOGIX_SERVER_URL", "http://example.invalid")
    monkeypatch.setenv("LOGIX_PRIVACY_MODE", "admin_full_sync")
    monkeypatch.setattr(log_physical.time, "sleep", lambda s: None)

    calls = []
    def _boom(*a, **kw):
        calls.append(1)
        raise TimeoutError("simulated network failure")
    monkeypatch.setattr(log_physical.urllib.request, "urlopen", _boom)

    con = log_physical.connect(tmp_path / "test.db")
    try:
        log_physical.migrate(con)
        _seed_one_unsynced_row(log_physical, con)
        result = log_physical.sync_unsynced_logs(con)  # default max_attempts
    finally:
        con.close()

    assert result == 0
    assert len(calls) == 1


def test_sync_retries_on_network_failure_then_succeeds(tmp_path, monkeypatch):
    import log_physical
    monkeypatch.setenv("LOGIX_SERVER_URL", "http://example.invalid")
    monkeypatch.setenv("LOGIX_PRIVACY_MODE", "admin_full_sync")
    sleeps = []
    monkeypatch.setattr(log_physical.time, "sleep", lambda s: sleeps.append(s))

    calls = []
    class _FakeResponse:
        status = 200
        def __enter__(self): return self
        def __exit__(self, *a): return False
    def _flaky(*a, **kw):
        calls.append(1)
        if len(calls) < 3:
            raise ConnectionRefusedError("simulated transient failure")
        return _FakeResponse()
    monkeypatch.setattr(log_physical.urllib.request, "urlopen", _flaky)

    con = log_physical.connect(tmp_path / "test.db")
    try:
        log_physical.migrate(con)
        _seed_one_unsynced_row(log_physical, con)
        result = log_physical.sync_unsynced_logs(con, max_attempts=3)
    finally:
        con.close()

    assert result == 1  # succeeded on the 3rd attempt
    assert len(calls) == 3
    assert sleeps == [1, 2]  # exponential backoff between the 2 failed attempts


def test_sync_does_not_retry_on_http_error(tmp_path, monkeypatch):
    """An HTTP error status means the server actively rejected the
    request -- retrying won't fix a 4xx/5xx."""
    import log_physical
    monkeypatch.setenv("LOGIX_SERVER_URL", "http://example.invalid")
    monkeypatch.setenv("LOGIX_PRIVACY_MODE", "admin_full_sync")
    monkeypatch.setattr(log_physical.time, "sleep", lambda s: (_ for _ in ()).throw(AssertionError("must not sleep/retry on HTTPError")))

    calls = []
    def _reject(*a, **kw):
        calls.append(1)
        raise log_physical.urllib.error.HTTPError("http://example.invalid", 401, "Unauthorized", {}, None)
    monkeypatch.setattr(log_physical.urllib.request, "urlopen", _reject)

    con = log_physical.connect(tmp_path / "test.db")
    try:
        log_physical.migrate(con)
        _seed_one_unsynced_row(log_physical, con)
        result = log_physical.sync_unsynced_logs(con, max_attempts=3)
    finally:
        con.close()

    assert result == 0
    assert len(calls) == 1


# --- Privacy-mode enforcement at the agent boundary (roadmap item F) -------
# docs/PRIVACY.md: "default = safest" -- local_only unless explicitly
# overridden. /api/log only ever carries full-detail rows, so it's gated to
# admin_full_sync specifically; redacted_sync's real delivery path is
# logix/gsheet_sync.py's already-tested redact() whitelist, untouched here.

def test_privacy_mode_defaults_to_local_only(monkeypatch):
    import paths
    monkeypatch.delenv("LOGIX_PRIVACY_MODE", raising=False)
    assert paths.privacy_mode() == "local_only"


def test_privacy_mode_reads_env_case_insensitively(monkeypatch):
    import paths
    monkeypatch.setenv("LOGIX_PRIVACY_MODE", "Admin_Full_Sync")
    assert paths.privacy_mode() == "admin_full_sync"


def test_privacy_mode_rejects_unrecognized_value(monkeypatch):
    import paths
    monkeypatch.setenv("LOGIX_PRIVACY_MODE", "bogus_mode")
    try:
        paths.privacy_mode()
        assert False, "expected ValueError for an unrecognized privacy mode"
    except ValueError:
        pass


def test_sync_skipped_under_default_local_only_even_with_server_configured(tmp_path, monkeypatch, capsys):
    """The core enforcement: today, a configured LOGIX_SERVER_URL alone was
    enough to sync. Now it must NOT be, unless privacy mode is explicitly
    admin_full_sync -- and the reason must be loud, not silent."""
    import log_physical
    monkeypatch.setenv("LOGIX_SERVER_URL", "http://example.invalid")
    monkeypatch.delenv("LOGIX_PRIVACY_MODE", raising=False)

    def _fail_if_called(*a, **kw):
        raise AssertionError("must not attempt to sync under local_only")
    monkeypatch.setattr(log_physical.urllib.request, "urlopen", _fail_if_called)

    con = log_physical.connect(tmp_path / "test.db")
    try:
        log_physical.migrate(con)
        _seed_one_unsynced_row(log_physical, con)
        result = log_physical.sync_unsynced_logs(con)
        err = capsys.readouterr().err
    finally:
        con.close()

    assert result == 0
    assert "local_only" in err
    assert "admin_full_sync" in err


def test_sync_skipped_under_redacted_sync_too(tmp_path, monkeypatch):
    """redacted_sync does not get a reshaped /api/log payload -- that
    endpoint is inherently full-detail. gsheet_sync.py is the real
    redacted_sync delivery path, unaffected by this gate."""
    import log_physical
    monkeypatch.setenv("LOGIX_SERVER_URL", "http://example.invalid")
    monkeypatch.setenv("LOGIX_PRIVACY_MODE", "redacted_sync")

    def _fail_if_called(*a, **kw):
        raise AssertionError("must not attempt to sync under redacted_sync")
    monkeypatch.setattr(log_physical.urllib.request, "urlopen", _fail_if_called)

    con = log_physical.connect(tmp_path / "test.db")
    try:
        log_physical.migrate(con)
        _seed_one_unsynced_row(log_physical, con)
        result = log_physical.sync_unsynced_logs(con)
    finally:
        con.close()

    assert result == 0


def test_sync_proceeds_under_admin_full_sync(tmp_path, monkeypatch):
    import log_physical
    monkeypatch.setenv("LOGIX_SERVER_URL", "http://example.invalid")
    monkeypatch.setenv("LOGIX_PRIVACY_MODE", "admin_full_sync")

    class _FakeResponse:
        status = 200
        def __enter__(self): return self
        def __exit__(self, *a): return False
    monkeypatch.setattr(log_physical.urllib.request, "urlopen", lambda *a, **kw: _FakeResponse())

    con = log_physical.connect(tmp_path / "test.db")
    try:
        log_physical.migrate(con)
        _seed_one_unsynced_row(log_physical, con)
        result = log_physical.sync_unsynced_logs(con)
    finally:
        con.close()

    assert result == 1


def test_preview_reports_skip_reason_under_local_only(tmp_path, monkeypatch, capsys):
    import log_physical
    monkeypatch.delenv("LOGIX_PRIVACY_MODE", raising=False)

    con = log_physical.connect(tmp_path / "test.db")
    try:
        log_physical.migrate(con)
        _seed_one_unsynced_row(log_physical, con)
        log_physical.preview_sync(con)
        out = capsys.readouterr().out
    finally:
        con.close()

    assert "none would actually be sent" in out
    assert "local_only" in out


# --- sync_status (backend-only groundwork for a future Device UI) ----------
# The state file is colocated with whatever DB file the connection actually
# points at (PRAGMA database_list), not paths.data_home() unconditionally --
# every test here uses a tmp_path db, so this also doubles as the guarantee
# that these tests cannot leak a sync_state.json into a real machine's
# C:\ProgramData\Logix.

def test_sync_status_disabled_with_no_server_configured(tmp_path, monkeypatch):
    import log_physical
    # delenv alone is not enough on a machine that has a real config.env
    # with a server URL already written to it (paths.get() falls back to
    # that file once the env var is gone) -- monkeypatch the resolved
    # function directly so this test's meaning ("no server at all") does
    # not depend on what happens to be installed on whatever machine runs
    # the suite.
    monkeypatch.setattr(log_physical.paths, "server_url", lambda: "")

    con = log_physical.connect(tmp_path / "test.db")
    try:
        log_physical.migrate(con)
        status = log_physical.sync_status(con)
    finally:
        con.close()

    assert status["connection_state"] == "disabled"
    assert status["server_configured"] is False


def test_sync_status_blocked_under_local_only(tmp_path, monkeypatch):
    import log_physical
    monkeypatch.setenv("LOGIX_SERVER_URL", "http://example.invalid")
    monkeypatch.delenv("LOGIX_PRIVACY_MODE", raising=False)

    con = log_physical.connect(tmp_path / "test.db")
    try:
        log_physical.migrate(con)
        status = log_physical.sync_status(con)
    finally:
        con.close()

    assert status["connection_state"] == "blocked"
    assert status["server_configured"] is True


def test_sync_status_pending_before_any_attempt(tmp_path, monkeypatch):
    """Configured and allowed, but nothing has actually reached the network
    yet -- distinct from 'offline', which means an attempt was MADE and it
    failed. A fresh install must not claim it's offline before it has ever
    tried."""
    import log_physical
    monkeypatch.setenv("LOGIX_SERVER_URL", "http://example.invalid")
    monkeypatch.setenv("LOGIX_PRIVACY_MODE", "admin_full_sync")

    con = log_physical.connect(tmp_path / "test.db")
    try:
        log_physical.migrate(con)
        status = log_physical.sync_status(con)
    finally:
        con.close()

    assert status["connection_state"] == "pending"
    assert status["last_attempt"] is None


def test_sync_status_pending_count_reflects_unsynced_rows(tmp_path, monkeypatch):
    import log_physical
    monkeypatch.delenv("LOGIX_SERVER_URL", raising=False)

    con = log_physical.connect(tmp_path / "test.db")
    try:
        log_physical.migrate(con)
        _seed_one_unsynced_row(log_physical, con)
        _seed_one_unsynced_row(log_physical, con)
        status = log_physical.sync_status(con)
    finally:
        con.close()

    assert status["pending_count"] == 2


def test_sync_status_connected_after_successful_sync(tmp_path, monkeypatch):
    import log_physical
    monkeypatch.setenv("LOGIX_SERVER_URL", "http://example.invalid")
    monkeypatch.setenv("LOGIX_PRIVACY_MODE", "admin_full_sync")

    class _FakeResponse:
        status = 200
        def __enter__(self): return self
        def __exit__(self, *a): return False
    monkeypatch.setattr(log_physical.urllib.request, "urlopen", lambda *a, **kw: _FakeResponse())

    con = log_physical.connect(tmp_path / "test.db")
    try:
        log_physical.migrate(con)
        _seed_one_unsynced_row(log_physical, con)
        log_physical.sync_unsynced_logs(con)
        status = log_physical.sync_status(con)
    finally:
        con.close()

    assert status["connection_state"] == "connected"
    assert status["pending_count"] == 0
    assert status["last_success"] is not None
    assert status["last_error"] is None


def test_sync_status_offline_after_failed_sync(tmp_path, monkeypatch):
    import log_physical
    monkeypatch.setenv("LOGIX_SERVER_URL", "http://example.invalid")
    monkeypatch.setenv("LOGIX_PRIVACY_MODE", "admin_full_sync")

    def _boom(*a, **kw):
        raise ConnectionRefusedError("simulated: server unreachable")
    monkeypatch.setattr(log_physical.urllib.request, "urlopen", _boom)

    con = log_physical.connect(tmp_path / "test.db")
    try:
        log_physical.migrate(con)
        _seed_one_unsynced_row(log_physical, con)
        log_physical.sync_unsynced_logs(con)
        status = log_physical.sync_status(con)
    finally:
        con.close()

    assert status["connection_state"] == "offline"
    assert status["pending_count"] == 1
    assert status["last_error"] is not None
    assert "simulated" in status["last_error"]


def test_sync_status_recovers_to_connected_after_a_later_success(tmp_path, monkeypatch):
    """last_error must actually clear on the next success, not just get
    overwritten alongside a stale success timestamp -- a UI reading this
    file should never show a lingering error next to 'Connected'."""
    import log_physical
    monkeypatch.setenv("LOGIX_SERVER_URL", "http://example.invalid")
    monkeypatch.setenv("LOGIX_PRIVACY_MODE", "admin_full_sync")

    con = log_physical.connect(tmp_path / "test.db")
    try:
        log_physical.migrate(con)
        _seed_one_unsynced_row(log_physical, con)

        monkeypatch.setattr(log_physical.urllib.request, "urlopen",
                             lambda *a, **kw: (_ for _ in ()).throw(ConnectionRefusedError("down")))
        log_physical.sync_unsynced_logs(con)
        assert log_physical.sync_status(con)["connection_state"] == "offline"

        class _FakeResponse:
            status = 200
            def __enter__(self): return self
            def __exit__(self, *a): return False
        monkeypatch.setattr(log_physical.urllib.request, "urlopen", lambda *a, **kw: _FakeResponse())
        log_physical.sync_unsynced_logs(con)
        status = log_physical.sync_status(con)
    finally:
        con.close()

    assert status["connection_state"] == "connected"
    assert status["last_error"] is None


def test_sync_status_state_file_is_colocated_with_the_actual_db_not_the_system_default(tmp_path):
    """The whole reason PRAGMA database_list is used instead of
    paths.data_home(): a device running against a non-default --db must not
    have its sync status attributed to (or collide with) the system
    install's sync_state.json. sync_status() itself is read-only (it never
    writes), so this records a real attempt first, the same way
    sync_unsynced_logs() would, then checks where that landed."""
    import log_physical

    db_path = tmp_path / "custom" / "wherever.db"
    con = log_physical.connect(db_path)
    try:
        log_physical.migrate(con)
        log_physical._record_sync_attempt(con, ok=True)
        status = log_physical.sync_status(con)
    finally:
        con.close()

    assert status["last_success"] is not None
    assert (tmp_path / "custom" / "sync_state.json").exists()
    assert not (tmp_path / "sync_state.json").exists(), "must not have landed one directory up either"


def test_record_sync_attempt_write_failure_does_not_raise(tmp_path, monkeypatch):
    """Observability must be best-effort -- a broken/unwritable state file
    must never turn into a sync failure that wasn't otherwise one."""
    import log_physical

    con = log_physical.connect(tmp_path / "test.db")
    try:
        log_physical.migrate(con)
        monkeypatch.setattr(log_physical.Path, "write_text",
                             lambda self, *a, **kw: (_ for _ in ()).throw(OSError("disk full")))
        log_physical._record_sync_attempt(con, ok=True)  # must not raise
    finally:
        con.close()


def test_sync_status_cli_flag_prints_json(tmp_path, monkeypatch, capsys):
    import log_physical
    monkeypatch.setattr(log_physical.paths, "server_url", lambda: "")

    con = log_physical.connect(tmp_path / "test.db")
    log_physical.migrate(con)
    con.close()

    rc = log_physical.main(["--db", str(tmp_path / "test.db"), "--sync-status"])
    out = capsys.readouterr().out

    assert rc == 0
    parsed = json.loads(out)
    assert parsed["connection_state"] == "disabled"
