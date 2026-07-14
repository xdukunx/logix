// Devices tab: fleet-summary stats, the persistent device registry table,
// and the Device Detail dialog (sync health, recent commands with retry,
// latest screenshot, Rename/Screenshot/Revoke). Ported from
// server/static/js/devices.js.
import { useCallback, useEffect, useState } from "react";
import type { ComponentType, SVGProps } from "react";
import { Badge } from "@astryxdesign/core/Badge";
import { Button } from "@astryxdesign/core/Button";
import { Card } from "@astryxdesign/core/Card";
import { Dialog } from "@astryxdesign/core/Dialog";
import { Grid } from "@astryxdesign/core/Grid";
import { HStack, VStack } from "@astryxdesign/core/Stack";
import { Table } from "@astryxdesign/core/Table";
import { Heading, Text } from "@astryxdesign/core/Text";
import { useToast } from "@astryxdesign/core/Toast";
import {
  ClockIcon,
  QueueListIcon,
  ServerStackIcon,
  ShieldCheckIcon,
  SignalIcon,
  SignalSlashIcon,
} from "@heroicons/react/24/outline";

import { fetchWithAuth, getJson, postEmpty, sendJson } from "../api";
import EnrollDialog from "../components/EnrollDialog";
import StatCard from "../components/StatCard";
import ConfirmModal from "../components/modals/ConfirmModal";
import RenameModal from "../components/modals/RenameModal";
import ScreenshotRequestModal from "../components/modals/ScreenshotRequestModal";
import EmptyState from "../components/states/EmptyState";
import ErrorState from "../components/states/ErrorState";
import { SkeletonGrid } from "../components/states/Skeleton";
import type { CommandStatus, Device, DeviceDetail, DeviceScreenshot, SyncStatus } from "../types";
import { formatDateTime, timeAgo, usePolling } from "../util";

const SYNC_BADGE: Record<SyncStatus, { label: string; variant: "success" | "warning" | "neutral" }> = {
  online: { label: "Online", variant: "success" },
  stale: { label: "Stale", variant: "warning" },
  offline: { label: "Offline", variant: "neutral" },
  never_seen: { label: "Never Seen", variant: "neutral" },
};

const COMMAND_BADGE: Record<CommandStatus, { label: string; variant: "success" | "warning" | "error" | "neutral" }> = {
  queued: { label: "Menunggu", variant: "warning" },
  done: { label: "Selesai", variant: "success" },
  failed: { label: "Gagal", variant: "error" },
  expired: { label: "Kedaluwarsa", variant: "neutral" },
};

const DEVICES_PER_PAGE = 15;

const syncBadge = (status: SyncStatus) => {
  const info = SYNC_BADGE[status] ?? { label: status, variant: "neutral" as const };
  return <Badge variant={info.variant} label={info.label} />;
};

const commandBadge = (status: CommandStatus) => {
  const info = COMMAND_BADGE[status] ?? { label: status, variant: "neutral" as const };
  return <Badge variant={info.variant} label={info.label} />;
};


export default function Devices() {
  const toast = useToast();
  const [devices, setDevices] = useState<Device[] | null>(null);
  const [backlog, setBacklog] = useState<number | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [detailId, setDetailId] = useState<string | null>(null);
  const [detail, setDetail] = useState<DeviceDetail | null>(null);
  const [detailError, setDetailError] = useState<string | null>(null);
  const [screenshot, setScreenshot] = useState<DeviceScreenshot | null>(null);
  // Action modals (replace native prompt()/confirm()).
  const [isRenameOpen, setRenameOpen] = useState(false);
  const [isScreenshotOpen, setScreenshotOpen] = useState(false);
  const [isRevokeOpen, setRevokeOpen] = useState(false);
  const [page, setPage] = useState(1);

  const notify = useCallback(
    (message: string, isError = false) =>
      toast({ body: message, type: isError ? "error" : "info" }),
    [toast],
  );

  const refresh = useCallback(async () => {
    try {
      setDevices(await getJson<Device[]>("/api/devices", "Gagal memuat data devices"));
      setError(null);
    } catch (err) {
      setError((err as Error).message);
    }
    try {
      const data = await getJson<{ total: number }>(
        "/api/audit-log?status=queued&limit=1",
        "Gagal memuat antrean perintah",
      );
      setBacklog(data.total);
    } catch {
      // stat stays at its last value on transient failure, like the legacy UI
    }
  }, []);

  usePolling(refresh, 10000);

  const loadDetail = useCallback(async (deviceId: string) => {
    setDetail(null);
    setDetailError(null);
    setScreenshot(null);
    try {
      setDetail(await getJson<DeviceDetail>(`/api/devices/${deviceId}`, "Gagal memuat detail device"));
    } catch (err) {
      setDetailError((err as Error).message);
      return;
    }
    // 404/403 are normal ("no capture yet" / no screenshot permission) --
    // the section just stays hidden.
    try {
      const res = await fetchWithAuth(`/api/devices/${deviceId}/screenshot`);
      if (res.ok) setScreenshot(await res.json());
    } catch {
      /* ignore */
    }
  }, []);

  useEffect(() => {
    if (detailId) loadDetail(detailId);
  }, [detailId, loadDetail]);

  const submitRename = async (display_name: string) => {
    if (!detail) return;
    try {
      await sendJson(
        "/api/devices/rename",
        "PUT",
        { hostname: detail.device.hostname, display_name },
        "Gagal mengubah nama device",
      );
      notify(`Device diganti nama menjadi "${display_name}"`);
      if (detailId) loadDetail(detailId);
      refresh();
    } catch (err) {
      notify((err as Error).message, true);
    }
  };

  const submitRevoke = async () => {
    if (!detailId || !detail) return;
    try {
      await postEmpty(`/api/devices/${detailId}/revoke`, "Gagal mencabut API key device");
      notify(`API key untuk ${detail.device.hostname} telah dicabut.`);
      loadDetail(detailId);
      refresh();
    } catch (err) {
      notify((err as Error).message, true);
    }
  };

  const submitScreenshot = async (reason: string) => {
    if (!detail) return;
    const hostname = detail.device.hostname;
    const prevAt = screenshot?.captured_at ?? "";
    try {
      await sendJson("/api/control/screenshot", "POST", { hostname, reason }, "Gagal meminta screenshot");
      notify("Permintaan screenshot dikirim. Menunggu device merespons...");
      // Poll for the new capture so it appears here without reopening.
      if (!detailId) return;
      for (let i = 0; i < 12; i++) {
        await new Promise((r) => setTimeout(r, 1500));
        try {
          const res = await fetchWithAuth(`/api/devices/${detailId}/screenshot`);
          if (res.ok) {
            const shot: DeviceScreenshot = await res.json();
            if (shot.captured_at !== prevAt) {
              setScreenshot(shot);
              return;
            }
          }
        } catch {
          /* keep polling */
        }
      }
    } catch (err) {
      notify((err as Error).message, true);
    }
  };

  const retryAction = (deviceId: string, actionId: number) => {
    postEmpty(`/api/devices/${deviceId}/actions/${actionId}/retry`, "Gagal mengulangi perintah")
      .then(() => {
        notify("Perintah diulang dan dimasukkan ke antrean.");
        loadDetail(deviceId);
        refresh();
      })
      .catch((err) => notify(err.message, true));
  };

  const counts = { total: 0, online: 0, stale: 0, offline: 0 };
  for (const d of devices ?? []) {
    counts.total++;
    if (d.sync_status === "online") counts.online++;
    else if (d.sync_status === "stale") counts.stale++;
    else counts.offline++; // offline + never_seen both read as "not reachable"
  }

  // Client-side pagination for the registry table (the fleet can grow to
  // hundreds; /api/devices returns the full list). Clamp the page so a
  // shrinking list never leaves us stranded past the end.
  const totalPages = Math.max(1, Math.ceil(counts.total / DEVICES_PER_PAGE));
  const safePage = Math.min(page, totalPages);
  const pagedDevices = (devices ?? []).slice(
    (safePage - 1) * DEVICES_PER_PAGE,
    safePage * DEVICES_PER_PAGE,
  );
  const rangeStart = counts.total === 0 ? 0 : (safePage - 1) * DEVICES_PER_PAGE + 1;
  const rangeEnd = (safePage - 1) * DEVICES_PER_PAGE + pagedDevices.length;

  return (
    <VStack gap={6}>
      <HStack gap={3} align="center" justify="between" wrap="wrap">
        <VStack gap={1}>
          <Heading level={3}>Devices</Heading>
          <Text type="supporting" color="secondary">
            {counts.total} perangkat terdaftar · {counts.online} online
          </Text>
        </VStack>
        <EnrollDialog onEnrolled={refresh} />
      </HStack>

      <Grid columns={{ minWidth: 170, repeat: "fit" }} gap={4}>
        <StatCard label="Total Devices" value={counts.total} icon={ServerStackIcon} variant="blue" />
        <StatCard label="Online" value={counts.online} icon={SignalIcon} variant="green" />
        <StatCard label="Stale" value={counts.stale} icon={ClockIcon} variant="yellow" />
        <StatCard label="Offline" value={counts.offline} icon={SignalSlashIcon} variant="muted" />
        <StatCard label="Antrean Perintah" value={backlog ?? "-"} icon={QueueListIcon} variant="orange" />
      </Grid>

      {error ? (
        <ErrorState description={error} onRetry={refresh} />
      ) : devices === null ? (
        <SkeletonGrid count={3} />
      ) : devices.length === 0 ? (
        <EmptyState
          title="Belum ada perangkat"
          description="Perangkat muncul di sini setelah mengirim heartbeat pertama. Daftarkan satu untuk mulai."
        />
      ) : (
        <VStack gap={3}>
        <Table<Device>
          data={pagedDevices}
          idKey="device_id"
          hasHover
          density="balanced"
          columns={[
            {
              key: "display_name",
              header: "Nama",
              renderCell: (d) => <strong>{(d.display_name as string) || d.hostname}</strong>,
            },
            { key: "hostname", header: "Hostname" },
            { key: "category", header: "Kategori" },
            {
              key: "sync_status",
              header: "Status",
              renderCell: (d) => syncBadge(d.sync_status),
            },
            {
              key: "last_seen",
              header: "Terakhir Terlihat",
              renderCell: (d) => timeAgo(d.last_seen),
            },
            {
              key: "policy_profile",
              header: "Policy",
              renderCell: (d) => (d.policy_profile as string) || "-",
            },
            {
              key: "actions",
              header: "",
              renderCell: (d) => (
                <Button label="Detail" size="sm" variant="ghost" onClick={() => setDetailId(d.device_id)} />
              ),
            },
          ]}
        />
        {counts.total > DEVICES_PER_PAGE && (
          <HStack gap={3} align="center" justify="between">
            <Text type="supporting" color="secondary">
              {rangeStart}–{rangeEnd} dari {counts.total} perangkat
            </Text>
            <HStack gap={2} align="center">
              <Button label="‹" size="sm" variant="secondary" isDisabled={safePage === 1} onClick={() => setPage((p) => Math.max(1, p - 1))} />
              <Text type="supporting" color="secondary">Halaman {safePage} / {totalPages}</Text>
              <Button label="›" size="sm" variant="secondary" isDisabled={safePage >= totalPages} onClick={() => setPage((p) => p + 1)} />
            </HStack>
          </HStack>
        )}
        </VStack>
      )}

      <Dialog isOpen={detailId !== null} onOpenChange={(open) => !open && setDetailId(null)} width={720}>
        <VStack gap={4}>
          <Heading level={4}>
            {detail ? (detail.device.display_name as string) || detail.device.hostname : "Device Detail"}
          </Heading>

          {detailError ? (
            <ErrorState description={detailError} onRetry={() => detailId && loadDetail(detailId)} />
          ) : !detail ? (
            <Text type="body">Memuat detail device…</Text>
          ) : (
            <>
              <Grid columns={3} gap={4}>
                <VStack gap={1}>
                  <Text type="supporting" color="secondary">Hostname</Text>
                  <Text type="body"><strong>{detail.device.hostname}</strong></Text>
                </VStack>
                <VStack gap={1}>
                  <Text type="supporting" color="secondary">Category</Text>
                  <Text type="body"><strong>{detail.device.category}</strong></Text>
                </VStack>
                <VStack gap={1}>
                  <Text type="supporting" color="secondary">Status</Text>
                  <HStack gap={1}>{syncBadge(detail.device.sync_status)}</HStack>
                </VStack>
                <VStack gap={1}>
                  <Text type="supporting" color="secondary">Last Seen</Text>
                  <Text type="body"><strong>{timeAgo(detail.device.last_seen)}</strong></Text>
                </VStack>
                <VStack gap={1}>
                  <Text type="supporting" color="secondary">Policy</Text>
                  <Text type="body">
                    <strong>{(detail.device.policy_profile as string) || "-"}</strong>
                    {detail.policy ? ` (${detail.policy.description})` : ""}
                  </Text>
                </VStack>
                <VStack gap={1}>
                  <Text type="supporting" color="secondary">Privacy Mode</Text>
                  <Text type="body"><strong>{(detail.device.privacy_mode as string) || "-"}</strong></Text>
                </VStack>
              </Grid>

              <HStack gap={2} align="start" style={{ background: "var(--lx-accent-weak)", border: "1px solid var(--color-border)", borderRadius: 8, padding: "11px 13px" }}>
                <ShieldCheckIcon style={{ width: 18, height: 18, color: "var(--lx-accent)", flexShrink: 0, marginTop: 1 }} />
                <Text type="supporting">
                  Kebijakan privasi: cuplikan memberi tahu pengguna. Tanpa perekaman keystroke. Log
                  penuh &amp; dapat diaudit.
                </Text>
              </HStack>

              <VStack gap={2}>
                <Heading level={6}>Sync Health</Heading>
                <HStack gap={4}>
                  {(Object.keys(COMMAND_BADGE) as CommandStatus[]).map((s) => (
                    <HStack key={s} gap={1} align="center">
                      {commandBadge(s)}
                      <Text type="body">{detail.sync_health[s] ?? 0}</Text>
                    </HStack>
                  ))}
                </HStack>
              </VStack>

              <VStack gap={2}>
                <Heading level={6}>Recent Commands</Heading>
                {detail.recent_actions.length === 0 ? (
                  <Text type="body" color="secondary">Belum ada tindakan tercatat.</Text>
                ) : (
                  <Table
                    data={detail.recent_actions}
                    idKey="action_id"
                    density="compact"
                    columns={[
                      {
                        key: "timestamp",
                        header: "Timestamp",
                        renderCell: (a) => formatDateTime(a.timestamp as string),
                      },
                      {
                        key: "action_type",
                        header: "Tindakan",
                        renderCell: (a) => (
                          <VStack gap={0.5}>
                            <Text type="body">{a.action_type as string}</Text>
                            {(a.retry_count as number) > 0 && (
                              <Text type="supporting" color="secondary">Percobaan ke-{a.retry_count as number}</Text>
                            )}
                          </VStack>
                        ),
                      },
                      {
                        key: "status",
                        header: "Status",
                        renderCell: (a) => commandBadge(a.status as CommandStatus),
                      },
                      {
                        key: "result_summary",
                        header: "Ringkasan",
                        renderCell: (a) =>
                          (a.result_summary as string) || (a.error_message as string) || "-",
                      },
                      {
                        key: "retry",
                        header: "",
                        renderCell: (a) =>
                          a.retryable ? (
                            <Button
                              label="Retry"
                              size="sm"
                              onClick={() => detailId && retryAction(detailId, a.action_id as number)}
                            />
                          ) : null,
                      },
                    ]}
                  />
                )}
              </VStack>

              {screenshot && (
                <VStack gap={2}>
                  <Heading level={6}>Tangkapan Layar Terakhir</Heading>
                  <img
                    src={`data:${screenshot.content_type || "image/jpeg"};base64,${screenshot.image_base64}`}
                    alt={`Screenshot ${screenshot.hostname}`}
                    style={{ maxWidth: "100%", borderRadius: "var(--radius-container, 8px)" }}
                  />
                  <Text type="supporting" color="secondary">
                    Diambil {formatDateTime(screenshot.captured_at)} — hanya tangkapan terbaru yang disimpan;
                    pengguna di perangkat selalu diberi tahu saat layar diambil.
                  </Text>
                </VStack>
              )}

              <HStack gap={2}>
                <Button label="Rename" size="sm" onClick={() => setRenameOpen(true)} />
                <Button label="Ambil Screenshot" size="sm" onClick={() => setScreenshotOpen(true)} />
                <Button
                  label="Revoke API Key"
                  size="sm"
                  variant="destructive"
                  onClick={() => setRevokeOpen(true)}
                />
              </HStack>
            </>
          )}
        </VStack>
      </Dialog>

      {detail && (
        <>
          <RenameModal
            isOpen={isRenameOpen}
            onClose={() => setRenameOpen(false)}
            hostname={detail.device.hostname}
            currentName={(detail.device.display_name as string) || detail.device.hostname}
            onSubmit={submitRename}
          />
          <ScreenshotRequestModal
            isOpen={isScreenshotOpen}
            onClose={() => setScreenshotOpen(false)}
            deviceLabel={(detail.device.display_name as string) || detail.device.hostname}
            onSubmit={submitScreenshot}
          />
          <ConfirmModal
            isOpen={isRevokeOpen}
            onClose={() => setRevokeOpen(false)}
            title={`Cabut API key ${detail.device.hostname}?`}
            subtitle="Revoke API Key"
            body="Device ini tidak akan bisa mengirim heartbeat sampai didaftarkan ulang."
            confirmLabel="Cabut API Key"
            onConfirm={submitRevoke}
          />
        </>
      )}
    </VStack>
  );
}
