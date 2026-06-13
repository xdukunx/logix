"""Tests for the sync setup tool's pure config-merge logic."""
import setup_sync as ss


def test_update_config_replaces_commented_template(tmp_path):
    cfg = tmp_path / "config.env"
    cfg.write_text(
        'LOGIX_HOME="/opt/software/logix"\n'
        '# export LOGIX_GSHEET_ID="your-spreadsheet-id"\n'
        '# export LOGIX_REDACT_MODE="initials"\n',
        encoding="utf-8",
    )
    ss.update_config(cfg, {
        "LOGIX_GSHEET_ID": "SHEET123",
        "LOGIX_REDACT_MODE": "hash",
        "LOGIX_GSHEET_SALT": "pepper",
    })
    text = cfg.read_text(encoding="utf-8")
    # commented templates replaced in place, not duplicated
    assert text.count("LOGIX_GSHEET_ID=") == 1
    assert 'LOGIX_GSHEET_ID="SHEET123"' in text
    assert 'LOGIX_REDACT_MODE="hash"' in text
    # untouched key preserved; new key appended
    assert 'LOGIX_HOME="/opt/software/logix"' in text
    assert 'LOGIX_GSHEET_SALT="pepper"' in text


def test_update_config_is_idempotent(tmp_path):
    cfg = tmp_path / "config.env"
    updates = {"LOGIX_GSHEET_ID": "X", "LOGIX_GSHEET_CREDS": "/secure/sa.json"}
    ss.update_config(cfg, updates)
    first = cfg.read_text(encoding="utf-8")
    ss.update_config(cfg, updates)
    assert cfg.read_text(encoding="utf-8") == first
    assert first.count("LOGIX_GSHEET_ID=") == 1


def test_macos_plist_is_well_formed(tmp_path):
    import plistlib
    from pathlib import Path
    plist = ss.build_macos_plist(Path("/Library/Application Support/Logix"), "/usr/bin/python3")
    data = plistlib.loads(plist.encode("utf-8"))   # raises if malformed
    assert data["Label"] == ss.MACOS_LABEL
    assert data["StartInterval"] == 3600
    assert data["ProgramArguments"][-1].endswith("gsheet_sync.py")
    assert data["EnvironmentVariables"]["LOGIX_HOME"].endswith("Logix")


def test_linux_units_have_required_sections(tmp_path):
    from pathlib import Path
    service, timer = ss.build_linux_units(Path("/opt/software/logix"), "/usr/bin/python3")
    assert "[Service]" in service and "ExecStart=" in service and "gsheet_sync.py" in service
    assert "OnCalendar=hourly" in timer and "WantedBy=timers.target" in timer


def test_windows_ps1_registers_named_task(tmp_path):
    from pathlib import Path
    ps1 = ss.build_windows_ps1(Path(r"C:\ProgramData\Logix"), r"C:\Python\python.exe")
    assert 'Register-ScheduledTask -TaskName "LogixGSheetSync"' in ps1
    assert "New-TimeSpan -Hours 1" in ps1
    assert "gsheet_sync.py" in ps1


def test_update_config_values_are_readable_by_paths(tmp_path, monkeypatch):
    """A config.env written by setup_sync must round-trip through paths.get()."""
    cfg = tmp_path / "config.env"
    ss.update_config(cfg, {"LOGIX_GSHEET_ID": "SHEET999", "LOGIX_REDACT_MODE": "code"})
    import paths
    monkeypatch.setenv("LOGIX_CONFIG", str(cfg))
    paths._CONFIG_CACHE = None  # bust the cache so it re-reads our file
    for var in ("LOGIX_GSHEET_ID", "LOGIX_REDACT_MODE"):
        monkeypatch.delenv(var, raising=False)
    assert paths.get("LOGIX_GSHEET_ID") == "SHEET999"
    assert paths.get("LOGIX_REDACT_MODE") == "code"
