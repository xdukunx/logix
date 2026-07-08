#!/usr/bin/env python3
"""Prune old generated Excel reports.

The server writes report .xlsx files into server/reports/ on every download
(`GET /api/reports`). They contain PII and accumulate forever -- both a disk
and a data-retention concern. This deletes ones older than N days (default 7);
they can always be regenerated on demand.

  python3 ops/cleanup_reports.py                # prune with defaults
  python3 ops/cleanup_reports.py --keep-days 3

Config via env (flags win): LOGIX_REPORTS_DIR, LOGIX_REPORTS_KEEP_DAYS.
"""
from __future__ import annotations

import argparse
import os
import time
from datetime import datetime
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DEFAULT_REPORTS_DIR = Path(os.environ.get("LOGIX_REPORTS_DIR", REPO / "server" / "reports"))
DEFAULT_KEEP_DAYS = int(os.environ.get("LOGIX_REPORTS_KEEP_DAYS", "7"))


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="Prune old Logix report files.")
    ap.add_argument("--reports-dir", type=Path, default=DEFAULT_REPORTS_DIR)
    ap.add_argument("--keep-days", type=int, default=DEFAULT_KEEP_DAYS)
    ns = ap.parse_args(argv)

    if not ns.reports_dir.is_dir():
        print(f"cleanup: reports dir {ns.reports_dir} not found; nothing to do")
        return 0

    cutoff = time.time() - ns.keep_days * 86400
    removed = kept = 0
    for f in ns.reports_dir.glob("*.xlsx"):
        if f.stat().st_mtime < cutoff:
            f.unlink()
            removed += 1
        else:
            kept += 1
    print(f"{datetime.now().isoformat(timespec='seconds')} cleanup: removed {removed}, "
          f"kept {kept} (retention {ns.keep_days}d) in {ns.reports_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
