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
                  "--allowed-origins", "x", "--admin-password", "pw"])
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
