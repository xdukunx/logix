"""Tests for install/install.py's interactive first-run wizard (roadmap
item H). Mirrors the existing prompt()/update_config() pattern already
proven in install/setup_sync.py.

install.py's main() calls paths._system_data_home() directly (not the
LOGIX_HOME-overridable data_home() -- deliberately, since its job is to
establish the true OS-default system location). Tests monkeypatch that
function directly to redirect into tmp_path rather than relying on an env
var install.py doesn't consult for this purpose.
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "install"))


def test_prompt_returns_default_when_not_a_tty(monkeypatch):
    import install
    monkeypatch.setattr(sys.stdin, "isatty", lambda: False)
    assert install.prompt("Anything", "the-default") == "the-default"


def test_prompt_privacy_mode_returns_default_when_not_a_tty(monkeypatch):
    import install
    monkeypatch.setattr(sys.stdin, "isatty", lambda: False)
    assert install.prompt_privacy_mode("local_only") == "local_only"


def test_update_config_appends_new_keys(tmp_path):
    import install
    cfg = tmp_path / "config.env"
    cfg.write_text("LOGIX_HOME=/opt/software/logix\n", encoding="utf-8")
    install.update_config(cfg, {"LOGIX_DEVICE_NAME": "Lab PC 1", "LOGIX_SERVER_URL": ""})
    content = cfg.read_text(encoding="utf-8")
    assert "LOGIX_DEVICE_NAME=Lab PC 1" in content
    assert "LOGIX_HOME=/opt/software/logix" in content
    # Blank values are never written -- an empty --server-url shouldn't
    # clobber a value already present in a pre-existing config.env.
    assert "LOGIX_SERVER_URL" not in content


def test_update_config_replaces_existing_key_in_place(tmp_path):
    import install
    cfg = tmp_path / "config.env"
    cfg.write_text("LOGIX_DEVICE_NAME=Old Name\nLOGIX_HOME=/x\n", encoding="utf-8")
    install.update_config(cfg, {"LOGIX_DEVICE_NAME": "New Name"})
    lines = cfg.read_text(encoding="utf-8").splitlines()
    assert lines.count("LOGIX_DEVICE_NAME=New Name") == 1
    assert "LOGIX_HOME=/x" in lines


def _run_install(monkeypatch, tmp_path, argv):
    import install
    monkeypatch.setattr(install.paths, "_system_data_home", lambda: tmp_path)
    # log_physical.py --migrate is invoked as a real subprocess; point it at
    # the same tmp_path via LOGIX_HOME so it doesn't touch the real system DB.
    monkeypatch.setenv("LOGIX_HOME", str(tmp_path))
    rc = install.main(argv)
    return install, rc


def test_non_interactive_completes_with_no_prompts(monkeypatch, tmp_path):
    def _fail_if_prompted(*a, **kw):
        raise AssertionError("must not prompt under --non-interactive")
    import install
    monkeypatch.setattr(install, "prompt", _fail_if_prompted)
    monkeypatch.setattr(install, "prompt_privacy_mode", _fail_if_prompted)

    _, rc = _run_install(monkeypatch, tmp_path, [
        "--non-interactive", "--device-name", "Lab PC 3",
        "--privacy-mode", "redacted_sync",
    ])
    assert rc == 0

    cfg_text = (tmp_path / "config.env").read_text(encoding="utf-8")
    assert "LOGIX_DEVICE_NAME=Lab PC 3" in cfg_text
    assert "LOGIX_PRIVACY_MODE=redacted_sync" in cfg_text


def test_non_interactive_default_device_name_is_hostname(monkeypatch, tmp_path):
    # machine_hostname(), not socket.gethostname(): on Windows the agent
    # reports $env:COMPUTERNAME, and the two spellings differ (often only in
    # case). Enrolling under one and heartbeating under the other is what
    # produced two registry rows for one machine.
    install, rc = _run_install(monkeypatch, tmp_path, ["--non-interactive"])
    assert rc == 0
    cfg_text = (tmp_path / "config.env").read_text(encoding="utf-8")
    assert f"LOGIX_DEVICE_NAME={install.machine_hostname()}" in cfg_text
    assert "LOGIX_PRIVACY_MODE=local_only" in cfg_text  # the safe default


def test_machine_hostname_matches_the_agent_on_windows(monkeypatch):
    import install
    monkeypatch.setattr(install.sys, "platform", "win32")
    monkeypatch.setenv("COMPUTERNAME", "DESKTOP-8H2K1L")
    assert install.machine_hostname() == "DESKTOP-8H2K1L"

    # Non-Windows keeps the POSIX source it always had.
    monkeypatch.setattr(install.sys, "platform", "linux")
    assert install.machine_hostname() == install.socket.gethostname()


def test_enrollment_sends_the_device_name(monkeypatch, tmp_path):
    """The typed name used to be accepted, written to config.env, and then
    dropped -- the enrol POST carried only the hostname, so the registry row
    was created under the bare machine name."""
    import install
    sent = {}

    class _Resp:
        def __enter__(self):
            return self

        def __exit__(self, *exc):
            return False

        def read(self):
            return b'{"device_id": "d1", "api_key": "k1", "category": "custom"}'

    def _fake_urlopen(req, timeout=None):
        sent["body"] = json.loads(req.data.decode("utf-8"))
        return _Resp()

    monkeypatch.setattr(install.urllib.request, "urlopen", _fake_urlopen)
    monkeypatch.setattr(install.paths, "write_device_identity",
                        lambda *a, **kw: tmp_path / "device.json")

    assert install.redeem_enrollment_code("http://example.invalid", "ABCD-1234", "WS-07") is True
    assert sent["body"]["device_name"] == "WS-07"
    assert sent["body"]["hostname"] == install.machine_hostname()


def test_interactive_prompts_used_when_flags_absent(monkeypatch, tmp_path):
    """Confirms the interactive branch actually calls prompt() (not just
    that --non-interactive skips it) -- a stdin-not-a-tty environment (like
    this test run) makes prompt() itself return defaults, but the
    *branch* taken must still be the interactive one when --non-interactive
    isn't passed."""
    import install
    calls = []
    original_prompt = install.prompt
    def _tracking_prompt(label, default=""):
        calls.append(label)
        return original_prompt(label, default)
    monkeypatch.setattr(install, "prompt", _tracking_prompt)

    _, rc = _run_install(monkeypatch, tmp_path, [])
    assert rc == 0
    assert any("Device name" in c for c in calls)


def test_enrollment_attempted_when_server_and_code_both_given(monkeypatch, tmp_path):
    import install
    calls = []
    def _fake_redeem(server_url, enroll_code, device_name):
        calls.append((server_url, enroll_code, device_name))
        return True
    monkeypatch.setattr(install, "redeem_enrollment_code", _fake_redeem)

    _run_install(monkeypatch, tmp_path, [
        "--non-interactive", "--server-url", "http://example.invalid",
        "--enroll-code", "ABCD-1234",
    ])
    assert calls == [("http://example.invalid", "ABCD-1234", install.machine_hostname())]


def test_no_enrollment_attempted_without_enroll_code(monkeypatch, tmp_path):
    import install
    def _fail_if_called(*a, **kw):
        raise AssertionError("must not attempt enrollment without an enroll code")
    monkeypatch.setattr(install, "redeem_enrollment_code", _fail_if_called)

    _run_install(monkeypatch, tmp_path, [
        "--non-interactive", "--server-url", "http://example.invalid",
    ])  # no --enroll-code


def test_redeem_enrollment_code_writes_device_identity(monkeypatch, tmp_path):
    import install

    class _FakeResponse:
        def __enter__(self): return self
        def __exit__(self, *a): return False
        def read(self):
            import json
            return json.dumps({"device_id": "dev-123", "api_key": "key-abc", "category": "lab_workstation"}).encode()
    monkeypatch.setattr(install.urllib.request, "urlopen", lambda *a, **kw: _FakeResponse())

    identity_path = tmp_path / "device.json"
    monkeypatch.setattr(install.paths, "device_identity_path", lambda: identity_path)

    ok = install.redeem_enrollment_code("http://example.invalid", "CODE-1", "Lab PC 1")
    assert ok is True
    import json
    saved = json.loads(identity_path.read_text(encoding="utf-8"))
    assert saved["device_id"] == "dev-123"
    assert saved["api_key"] == "key-abc"


def test_configure_in_place_skips_copy_when_src_equals_dest(monkeypatch, tmp_path):
    """Package-manager `logix configure` path: install.py runs from the very
    directory the core files already live in (a deb/rpm/homebrew install lays
    them down, then invokes install.py in place), so SRC == dest. The copy
    step must SKIP cleanly -- no shutil.SameFileError from copying a file onto
    itself -- and still write config.env and initialize the DB in place. This
    locks in the copy-guard that makes install.py reusable as the package
    configure tool."""
    import shutil
    import install
    src_repo = Path(install.__file__).resolve().parent.parent / "logix"
    for f in install.CORE_FILES:
        shutil.copy2(src_repo / f, tmp_path / f)
    # Make SRC and the OS data home both the pre-populated dir -> src == dst.
    monkeypatch.setattr(install, "SRC", tmp_path)
    monkeypatch.setattr(install.paths, "_system_data_home", lambda: tmp_path)
    monkeypatch.setenv("LOGIX_HOME", str(tmp_path))
    rc = install.main(["--non-interactive", "--device-name", "Pkg PC", "--privacy-mode", "local_only"])
    assert rc == 0
    cfg = (tmp_path / "config.env").read_text(encoding="utf-8")
    assert "LOGIX_DEVICE_NAME=Pkg PC" in cfg
    assert "LOGIX_PRIVACY_MODE=local_only" in cfg
    assert (tmp_path / "logix.db").exists()  # migration ran in place


def test_redeem_enrollment_code_returns_false_on_network_failure(monkeypatch, tmp_path):
    import install

    def _boom(*a, **kw):
        raise install.urllib.error.URLError("simulated failure")
    monkeypatch.setattr(install.urllib.request, "urlopen", _boom)

    ok = install.redeem_enrollment_code("http://example.invalid", "CODE-1", "Lab PC 1")
    assert ok is False
