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
import { EmptyState } from "@astryxdesign/core/EmptyState";
import { Grid } from "@astryxdesign/core/Grid";
import { HStack, VStack } from "@astryxdesign/core/Stack";
import { Table } from "@astryxdesign/core/Table";
import { Heading, Text } from "@astryxdesign/core/Text";
import { useToast } from "@astryxdesign/core/Toast";
import {
  ClockIcon,
  QueueListIcon,
  ServerStackIcon,
  SignalIcon,
  SignalSlashIcon,
} from "@heroicons/react/24/outline";

import { fetchWithAuth, getJson, postEmpty, sendJson } from "../api";
import StatCard from "../components/StatCard";
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

  const renameDevice = (hostname: string, currentName: string | null) => {
    const name = prompt(`Nama baru untuk ${hostname}:`, currentName || "");
    if (name === null) return;
    const trimmed = name.trim();
    if (!trimmed) {
      notify("Nama tidak boleh kosong.", true);
      return;
    }
    sendJson("/api/devices/rename", "PUT", { hostname, display_name: trimmed }, "Gagal mengubah nama device")
      .then(() => {
        notify(`Device diganti nama menjadi "${trimmed}"`);
        if (detailId) loadDetail(detailId);
        refresh();
      })
      .catch((err) => notify(err.message, true));
  };

  const revokeDevice = (deviceId: string, hostname: string) => {
    if (!confirm(`Cabut API key untuk ${hostname}? Device ini tidak akan bisa mengirim heartbeat sampai didaftarkan ulang.`)) return;
    postEmpty(`/api/devices/${deviceId}/revoke`, "Gagal mencabut API key device")
      .then(() => {
        notify(`API key untuk ${hostname} telah dicabut.`);
        loadDetail(deviceId);
        refresh();
      })
      .catch((err) => notify(err.message, true));
  };

  const requestScreenshot = (hostname: string) => {
    const reason = prompt(`Alasan mengambil screenshot ${hostname} (kebijakan device dapat mewajibkan ini):`, "");
    if (reason === null) return;
    sendJson("/api/control/screenshot", "POST", { hostname, reason: reason.trim() }, "Gagal meminta screenshot")
      .then(() => notify("Permintaan screenshot dikirim. Hasil muncul di sini setelah device merespons (heartbeat berikutnya)."))
      .catch((err) => notify(err.message, true));
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

  return (
    <VStack gap={6}>
      <Heading level={3}>Devices</Heading>

      <Grid columns={{ minWidth: 170, repeat: "fit" }} gap={4}>
        <StatCard label="Total Devices" value={counts.total} icon={ServerStackIcon} variant="blue" />
        <StatCard label="Online" value={counts.online} icon={SignalIcon} variant="green" />
        <StatCard label="Stale" value={counts.stale} icon={ClockIcon} variant="yellow" />
        <StatCard label="Offline" value={counts.offline} icon={SignalSlashIcon} variant="muted" />
        <StatCard label="Antrean Perintah" value={backlog ?? "-"} icon={QueueListIcon} variant="orange" />
      </Grid>

      {error ? (
        <EmptyState title="Terjadi Kesalahan" description={error} />
      ) : devices === null ? (
        <Text type="body">Memuat data devices...</Text>
      ) : devices.length === 0 ? (
        <EmptyState
          icon={<ServerStackIcon style={{ width: 40, height: 40 }} />}
          title="No Devices Yet"
          description="Devices will appear here once they send their first heartbeat."
        />
      ) : (
        <Table<Device>
          data={devices}
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
      )}

      <Dialog isOpen={detailId !== null} onOpenChange={(open) => !open && setDetailId(null)} width={720}>
        <VStack gap={4}>
          <Heading level={4}>
            {detail ? (detail.device.display_name as string) || detail.device.hostname : "Device Detail"}
          </Heading>

          {detailError ? (
            <EmptyState title="Terjadi Kesalahan" description={detailError} />
          ) : !detail ? (
            <Text type="body">Memuat detail device...</Text>
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
                <Button
                  label="Rename"
                  size="sm"
                  onClick={() => renameDevice(detail.device.hostname, detail.device.display_name as string | null)}
                />
                <Button
                  label="Ambil Screenshot"
                  size="sm"
                  onClick={() => requestScreenshot(detail.device.hostname)}
                />
                <Button
                  label="Revoke API Key"
                  size="sm"
                  variant="destructive"
                  onClick={() => detailId && revokeDevice(detailId, detail.device.hostname)}
                />
              </HStack>
            </>
          )}
        </VStack>
      </Dialog>
    </VStack>
  );
}
