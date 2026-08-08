"""The backup/restore round trip, exercised for real.

Backups were automated; restoring from one was four lines of `cp` in the
runbook that had never been run. A backup you have never restored is a hope --
the failure modes it hides (an older schema, a truncated file that still opens,
a copy taken while the server held the DB) all look fine right up until the
moment you need them.
"""
import importlib
import sqlite3
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))

backup_db = importlib.import_module("ops.backup_db")
restore_db = importlib.import_module("ops.restore_db")


def _make_db(path: Path, rows: int = 3, with_new_columns: bool = True) -> None:
    """A miniature physical_log carrying every column ops/ touches.

    with_new_columns=False simulates a snapshot taken before a later migration
    added identity_source/person_role -- the case the restore has to repair.
    """
    conn = sqlite3.connect(str(path))
    try:
        extra = ", identity_source TEXT, person_role TEXT" if with_new_columns else ""
        conn.execute(
            "CREATE TABLE physical_log (id INTEGER PRIMARY KEY AUTOINCREMENT, "
            "timestamp TEXT NOT NULL, event TEXT NOT NULL, nama TEXT, nim TEXT, "
            "username TEXT, windows_user TEXT, keterangan TEXT, raw_json TEXT, "
            f"session_id TEXT{extra})"
        )
        for i in range(rows):
            conn.execute(
                "INSERT INTO physical_log (timestamp, event, nama, nim, username, "
                "windows_user, keterangan, session_id) VALUES (?,?,?,?,?,?,?,?)",
                (f"2026-05-0{i + 1}T08:00:00", "START", f"Mahasiswa {i}", f"16222104{i}",
                 f"user{i}", f"LAB\\user{i}", "Praktikum", f"s{i}"),
            )
        conn.commit()
    finally:
        conn.close()


def test_a_backup_can_actually_be_restored(tmp_path):
    db = tmp_path / "central_logix.db"
    backups = tmp_path / "backups"
    backups.mkdir()
    _make_db(db, rows=3)

    assert backup_db.main(["--db", str(db), "--backup-dir", str(backups)]) == 0
    snapshots = restore_db.available_backups(backups)
    assert len(snapshots) == 1

    # Lose the database entirely, the way a disk failure would.
    db.unlink()
    assert restore_db.restore(snapshots[0], db) == 0
    assert db.exists()

    conn = sqlite3.connect(str(db))
    try:
        (n,) = conn.execute("SELECT COUNT(*) FROM physical_log").fetchone()
    finally:
        conn.close()
    assert n == 3


def test_restore_keeps_the_current_database_aside_before_overwriting(tmp_path):
    """Restoring the wrong snapshot must not be the end of the story."""
    db = tmp_path / "central_logix.db"
    backups = tmp_path / "backups"
    backups.mkdir()
    _make_db(db, rows=2)
    backup_db.main(["--db", str(db), "--backup-dir", str(backups)])

    # The live DB moves on after the backup was taken.
    _make_db(db.with_name("newer.db"), rows=9)
    db.unlink()
    db.with_name("newer.db").rename(db)

    assert restore_db.restore(restore_db.available_backups(backups)[0], db) == 0
    aside = list(tmp_path.glob("central_logix.pre-restore-*.db"))
    assert len(aside) == 1, "the pre-restore copy is the only way back from a wrong restore"
    conn = sqlite3.connect(str(aside[0]))
    try:
        (n,) = conn.execute("SELECT COUNT(*) FROM physical_log").fetchone()
    finally:
        conn.close()
    assert n == 9


def test_a_corrupt_backup_is_refused_rather_than_installed(tmp_path):
    db = tmp_path / "central_logix.db"
    _make_db(db, rows=1)
    bad = tmp_path / "central_logix-20260101-000000.db"
    bad.write_bytes(b"SQLite format 3\x00" + b"\x00garbage" * 200)

    assert restore_db.restore(bad, db) == 1
    # The good database is untouched.
    conn = sqlite3.connect(str(db))
    try:
        (n,) = conn.execute("SELECT COUNT(*) FROM physical_log").fetchone()
    finally:
        conn.close()
    assert n == 1
    assert not list(tmp_path.glob("*.pre-restore-*.db"))


def test_dry_run_verifies_without_writing(tmp_path):
    db = tmp_path / "central_logix.db"
    backups = tmp_path / "backups"
    backups.mkdir()
    _make_db(db, rows=2)
    backup_db.main(["--db", str(db), "--backup-dir", str(backups)])
    snapshot = restore_db.available_backups(backups)[0]

    db.unlink()
    assert restore_db.restore(snapshot, db, dry_run=True) == 0
    assert not db.exists(), "a dry run must not restore anything"


def test_an_older_snapshot_is_brought_up_to_the_current_schema(tmp_path):
    """The quiet failure: a snapshot from before a column was added restores
    fine and then breaks the app at runtime. Migrating during the restore is
    what turns that into a problem you find now instead of at 9am Monday."""
    db = tmp_path / "central_logix.db"
    old = tmp_path / "central_logix-20250101-000000.db"
    _make_db(old, rows=2, with_new_columns=False)

    cols_before = {r[1] for r in sqlite3.connect(str(old)).execute(
        "PRAGMA table_info(physical_log)").fetchall()}
    assert "identity_source" not in cols_before

    assert restore_db.restore(old, db) == 0

    conn = sqlite3.connect(str(db))
    try:
        cols_after = {r[1] for r in conn.execute("PRAGMA table_info(physical_log)").fetchall()}
        (n,) = conn.execute("SELECT COUNT(*) FROM physical_log").fetchone()
    finally:
        conn.close()
    assert "identity_source" in cols_after, "restore must migrate an older snapshot"
    assert "server_received_at" in cols_after
    assert n == 2, "migrating must not lose the rows"


def test_listing_backups_reports_nothing_rather_than_crashing(tmp_path):
    assert restore_db.available_backups(tmp_path / "nope") == []
    assert restore_db.main(["--backup-dir", str(tmp_path / "nope"), "--list"]) == 1


def test_retention_and_restore_compose(tmp_path):
    """Redaction must survive a backup/restore cycle -- purged personal data
    coming back from a restore would be a quiet privacy regression."""
    retention = importlib.import_module("ops.retention")
    db = tmp_path / "central_logix.db"
    backups = tmp_path / "backups"
    backups.mkdir()
    _make_db(db, rows=2)

    assert retention.purge(db, days=1) == 2
    backup_db.main(["--db", str(db), "--backup-dir", str(backups)])
    db.unlink()
    assert restore_db.restore(restore_db.available_backups(backups)[0], db) == 0

    conn = sqlite3.connect(str(db))
    try:
        names = {r[0] for r in conn.execute("SELECT nama FROM physical_log").fetchall()}
    finally:
        conn.close()
    assert names == {retention.REDACTED_MARKER}
