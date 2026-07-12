// Analytics & reports (design: docs/design/LogiX Analytics.dc.html). KPI row,
// an occupancy heat strip, utilisation/purpose bar lists, the paginated +
// searchable session log, the Control audit log, and a prominent Excel export.
//
// The backend's /api/analytics currently exposes only { totals, by_workstation,
// by_purpose, by_hour }. Several design elements need data it doesn't yet
// provide; those are derived best-effort or omitted, each marked
// TODO(backend) and collected in docs/design/BACKEND_TODO_BACKLOG.md.
import { useCallback, useEffect, useRef, useState } from "react";
import { Badge } from "@astryxdesign/core/Badge";
import { Button } from "@astryxdesign/core/Button";
import { Card } from "@astryxdesign/core/Card";
import { Grid } from "@astryxdesign/core/Grid";
import { ProgressBar } from "@astryxdesign/core/ProgressBar";
import { SegmentedControl, SegmentedControlItem } from "@astryxdesign/core/SegmentedControl";
import { HStack, VStack } from "@astryxdesign/core/Stack";
import { Table } from "@astryxdesign/core/Table";
import { Heading, Text } from "@astryxdesign/core/Text";
import { TextInput } from "@astryxdesign/core/TextInput";
import { ArrowDownTrayIcon } from "@heroicons/react/24/outline";

import { getJson } from "../api";
import ReportDialog from "../chrome/ReportDialog";
import EmptyState from "../components/states/EmptyState";
import ErrorState from "../components/states/ErrorState";
import { SkeletonLines } from "../components/states/Skeleton";
import type { Analytics as AnalyticsData, AuditAction, CommandStatus, SessionLog } from "../types";
import { formatDateTime, usePolling } from "../util";

const ITEMS_PER_PAGE = 15;
const AUDIT_PER_PAGE = 10;

const AUDIT_BADGE: Record<CommandStatus, { label: string; variant: "success" | "warning" | "error" | "neutral" }> = {
  queued: { label: "Menunggu", variant: "warning" },
  done: { label: "Selesai", variant: "success" },
  failed: { label: "Gagal", variant: "error" },
  expired: { label: "Kedaluwarsa", variant: "neutral" },
};

const eventBadge = (event: string) => {
  if (event === "START" || event === "UNLOCK") return <Badge variant="success" label={event} />;
  if (event === "END" || event === "LOCK" || event.includes("AUTO")) return <Badge variant="error" label={event} />;
  return <Badge variant="neutral" label={event} />;
};

// A KPI tile: label, big value (+ optional unit), and a sub line.
const KpiCard = ({ label, value, unit, sub }: { label: string; value: string | number; unit?: string; sub?: string }) => (
  <Card padding={4}>
    <VStack gap={1}>
      <Text type="supporting" color="secondary">
        <span style={{ textTransform: "uppercase", letterSpacing: "0.05em", fontWeight: 600, fontSize: 11 }}>{label}</span>
      </Text>
      <span style={{ fontSize: 30, fontWeight: 800, letterSpacing: "-0.02em", color: "var(--color-text-primary)" }}>
        {value}
        {unit && <span style={{ fontSize: 15, fontWeight: 600, color: "var(--lx-text-muted)" }}> {unit}</span>}
      </span>
      {sub && <Text type="supporting" color="secondary">{sub}</Text>}
    </VStack>
  </Card>
);

const BarList = ({ items, emptyLabel }: { items: { label: string; value: number; suffix: string }[]; emptyLabel: string }) => {
  if (items.length === 0) return <Text type="body" color="secondary">{emptyLabel}</Text>;
  const max = Math.max(...items.map((i) => i.value)) || 1;
  return (
    <VStack gap={3}>
      {items.map((item) => (
        <VStack key={item.label} gap={1}>
          <HStack gap={2} justify="between">
            <Text type="body"><strong>{item.label}</strong></Text>
            <Text type="supporting" color="secondary">{item.value} {item.suffix}</Text>
          </HStack>
          <ProgressBar value={(item.value / max) * 100} label={`${item.label}: ${item.value} ${item.suffix}`} isLabelHidden />
        </VStack>
      ))}
    </VStack>
  );
};

// Occupancy heat strip: one cell per hour, tinted by relative volume. This is
// the best-effort stand-in for the design's day×hour heat map.
// TODO(backend): expose a day×hour occupancy matrix for the full grid.
const HeatStrip = ({ byHour }: { byHour: { hour: string; count: number }[] }) => {
  const max = Math.max(...byHour.map((h) => h.count), 1);
  return (
    <VStack gap={2}>
      <div style={{ display: "grid", gridTemplateColumns: "repeat(24, 1fr)", gap: 3 }}>
        {Array.from({ length: 24 }).map((_, h) => {
          const count = byHour.find((b) => Number(b.hour) === h)?.count ?? 0;
          const intensity = count / max; // 0..1
          return (
            <div
              key={h}
              title={`Pukul ${String(h).padStart(2, "0")}:00 — ${count} sesi`}
              style={{
                aspectRatio: "1",
                borderRadius: 4,
                background:
                  intensity === 0
                    ? "var(--lx-skeleton-base)"
                    : `color-mix(in srgb, var(--lx-accent) ${Math.round(20 + intensity * 80)}%, transparent)`,
              }}
            />
          );
        })}
      </div>
      <HStack justify="between">
        <Text type="supporting" color="secondary">00:00</Text>
        <HStack gap={1} align="center">
          <Text type="supporting" color="secondary">sepi</Text>
          <div style={{ width: 60, height: 8, borderRadius: 999, background: "linear-gradient(90deg, var(--lx-skeleton-base), var(--lx-accent))" }} />
          <Text type="supporting" color="secondary">ramai</Text>
        </HStack>
        <Text type="supporting" color="secondary">23:00</Text>
      </HStack>
    </VStack>
  );
};

type Range = "today" | "7d" | "30d" | "custom";

export default function Analytics() {
  const [analytics, setAnalytics] = useState<AnalyticsData | null>(null);
  const [analyticsError, setAnalyticsError] = useState<string | null>(null);
  const [range, setRange] = useState<Range>("30d"); // TODO(backend): pass range to /api/analytics
  const [isReportOpen, setReportOpen] = useState(false);
  const [sessions, setSessions] = useState<SessionLog[] | null>(null);
  const [totalLogs, setTotalLogs] = useState(0);
  const [page, setPage] = useState(1);
  const [search, setSearch] = useState("");
  const [query, setQuery] = useState("");
  const [audit, setAudit] = useState<AuditAction[] | null>(null);
  const [auditPage, setAuditPage] = useState(1);
  const [auditTotal, setAuditTotal] = useState(0);
  const debounceRef = useRef<ReturnType<typeof setTimeout>>(undefined);

  const fetchAnalytics = useCallback(async () => {
    try {
      setAnalytics(await getJson<AnalyticsData>("/api/analytics", "Gagal memuat analitik"));
      setAnalyticsError(null);
    } catch (err) {
      setAnalyticsError((err as Error).message);
    }
  }, []);

  const fetchSessions = useCallback(async () => {
    try {
      const offset = (page - 1) * ITEMS_PER_PAGE;
      let url = `/api/sessions?limit=${ITEMS_PER_PAGE}&offset=${offset}`;
      if (query) url += `&username=${encodeURIComponent(query)}&hostname=${encodeURIComponent(query)}`;
      const data = await getJson<{ total: number; sessions: SessionLog[] }>(url, "Gagal mengambil data catatan sesi");
      setSessions(data.sessions);
      setTotalLogs(data.total);
    } catch {
      setSessions([]);
    }
  }, [page, query]);

  const fetchAudit = useCallback(async () => {
    try {
      const offset = (auditPage - 1) * AUDIT_PER_PAGE;
      const data = await getJson<{ total: number; actions: AuditAction[] }>(
        `/api/audit-log?limit=${AUDIT_PER_PAGE}&offset=${offset}`,
        "Gagal mengambil audit log",
      );
      setAudit(data.actions);
      setAuditTotal(data.total);
    } catch {
      setAudit([]);
    }
  }, [auditPage]);

  usePolling(fetchAnalytics, 10000);
  useEffect(() => {
    fetchSessions();
    const id = setInterval(fetchSessions, 30000);
    return () => clearInterval(id);
  }, [fetchSessions]);
  useEffect(() => {
    fetchAudit();
    const id = setInterval(fetchAudit, 30000);
    return () => clearInterval(id);
  }, [fetchAudit]);

  const onSearchChange = (value: string) => {
    setSearch(value);
    clearTimeout(debounceRef.current);
    debounceRef.current = setTimeout(() => {
      setQuery(value.trim());
      setPage(1);
    }, 400);
  };

  const totalPages = Math.ceil(totalLogs / ITEMS_PER_PAGE) || 1;

  // Derived KPIs (best-effort from available fields).
  const byHour = analytics?.by_hour ?? [];
  const peak = byHour.reduce<{ hour: string; count: number } | null>((m, h) => (!m || h.count > m.count ? h : m), null);
  const topDevice = (analytics?.by_workstation ?? []).slice().sort((a, b) => b.hours - a.hours)[0];
  const sessionStart = totalLogs === 0 ? 0 : (page - 1) * ITEMS_PER_PAGE + 1;
  const sessionEnd = (page - 1) * ITEMS_PER_PAGE + (sessions?.length ?? 0);

  return (
    <VStack gap={6}>
      {/* Header */}
      <HStack gap={3} align="center" justify="between" wrap="wrap">
        <VStack gap={1}>
          <Heading level={3}>Analitik &amp; Laporan</Heading>
          <Text type="supporting" color="secondary">Kehadiran &amp; penggunaan lab</Text>
        </VStack>
        <HStack gap={2} align="center" wrap="wrap">
          <SegmentedControl label="Rentang waktu" value={range} onChange={(v) => setRange(v as Range)} size="sm">
            <SegmentedControlItem value="today" label="Hari ini" />
            <SegmentedControlItem value="7d" label="7 hari" />
            <SegmentedControlItem value="30d" label="30 hari" />
            <SegmentedControlItem value="custom" label="Custom" />
          </SegmentedControl>
          <Button
            label="Unduh Laporan (Excel)"
            variant="primary"
            icon={<ArrowDownTrayIcon style={{ width: 16, height: 16 }} />}
            onClick={() => setReportOpen(true)}
          />
        </HStack>
      </HStack>

      {analyticsError ? (
        <ErrorState description={analyticsError} onRetry={fetchAnalytics} />
      ) : (
        <>
          {/* KPI row */}
          <Grid columns={{ minWidth: 180, repeat: "fit" }} gap={4}>
            <KpiCard label="Total Jam" value={analytics?.totals.hours ?? "—"} unit="j" />
            <KpiCard label="Jumlah Sesi" value={analytics?.totals.sessions ?? "—"} />
            <KpiCard label="Workstation Terpakai" value={analytics?.totals.workstations ?? "—"} sub="dari yang tercatat" />
            <KpiCard
              label="Jam Puncak"
              value={peak ? `${String(peak.hour).padStart(2, "0")}:00` : "—"}
              sub={peak ? "jam tersibuk" : undefined}
            />
            <KpiCard
              label="Perangkat Teratas"
              value={topDevice ? topDevice.hostname : "—"}
              sub={topDevice ? `${topDevice.hours} j` : undefined}
            />
          </Grid>

          {/* Occupancy heat strip */}
          <Card padding={4}>
            <VStack gap={3}>
              <VStack gap={0.5}>
                <Heading level={6}>Peta Okupansi</Heading>
                <Text type="supporting" color="secondary">per jam · volume sesi</Text>
              </VStack>
              {analytics ? <HeatStrip byHour={byHour} /> : <SkeletonLines lines={2} widths={["100%", "60%"]} />}
            </VStack>
          </Card>

          {/* Bar charts */}
          <Grid columns={{ minWidth: 300, repeat: "fit" }} gap={4}>
            <Card padding={4}>
              <VStack gap={3}>
                <Heading level={6}>Jam per Workstation</Heading>
                <BarList
                  emptyLabel="Tidak ada data stasiun."
                  items={(analytics?.by_workstation ?? []).map((w) => ({ label: w.hostname, value: w.hours, suffix: "jam" }))}
                />
              </VStack>
            </Card>
            <Card padding={4}>
              <VStack gap={3}>
                <Heading level={6}>Sesi per Tujuan</Heading>
                <BarList
                  emptyLabel="Tidak ada data tujuan."
                  items={(analytics?.by_purpose ?? []).map((p) => ({ label: p.purpose, value: p.count, suffix: "sesi" }))}
                />
              </VStack>
            </Card>
          </Grid>
        </>
      )}

      {/* Session log */}
      <VStack gap={3}>
        <HStack gap={3} align="center" justify="between" wrap="wrap">
          <Heading level={5}>Log Sesi</Heading>
          <TextInput
            label="Cari"
            isLabelHidden
            placeholder="Cari username / hostname…"
            value={search}
            onChange={onSearchChange}
            size="sm"
            hasClear
          />
        </HStack>

        {sessions === null ? (
          <SkeletonLines lines={5} widths={["100%", "90%", "95%", "85%", "92%"]} />
        ) : sessions.length === 0 ? (
          <EmptyState title="Tidak ada catatan sesi" description="Coba ubah kata kunci pencarian atau rentang waktu." showMascot={false} />
        ) : (
          <Table
            data={sessions}
            density="compact"
            hasHover
            columns={[
              { key: "timestamp", header: "Waktu", renderCell: (s) => formatDateTime(s.timestamp as string) },
              { key: "hostname", header: "Perangkat", renderCell: (s) => <strong>{(s.hostname as string) || "-"}</strong> },
              { key: "event", header: "Event", renderCell: (s) => eventBadge(s.event as string) },
              { key: "session_type", header: "Tipe", renderCell: (s) => (s.session_type as string) || "-" },
              { key: "nama", header: "Pengguna", renderCell: (s) => (s.nama as string) || (s.username as string) || "-" },
              { key: "nim", header: "NIM", renderCell: (s) => (s.nim as string) || "-" },
              { key: "tujuan", header: "Tujuan", renderCell: (s) => (s.tujuan as string) || "-" },
            ]}
          />
        )}

        <HStack gap={3} align="center" justify="between">
          <Text type="supporting" color="secondary">
            {sessionStart}–{sessionEnd} dari {totalLogs} sesi
          </Text>
          <HStack gap={2} align="center">
            <Button label="‹" size="sm" variant="secondary" isDisabled={page === 1} onClick={() => setPage((p) => Math.max(1, p - 1))} />
            <Text type="supporting" color="secondary">Halaman {page} / {totalPages}</Text>
            <Button label="›" size="sm" variant="secondary" isDisabled={sessionEnd >= totalLogs} onClick={() => setPage((p) => p + 1)} />
          </HStack>
        </HStack>
      </VStack>

      {/* Audit log */}
      <VStack gap={3}>
        <VStack gap={0.5}>
          <HStack gap={2} align="center">
            <Heading level={5}>Log Audit Kontrol</Heading>
            <Badge variant="neutral" label={`${auditTotal} total`} />
          </HStack>
          <Text type="supporting" color="secondary">Setiap tindakan admin tercatat — akuntabilitas penuh.</Text>
        </VStack>
        {audit === null ? (
          <SkeletonLines lines={4} />
        ) : audit.length === 0 ? (
          <EmptyState title="Belum ada tindakan admin tercatat" showMascot={false} />
        ) : (
          <Table
            data={audit}
            density="compact"
            hasHover
            columns={[
              { key: "timestamp", header: "Waktu", renderCell: (a) => formatDateTime(a.timestamp as string) },
              { key: "actor_email", header: "Aktor" },
              { key: "target_device", header: "Target", renderCell: (a) => <strong>{(a.target_device as string) || "-"}</strong> },
              { key: "action_type", header: "Aksi" },
              {
                key: "status",
                header: "Status",
                renderCell: (a) => {
                  const info = AUDIT_BADGE[a.status as CommandStatus] ?? { label: a.status as string, variant: "neutral" as const };
                  return <Badge variant={info.variant} label={info.label} />;
                },
              },
              { key: "reason", header: "Alasan", renderCell: (a) => (a.reason as string) || "-" },
            ]}
          />
        )}

        <HStack gap={3} align="center" justify="end">
          <Button label="‹" size="sm" variant="secondary" isDisabled={auditPage === 1} onClick={() => setAuditPage((p) => Math.max(1, p - 1))} />
          <Text type="supporting" color="secondary">Halaman {auditPage} / {Math.ceil(auditTotal / AUDIT_PER_PAGE) || 1}</Text>
          <Button
            label="›"
            size="sm"
            variant="secondary"
            isDisabled={(auditPage - 1) * AUDIT_PER_PAGE + (audit?.length ?? 0) >= auditTotal}
            onClick={() => setAuditPage((p) => p + 1)}
          />
        </HStack>
      </VStack>

      <ReportDialog isOpen={isReportOpen} onOpenChange={setReportOpen} />
    </VStack>
  );
}
