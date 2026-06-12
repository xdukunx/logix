#!/usr/bin/env python3
from __future__ import annotations
import argparse, sqlite3, sys, os
from pathlib import Path
DB=Path(os.environ.get('NOTIFY_DB','/opt/software/notify/notify.db'))

def main(argv):
    p=argparse.ArgumentParser(description='Run a read-only SQLite query using Python sqlite3, avoiding broken sqlite3 CLI libraries.')
    p.add_argument('sql', nargs='?', default="select id,timestamp,event,session_type,nama,tujuan,keterangan from physical_log order by id desc limit 10")
    p.add_argument('--db', default=str(DB))
    ns=p.parse_args(argv)
    sql=ns.sql.strip()
    if not sql.lower().startswith(('select','pragma')):
        raise SystemExit('Only SELECT/PRAGMA are allowed via logbook-sql')
    con=sqlite3.connect(ns.db)
    con.row_factory=sqlite3.Row
    rows=con.execute(sql).fetchall()
    if not rows:
        print('(no rows)'); return 0
    cols=rows[0].keys()
    print('\t'.join(cols))
    for r in rows:
        print('\t'.join('' if r[c] is None else str(r[c]) for c in cols))
    return 0
if __name__=='__main__':
    raise SystemExit(main(sys.argv[1:]))
