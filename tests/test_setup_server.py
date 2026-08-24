"""Tests for the central-server setup tool's pure builder logic."""
import setup_server as sv


def test_linux_unit_has_required_sections():
    unit = sv.build_linux_unit("/usr/bin/python3", "127.0.0.1", 8000, "")
    assert "[Unit]" in unit and "[Service]" in unit and "[Install]" in unit
    assert "ExecStart=/usr/bin/python3 -m uvicorn main:app --host 127.0.0.1 --port 8000" in unit
    assert f"EnvironmentFile={sv.ENV_PATH}" in unit
    assert "Restart=on-failure" in unit
    assert "WantedBy=multi-user.target" in unit
    # no User= line unless a service user was given
    assert "User=" not in unit.replace("EnvironmentFile=", "")


def test_linux_unit_optional_service_user():
    unit = sv.build_linux_unit("/usr/bin/python3", "127.0.0.1", 8000, "logix")
    assert "User=logix\n" in unit


def test_macos_plist_is_well_formed():
    import plistlib
    plist = sv.build_macos_plist("/usr/bin/python3", "127.0.0.1", 9000)
    data = plistlib.loads(plist.encode("utf-8"))   # raises if malformed
    assert data["Label"] == sv.MACOS_LABEL
    assert data["RunAtLoad"] is True
    assert data["KeepAlive"] is True
    args = data["ProgramArguments"]
    assert args[1:4] == ["-m", "uvicorn", "main:app"]
    assert "9000" in args


def test_windows_ps1_registers_startup_task():
    ps1 = sv.build_windows_ps1(r"C:\Python\python.exe", "127.0.0.1", 8000)
    assert f'Register-ScheduledTask -TaskName "{sv.WINDOWS_TASK}"' in ps1
    assert "New-ScheduledTaskTrigger -AtStartup" in ps1
    assert "-m uvicorn main:app --host 127.0.0.1 --port 8000" in ps1


def test_env_written_via_flags_and_seeded_from_example(tmp_path, monkeypatch):
    """Non-interactive main() seeds .env from .env.example and merges values."""
    server_dir = tmp_path / "server"
    server_dir.mkdir()
    (server_dir / "requirements.txt").write_text("fastapi\n", encoding="utf-8")
    (server_dir / ".env.example").write_text(
        '# --- Admin allowlist ---\n'
        'ADMIN_EMAILS="admin@example.org"\n'
        'LOGIX_ADMIN_PASSWORD=""\n'
        'LOGIX_INGEST_API_KEY=""\n'
        'LOGIX_DEV_MODE="0"\n'
        'LOGIX_ALLOWED_ORIGINS="http://localhost:8000"\n',
        encoding="utf-8",
    )
    monkeypatch.setattr(sv, "SERVER_DIR", server_dir)
    monkeypatch.setattr(sv, "ENV_PATH", server_dir / ".env")
    monkeypatch.setattr(sv, "REQUIREMENTS", server_dir / "requirements.txt")

    rc = sv.main([
        "--admin-emails", "ops@example.org",
        "--admin-password", "s3cret-pass",
        "--ingest-key", "k123",
        "--allowed-origins", "https://logix.example.org",
        "--dev-mode", "0",
        "--no-install-deps",
    ])
    assert rc == 0
    text = (server_dir / ".env").read_text(encoding="utf-8")
    # comments survive the seed, keys replaced in place exactly once
    assert "# --- Admin allowlist ---" in text
    assert text.count("ADMIN_EMAILS=") == 1
    assert 'ADMIN_EMAILS="ops@example.org"' in text
    assert 'LOGIX_ADMIN_PASSWORD="s3cret-pass"' in text
    assert 'LOGIX_INGEST_API_KEY="k123"' in text
    assert 'LOGIX_ALLOWED_ORIGINS="https://logix.example.org"' in text


def test_generated_ingest_key_is_strong(tmp_path, monkeypatch):
    server_dir = tmp_path / "server"
    server_dir.mkdir()
    (server_dir / "requirements.txt").write_text("fastapi\n", encoding="utf-8")
    monkeypatch.setattr(sv, "SERVER_DIR", server_dir)
    monkeypatch.setattr(sv, "ENV_PATH", server_dir / ".env")
    monkeypatch.setattr(sv, "REQUIREMENTS", server_dir / "requirements.txt")

    rc = sv.main(["--admin-emails", "a@b.c", "--dev-mode", "0",
                  "--allowed-origins", "x", "--admin-password", "pw",
                  "--no-install-deps"])
    assert rc == 0
    text = (server_dir / ".env").read_text(encoding="utf-8")
    key_line = next(l for l in text.splitlines() if l.startswith("LOGIX_INGEST_API_KEY="))
    key = key_line.split("=", 1)[1].strip('"')
    assert len(key) == 64  # secrets.token_hex(32)


def test_env_autoload_in_server_main(tmp_path, monkeypatch):
    """main.py's _load_dotenv fills unset keys and never overrides real env."""
    import main as server_main
    env = tmp_path / ".env"
    env.write_text(
        'FOO_FROM_DOTENV="hello"\n'
        'PRESET_KEY="should-not-win"\n'
        "# comment\n"
        "not a kv line\n",
        encoding="utf-8",
    )
    monkeypatch.setenv("PRESET_KEY", "real-env-wins")
    monkeypatch.delenv("FOO_FROM_DOTENV", raising=False)
    server_main._load_dotenv(env)
    import os
    assert os.environ["FOO_FROM_DOTENV"] == "hello"
    assert os.environ["PRESET_KEY"] == "real-env-wins"
    monkeypatch.delenv("FOO_FROM_DOTENV", raising=False)


# --- Windows housekeeping parity ---------------------------------------------
# backup / cleanup / retention / watchdog existed only as systemd units, so a
# Windows-hosted server -- the likely case for a lab full of Windows
# workstations -- ran with no backups, no retention enforcement and no
# watchdog, and nothing said so.

def test_windows_jobs_cover_every_systemd_timer():
    """If a timer is added to ops/systemd/ without a Windows counterpart, the
    two platforms silently diverge. Compare the sets rather than trusting that
    whoever added one remembered the other."""

    timers = {p.stem.replace("logix-", "")
              for p in (sv.REPO / "ops" / "systemd").glob("*.timer")}
    windows = {suffix.lower() for _, suffix, _, _ in sv.WINDOWS_JOBS}
    # systemd names them backup/cleanup/watchdog; Windows uses CleanupReports.
    windows = {"cleanup" if w == "cleanupreports" else w for w in windows}
    missing = timers - windows
    assert not missing, f"systemd timers with no Windows equivalent: {sorted(missing)}"


def test_windows_jobs_script_is_valid_powershell():
    """Generated PowerShell that does not parse fails at install time, on
    somebody else's machine, with the console already closed."""
    import shutil
    import subprocess
    import tempfile
    from pathlib import Path

    powershell = shutil.which("powershell") or shutil.which("pwsh")
    if not powershell:
        import pytest
        pytest.skip("no PowerShell on this host")

    script = sv.build_windows_jobs_ps1(r"C:\Python\python.exe")
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "jobs.ps1"
        path.write_text(script, encoding="ascii")
        # Parse only -- registering four SYSTEM tasks is not a test's business.
        check = (
            "$e=$null; "
            f"[void][System.Management.Automation.Language.Parser]::ParseFile('{path}',"
            "[ref]$null,[ref]$e); "
            "if ($e.Count) { $e | ForEach-Object { $_.Message }; exit 1 } else { 'ok' }"
        )
        res = subprocess.run([powershell, "-NoProfile", "-Command", check],
                             capture_output=True, text=True)
    assert res.returncode == 0, f"generated script does not parse:\n{res.stdout}{res.stderr}"


def test_windows_jobs_quote_paths_that_contain_spaces():
    r"""Start-Process/schtasks arguments split on spaces unless quoted, and this
    repo has already been bitten by exactly that (C:\Program Files -> C:\Program)."""
    script = sv.build_windows_jobs_ps1(r"C:\Program Files\Python\python.exe")
    assert r'-Execute "C:\Program Files\Python\python.exe"' in script
    # The script path is quoted INSIDE -Argument, which is itself a quoted string.
    assert '-Argument "\\"' in script


def test_watchdog_repeats_rather_than_running_once_a_day():
    entry = next(j for j in sv.WINDOWS_JOBS if "watchdog" in j[0])
    assert entry[2] is None, "the watchdog is a polling job, not a daily one"
    script = sv.build_windows_jobs_ps1("python")
    assert f"-RepetitionInterval (New-TimeSpan -Minutes {sv.WATCHDOG_INTERVAL_MINUTES})" in script


def test_jobs_catch_up_after_the_host_was_off():
    """Persistent=true in the systemd timers; StartWhenAvailable is its
    Task Scheduler equivalent. Without it a machine switched off overnight
    silently skips that night's backup."""
    script = sv.build_windows_jobs_ps1("python")
    assert script.count("-StartWhenAvailable") == len(sv.WINDOWS_JOBS)


def test_dependencies_are_installed_by_default(tmp_path, monkeypatch):
    """The old default produced a setup that reported success and then could
    not start: nothing installed fastapi/uvicorn, so the "Done, run this"
    command died on ModuleNotFoundError. Installing is now the default."""
    server_dir = tmp_path / "server"
    server_dir.mkdir()
    (server_dir / "requirements.txt").write_text("fastapi\n", encoding="utf-8")
    monkeypatch.setattr(sv, "SERVER_DIR", server_dir)
    monkeypatch.setattr(sv, "ENV_PATH", server_dir / ".env")
    monkeypatch.setattr(sv, "REQUIREMENTS", server_dir / "requirements.txt")

    calls = []
    monkeypatch.setattr(sv, "install_deps", lambda: calls.append(True) or "PY")

    rc = sv.main(["--admin-emails", "a@b.c", "--dev-mode", "0",
                  "--allowed-origins", "x", "--admin-password", "pw"])
    assert rc == 0
    assert calls, "setup ran without installing the server's dependencies"


def test_no_install_deps_opts_out(tmp_path, monkeypatch):
    server_dir = tmp_path / "server"
    server_dir.mkdir()
    (server_dir / "requirements.txt").write_text("fastapi\n", encoding="utf-8")
    monkeypatch.setattr(sv, "SERVER_DIR", server_dir)
    monkeypatch.setattr(sv, "ENV_PATH", server_dir / ".env")
    monkeypatch.setattr(sv, "REQUIREMENTS", server_dir / "requirements.txt")

    calls = []
    monkeypatch.setattr(sv, "install_deps", lambda: calls.append(True) or "PY")

    rc = sv.main(["--admin-emails", "a@b.c", "--dev-mode", "0",
                  "--allowed-origins", "x", "--admin-password", "pw",
                  "--no-install-deps"])
    assert rc == 0
    assert not calls


def test_venv_follows_server_dir(tmp_path, monkeypatch):
    """venv_dir() is derived at call time, so pointing SERVER_DIR elsewhere
    never builds a virtualenv inside the real checkout."""
    server_dir = tmp_path / "server"
    server_dir.mkdir()
    monkeypatch.setattr(sv, "SERVER_DIR", server_dir)
    assert sv.venv_dir() == server_dir / ".venv"
    assert str(sv.venv_python()).startswith(str(server_dir))


def test_service_unit_uses_the_interpreter_that_has_uvicorn(tmp_path, monkeypatch):
    """The systemd unit must ExecStart the venv's python. Pointing it at the
    system interpreter gives a service that fails on every boot, because the
    dependencies were installed into the venv."""
    server_dir = tmp_path / "server"
    server_dir.mkdir()
    monkeypatch.setattr(sv, "SERVER_DIR", server_dir)
    monkeypatch.setattr(sv, "ENV_PATH", server_dir / ".env")

    venv_py = str(sv.venv_python())
    unit = sv.build_linux_unit(venv_py, "127.0.0.1", 8000, "logix")
    assert f"ExecStart={venv_py} -m uvicorn main:app" in unit
    assert "User=logix" in unit
