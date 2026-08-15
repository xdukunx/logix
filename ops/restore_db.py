#!/usr/bin/env python3
"""Restore the Logix central database from a backup -- and prove it worked.

The backup half of this was already automated and the restore half was four
lines of `cp` in the runbook that nobody had ever run. A backup you have never
restored is a hope, not a backup: the failure modes it hides are a snapshot of
an older schema, a truncated file that still opens, and a copy made while the
server held the DB open.

So this does the whole operation and checks it:

  1. refuses to run while the server is holding the database (unless --force)
  2. keeps the current DB aside as .pre-restore-<stamp> before overwriting
  3. PRAGMA integrity_check on the RESTORED file, not just the backup
  4. brings the schema up to date -- an older snapshot is missing whatever
     columns have been added since, and the app would fail at runtime, not here
  5. prints row counts so the operator can see they got the data they expected

  python3 ops/restore_db.py --list             # what is available
  python3 ops/restore_db.py --latest           # restore the newest
  python3 ops/restore_db.py --from <path>      # restore a specific file
  python3 ops/restore_db.py --latest --dry-run # check it, change nothing

Stop the server first. On Windows:
  Stop-ScheduledTask -TaskName "Logix Server"
On Linux:
  sudo systemctl stop logix-server
"""
from __future__ import annotations

import argparse
import os
import shutil
import sqlite3
import sys
from datetime import datetime
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DEFAULT_DB = Path(os.environ.get("LOGIX_DB", REPO / "server" / "central_logix.db"))
DEFAULT_BACKUP_DIR = Path(os.environ.get("LOGIX_BACKUP_DIR", REPO / "server" / "backups"))
PREFIX = "central_logix-"

# Tables worth counting after a restore. Not exhaustive on purpose -- these are
# the ones whose emptiness would mean the restore silently gave you nothing.
COUNTED_TABLES = ("physical_log", "devices", "alerts")


def log(msg: str) -> None:
    print(f"[{datetime.now():%Y-%m-%d %H:%M:%S}] {msg}")


def available_backups(backup_dir: Path) -> list[Path]:
    if not backup_dir.exists():
        return []
    return sorted(backup_dir.glob(f"{PREFIX}*.db"), reverse=True)


def integrity_ok(db: Path) -> bool:
    try:
        conn = sqlite3.connect(str(db))
        try:
            row = conn.execute("PRAGMA integrity_check").fetchone()
            return bool(row and row[0] == "ok")
        finally:
            conn.close()
    except sqlite3.Error as exc:
        log(f"ERROR: cannot open {db.name}: {exc}")
        return False


def table_counts(db: Path) -> dict[str, int]:
    counts: dict[str, int] = {}
    conn = sqlite3.connect(str(db))
    try:
        for table in COUNTED_TABLES:
            try:
                (n,) = conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()
                counts[table] = n
            except sqlite3.Error:
                counts[table] = -1  # table absent in this snapshot
    finally:
        conn.close()
    return counts


def migrate_restored(db: Path) -> bool:
    """Run the app's own schema setup against the restored file.

    An older snapshot predates whatever columns have been added since it was
    taken. Both init_db() and init_control_tables() are additive and
    idempotent, so this is safe on a current backup and necessary on an old
    one -- and doing it here means the gap surfaces during the restore rather
    than as a 500 the first time somebody loads the dashboard.
    """
    server_dir = REPO / "server"
    sys.path.insert(0, str(server_dir))
    previous = os.environ.get("LOGIX_DEV_MODE")
    try:
        os.environ.setdefault("LOGIX_DEV_MODE", "1")  # import-time posture check
        import main  # type: ignore

        main.DB_PATH = db
        main.init_db()
        main.init_control_tables()
        return True
    except Exception as exc:  # pragma: no cover - depends on the app importing
        log(f"WARNING: could not apply schema migrations: {exc}")
        log("  the file is restored; start the server and check its log.")
        return False
    finally:
        if previous is None:
            os.environ.pop("LOGIX_DEV_MODE", None)
        else:
            os.environ["LOGIX_DEV_MODE"] = previous
        sys.path.remove(str(server_dir))


def server_is_holding(db: Path) -> bool:
    """Best-effort check that nothing has the DB open for writing.

    SQLite lets several processes open a file, so this cannot be conclusive --
    it catches the common and costly case of restoring underneath a running
    server, which produces a corrupt result that looks fine until it doesn't.
    """
    if not db.exists():
        return False
    try:
        conn = sqlite3.connect(f"file:{db}?mode=rw", uri=True, timeout=0.5)
        try:
            conn.execute("BEGIN IMMEDIATE")
            conn.rollback()
            return False
        finally:
            conn.close()
    except sqlite3.OperationalError:
        return True


def restore(source: Path, db: Path, dry_run: bool = False, force: bool = False) -> int:
    if not source.exists():
        log(f"ERROR: backup not found: {source}")
        return 1
    if not integrity_ok(source):
        log(f"ERROR: {source.name} fails integrity_check -- refusing to restore it")
        return 1

    counts = table_counts(source)
    log(f"source: {source.name} ({source.stat().st_size / 1024:.0f} KB)")
    for table, n in counts.items():
        log(f"  {table}: {'absent' if n < 0 else n} row(s)")

    if dry_run:
        log("[dry-run] backup is readable and passes integrity_check; nothing written.")
        return 0

    if not force and server_is_holding(db):
        log(f"ERROR: {db.name} is locked -- the server looks like it is still running.")
        log("  Stop it first, or pass --force if you are certain.")
        return 1

    if db.exists():
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        aside = db.with_suffix(f".pre-restore-{stamp}.db")
        shutil.copy2(db, aside)
        log(f"kept the current database aside as {aside.name}")

    shutil.copy2(source, db)
    log(f"restored into {db}")

    if not integrity_ok(db):
        log("ERROR: the RESTORED file fails integrity_check.")
        return 1
    log("integrity_check: ok")

    migrate_restored(db)
    for table, n in table_counts(db).items():
        log(f"  {table}: {'absent' if n < 0 else n} row(s)")
    log("Restore complete. Start the server and confirm the dashboard loads.")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--db", type=Path, default=DEFAULT_DB)
    ap.add_argument("--backup-dir", type=Path, default=DEFAULT_BACKUP_DIR)
    group = ap.add_mutually_exclusive_group()
    group.add_argument("--list", action="store_true", help="list available backups and exit")
    group.add_argument("--latest", action="store_true", help="restore the newest backup")
    group.add_argument("--from", dest="source", type=Path, help="restore this specific file")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--force", action="store_true",
                    help="restore even if the database appears to be in use")
    ns = ap.parse_args(argv)

    backups = available_backups(ns.backup_dir)
    if ns.list or not (ns.latest or ns.source):
        if not backups:
            log(f"no backups in {ns.backup_dir}")
            return 1
        log(f"{len(backups)} backup(s) in {ns.backup_dir}:")
        for b in backups:
            size = b.stat().st_size / 1024
            when = datetime.fromtimestamp(b.stat().st_mtime)
            print(f"  {b.name}  {size:8.0f} KB  {when:%Y-%m-%d %H:%M}")
        if not ns.list:
            log("pick one with --from, or use --latest")
        return 0

    source = ns.source if ns.source else backups[0] if backups else None
    if source is None:
        log(f"no backups in {ns.backup_dir}")
        return 1
    return restore(source, ns.db, dry_run=ns.dry_run, force=ns.force)


if __name__ == "__main__":
    raise SystemExit(main())
