// Riwayat -- session + audit history. Replaces the old Analytics page.
// Design: docs/design_handoff_logix_v3/LogiX Riwayat.dc.html (D-04) + README
// section 2.
//
// Explicitly ZERO charts: the heat map, Gantt, per-tujuan and per-workstation
// breakdowns and the "Jam Puncak"/"Perangkat Teratas" KPIs were all a
// deliberate pruning decision. What replaces them is three numbers inline in a
// sentence, a period preset, and exports -- deep analysis happens in the
// downloaded file, not on screen.
import { useCallback, useMemo, useState } from "react";

import { fetchWithAuth, getJson } from "../api";
import { STATUS_LABEL, type StationStatus } from "../tokens";
import type { AuditAction, SessionSpan } from "../types";
import { Mono, PageHeader, StatusDot } from "../ui/base";
import { Pagination, PillSelect, PillTabs, SearchChip } from "../ui/controls";
import { useToast } from "../ui/overlays";
import { Table, type Column } from "../ui/table";
import { formatDuration, formatLogTime, usePolling } from "../util";

type Period = "hari" | "7hari" | "bulan" | "semester" | "semua";
type SubTab = "sesi" | "audit";
type ExportFormat = "xlsx" | "csv" | "per_user";

const PERIODS: { value: Period; label: string; isDivided?: boolean }[] = [
  { value: "hari", label: "Hari ini" },
  { value: "7hari", label: "7 hari terakhir" },
  { value: "bulan", label: "Bulan ini" },
  { value: "semester", label: "Semester ini" },
  { value: "semua", label: "Semua waktu", isDivided: true },
];

const EXPORTS: { value: ExportFormat; label: string }[] = [
  { value: "xlsx", label: "Excel (.xlsx)" },
  { value: "csv", label: "CSV" },
  { value: "per_user", label: "Rekap per-pengguna" },
];

const iso = (d: Date) =>
  `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;

/**
 * Resolve a preset to an inclusive YYYY-MM-DD range. "Semester ini" follows
 * the Indonesian academic split: Feb-Jul (genap) and Aug-Jan (ganjil).
 */
const rangeFor = (period: Period): { start_date?: string; end_date?: string } => {
  const now = new Date();
  const end = iso(now);
  switch (period) {
    case "hari":
      return { start_date: end, end_date: end };
    case "7hari": {
      const from = new Date(now);
      from.setDate(from.getDate() - 6);
      return { start_date: iso(from), end_date: end };
    }
    case "bulan":
      return { start_date: iso(new Date(now.getFullYear(), now.getMonth(), 1)), end_date: end };
    case "semester": {
      const m = now.getMonth();
      const start =
        m >= 1 && m <= 6
          ? new Date(now.getFullYear(), 1, 1)
          : new Date(m === 0 ? now.getFullYear() - 1 : now.getFullYear(), 7, 1);
      return { start_date: iso(start), end_date: end };
    }
    default:
      return {};
  }
};

const PAGE_SIZE = 25;

const AUDIT_STATUS: Record<string, StationStatus> = {
  done: "active",
  queued: "idle",
  failed: "alert",
  expired: "locked",
};

const AUDIT_LABEL: Record<string, string> = {
  done: "OK",
  queued: "Antre",
  failed: "Gagal",
  expired: "Kedaluwarsa",
};

export default function Riwayat() {
  const toast = useToast();
  const [period, setPeriod] = useState<Period>("bulan");
  const [tab, setTab] = useState<SubTab>("sesi");
  const [search, setSearch] = useState("");
  const [deviceFilter, setDeviceFilter] = useState("");
  const [page, setPage] = useState(1);

  const [summary, setSummary] = useState<{ hours: number; sessions: number; users: number } | null>(null);
  const [sessions, setSessions] = useState<{ total: number; sessions: SessionSpan[] }>({ total: 0, sessions: [] });
  const [audit, setAudit] = useState<{ total: number; actions: AuditAction[] }>({ total: 0, actions: [] });

  const range = useMemo(() => rangeFor(period), [period]);

  const query = useCallback(
    (extra: Record<string, string | number>) => {
      const params = new URLSearchParams();
      if (range.start_date) params.set("start_date", range.start_date);
      if (range.end_date) params.set("end_date", range.end_date);
      for (const [k, v] of Object.entries(extra)) if (v !== "" && v != null) params.set(k, String(v));
      return params.toString();
    },
    [range],
  );

  const refresh = useCallback(async () => {
    try {
      setSummary(
        await getJson<{ hours: number; sessions: number; users: number }>(
          `/api/sessions/summary?${query({})}`,
          "Gagal memuat ringkasan",
        ),
      );
    } catch {
      setSummary(null);
    }
    const offset = (page - 1) * PAGE_SIZE;
    try {
      if (tab === "sesi") {
        setSessions(
          await getJson(
            `/api/sessions/spans?${query({ limit: PAGE_SIZE, offset, username: search, hostname: deviceFilter })}`,
            "Gagal memuat log sesi",
          ),
        );
      } else {
        setAudit(
          await getJson(
            `/api/audit-log?${query({ limit: PAGE_SIZE, offset, target_device: deviceFilter || search })}`,
            "Gagal memuat log audit",
          ),
        );
      }
    } catch (err) {
      toast((err as Error).message, "alert");
    }
  }, [query, page, tab, search, deviceFilter, toast]);

  usePolling(refresh, 30000);

  const download = async (format: ExportFormat) => {
    try {
      const res = await fetchWithAuth(`/api/reports?${query({ format })}`);
      if (!res.ok) throw new Error("Gagal membuat berkas ekspor");
      const blob = await res.blob();
      const disposition = res.headers.get("Content-Disposition") || "";
      const match = /filename="?([^"]+)"?/.exec(disposition);
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url;
      a.download = match?.[1] || (format === "xlsx" ? "laporan.xlsx" : "laporan.csv");
      a.click();
      URL.revokeObjectURL(url);
      toast("Berkas ekspor diunduh.");
    } catch (err) {
      toast((err as Error).message, "alert");
    }
  };

  const sessionColumns: Column<SessionSpan>[] = [
    {
      key: "waktu",
      header: "Waktu",
      width: "150px",
      phone: "primary",
      render: (r) => <Mono style={{ fontSize: 12.5 }}>{formatLogTime(r.timestamp)}</Mono>,
    },
    {
      key: "perangkat",
      header: "Perangkat",
      width: "120px",
      phone: "primary",
      render: (r) => <Mono style={{ fontSize: 12.5 }}>{r.hostname || "-"}</Mono>,
    },
    { key: "pengguna", header: "Pengguna", width: "1fr", phone: "secondary", render: (r) => r.nama || r.username || "-" },
    { key: "tipe", header: "Tipe akses", width: "110px", phone: "secondary", render: (r) => r.session_type || "-" },
    {
      key: "tujuan",
      header: "Tujuan",
      width: "1.3fr",
      phone: "secondary",
      render: (r) => <span style={{ color: "var(--lx-muted)" }}>{r.tujuan || "-"}</span>,
    },
    {
      key: "durasi",
      header: "Durasi",
      width: "90px",
      align: "right",
      phone: "secondary",
      // A null duration means the session has a START but no close event yet.
      render: (r) => (
        <Mono style={{ fontSize: 12.5 }}>
          {r.duration_seconds == null ? "berjalan" : formatDuration(r.duration_seconds)}
        </Mono>
      ),
    },
  ];

  const auditColumns: Column<AuditAction>[] = [
    {
      key: "waktu",
      header: "Waktu",
      width: "136px",
      phone: "primary",
      render: (r) => <Mono style={{ fontSize: 12 }}>{formatLogTime(r.timestamp)}</Mono>,
    },
    { key: "aktor", header: "Aktor", width: "110px", phone: "secondary", render: (r) => r.actor_email || "sistem" },
    {
      key: "target",
      header: "Target",
      width: "100px",
      phone: "primary",
      render: (r) => <Mono style={{ fontSize: 12 }}>{r.target_device || "-"}</Mono>,
    },
    { key: "aksi", header: "Aksi", width: "1fr", phone: "secondary", render: (r) => r.action_type },
    {
      key: "status",
      header: "Status",
      width: "88px",
      phone: "secondary",
      render: (r) => (
        <span style={{ display: "inline-flex", alignItems: "center", gap: 6 }}>
          <StatusDot status={AUDIT_STATUS[r.status] ?? "idle"} />
          {AUDIT_LABEL[r.status] ?? STATUS_LABEL.idle}
        </span>
      ),
    },
    {
      key: "alasan",
      header: "Alasan",
      width: "1.2fr",
      render: (r) => <span style={{ color: "var(--lx-muted)" }}>{r.reason || "-"}</span>,
    },
  ];

  const total = tab === "sesi" ? sessions.total : audit.total;
  const shown = tab === "sesi" ? sessions.sessions.length : audit.actions.length;
  const from = total === 0 ? 0 : (page - 1) * PAGE_SIZE + 1;
  const pageCount = Math.max(1, Math.ceil(total / PAGE_SIZE));

  const changeTab = (next: SubTab) => {
    setTab(next);
    setPage(1);
  };

  return (
    <>
      <PageHeader
        title="Riwayat"
        summary={
          summary ? (
            <>
              <Mono style={{ color: "var(--lx-text)" }}>{summary.hours} j</Mono> total ·{" "}
              <Mono style={{ color: "var(--lx-text)" }}>{summary.sessions}</Mono> sesi ·{" "}
              <Mono style={{ color: "var(--lx-text)" }}>{summary.users}</Mono> pengguna
            </>
          ) : (
            "Memuat ringkasan..."
          )
        }
        action={
          <div style={{ display: "flex", gap: 10, flexWrap: "wrap" }}>
            <PillSelect
              value={period}
              options={PERIODS}
              onChange={(p) => {
                setPeriod(p);
                setPage(1);
              }}
            />
            <PillSelect
              triggerLabel="Unduh"
              options={EXPORTS}
              onChange={download}
              isAccent
              width={196}
            />
          </div>
        }
      />

      <div style={{ marginBottom: 18 }}>
        <PillTabs
          ariaLabel="Jenis log"
          value={tab}
          onChange={changeTab}
          options={[
            { value: "sesi", label: "Log Sesi" },
            { value: "audit", label: "Log Audit" },
          ]}
        />
      </div>

      <div style={{ display: "flex", gap: 10, marginBottom: 16, flexWrap: "wrap" }}>
        <SearchChip
          value={search}
          onChange={(v) => {
            setSearch(v);
            setPage(1);
          }}
          placeholder="Cari pengguna / perangkat"
        />
        <SearchChip
          value={deviceFilter}
          onChange={(v) => {
            setDeviceFilter(v);
            setPage(1);
          }}
          placeholder="Perangkat"
          width={180}
        />
      </div>

      {tab === "sesi" ? (
        <Table
          columns={sessionColumns}
          rows={sessions.sessions}
          getRowKey={(r) => r.session_id}
          emptyLabel="Tidak ada sesi pada periode ini."
        />
      ) : (
        <Table
          columns={auditColumns}
          rows={audit.actions}
          getRowKey={(r) => `${r.timestamp}-${r.target_device}-${r.action_type}`}
          emptyLabel="Tidak ada aksi admin pada periode ini."
        />
      )}

      <div style={{ display: "flex", alignItems: "center", marginTop: 14, gap: 12, flexWrap: "wrap" }}>
        <span style={{ fontSize: 12.5, color: "var(--lx-muted)" }}>
          Menampilkan{" "}
          <Mono>
            {from}–{from + Math.max(0, shown - 1)}
          </Mono>{" "}
          dari <Mono>{total}</Mono> {tab === "sesi" ? "baris sesi" : "aksi"}
        </span>
        <span style={{ marginLeft: "auto" }}>
          <Pagination page={page} pageCount={pageCount} onChange={setPage} />
        </span>
      </div>
    </>
  );
}
