"""paths.writable_reports_dir(): where an export is allowed to land.

The default reports directory sits under the SYSTEM data home, which is
root-owned on macOS (/Library/Application Support/Logix) and on Linux
(/opt/software/logix). The local dashboard is a per-user, no-admin,
loopback-only tool, so every export there died with "[Errno 13] Permission
denied" -- six tests caught it on macOS while Windows and the Linux runner
sailed past, because those paths happen to be writable there.

The privacy half matters as much as the permission half: reports contain
names and NIMs, so an admin who set LOGBOOK_REPORT_DIR to a particular volume
must never have them quietly written somewhere else.
"""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "logix"))
import paths  # noqa: E402


@pytest.fixture(autouse=True)
def _clean_env(monkeypatch, tmp_path):
    monkeypatch.delenv("LOGBOOK_REPORT_DIR", raising=False)
    monkeypatch.setenv("LOGIX_CONFIG", str(tmp_path / "empty.env"))
    (tmp_path / "empty.env").write_text("", encoding="utf-8")
    paths._CONFIG_CACHE = None
    monkeypatch.setattr(paths, "user_data_home", lambda: tmp_path / "user")


def _unwritable(tmp_path) -> Path:
    """A path that cannot be mkdir'd: a regular file already sits there.
    Stands in for a root-owned directory without needing to be root."""
    blocked = tmp_path / "blocked"
    blocked.write_text("not a directory", encoding="utf-8")
    return blocked / "reports"


def test_default_falls_back_when_the_system_dir_is_not_writable(tmp_path, monkeypatch):
    monkeypatch.setattr(paths, "default_reports_dir", lambda: _unwritable(tmp_path))
    got = paths.writable_reports_dir()
    assert got == tmp_path / "user" / "reports"
    assert got.is_dir(), "the fallback must exist and be usable"


def test_a_writable_default_is_used_as_is(tmp_path, monkeypatch):
    wanted = tmp_path / "system" / "reports"
    monkeypatch.setattr(paths, "default_reports_dir", lambda: wanted)
    assert paths.writable_reports_dir() == wanted
    assert wanted.is_dir()


def test_an_explicit_directory_is_never_silently_redirected(tmp_path, monkeypatch):
    """Reports carry PII. An admin who names a volume gets that volume, or a
    loud failure -- never a quiet write to somewhere else."""
    explicit = _unwritable(tmp_path)
    monkeypatch.setenv("LOGBOOK_REPORT_DIR", str(explicit))
    paths._CONFIG_CACHE = None

    got = paths.writable_reports_dir()
    assert got == explicit, "an explicit reports dir was silently relocated"
    assert not (tmp_path / "user" / "reports").exists(), \
        "fell back to the per-user directory despite an explicit setting"


def test_an_explicit_writable_directory_is_honoured(tmp_path, monkeypatch):
    explicit = tmp_path / "on-the-encrypted-volume"
    monkeypatch.setenv("LOGBOOK_REPORT_DIR", str(explicit))
    paths._CONFIG_CACHE = None
    assert paths.writable_reports_dir() == explicit
    assert explicit.is_dir()


def test_user_data_home_is_under_the_users_own_home(monkeypatch):
    """Whatever the platform, the fallback must be somewhere the running user
    owns -- otherwise it is the same bug in a new location."""
    monkeypatch.undo()
    home = Path.home().resolve()
    real = paths.user_data_home().resolve()
    if sys.platform.startswith("win"):
        assert real.is_relative_to(home) or "AppData" in str(real)
    else:
        assert real.is_relative_to(home)
