// Riwayat -- the administrator's analysis page, v4 "Denyut". Replaces the old
// Analytics page.
//
// Top, a bento for the chosen period: how much the lab was used (hours,
// sessions, people), how far those hours can be trusted (sessions still
// running, closed by the server, capped), and then where, when and for what
// -- per station, weekday x hour, per purpose, and how long sessions last.
// Below it the session and audit logs, with everything they could do before.
//
// The headline numbers come from /api/sessions/summary so they always match
// the exports; the charts are computed in RiwayatAnalysis.ts from
// /api/sessions/spans for the same period.
import { useCallback, useEffect, useMemo, useRef, useState, type CSSProperties, type ReactNode } from "react";

import { fetchWithAuth, getJson } from "../api";
import { ACCESS_LABEL, STATUS_LABEL, resolveAccessType, type StationStatus } from "../tokens";
import type { AuditAction, CommandStatus, Device, SessionSpan } from "../types";
import { Card, ErrorState, Mono, PageHeader, SectionLabel, Skeleton, StatusDot } from "../ui/base";
import { Button, Pagination, PillSelect, PillTabs, SearchChip } from "../ui/controls";
import { useBreakpoint, useReducedMotion } from "../ui/hooks";
import { SidePanel, useToast } from "../ui/overlays";
import { Table, type Column } from "../ui/table";
import { BigNumber, CardTitle, Delta } from "../ui/viz";
import { durationSince, formatClock, formatDateTime, formatDuration, formatLogTime } from "../util";
import {
  MAX_SESSION_HOURS,
  analyse,
  clippedHours,
  hoursText,
  iso,
  periodStart,
  leadInDate,
  previousWindow,
  rangeFor,
  rangeLabel,
  spanEnd,
  weekdayOf,
  type Period,
  type Ranked,
} from "./RiwayatAnalysis";
import { DataDial, HeatGrid, HeatLegend, PillBars, RankBars, ShareBreakdown, SplitBar, peakSentence } from "./RiwayatCharts";

type SubTab = "sesi" | "audit";
type ExportFormat = "xlsx" | "csv" | "per_user";

interface Summary {
  hours: number;
  sessions: number;
  users: number;
  open_sessions?: number;
  auto_closed_sessions?: number;
}

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

const PAGE_SIZE = 25;
// The charts need every span of the period, not a page of them. Above this a
// period is analysed from its most recent sessions and the page says so.
const ANALYSIS_LIMIT = 10000;
const TOP_PURPOSES = 5;
const TOP_STATIONS = 8;

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

const AUDIT_FILTERS: { value: "" | CommandStatus; label: string }[] = [
  { value: "", label: "Semua" },
  { value: "done", label: "OK" },
  { value: "queued", label: "Antre" },
  { value: "failed", label: "Gagal" },
  { value: "expired", label: "Kedaluwarsa" },
];

// remote_actions.action_type is an internal code; unknown ones fall through
// as-is rather than being hidden.
const ACTION_LABEL: Record<string, string> = {
  LOCK: "Kunci",
  UNLOCK: "Buka kunci",
  SCREENSHOT: "Cuplikan layar",
  SHUTDOWN: "Matikan",
  RESTART: "Mulai ulang",
  LOGOFF: "Log off pengguna",
  REVOKE_API_KEY: "Cabut kunci API",
  DELETE_DEVICE: "Hapus perangkat",
  RENAME: "Ganti nama",
};

// The reasons the dashboard itself writes for messages; typed reasons pass
// through untouched.
const REASON_LABEL: Record<string, string> = {
  "Direction Message": "Pesan langsung",
  "Emergency Alert": "Siaran darurat",
};

const IDENTITY_LABEL: Record<string, string> = {
  self_declared: "Diisi sendiri",
  unverified: "Belum diverifikasi",
  directory: "Direktori kampus",
};

const actionLabel = (a: AuditAction) => {
  if (a.action_type === "BROADCAST") {
    if (a.reason === "Emergency Alert") return "Siaran darurat";
    return a.target_device === "ALL" ? "Broadcast" : "Pesan";
  }
  return ACTION_LABEL[a.action_type] ?? a.action_type;
};
const reasonLabel = (reason: string | null | undefined) => (reason ? (REASON_LABEL[reason] ?? reason) : "");
const text = (v: unknown) => (v === null || v === undefined ? "" : String(v));
const personName = (s: SessionSpan) => s.nama || s.username || "Tanpa nama";
const accessOf = (s: SessionSpan) => ACCESS_LABEL[resolveAccessType(s.session_type)];

const useDebounced = <T,>(value: T, ms: number) => {
  const [settled, setSettled] = useState(value);
  useEffect(() => {
    const id = window.setTimeout(() => setSettled(value), ms);
    return () => window.clearTimeout(id);
  }, [value, ms]);
  return settled;
};

const Muted = ({ children, style }: { children: ReactNode; style?: CSSProperties }) => (
  <div style={{ fontSize: 12.5, color: "var(--lx-muted)", lineHeight: 1.5, ...style }}>{children}</div>
);

/** The breathing dot of a session that is running right now. */
const LiveDot = () => (
  <span
    className="lx-breathe"
    aria-hidden="true"
    style={{ width: 7, height: 7, borderRadius: 999, background: "var(--lx-status-active)", flexShrink: 0, display: "inline-block" }}
  />
);

/** Small grey marker beside a duration the server inferred or cut. */
const Marker = ({ label, title }: { label: string; title: string }) => (
  <span
    title={title}
    style={{
      fontSize: 10.5,
      fontWeight: 600,
      padding: "1px 7px",
      borderRadius: 999,
      background: "var(--lx-sunken)",
      color: "var(--lx-muted)",
      border: "1px solid var(--lx-border)",
      whiteSpace: "nowrap",
    }}
  >
    {label}
  </span>
);

const detailRow = (label: string, value: ReactNode) => (
  <div style={{ display: "flex", justifyContent: "space-between", alignItems: "baseline", gap: 16 }}>
    <span style={{ color: "var(--lx-muted)", flexShrink: 0 }}>{label}</span>
    <span style={{ textAlign: "right", minWidth: 0, overflowWrap: "anywhere" }}>{value || "-"}</span>
  </div>
);

export default function Riwayat() {
  const toast = useToast();
  const breakpoint = useBreakpoint();
  const isPhone = breakpoint === "phone";
  const isReducedMotion = useReducedMotion();

  const [period, setPeriod] = useState<Period>("bulan");
  const [tab, setTab] = useState<SubTab>("sesi");
  const [search, setSearch] = useState("");
  const [deviceFilter, setDeviceFilter] = useState("");
  const [auditStatus, setAuditStatus] = useState<"" | CommandStatus>("");
  const [page, setPage] = useState(1);
  const [isAllStations, setAllStations] = useState(false);
  const debouncedSearch = useDebounced(search, 300);
  const debouncedDevice = useDebounced(deviceFilter, 300);

  // ---- Period ----
  const now = Date.now();
  const minute = Math.floor(now / 60000);
  const today = iso(new Date(now));
  // Keyed on the date too, so a page left open past midnight moves with it.
  const range = useMemo(() => rangeFor(period), [period, today]);
  const rangeKey = `${period}|${range.start_date ?? ""}|${range.end_date ?? ""}`;
  const from = periodStart(range);

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

  // ---- Overview: summary numbers + every span of the period ----
  const [summary, setSummary] = useState<{ key: string; data: Summary } | null>(null);
  const [summaryError, setSummaryError] = useState<string | null>(null);
  const [analysisData, setAnalysisData] = useState<{
    key: string;
    period: Period;
    from: number | null;
    total: number;
    sessions: SessionSpan[];
  } | null>(null);
  const [analysisError, setAnalysisError] = useState<string | null>(null);
  const [devices, setDevices] = useState<Device[] | null>(null);
  const overviewSeq = useRef(0);

  const refreshOverview = useCallback(async () => {
    const seq = ++overviewSeq.current;
    const [sum, spans, registry] = await Promise.allSettled([
      getJson<Summary>(`/api/sessions/summary?${query({})}`, "Gagal memuat ringkasan"),
      getJson<{ total: number; sessions: SessionSpan[] }>(
        `/api/sessions/spans?${query({ limit: ANALYSIS_LIMIT, ...(range.start_date ? { start_date: leadInDate(range.start_date) } : {}) })}`,
        "Gagal memuat data analisis",
      ),
      getJson<Device[]>("/api/devices", "Gagal mengambil daftar perangkat"),
    ]);
    // A slower answer for a period the admin has already left must not
    // overwrite the one they are looking at.
    if (seq !== overviewSeq.current) return;
    if (sum.status === "fulfilled") {
      setSummary({ key: rangeKey, data: sum.value });
      setSummaryError(null);
    } else {
      setSummaryError((sum.reason as Error).message);
    }
    if (spans.status === "fulfilled") {
      setAnalysisData({ key: rangeKey, period, from, total: spans.value.total, sessions: spans.value.sessions });
      setAnalysisError(null);
    } else {
      setAnalysisError((spans.reason as Error).message);
    }
    // Without devices_read the station chart still lists every station that
    // had a session; it only loses the ones nobody used.
    if (registry.status === "fulfilled") setDevices(registry.value);
    else setDevices((prev) => prev ?? []);
  }, [query, rangeKey, period, from]);

  useEffect(() => {
    refreshOverview();
    const id = window.setInterval(refreshOverview, 60000);
    return () => window.clearInterval(id);
  }, [refreshOverview]);

  // ---- The comparison window, for the delta pill ----
  const prevWin = from === null ? null : previousWindow(period, from, now);
  const prevKey = prevWin ? `${iso(new Date(prevWin.from))}|${iso(new Date(prevWin.to))}` : null;
  const [prevSpans, setPrevSpans] = useState<{ key: string; sessions: SessionSpan[] } | null>(null);
  useEffect(() => {
    if (!prevKey) return;
    let isCancelled = false;
    const [start, end] = prevKey.split("|");
    getJson<{ sessions: SessionSpan[] }>(
      `/api/sessions/spans?start_date=${leadInDate(start)}&end_date=${end}&limit=${ANALYSIS_LIMIT}`,
      "Gagal memuat periode pembanding",
    )
      .then((res) => {
        if (!isCancelled) setPrevSpans({ key: prevKey, sessions: res.sessions });
      })
      .catch(() => {
        // No comparison period simply means no delta pill.
      });
    return () => {
      isCancelled = true;
    };
  }, [prevKey]);

  const analysis = useMemo(
    () =>
      analysisData ? analyse(analysisData.sessions, analysisData.period, analysisData.from, Date.now(), devices) : null,
    // `now` moves every render; the charts only need a fresh "now" once a minute.
    [analysisData, devices, minute],
  );
  const isAnalysisStale = analysisData !== null && analysisData.key !== rangeKey;
  const isSummaryStale = summary !== null && summary.key !== rangeKey;
  const sum = summary?.data ?? null;

  // Both sides counted the same way -- clipped, running sessions up to "now"
  // -- so the pill compares like with like even though the big number beside
  // it (the summary) leaves running sessions out.
  const prevHours =
    prevWin && prevSpans?.key === prevKey ? clippedHours(prevSpans.sessions, prevWin.from, prevWin.to, now) : 0;
  const delta =
    analysis && !isAnalysisStale && prevHours > 0 ? ((analysis.totalHours - prevHours) / prevHours) * 100 : null;

  // ---- Log table ----
  const [sessions, setSessions] = useState<{ total: number; sessions: SessionSpan[] }>({ total: 0, sessions: [] });
  const [audit, setAudit] = useState<{ total: number; actions: AuditAction[] }>({ total: 0, actions: [] });
  const [auditCounts, setAuditCounts] = useState<Record<string, number | null> | null>(null);
  const [loadedKey, setLoadedKey] = useState<string | null>(null);
  const [hasLoaded, setHasLoaded] = useState<Record<SubTab, boolean>>({ sesi: false, audit: false });
  const [tableError, setTableError] = useState<string | null>(null);
  const tableSeq = useRef(0);
  const lastToast = useRef<string | null>(null);

  const auditTarget = debouncedDevice || debouncedSearch;
  const tableKey = [tab, rangeKey, page, debouncedSearch, debouncedDevice, tab === "audit" ? auditStatus : ""].join("|");

  const refreshTable = useCallback(async () => {
    const seq = ++tableSeq.current;
    const offset = (page - 1) * PAGE_SIZE;
    try {
      if (tab === "sesi") {
        const data = await getJson<{ total: number; sessions: SessionSpan[] }>(
          `/api/sessions/spans?${query({ limit: PAGE_SIZE, offset, username: debouncedSearch, hostname: debouncedDevice })}`,
          "Gagal memuat log sesi",
        );
        if (seq !== tableSeq.current) return;
        setSessions(data);
      } else {
        const [data, counts] = await Promise.all([
          getJson<{ total: number; actions: AuditAction[] }>(
            `/api/audit-log?${query({ limit: PAGE_SIZE, offset, target_device: auditTarget, status: auditStatus })}`,
            "Gagal memuat log audit",
          ),
          // limit=0 returns just the count: one per status chip.
          Promise.all(
            AUDIT_FILTERS.filter((f) => f.value).map((f) =>
              getJson<{ total: number }>(
                `/api/audit-log?${query({ limit: 0, target_device: auditTarget, status: f.value })}`,
                "",
              )
                .then((r) => [f.value, r.total] as const)
                .catch(() => [f.value, null] as const),
            ),
          ),
        ]);
        if (seq !== tableSeq.current) return;
        setAudit(data);
        setAuditCounts(Object.fromEntries(counts));
      }
      setLoadedKey(tableKey);
      setHasLoaded((prev) => (prev[tab] ? prev : { ...prev, [tab]: true }));
      setTableError(null);
      lastToast.current = null;
    } catch (err) {
      if (seq !== tableSeq.current) return;
      const message = (err as Error).message;
      setTableError(message);
      // Once per distinct failure, not once every poll.
      if (lastToast.current !== message) {
        toast(message, "alert");
        lastToast.current = message;
      }
    }
  }, [query, page, tab, debouncedSearch, debouncedDevice, auditTarget, auditStatus, tableKey, toast]);

  useEffect(() => {
    refreshTable();
    const id = window.setInterval(refreshTable, 30000);
    return () => window.clearInterval(id);
  }, [refreshTable]);

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

  // ---- Detail panels ----
  const [detailSession, setDetailSession] = useState<SessionSpan | null>(null);
  const [detailAudit, setDetailAudit] = useState<AuditAction | null>(null);
  const logRef = useRef<HTMLDivElement>(null);

  const changePeriod = (next: Period) => {
    setPeriod(next);
    setPage(1);
  };
  const changeTab = (next: SubTab) => {
    setTab(next);
    setPage(1);
  };
  const changeSearch = (v: string) => {
    setSearch(v);
    setPage(1);
  };
  const changeDevice = (v: string) => {
    setDeviceFilter(v);
    setPage(1);
  };
  const hasFilter = search !== "" || deviceFilter !== "" || (tab === "audit" && auditStatus !== "");
  const clearFilters = () => {
    setSearch("");
    setDeviceFilter("");
    setAuditStatus("");
    setPage(1);
  };
  const showLog = () =>
    window.requestAnimationFrame(() =>
      logRef.current?.scrollIntoView({ behavior: isReducedMotion ? "auto" : "smooth", block: "start" }),
    );

  /** Station chart row -> the session log filtered to it (click again to undo). */
  const focusStation = (row: Ranked) => {
    const isSame = deviceFilter.toUpperCase() === row.key.toUpperCase();
    setTab("sesi");
    setDeviceFilter(isSame ? "" : row.key);
    setPage(1);
    if (!isSame) showLog();
  };

  // ---- Columns ----
  const durationCell = (r: SessionSpan) => {
    // A null duration means the session has a START but no close event yet.
    if (r.duration_seconds == null) {
      return (
        <span style={{ display: "inline-flex", alignItems: "center", gap: 6, color: "var(--lx-accent-text)" }}>
          <LiveDot />
          <Mono style={{ fontSize: 12.5 }}>berjalan {durationSince(r.timestamp)}</Mono>
        </span>
      );
    }
    return (
      <span style={{ display: "inline-flex", alignItems: "center", gap: 6, justifyContent: "flex-end" }}>
        {r.duration_capped === true && (
          <Marker
            label={`maks ${MAX_SESSION_HOURS}j`}
            title={`Dibatasi ${MAX_SESSION_HOURS} jam: sesi tidak pernah ditutup atau jam perangkat melompat.`}
          />
        )}
        {r.auto_closed === true && r.duration_capped !== true && (
          <Marker label="otomatis" title="Ditutup server memakai tanda hidup terakhir perangkat, bukan oleh perangkat." />
        )}
        <Mono style={{ fontSize: 12.5 }}>{formatDuration(r.duration_seconds)}</Mono>
      </span>
    );
  };

  const sessionColumns: Column<SessionSpan>[] = [
    {
      key: "waktu",
      header: "Waktu",
      width: "130px",
      phone: "primary",
      render: (r) => <Mono style={{ fontSize: 12.5 }}>{formatLogTime(r.timestamp)}</Mono>,
    },
    {
      key: "perangkat",
      header: "Perangkat",
      width: "96px",
      phone: "primary",
      render: (r) => <Mono style={{ fontSize: 12.5 }}>{r.hostname || "-"}</Mono>,
    },
    { key: "pengguna", header: "Pengguna", width: "1fr", phone: "secondary", render: (r) => r.nama || r.username || "-" },
    { key: "tipe", header: "Tipe akses", width: "96px", phone: "secondary", render: accessOf },
    {
      key: "tujuan",
      header: "Tujuan",
      width: "1.2fr",
      phone: "secondary",
      render: (r) => <span style={{ color: "var(--lx-muted)" }}>{r.tujuan || "-"}</span>,
    },
    { key: "durasi", header: "Durasi", width: "170px", align: "right", phone: "secondary", render: durationCell },
  ];

  const auditColumns: Column<AuditAction>[] = [
    {
      key: "waktu",
      header: "Waktu",
      width: "130px",
      phone: "primary",
      render: (r) => <Mono style={{ fontSize: 12 }}>{formatLogTime(r.timestamp)}</Mono>,
    },
    {
      key: "aktor",
      header: "Aktor",
      width: "150px",
      phone: "secondary",
      render: (r) => <span title={r.actor_email || undefined}>{r.actor_email || "sistem"}</span>,
    },
    {
      key: "target",
      header: "Target",
      width: "90px",
      phone: "primary",
      render: (r) => <Mono style={{ fontSize: 12 }}>{r.target_device === "ALL" ? "Semua" : r.target_device || "-"}</Mono>,
    },
    {
      key: "aksi",
      header: "Aksi",
      width: "130px",
      phone: "secondary",
      render: (r) => <span title={r.action_type}>{actionLabel(r)}</span>,
    },
    {
      key: "status",
      header: "Status",
      width: "112px",
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
      width: "1fr",
      render: (r) => {
        const message = r.action_type === "BROADCAST" ? text(r.param) : "";
        return (
          <span style={{ color: "var(--lx-muted)" }}>
            {reasonLabel(r.reason) || (message ? "" : "-")}
            {message && (
              <span style={{ color: "var(--lx-text)" }}>
                {r.reason ? " · " : ""}“{message}”
              </span>
            )}
          </span>
        );
      },
    },
  ];

  const total = tab === "sesi" ? sessions.total : audit.total;
  const shown = tab === "sesi" ? sessions.sessions.length : audit.actions.length;
  const firstRow = total === 0 ? 0 : (page - 1) * PAGE_SIZE + 1;
  const pageCount = Math.max(1, Math.ceil(total / PAGE_SIZE));
  const isTableBusy = loadedKey !== tableKey || search !== debouncedSearch || deviceFilter !== debouncedDevice;
  const auditStatusOptions = AUDIT_FILTERS.map((f) => {
    const count = f.value
      ? auditCounts?.[f.value]
      : auditCounts && Object.values(auditCounts).reduce<number>((s, v) => s + (v ?? 0), 0);
    return { value: f.value, label: count == null ? f.label : `${f.label} (${count})` };
  });

  // ---- Layout ----
  const bentoColumns = breakpoint === "desktop" ? "repeat(12, 1fr)" : breakpoint === "tablet" ? "1fr 1fr" : "1fr";
  const bentoSpan = (desktop: number, tablet: number) =>
    breakpoint === "desktop" ? `span ${desktop}` : breakpoint === "tablet" ? `span ${tablet}` : undefined;
  const gap = isPhone ? 10 : 16;
  const cardPad = isPhone ? "18px 16px 18px" : "20px 22px 22px";
  const rise = (i: number, extra?: CSSProperties) => ({ "--i": i, ...extra }) as CSSProperties;
  // Old numbers stay on screen, dimmed, until the new period's arrive -- then
  // the big numbers count from one to the other.
  const fade = (isStale: boolean): CSSProperties => ({
    opacity: isStale ? 0.42 : 1,
    transition: "opacity var(--lx-motion) var(--lx-ease)",
  });

  const range_ = rangeLabel(range);
  const numbersError = summaryError && (!sum || isSummaryStale) ? summaryError : null;
  const chartsError = analysisError && (!analysis || isAnalysisStale) ? analysisError : null;

  const hoursValue = sum?.hours ?? 0;
  const openCount = sum?.open_sessions ?? analysis?.runningCount ?? 0;
  const autoCount = sum?.auto_closed_sessions ?? analysis?.autoClosedCount ?? 0;
  const observedShare = analysis && analysis.totalHours > 0 ? analysis.observedHours / analysis.totalHours : null;

  const stationRows = analysis ? (isAllStations ? analysis.stations : analysis.stations.slice(0, TOP_STATIONS)) : [];
  const idleStations = analysis ? analysis.stations.filter((s) => s.sessions === 0).length : 0;
  const purposeRows = useMemo(() => {
    if (!analysis) return [];
    const top = analysis.purposes.slice(0, TOP_PURPOSES);
    const rest = analysis.purposes.slice(TOP_PURPOSES);
    if (rest.length === 0) return top;
    return [
      ...top,
      {
        key: "__lainnya",
        label: `Lainnya (${rest.length} tujuan)`,
        hours: rest.reduce((s, r) => s + r.hours, 0),
        sessions: rest.reduce((s, r) => s + r.sessions, 0),
      },
    ];
  }, [analysis]);
  const trendNoun = analysis ? { hour: "jam", day: "hari", week: "minggu", month: "bulan" }[analysis.grain] : "hari";

  const chartBody = (content: () => ReactNode, height: number) => {
    if (chartsError) return <Muted style={{ padding: "8px 0" }}>{chartsError}</Muted>;
    if (!analysis) return <Skeleton height={height} />;
    return content();
  };

  // ---- Detail: session ----
  const ds = detailSession;
  const dsLive = ds !== null && ds.duration_seconds === null;
  const dsEnd = ds ? spanEnd(ds, now) : 0;
  const dsPerson = ds ? ds.nim || ds.nama || ds.username : "";

  return (
    <>
      <PageHeader
        title="Riwayat"
        summary={
          sum && !isSummaryStale ? (
            <>
              <Mono style={{ color: "var(--lx-text)" }}>{sum.hours.toLocaleString("id-ID", { maximumFractionDigits: 1 })} j</Mono> total ·{" "}
              <Mono style={{ color: "var(--lx-text)" }}>{sum.sessions}</Mono> sesi ·{" "}
              <Mono style={{ color: "var(--lx-text)" }}>{sum.users}</Mono> pengguna · <Mono>{range_}</Mono>
            </>
          ) : numbersError ? (
            numbersError
          ) : (
            "Memuat ringkasan..."
          )
        }
        action={
          <div style={{ display: "flex", gap: 10, flexWrap: "wrap" }}>
            <PillSelect value={period} options={PERIODS} onChange={changePeriod} />
            <PillSelect triggerLabel="Unduh" options={EXPORTS} onChange={download} isAccent width={196} />
          </div>
        }
      />

      {/* ---- Bento ---- */}
      <div style={{ display: "grid", gridTemplateColumns: bentoColumns, gap }}>
        {/* Jam pakai + trend */}
        <Card padding={cardPad} className="lx-rise" style={rise(0, { gridColumn: bentoSpan(6, 2) })}>
          <CardTitle>Jam pakai</CardTitle>
          {numbersError ? (
            <Muted>{numbersError}</Muted>
          ) : !sum ? (
            <Skeleton height={50} />
          ) : (
            <div style={{ display: "flex", alignItems: "flex-end", gap: 14, flexWrap: "wrap", ...fade(isSummaryStale) }}>
              <BigNumber value={hoursValue} decimals={1} size={isPhone ? 44 : 50} suffix="jam" />
              {prevWin && <Delta percent={delta} caption={prevWin.caption} />}
            </div>
          )}
          <div style={{ marginTop: 18, ...fade(isAnalysisStale) }}>
            {chartBody(
              () => (
                <PillBars
                  key={analysisData?.key}
                  bars={analysis!.trend}
                  average={analysis!.trendAverage}
                  height={isPhone ? 110 : 130}
                  maxLabels={isPhone ? 6 : 12}
                />
              ),
              isPhone ? 150 : 170,
            )}
          </div>
          {analysis && !chartsError && (
            <Muted style={{ marginTop: 12, ...fade(isAnalysisStale) }}>
              {analysis.runningCount > 0 && (
                <>
                  <Mono style={{ color: "var(--lx-text)" }}>+{hoursText(analysis.runningHours)}</Mono> dari{" "}
                  <Mono style={{ color: "var(--lx-text)" }}>{analysis.runningCount}</Mono> sesi berjalan, belum masuk total ·{" "}
                </>
              )}
              rata-rata <Mono style={{ color: "var(--lx-text)" }}>{hoursText(analysis.trendAverage)}</Mono> per {trendNoun}
            </Muted>
          )}
        </Card>

        {/* Sesi + Pengguna */}
        <div
          style={{
            gridColumn: bentoSpan(3, 1),
            display: "grid",
            gap,
            gridTemplateColumns: isPhone ? "1fr 1fr" : "1fr",
            gridTemplateRows: isPhone ? undefined : "1fr 1fr",
          }}
        >
          <Card padding={cardPad} className="lx-rise" style={rise(1, { display: "flex", flexDirection: "column" })}>
            <CardTitle>Sesi</CardTitle>
            {numbersError ? (
              <Muted>-</Muted>
            ) : !sum ? (
              <Skeleton height={40} />
            ) : (
              <div style={fade(isSummaryStale)}>
                <BigNumber value={sum.sessions} size={isPhone ? 36 : 42} />
              </div>
            )}
            {analysis && !chartsError && (
              <div style={{ marginTop: "auto", paddingTop: 14, ...fade(isAnalysisStale) }}>
                <SplitBar key={analysisData?.key} parts={analysis.access.map((a) => ({ key: a.type, label: a.label, count: a.count }))} />
              </div>
            )}
          </Card>
          <Card padding={cardPad} className="lx-rise" style={rise(2)}>
            <CardTitle>Pengguna</CardTitle>
            {numbersError ? (
              <Muted>-</Muted>
            ) : !sum ? (
              <Skeleton height={40} />
            ) : (
              <div style={fade(isSummaryStale)}>
                <BigNumber value={sum.users} size={isPhone ? 36 : 42} />
                <Muted style={{ marginTop: 6 }}>
                  {sum.users > 0 ? (
                    <>
                      <Mono style={{ color: "var(--lx-text)" }}>
                        {(sum.sessions / sum.users).toLocaleString("id-ID", { maximumFractionDigits: 1 })}
                      </Mono>{" "}
                      sesi · <Mono style={{ color: "var(--lx-text)" }}>{hoursText(sum.hours / sum.users)}</Mono> per orang
                    </>
                  ) : (
                    "belum ada pengguna"
                  )}
                </Muted>
              </div>
            )}
          </Card>
        </div>

        {/* Kelengkapan data -- the ink card */}
        <Card
          padding={cardPad}
          className="lx-rise"
          style={rise(3, {
            gridColumn: bentoSpan(3, 1),
            background: "var(--lx-ink)",
            color: "var(--lx-on-ink)",
            // Secondary text inside the card reads the ink ramp, the way
            // .lx-frame-scope re-points the tokens for the sidebar.
            "--lx-muted": "color-mix(in srgb, var(--lx-on-ink) 60%, var(--lx-ink))",
            display: "flex",
            flexDirection: "column",
          } as CSSProperties)}
        >
          <CardTitle>Kelengkapan data</CardTitle>
          {numbersError && chartsError ? (
            <Muted>{numbersError}</Muted>
          ) : (
            <>
              <div style={{ ...fade(isAnalysisStale || isSummaryStale), flex: 1, display: "flex", alignItems: "center" }}>
                <DataDial fraction={observedShare}>
                  {observedShare === null ? (
                    <span className="lx-big" style={{ fontSize: 30 }}>
                      –
                    </span>
                  ) : (
                    <BigNumber value={Math.round(observedShare * 100)} size={32} suffix="%" />
                  )}
                  <div style={{ fontSize: 11, color: "var(--lx-muted)", marginTop: 4, lineHeight: 1.2 }}>jam teramati</div>
                </DataDial>
              </div>
              <div style={{ display: "grid", gap: 8, marginTop: 16, fontSize: 12.5, ...fade(isSummaryStale) }}>
                {(
                  [
                    ["Masih berjalan", openCount, "Jamnya belum masuk total."],
                    ["Ditutup otomatis", autoCount, "Jamnya diperkirakan dari tanda hidup terakhir."],
                    [`Dibatasi ${MAX_SESSION_HOURS} jam`, analysis?.cappedCount ?? 0, "Sesi terlalu panjang untuk dipercaya."],
                  ] as const
                ).map(([label, count, hint], i) => (
                  <div key={label} title={hint} style={{ display: "flex", alignItems: "center", gap: 8 }}>
                    {i === 0 && count > 0 ? (
                      <LiveDot />
                    ) : (
                      <span style={{ width: 7, height: 7, borderRadius: 999, background: "var(--lx-muted)", flexShrink: 0 }} />
                    )}
                    <span style={{ color: count > 0 ? "var(--lx-on-ink)" : "var(--lx-muted)" }}>{label}</span>
                    <Mono style={{ marginLeft: "auto", fontWeight: 700 }}>{count}</Mono>
                  </div>
                ))}
              </div>
            </>
          )}
        </Card>

        {/* Jam sibuk */}
        <Card padding={isPhone ? "18px 14px" : "20px 24px 22px"} className="lx-rise" style={rise(4, { gridColumn: bentoSpan(7, 2) })}>
          <CardTitle action={isPhone ? undefined : <HeatLegend />}>Jam sibuk</CardTitle>
          <div style={fade(isAnalysisStale)}>
            {chartBody(
              () => (
                <>
                  <HeatGrid
                    key={analysisData?.key}
                    heat={analysis!.heat}
                    stationCount={analysis!.stationCount}
                    todayWeekday={weekdayOf(now)}
                    isCompact={isPhone}
                  />
                  <Muted style={{ marginTop: 14 }}>{peakSentence(analysis!.heat, analysis!.stationCount)}</Muted>
                </>
              ),
              260,
            )}
          </div>
        </Card>

        {/* Stasiun */}
        <Card padding={isPhone ? "18px 12px" : "20px 16px 18px"} className="lx-rise" style={rise(5, { gridColumn: bentoSpan(5, 1) })}>
          <div style={{ padding: "0 8px" }}>
            <CardTitle action={<span style={{ fontSize: 12, color: "var(--lx-muted)" }}>jam · sesi</span>}>Stasiun</CardTitle>
          </div>
          <div style={fade(isAnalysisStale)}>
            {chartBody(
              () =>
                analysis!.stations.length === 0 ? (
                  <Muted style={{ padding: "0 8px" }}>Belum ada stasiun terdaftar.</Muted>
                ) : (
                  <>
                    <RankBars key={analysisData?.key} rows={stationRows} selectedKey={deviceFilter} onSelect={focusStation} />
                    <div style={{ display: "flex", alignItems: "center", gap: 10, flexWrap: "wrap", padding: "10px 8px 0" }}>
                      <Muted>
                        Pilih stasiun untuk menyaring log di bawah
                        {idleStations > 0 && (
                          <>
                            {" "}
                            · <Mono style={{ color: "var(--lx-text)" }}>{idleStations}</Mono> tidak dipakai
                          </>
                        )}
                      </Muted>
                      {analysis!.stations.length > TOP_STATIONS && (
                        <Button
                          label={isAllStations ? "Ringkas" : `Semua ${analysis!.stations.length}`}
                          variant="ghost"
                          size="sm"
                          style={{ marginLeft: "auto", padding: "4px 10px" }}
                          onClick={() => setAllStations((v) => !v)}
                        />
                      )}
                    </div>
                  </>
                ),
              260,
            )}
          </div>
        </Card>

        {/* Tujuan */}
        <Card padding={cardPad} className="lx-rise" style={rise(6, { gridColumn: bentoSpan(7, 1) })}>
          <CardTitle action={<span style={{ fontSize: 12, color: "var(--lx-muted)" }}>porsi jam</span>}>Tujuan pemakaian</CardTitle>
          <div style={fade(isAnalysisStale)}>
            {chartBody(
              () =>
                purposeRows.length === 0 ? (
                  <Muted>Belum ada sesi pada periode ini.</Muted>
                ) : (
                  <ShareBreakdown key={analysisData?.key} rows={purposeRows} total={analysis!.totalHours} />
                ),
              200,
            )}
          </div>
        </Card>

        {/* Lama sesi */}
        <Card padding={cardPad} className="lx-rise" style={rise(7, { gridColumn: bentoSpan(5, 2) })}>
          <CardTitle
            action={
              analysis?.medianSeconds != null ? (
                <span style={{ fontSize: 12, color: "var(--lx-muted)" }}>
                  median <Mono style={{ color: "var(--lx-text)" }}>{formatDuration(analysis.medianSeconds)}</Mono>
                </span>
              ) : undefined
            }
          >
            Lama sesi
          </CardTitle>
          <div style={fade(isAnalysisStale)}>
            {chartBody(
              () => (
                <>
                  <PillBars key={analysisData?.key} bars={analysis!.durations} height={isPhone ? 96 : 116} />
                  <Muted style={{ marginTop: 12 }}>
                    {analysis!.maxSeconds != null ? (
                      <>
                        terlama <Mono style={{ color: "var(--lx-text)" }}>{formatDuration(analysis!.maxSeconds)}</Mono>
                      </>
                    ) : (
                      "belum ada sesi selesai"
                    )}
                    {analysis!.runningCount > 0 && (
                      <>
                        {" "}
                        · <Mono style={{ color: "var(--lx-text)" }}>{analysis!.runningCount}</Mono> sesi berjalan belum dihitung
                      </>
                    )}
                  </Muted>
                </>
              ),
              190,
            )}
          </div>
        </Card>
      </div>

      {analysisData && !isAnalysisStale && analysisData.total > analysisData.sessions.length && (
        <Muted style={{ marginTop: 12 }}>
          Grafik memakai <Mono>{analysisData.sessions.length.toLocaleString("id-ID")}</Mono> sesi terbaru dari{" "}
          <Mono>{analysisData.total.toLocaleString("id-ID")}</Mono> pada periode ini; angka ringkasan tetap menghitung semuanya.
        </Muted>
      )}

      {/* ---- Logs ---- */}
      <div
        ref={logRef}
        style={{ display: "flex", alignItems: "center", gap: 10, flexWrap: "wrap", margin: "30px 0 14px", scrollMarginTop: 16 }}
      >
        <PillTabs
          ariaLabel="Jenis log"
          value={tab}
          onChange={changeTab}
          options={[
            { value: "sesi", label: "Log Sesi" },
            { value: "audit", label: "Log Audit" },
          ]}
        />
        <div style={{ display: "flex", gap: 10, flexWrap: "wrap", alignItems: "center", marginLeft: isPhone ? 0 : "auto" }}>
          <SearchChip value={search} onChange={changeSearch} placeholder="Cari pengguna / perangkat" width={isPhone ? 360 : 250} />
          <SearchChip value={deviceFilter} onChange={changeDevice} placeholder="Perangkat" width={isPhone ? 360 : 170} />
          {tab === "audit" && (
            <PillSelect
              label="Status"
              value={auditStatus}
              options={auditStatusOptions}
              onChange={(v) => {
                setAuditStatus(v);
                setPage(1);
              }}
            />
          )}
          {hasFilter && <Button label="Hapus filter" variant="ghost" size="sm" onClick={clearFilters} />}
        </div>
      </div>

      {!hasLoaded[tab] ? (
        tableError ? (
          <ErrorState description={tableError} onRetry={refreshTable} />
        ) : (
          <Skeleton height={320} />
        )
      ) : (
        <div style={fade(isTableBusy)}>
          {tab === "sesi" ? (
            <Table
              columns={sessionColumns}
              rows={sessions.sessions}
              getRowKey={(r) => r.session_id}
              onRowClick={setDetailSession}
              selectedKey={detailSession?.session_id ?? null}
              emptyLabel={hasFilter ? "Tidak ada sesi yang cocok dengan filter." : "Tidak ada sesi pada periode ini."}
            />
          ) : (
            <Table
              columns={auditColumns}
              rows={audit.actions}
              getRowKey={(r) => (r.action_id != null ? String(r.action_id) : `${r.timestamp}-${r.target_device}-${r.action_type}`)}
              onRowClick={setDetailAudit}
              emptyLabel={hasFilter ? "Tidak ada aksi yang cocok dengan filter." : "Tidak ada aksi admin pada periode ini."}
            />
          )}
        </div>
      )}

      <div style={{ display: "flex", alignItems: "center", marginTop: 14, gap: 12, flexWrap: "wrap" }}>
        <span style={{ fontSize: 12.5, color: "var(--lx-muted)" }}>
          Menampilkan{" "}
          <Mono>
            {firstRow}–{firstRow + Math.max(0, shown - 1)}
          </Mono>{" "}
          dari <Mono>{total}</Mono> {tab === "sesi" ? "baris sesi" : "aksi"}
        </span>
        <span style={{ marginLeft: "auto" }}>
          <Pagination page={page} pageCount={pageCount} onChange={setPage} />
        </span>
      </div>

      {/* ---- Session detail ---- */}
      <SidePanel
        isOpen={ds !== null}
        onClose={() => setDetailSession(null)}
        label="Detail sesi"
        header={
          ds && (
            <>
              <div style={{ fontSize: 20, fontWeight: 650, letterSpacing: "-0.01em" }}>{personName(ds)}</div>
              <div style={{ fontSize: 12.5, color: "var(--lx-muted)", marginTop: 4 }}>
                <Mono>{ds.hostname || "-"}</Mono> · {accessOf(ds)} · {ds.tujuan || "Tanpa tujuan"}
              </div>
            </>
          )
        }
      >
        {ds && (
          <div style={{ display: "grid", gap: 22 }}>
            <section style={{ background: "var(--lx-sunken)", borderRadius: 18, padding: "14px 16px" }}>
              <div style={{ display: "flex", alignItems: "baseline", gap: 10, flexWrap: "wrap" }}>
                <span className="lx-big lx-mono" style={{ fontSize: 30 }}>
                  {dsLive ? durationSince(ds.timestamp) : formatDuration(ds.duration_seconds)}
                </span>
                <span style={{ display: "inline-flex", alignItems: "center", gap: 6, fontSize: 12.5, color: "var(--lx-muted)" }}>
                  {dsLive && <LiveDot />}
                  {dsLive
                    ? "masih berjalan"
                    : ds.duration_capped === true
                      ? `dibatasi ${MAX_SESSION_HOURS} jam`
                      : ds.auto_closed === true
                        ? "ditutup otomatis oleh server"
                        : "selesai"}
                </span>
              </div>
              <div style={{ fontSize: 12.5, color: "var(--lx-muted)", marginTop: 6 }}>
                <Mono style={{ color: "var(--lx-text)" }}>{formatClock(ds.timestamp)}</Mono> →{" "}
                <Mono style={{ color: "var(--lx-text)" }}>{dsLive ? "sekarang" : formatClock(new Date(dsEnd).toISOString())}</Mono>
              </div>
            </section>

            <section style={{ display: "grid", gap: 9, fontSize: 13 }}>
              {detailRow("Mulai", <Mono>{formatDateTime(ds.timestamp)}</Mono>)}
              {detailRow("Selesai", dsLive ? "belum" : <Mono>{formatDateTime(new Date(dsEnd).toISOString())}</Mono>)}
            </section>

            <section style={{ display: "grid", gap: 9, fontSize: 13 }}>
              <SectionLabel>Identitas</SectionLabel>
              {detailRow("Nama", ds.nama)}
              {detailRow("NIM", ds.nim && <Mono>{ds.nim}</Mono>)}
              {detailRow("Nama pengguna", ds.username && <Mono>{ds.username}</Mono>)}
              {detailRow("Sumber identitas", IDENTITY_LABEL[text(ds.identity_source)] ?? text(ds.identity_source))}
              {detailRow("Peran", text(ds.person_role))}
              {detailRow("ID sesi", <Mono style={{ fontSize: 11.5, userSelect: "all" }}>{ds.session_id}</Mono>)}
            </section>

            <section style={{ display: "grid", gap: 8 }}>
              <Button
                label={`Semua sesi di ${ds.hostname || "perangkat ini"}`}
                variant="primary"
                isFullWidth
                disabled={!ds.hostname}
                onClick={() => {
                  setDetailSession(null);
                  setTab("sesi");
                  setSearch("");
                  setDeviceFilter(ds.hostname);
                  setPage(1);
                }}
              />
              {dsPerson && (
                <Button
                  label={`Sesi lain oleh ${personName(ds)}`}
                  isFullWidth
                  onClick={() => {
                    setDetailSession(null);
                    setTab("sesi");
                    setDeviceFilter("");
                    setSearch(dsPerson);
                    setPage(1);
                  }}
                />
              )}
            </section>
          </div>
        )}
      </SidePanel>

      {/* ---- Audit detail ---- */}
      <SidePanel
        isOpen={detailAudit !== null}
        onClose={() => setDetailAudit(null)}
        label="Detail aksi"
        header={
          detailAudit && (
            <>
              <div style={{ fontSize: 20, fontWeight: 650, letterSpacing: "-0.01em" }}>{actionLabel(detailAudit)}</div>
              <div style={{ fontSize: 12.5, color: "var(--lx-muted)", marginTop: 4 }}>
                <Mono>{detailAudit.target_device === "ALL" ? "Semua stasiun" : detailAudit.target_device || "-"}</Mono> ·{" "}
                <Mono>{formatLogTime(detailAudit.timestamp)}</Mono>
              </div>
            </>
          )
        }
      >
        {detailAudit && (
          <div style={{ display: "grid", gap: 22 }}>
            <section
              style={{
                background: "var(--lx-sunken)",
                borderRadius: 18,
                padding: "14px 16px",
                display: "flex",
                alignItems: "center",
                gap: 10,
                fontSize: 14,
              }}
            >
              <StatusDot status={AUDIT_STATUS[detailAudit.status] ?? "idle"} />
              <span style={{ fontWeight: 650 }}>{AUDIT_LABEL[detailAudit.status] ?? detailAudit.status}</span>
              {text(detailAudit.executed_at) && (
                <span style={{ fontSize: 12.5, color: "var(--lx-muted)", marginLeft: "auto" }}>
                  diproses <Mono>{formatClock(text(detailAudit.executed_at))}</Mono>
                </span>
              )}
            </section>
            {detailAudit.action_type === "BROADCAST" && text(detailAudit.param) && (
              <section>
                <SectionLabel>Isi pesan</SectionLabel>
                <div style={{ marginTop: 8, fontSize: 14, lineHeight: 1.55, whiteSpace: "pre-wrap" }}>“{text(detailAudit.param)}”</div>
              </section>
            )}
            <section style={{ display: "grid", gap: 9, fontSize: 13 }}>
              {detailRow("Waktu", <Mono>{formatDateTime(detailAudit.timestamp)}</Mono>)}
              {detailRow("Aktor", detailAudit.actor_email || "sistem")}
              {detailRow("Target", <Mono>{detailAudit.target_device || "-"}</Mono>)}
              {detailRow(
                "Aksi",
                <>
                  {actionLabel(detailAudit)} <Mono style={{ fontSize: 11.5, color: "var(--lx-muted)" }}>{detailAudit.action_type}</Mono>
                </>,
              )}
              {detailRow("Alasan", reasonLabel(detailAudit.reason))}
              {detailRow("Hasil", detailAudit.result_summary)}
              {text(detailAudit.error_message) &&
                detailRow("Galat", <span style={{ color: "var(--lx-status-alert)" }}>{text(detailAudit.error_message)}</span>)}
              {detailRow("Percobaan ulang", <Mono>{text(detailAudit.retry_count) || "0"}</Mono>)}
              {text(detailAudit.command_id) &&
                detailRow("ID perintah", <Mono style={{ fontSize: 11.5, userSelect: "all" }}>{text(detailAudit.command_id)}</Mono>)}
            </section>
          </div>
        )}
      </SidePanel>
    </>
  );
}
