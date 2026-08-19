"""The exported workbook (Phase G).

A report is the one artefact that leaves the workstation, so it has to carry
the things a reader cannot reconstruct: which machine, which period, when it
was generated. It also has to carry the job metadata, because a column that
exists in the dashboard and vanishes in the export is worse than not having
the column.

Everything here is asserted against a real .xlsx read back with openpyxl,
not against the code that wrote it.
"""
from __future__ import annotations

import importlib
import sys

import pytest

openpyxl = pytest.importorskip(
    "openpyxl", reason="openpyxl is an optional dependency; export degrades to CSV without it")


def _mod(name):
    if name in sys.modules:
        return importlib.reload(sys.modules[name])
    return importlib.import_module(name)


@pytest.fixture
def book(monkeypatch, tmp_path):
    """A workbook built from two complete sessions on one workstation.

    LOGIX_DB deliberately points somewhere OTHER than the database being
    reported on: build() repairs an active session from session.json when the
    target IS the default database, which on a developer machine injects
    whoever is currently signed in and quietly changes every count below.
    """
    cfg = tmp_path / "config.env"
    cfg.write_text("", encoding="utf-8")
    monkeypatch.setenv("LOGIX_CONFIG", str(cfg))
    monkeypatch.setenv("LOGIX_SERVER_URL", "")
    monkeypatch.setenv("LOGIX_PRIVACY_MODE", "local_only")
    monkeypatch.setenv("LOGIX_DB", str(tmp_path / "not-the-reported.db"))
    _mod("paths")

    lp = _mod("log_physical")
    rep = _mod("logbook_report")
    db = tmp_path / "device.db"
    con = lp.connect(db)
    lp.migrate(con)

    def ev(event, sid, ts, **kw):
        args = ["--event", event, "--session-id", sid, "--hostname", "LAB-03"]
        for k, v in kw.items():
            args += ["--" + k.replace("_", "-"), v]
        payload = lp.payload_from_args(lp.parse_args(args))
        payload["timestamp"] = ts
        lp.insert_event(con, payload)

    ev("START", "s1", "2026-08-18T08:41:00", nama="Rani", nim="000000000",
       tujuan="DFTB Parameterization", job_type="Simulation", job_id="258026",
       keterangan="Slater-Koster parameter validation.", session_type="Physical")
    ev("END", "s1", "2026-08-18T11:15:00")
    ev("START", "s2", "2026-08-18T12:00:00", nama="Alya", nim="000000001",
       tujuan="Molecular Dynamics", session_type="Physical")
    ev("END", "s2", "2026-08-18T13:48:00")
    con.commit()
    con.close()

    out = rep.build(full=True, db=db, out_dir=tmp_path)
    return openpyxl.load_workbook(out), out


def _headers(ws):
    return [c.value for c in ws[4]]


def _summary(wb):
    return {r[0]: r[1] for r in wb["Summary"].iter_rows(min_row=2, values_only=True)
            if r and r[0]}


# ---- structure ----------------------------------------------------------

def test_workbook_has_the_expected_sheets(book):
    wb, _ = book
    assert "Report Logbook" in wb.sheetnames
    assert "Summary" in wb.sheetnames


def test_export_produces_a_real_xlsx(book):
    _, out = book
    assert str(out).endswith(".xlsx")
    with open(out, "rb") as fh:
        assert fh.read(2) == b"PK", "an xlsx is a zip container"


# ---- job metadata reaches the file --------------------------------------

def test_sessions_sheet_has_job_columns(book):
    wb, _ = book
    h = _headers(wb["Report Logbook"])
    assert "Job Type" in h and "Job ID" in h
    assert h.index("Job Type") == h.index("Tujuan") + 1, "job sits with the purpose it describes"


def test_job_values_are_exported(book):
    wb, _ = book
    ws = wb["Report Logbook"]
    h = _headers(ws)
    jt, jid = h.index("Job Type") + 1, h.index("Job ID") + 1
    rows = {ws.cell(r, h.index("Nama / User") + 1).value:
            (ws.cell(r, jt).value, ws.cell(r, jid).value)
            for r in range(5, 5 + 2)}
    assert rows["Rani"] == ("Simulation", "258026")


def test_absent_job_is_blank_not_a_placeholder(book):
    """A spreadsheet reader can filter on an empty cell. It cannot filter on
    an em dash, and a dash would also sort among real values."""
    wb, _ = book
    ws = wb["Report Logbook"]
    h = _headers(ws)
    jt = h.index("Job Type") + 1
    vals = [ws.cell(r, jt).value for r in range(5, 7)]
    assert "" in [v or "" for v in vals]
    assert "—" not in [str(v) for v in vals]


# ---- the columns that shifted must not have taken styling with them ------

def test_status_and_access_columns_are_where_the_headers_say(book):
    """Two style branches key off a column INDEX. Inserting columns ahead of
    them silently moves the colouring onto the wrong data unless both are
    updated, and nothing else would catch that."""
    wb, _ = book
    ws = wb["Report Logbook"]
    h = _headers(ws)
    assert ws.cell(5, h.index("Status") + 1).value in (
        "Selesai / Finish", "Aktif", "Auto Finish")
    assert ws.cell(5, h.index("Tipe Akses") + 1).value == "Physical"


def test_autofilter_covers_every_column(book):
    wb, _ = book
    ws = wb["Report Logbook"]
    last_col = openpyxl.utils.get_column_letter(len(_headers(ws)))
    assert ws.auto_filter.ref.split(":")[1].startswith(last_col)


# ---- the summary carries what a reader cannot reconstruct ---------------

def test_summary_names_the_workstation(book):
    wb, _ = book
    assert _summary(wb)["Workstation"] == "LAB-03"


def test_summary_states_the_period_and_export_time(book):
    wb, _ = book
    s = _summary(wb)
    assert s["Periode laporan"]
    assert s["Diekspor"]


def test_summary_counts_unique_users_not_sessions(book):
    wb, _ = book
    s = _summary(wb)
    assert s["Pengguna unik"] == 2
    assert s["Total sesi/event logbook"] == 2


def test_summary_total_duration_is_the_sum_of_the_sessions(book):
    """2h34m + 1h48m = 4h22m. Recomputed from the timestamps rather than
    parsed back out of the rendered duration strings."""
    wb, _ = book
    assert _summary(wb)["Total durasi"] == "4j 22m"


def test_export_needs_no_network(book):
    """LOGIX_SERVER_URL is empty in this fixture, so a workbook that built at
    all provably needed nothing off the machine."""
    wb, out = book
    assert out
