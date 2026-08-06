#!/usr/bin/env python3
"""Run every check Logix has, then open the visual walkthrough.

One command. It starts a real server, exercises the product the way an admin
does, and leaves behind an HTML page with a screenshot and a video of every
step -- that page is the demo.

  python ops/demo.py            # run everything, then open the report
  python ops/demo.py --no-open  # for CI

Stages, in order of how fast they fail:
  1. backend      pytest        -- API, auth, exports, enrolment
  2. client       PowerShell    -- WPF XAML, installer config writer, P/Invoke
  3. typecheck    tsc           -- the dashboard compiles
  4. build        vite          -- and produces the bundle the server serves
  5. end-to-end   Playwright    -- the whole product, in a real browser

The end-to-end stage needs a server. If nothing is already listening it starts
ops/serve.py itself and shuts it down afterwards, so this works from a cold
checkout with no setup.
"""
from __future__ import annotations

import argparse
import os
import shutil
import socket
import subprocess
import sys
import time
import webbrowser
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
FRONTEND = REPO / "frontend"
REPORT = FRONTEND / "playwright-report" / "index.html"
HOST, PORT = "127.0.0.1", 8791


def c(text: str, code: str) -> str:
    return f"\033[{code}m{text}\033[0m" if sys.stdout.isatty() else text


def banner(n: int, total: int, title: str) -> None:
    print(f"\n{c(f'[{n}/{total}]', '36')} {c(title, '1')}")
    print(c("-" * 68, "90"))


def port_open() -> bool:
    with socket.socket() as s:
        s.settimeout(0.4)
        return s.connect_ex((HOST, PORT)) == 0


def resolve(program: str) -> str:
    """Full path to an executable.

    npm and npx are .cmd shims on Windows, which CreateProcess will not find
    from a bare name -- subprocess raises FileNotFoundError. shutil.which knows
    about PATHEXT and returns the real file.
    """
    found = shutil.which(program)
    if not found:
        raise FileNotFoundError(f"{program} is not on PATH")
    return found


def run(cmd: list[str], cwd: Path, label: str) -> tuple[bool, str]:
    """Run a stage, streaming nothing but reporting clearly. Returns (ok, tail)."""
    started = time.time()
    cmd = [resolve(cmd[0]), *cmd[1:]]
    proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, encoding="utf-8", errors="replace")
    took = time.time() - started
    out = (proc.stdout or "") + (proc.stderr or "")
    ok = proc.returncode == 0
    mark = c("PASS", "32") if ok else c("FAIL", "31")
    print(f"  {mark}  {label}  {c(f'({took:.1f}s)', '90')}")
    if not ok:
        tail = "\n".join(line for line in out.splitlines()[-25:])
        print(c("\n".join("      " + l for l in tail.splitlines()), "90"))
    return ok, out


def start_server() -> subprocess.Popen | None:
    """Bring up ops/serve.py and wait for it to answer."""
    proc = subprocess.Popen(
        [sys.executable, str(REPO / "ops" / "serve.py"), "--host", HOST, "--port", str(PORT)],
        cwd=REPO, stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT,
    )
    for _ in range(60):
        if proc.poll() is not None:
            print(c("      server exited during startup -- check ops/go_live.py check", "31"))
            return None
        if port_open():
            return proc
        time.sleep(0.5)
    proc.terminate()
    print(c("      server did not come up in 30s", "31"))
    return None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--no-open", action="store_true", help="do not open the report at the end")
    ap.add_argument("--only", choices=["backend", "client", "typecheck", "build", "e2e"],
                    help="run a single stage")
    ns = ap.parse_args()

    stages = ["backend", "client", "typecheck", "build", "e2e"]
    if ns.only:
        stages = [ns.only]
    total = len(stages)
    results: list[tuple[str, bool]] = []
    server: subprocess.Popen | None = None
    borrowed = False

    print(c("\n  Logix -- full verification", "1"))
    print(c(f"  {len(stages)} stage(s)\n", "90"))

    try:
        for i, stage in enumerate(stages, 1):
            if stage == "backend":
                banner(i, total, "Backend: API, auth, exports, enrolment")
                ok, _ = run([sys.executable, "-m", "pytest", "tests", "-q", "--no-header",
                             "-p", "no:cacheprovider"], REPO, "pytest")

            elif stage == "client":
                banner(i, total, "Client: WPF surfaces, installer, P/Invoke")
                if os.name != "nt":
                    print(f"  {c('SKIP', '33')}  Windows-only stage")
                    continue
                ok, _ = run(["powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
                             "-File", str(REPO / "windows" / "test_logbook_config.ps1")],
                            REPO, "test_logbook_config.ps1")

            elif stage == "typecheck":
                banner(i, total, "Dashboard: TypeScript")
                ok, _ = run(["npx", "tsc", "--noEmit"], FRONTEND, "tsc --noEmit")

            elif stage == "build":
                banner(i, total, "Dashboard: production build")
                ok, _ = run(["npm", "run", "build"], FRONTEND, "vite build")

            else:
                banner(i, total, "End-to-end: the whole product in a browser")
                if port_open():
                    borrowed = True
                    print(c("      using the server already on :8791", "90"))
                else:
                    print(c("      starting ops/serve.py...", "90"))
                    server = start_server()
                    if server is None:
                        results.append((stage, False))
                        continue
                ok, _ = run(["npx", "playwright", "test"], FRONTEND, "playwright")

            results.append((stage, ok))
    finally:
        if server is not None:
            server.terminate()
            try:
                server.wait(timeout=10)
            except subprocess.TimeoutExpired:
                server.kill()
        if borrowed:
            print(c("\n  (left the existing server running)", "90"))

    print("\n" + c("=" * 68, "90"))
    passed = sum(1 for _, ok in results if ok)
    for stage, ok in results:
        print(f"  {c('PASS', '32') if ok else c('FAIL', '31')}  {stage}")
    print(c("=" * 68, "90"))

    if REPORT.exists():
        print(f"\n  Walkthrough: {REPORT}")
        if not ns.no_open:
            webbrowser.open(REPORT.as_uri())

    if passed == len(results):
        print(c(f"\n  All {passed} stage(s) passed.\n", "32"))
        return 0
    print(c(f"\n  {len(results) - passed} of {len(results)} stage(s) failed.\n", "31"))
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
