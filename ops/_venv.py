#!/usr/bin/env python3
"""Run the ops scripts under the interpreter that has the dependencies.

The server's dependencies live in `server/.venv`, not in the system Python:
Debian 12 and Ubuntu 23.04+ mark theirs as externally managed (PEP 668), so
`pip install` cannot write there at all. That is the right place for them, but
it leaves a trap -- every doc, runbook and muscle memory says
`python3 ops/serve.py`, and the system python running that has no fastapi, so
it dies on ModuleNotFoundError with nothing to suggest what went wrong.

Rather than rewrite every documented command to carry a
`server/.venv/bin/python` prefix (and have them drift apart again), the
scripts that need those dependencies re-exec themselves under the venv when
they find they are missing. Plain `python3 ops/serve.py` keeps working, on
every platform, however the server was installed.
"""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

# Set on the child so a venv that is somehow still missing the dependency
# fails with the real ImportError instead of re-execing forever.
_GUARD = "LOGIX_VENV_REEXEC"


def venv_python() -> Path | None:
    """The venv interpreter, if `install/setup_server.py` created one."""
    base = REPO / "server" / ".venv"
    py = base / ("Scripts/python.exe" if os.name == "nt" else "bin/python")
    return py if py.exists() else None


def ensure(module: str = "fastapi") -> None:
    """Re-exec under server/.venv if `module` is missing from this interpreter.

    A no-op in the common cases: the dependency is already importable (someone
    installed it system-wide, or we are already the venv), or there is no venv
    to switch to -- in which case the caller's own ImportError is the more
    useful thing to show.
    """
    if os.environ.get(_GUARD):
        return
    try:
        __import__(module)
        return
    except ImportError:
        pass

    py = venv_python()
    if py is None:
        return

    # "Am I already running as the venv interpreter?" must be answered with
    # sys.prefix, NOT by comparing resolved executable paths. On Linux a
    # venv's bin/python is a symlink to the base interpreter, so resolving
    # both sides turns /usr/bin/python3 == /usr/bin/python3 and every re-exec
    # is skipped -- which is exactly how ops/go_live.py reached `import main`
    # under a system python with no fastapi on Ubuntu, while Windows (where
    # venvs copy python.exe instead of symlinking it) looked fine.
    # sys.prefix points at the venv for a venv interpreter and at /usr for the
    # system one, which is the distinction actually being made here.
    try:
        if Path(sys.prefix).resolve() == (REPO / "server" / ".venv").resolve():
            return
    except OSError:
        return

    # flush: stdout is block-buffered when it is a pipe (a CI step, `| tee`,
    # anything capturing output), so without this the notice sits in the
    # parent's buffer until exit and lands AFTER everything the child printed
    # -- announcing the interpreter switch below the work it supposedly
    # preceded.
    print(f"Using the server's virtualenv: {py}", flush=True)
    env = dict(os.environ, **{_GUARD: "1"})
    result = subprocess.run([str(py), *sys.argv], env=env)
    sys.exit(result.returncode)
