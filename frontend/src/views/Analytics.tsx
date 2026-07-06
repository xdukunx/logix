// Analytics tab: utilization/purpose bar lists, the hourly SVG chart, the
// paginated + searchable session-logs table, and the Control audit log.
// Ported from server/static/js/analytics.js.
import { useCallback, useEffect, useRef, useState } from "react";
import { Badge } from "@astryxdesign/core/Badge";
import { Button } from "@astryxdesign/core/Button";
import { Card } from "@astryxdesign/core/Card";
import { EmptyState } from "@astryxdesign/core/EmptyState";
import { Grid } from "@astryxdesign/core/Grid";
import { ProgressBar } from "@astryxdesign/core/ProgressBar";
import { HStack, VStack } from "@astryxdesign/core/Stack";
import { Table } from "@astryxdesign/core/Table";
import { Heading, Text } from "@astryxdesign/core/Text";
import { TextInput } from "@astryxdesign/core/TextInput";
import {
  ClockIcon,
  ComputerDesktopIcon,
  PresentationChartLineIcon,
} from "@heroicons/react/24/outline";

import { getJson } from "../api";
import StatCard from "../components/StatCard";
import type { Analytics as AnalyticsData, AuditAction, CommandStatus, SessionLog } from "../types";
import { formatDateTime, usePolling } from "../util";

const ITEMS_PER_PAGE = 15;

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

const BarList = ({
  items,
  emptyLabel,
}: {
  items: { label: string; value: number; suffix: string }[];
  emptyLabel: string;
}) => {
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

// Hourly session distribution as a small inline SVG bar chart, same as the
// legacy view (SVG content, not layout markup).
const HourlyChart = ({ byHour }: { byHour: { hour: string; count: number }[] }) => {
  const width = 360;
  const height = 180;
  const padding = 20;
  const chartWidth = width - padding * 2;
  const chartHeight = height - padding * 2;
  const barWidth = chartWidth / 24 - 2;
  const max = Math.max(...byHour.map((h) => h.count)) || 1;

  return (
    <svg viewBox={`0 0 ${width} ${height}`} style={{ width: "100%", height: "auto" }} role="img" aria-label="Sesi per jam">
      <line x1={padding} y1={height - padding} x2={width - padding} y2={height - padding} stroke="var(--color-border, #ccc)" strokeWidth="1.5" />
      {byHour.map((h, index) => {
        const barHeight = (h.count / max) * chartHeight;
        const x = padding + index * (chartWidth / 24);
        const y = height - padding - barHeight;
        return (
          <g key={h.hour}>
            <rect x={x} y={y} width={barWidth} height={barHeight} fill="var(--color-accent, #3b82f6)" opacity="0.8" rx="2">
              <title>{`Pukul ${h.hour}: ${h.count} sesi`}</title>
            </rect>
            {index % 4 === 0 && (
              <text x={x + barWidth / 2} y={height - 4} fill="var(--color-text-secondary, #888)" fontSize="8" textAnchor="middle">
                {index}
              </text>
            )}
          </g>
        );
      })}
    </svg>
  );
};

export default function Analytics() {
  const [analytics, setAnalytics] = useState<AnalyticsData | null>(null);
  const [analyticsError, setAnalyticsError] = useState<string | null>(null);
  const [sessions, setSessions] = useState<SessionLog[] | null>(null);
  const [totalLogs, setTotalLogs] = useState(0);
  const [page, setPage] = useState(1);
  const [search, setSearch] = useState("");
  const [query, setQuery] = useState("");
  const [audit, setAudit] = useState<AuditAction[] | null>(null);
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
      if (query) {
        url += `&username=${encodeURIComponent(query)}&hostname=${encodeURIComponent(query)}`;
      }
      const data = await getJson<{ total: number; sessions: SessionLog[] }>(url, "Gagal mengambil data catatan sesi");
      setSessions(data.sessions);
      setTotalLogs(data.total);
    } catch {
      setSessions([]);
    }
  }, [page, query]);

  const fetchAudit = useCallback(async () => {
    try {
      const data = await getJson<{ actions: AuditAction[] }>("/api/audit-log?limit=20", "Gagal mengambil audit log");
      setAudit(data.actions);
    } catch {
      setAudit([]);
    }
  }, []);

  usePolling(fetchAnalytics, 10000);
  usePolling(fetchAudit, 30000);
  useEffect(() => {
    fetchSessions();
    const id = setInterval(fetchSessions, 30000);
    return () => clearInterval(id);
  }, [fetchSessions]);

  const onSearchChange = (value: string) => {
    setSearch(value);
    clearTimeout(debounceRef.current);
    debounceRef.current = setTimeout(() => {
      setQuery(value.trim());
      setPage(1);
    }, 400);
  };

  const totalPages = Math.ceil(totalLogs / ITEMS_PER_PAGE) || 1;

  return (
    <VStack gap={6}>
      <Heading level={3}>Analytics</Heading>

      {analyticsError ? (
        <EmptyState title="Terjadi Kesalahan" description={analyticsError} />
      ) : (
        <>
        <Grid columns={{ minWidth: 200, repeat: "fit" }} gap={4}>
          <StatCard label="Total Jam Penggunaan" value={analytics?.totals.hours ?? "-"} icon={ClockIcon} variant="blue" />
          <StatCard label="Total Sesi" value={analytics?.totals.sessions ?? "-"} icon={PresentationChartLineIcon} variant="cyan" />
          <StatCard label="Workstation Terpakai" value={analytics?.totals.workstations ?? "-"} icon={ComputerDesktopIcon} variant="purple" />
        </Grid>
        <Grid columns={{ minWidth: 300, repeat: "fit" }} gap={4}>
          <Card padding={4}>
            <VStack gap={3}>
              <Heading level={6}>Utilisasi Workstation (jam)</Heading>
              <BarList
                emptyLabel="Tidak ada data stasiun."
                items={(analytics?.by_workstation ?? []).map((w) => ({
                  label: w.hostname,
                  value: w.hours,
                  suffix: "jam",
                }))}
              />
            </VStack>
          </Card>
          <Card padding={4}>
            <VStack gap={3}>
              <Heading level={6}>Tujuan Penggunaan</Heading>
              <BarList
                emptyLabel="Tidak ada data tujuan."
                items={(analytics?.by_purpose ?? []).map((p) => ({
                  label: p.purpose,
                  value: p.count,
                  suffix: "sesi",
                }))}
              />
            </VStack>
          </Card>
          <Card padding={4}>
            <VStack gap={3}>
              <Heading level={6}>Distribusi Jam Sesi</Heading>
              {analytics ? <HourlyChart byHour={analytics.by_hour} /> : <Text type="body">Memuat...</Text>}
            </VStack>
          </Card>
        </Grid>
        </>
      )}

      <VStack gap={3}>
        <HStack gap={3} align="center" justify="between">
          <HStack gap={2} align="center">
            <Heading level={5}>Catatan Sesi</Heading>
            <Badge variant="neutral" label={`${totalLogs} total`} />
          </HStack>
          <TextInput
            label="Cari"
            isLabelHidden
            placeholder="Cari username / hostname..."
            value={search}
            onChange={onSearchChange}
            size="sm"
            hasClear
          />
        </HStack>

        {sessions === null ? (
          <Text type="body">Memuat catatan sesi...</Text>
        ) : sessions.length === 0 ? (
          <EmptyState title="Tidak ada catatan sesi ditemukan." isCompact />
        ) : (
          <Table
            data={sessions}
            density="compact"
            hasHover
            columns={[
              { key: "timestamp", header: "Waktu", renderCell: (s) => formatDateTime(s.timestamp as string) },
              { key: "hostname", header: "Stasiun", renderCell: (s) => <strong>{(s.hostname as string) || "-"}</strong> },
              { key: "event", header: "Event", renderCell: (s) => eventBadge(s.event as string) },
              { key: "session_type", header: "Tipe", renderCell: (s) => (s.session_type as string) || "-" },
              { key: "nama", header: "Nama", renderCell: (s) => (s.nama as string) || (s.username as string) || "-" },
              { key: "nim", header: "NIM", renderCell: (s) => (s.nim as string) || "-" },
              { key: "tujuan", header: "Tujuan", renderCell: (s) => (s.tujuan as string) || "-" },
              { key: "keterangan", header: "Keterangan", renderCell: (s) => (s.keterangan as string) || "-" },
            ]}
          />
        )}

        <HStack gap={3} align="center" justify="end">
          <Button label="Sebelumnya" size="sm" isDisabled={page === 1} onClick={() => setPage((p) => Math.max(1, p - 1))} />
          <Text type="supporting" color="secondary">Halaman {page} dari {totalPages}</Text>
          <Button
            label="Berikutnya"
            size="sm"
            isDisabled={(page - 1) * ITEMS_PER_PAGE + (sessions?.length ?? 0) >= totalLogs}
            onClick={() => setPage((p) => p + 1)}
          />
        </HStack>
      </VStack>

      <VStack gap={3}>
        <Heading level={5}>Audit Log (Logix Control)</Heading>
        {audit === null ? (
          <Text type="body">Memuat audit log...</Text>
        ) : audit.length === 0 ? (
          <EmptyState title="Belum ada tindakan admin tercatat." isCompact />
        ) : (
          <Table
            data={audit}
            density="compact"
            hasHover
            columns={[
              { key: "timestamp", header: "Waktu", renderCell: (a) => formatDateTime(a.timestamp as string) },
              { key: "actor_email", header: "Admin" },
              { key: "target_device", header: "Target", renderCell: (a) => <strong>{(a.target_device as string) || "-"}</strong> },
              { key: "action_type", header: "Tindakan" },
              {
                key: "status",
                header: "Status",
                renderCell: (a) => {
                  const info = AUDIT_BADGE[a.status as CommandStatus] ?? { label: a.status as string, variant: "neutral" as const };
                  return <Badge variant={info.variant} label={info.label} />;
                },
              },
              { key: "reason", header: "Alasan", renderCell: (a) => (a.reason as string) || "-" },
              { key: "result_summary", header: "Hasil", renderCell: (a) => (a.result_summary as string) || "-" },
            ]}
          />
        )}
      </VStack>
    </VStack>
  );
}
