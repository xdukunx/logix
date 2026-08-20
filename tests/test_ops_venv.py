"""ops/_venv.py: hop into server/.venv when the dependencies are not here.

The bug this file exists to prevent: the "am I already the venv interpreter?"
guard originally compared Path(sys.executable).resolve() with the venv's
python. On Linux a venv's bin/python is a SYMLINK to the base interpreter, so
both sides resolved to /usr/bin/python3, the guard concluded it was already
running inside the venv, and no re-exec ever happened. `python3 ops/serve.py`
and `python3 ops/go_live.py` then died on ModuleNotFoundError: fastapi on
every Ubuntu server -- while Windows, where venvs copy python.exe rather than
symlinking it, looked perfectly fine.
"""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "ops"))
import _venv  # noqa: E402


@pytest.fixture()
def venv(tmp_path, monkeypatch):
    """A repo layout with a populated-looking server/.venv."""
    monkeypatch.setattr(_venv, "REPO", tmp_path)
    py = tmp_path / "server" / ".venv" / (
        "Scripts/python.exe" if _venv.os.name == "nt" else "bin/python")
    py.parent.mkdir(parents=True)
    py.write_text("", encoding="utf-8")
    monkeypatch.delenv(_venv._GUARD, raising=False)
    return py


def test_reexecs_when_the_dependency_is_missing(venv, monkeypatch):
    calls = []
    monkeypatch.setattr(_venv.subprocess, "run",
                        lambda cmd, **kw: calls.append(cmd) or _Done(0))
    # Not inside the venv: sys.prefix is the system interpreter's.
    monkeypatch.setattr(sys, "prefix", "/usr")

    with pytest.raises(SystemExit):
        _venv.ensure("a_module_that_does_not_exist_xyz")
    assert calls, "no re-exec happened; the ops scripts would die on ImportError"
    assert str(venv) == calls[0][0]


def test_symlinked_venv_still_reexecs(venv, monkeypatch):
    """The regression itself: on Linux the venv python resolves to the base
    interpreter, so a resolve()-based guard would skip the re-exec here."""
    calls = []
    monkeypatch.setattr(_venv.subprocess, "run",
                        lambda cmd, **kw: calls.append(cmd) or _Done(0))
    monkeypatch.setattr(sys, "prefix", "/usr")
    # Both interpreters resolve to the same real file, as a symlinked venv does.
    monkeypatch.setattr(sys, "executable", str(venv))

    with pytest.raises(SystemExit):
        _venv.ensure("a_module_that_does_not_exist_xyz")
    assert calls, "a symlinked venv suppressed the re-exec (the Ubuntu bug)"


def test_does_not_reexec_into_itself(venv, monkeypatch):
    """Running as the venv interpreter must be a no-op, or it re-execs forever."""
    calls = []
    monkeypatch.setattr(_venv.subprocess, "run",
                        lambda cmd, **kw: calls.append(cmd) or _Done(0))
    # sys.prefix inside a venv IS the venv directory.
    monkeypatch.setattr(sys, "prefix", str(venv.parent.parent))

    _venv.ensure("a_module_that_does_not_exist_xyz")
    assert not calls


def test_guard_env_var_stops_recursion(venv, monkeypatch):
    calls = []
    monkeypatch.setattr(_venv.subprocess, "run",
                        lambda cmd, **kw: calls.append(cmd) or _Done(0))
    monkeypatch.setattr(sys, "prefix", "/usr")
    monkeypatch.setenv(_venv._GUARD, "1")

    _venv.ensure("a_module_that_does_not_exist_xyz")
    assert not calls


def test_importable_module_is_a_no_op(venv, monkeypatch):
    calls = []
    monkeypatch.setattr(_venv.subprocess, "run",
                        lambda cmd, **kw: calls.append(cmd) or _Done(0))
    monkeypatch.setattr(sys, "prefix", "/usr")

    _venv.ensure("json")
    assert not calls


def test_no_venv_lets_the_real_importerror_surface(tmp_path, monkeypatch):
    """With nothing to switch to, the caller's own ImportError is the more
    useful thing to show, so ensure() must return rather than raise."""
    monkeypatch.setattr(_venv, "REPO", tmp_path)
    monkeypatch.delenv(_venv._GUARD, raising=False)
    monkeypatch.setattr(sys, "prefix", "/usr")
    assert _venv.venv_python() is None
    _venv.ensure("a_module_that_does_not_exist_xyz")  # must not raise


class _Done:
    def __init__(self, returncode):
        self.returncode = returncode
