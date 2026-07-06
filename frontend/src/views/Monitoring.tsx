// Monitoring tab: active workstation cards, right-click actions (Remote,
// Lock, Screenshot, Rename, Message, Power), per-card unread-reply badges,
// and the Emergency Alert broadcast card. Ported from
// server/static/js/monitoring.js -- prompts/confirms preserved as-is.
import { useCallback, useMemo, useState } from "react";
import { Badge } from "@astryxdesign/core/Badge";
import { Button } from "@astryxdesign/core/Button";
import { Card } from "@astryxdesign/core/Card";
import { ContextMenu } from "@astryxdesign/core/ContextMenu";
import { Dialog } from "@astryxdesign/core/Dialog";
import { EmptyState } from "@astryxdesign/core/EmptyState";
import { Grid } from "@astryxdesign/core/Grid";
import { HStack, VStack } from "@astryxdesign/core/Stack";
import { StatusDot } from "@astryxdesign/core/StatusDot";
import { Heading, Text } from "@astryxdesign/core/Text";
import { TextArea } from "@astryxdesign/core/TextArea";
import { useToast } from "@astryxdesign/core/Toast";
import { ComputerDesktopIcon } from "@heroicons/react/24/outline";

import { getJson, postEmpty, sendJson } from "../api";
import type { ActiveWorkstation, Reply } from "../types";
import { formatTime, timeAgo, usePolling } from "../util";

export default function Monitoring() {
  const toast = useToast();
  const [pcs, setPcs] = useState<ActiveWorkstation[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [repliesByHost, setRepliesByHost] = useState<Record<string, Reply[]>>({});
  const [replyDialogHost, setReplyDialogHost] = useState<string | null>(null);
  const [broadcast, setBroadcast] = useState("");

  const notify = useCallback(
    (message: string, isError = false) =>
      toast({ body: message, type: isError ? "error" : "info" }),
    [toast],
  );

  const refresh = useCallback(async () => {
    try {
      setPcs(await getJson<ActiveWorkstation[]>("/api/active", "Gagal mengambil data workstation aktif"));
      setError(null);
    } catch (err) {
      setError((err as Error).message);
    }
    try {
      const data = await getJson<{ replies: Reply[] }>("/api/replies?limit=100", "");
      const byHost: Record<string, Reply[]> = {};
      for (const r of data.replies || []) (byHost[r.hostname] ??= []).push(r);
      setRepliesByHost(byHost);
    } catch {
      // 403 (role can't read replies) or transient error: leave badges as-is
    }
  }, []);

  usePolling(refresh, 10000);

  const act = useCallback(
    async (fn: () => Promise<unknown>, successMessage: string) => {
      try {
        await fn();
        notify(successMessage);
        refresh();
      } catch (err) {
        notify((err as Error).message, true);
      }
    },
    [notify, refresh],
  );

  const lockWorkstation = (hostname: string) =>
    act(
      () => sendJson("/api/control/lock", "POST", { hostname }, "Gagal mengirim perintah kunci"),
      `Perintah KUNCI ditambahkan ke antrean stasiun ${hostname}`,
    );

  const sendDirectMessage = (hostname: string) => {
    const message = prompt(`Pesan untuk ${hostname}:`, "");
    if (!message || !message.trim()) return;
    act(
      () =>
        sendJson(
          "/api/control/broadcast",
          "POST",
          { hostname, param: message.trim(), reason: "Direction Message" },
          "Gagal mengirim pesan",
        ),
      `Pesan dikirim ke ${hostname}`,
    );
  };

  const requestScreenshot = (hostname: string) => {
    const reason = prompt(`Alasan mengambil screenshot ${hostname} (kebijakan device dapat mewajibkan ini):`, "");
    if (reason === null) return;
    act(
      () =>
        sendJson(
          "/api/control/screenshot",
          "POST",
          { hostname, reason: reason.trim() },
          "Gagal meminta screenshot",
        ),
      `Permintaan screenshot dikirim ke ${hostname}. Hasilnya muncul di Device Detail (tab Devices).`,
    );
  };

  const POWER_LABELS: Record<string, string> = {
    shutdown: "mematikan",
    restart: "memulai ulang",
    logoff: "mengeluarkan pengguna dari",
  };

  const sendPowerCommand = (hostname: string, action: "shutdown" | "restart" | "logoff") => {
    if (!confirm(`Yakin ingin ${POWER_LABELS[action]} ${hostname}? Pengguna diberi peringatan 30 detik.`)) return;
    const reason = prompt("Alasan (kebijakan device dapat mewajibkan ini):", "");
    if (reason === null) return;
    act(
      () =>
        sendJson(
          "/api/control/power",
          "POST",
          { hostname, action, reason: reason.trim() },
          "Gagal mengirim perintah daya",
        ),
      `Perintah ${action.toUpperCase()} ditambahkan ke antrean ${hostname}.`,
    );
  };

  const renameWorkstation = (hostname: string, currentName: string) => {
    const name = prompt(`Nama baru untuk ${hostname}:`, currentName || "");
    if (name === null) return;
    const trimmed = name.trim();
    if (!trimmed) {
      notify("Nama tidak boleh kosong.", true);
      return;
    }
    act(
      () =>
        sendJson("/api/devices/rename", "PUT", { hostname, display_name: trimmed }, "Gagal mengubah nama device"),
      `Device diganti nama menjadi "${trimmed}"`,
    );
  };

  const sendEmergencyAlert = async () => {
    const message = broadcast.trim();
    if (!message) {
      notify("Tulis pesan terlebih dahulu.", true);
      return;
    }
    try {
      await sendJson(
        "/api/control/broadcast",
        "POST",
        { hostname: "ALL", param: message, reason: "Emergency Alert" },
        "Gagal mengirim pesan",
      );
      notify("Emergency Alert sent to all active workstations.");
      setBroadcast("");
    } catch (err) {
      notify((err as Error).message, true);
    }
  };

  const unreadFor = (hostname: string) =>
    (repliesByHost[hostname] || []).filter((r) => !r.read_at).length;

  const markAllRead = async (hostname: string) => {
    const unread = (repliesByHost[hostname] || []).filter((r) => !r.read_at);
    await Promise.all(
      unread.map((r) => postEmpty(`/api/replies/${r.id}/read`, "").catch(() => {})),
    );
    setReplyDialogHost(null);
    refresh();
  };

  const menuItemsFor = (pc: ActiveWorkstation) => [
    pc.anydesk_id
      ? { label: "Remote", onClick: () => (window.location.href = `anydesk:${pc.anydesk_id}`) }
      : { label: "Remote (AnyDesk ID tidak terdeteksi)", isDisabled: true },
    { label: "Lock", onClick: () => lockWorkstation(pc.hostname) },
    { label: "Screenshot", onClick: () => requestScreenshot(pc.hostname) },
    { label: "Rename", onClick: () => renameWorkstation(pc.hostname, pc.device_name) },
    { type: "divider" as const },
    { label: "Send Message", onClick: () => sendDirectMessage(pc.hostname) },
    { type: "divider" as const },
    { label: "Log Off User", onClick: () => sendPowerCommand(pc.hostname, "logoff") },
    { label: "Restart", onClick: () => sendPowerCommand(pc.hostname, "restart") },
    { label: "Shut Down", onClick: () => sendPowerCommand(pc.hostname, "shutdown") },
  ];

  const dialogReplies = useMemo(
    () =>
      replyDialogHost
        ? (repliesByHost[replyDialogHost] || [])
            .slice()
            .sort((a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime())
        : [],
    [replyDialogHost, repliesByHost],
  );

  const activeCount = pcs?.length ?? 0;

  return (
    <VStack gap={6}>
      <HStack gap={3} align="center">
        <Heading level={3}>Monitoring</Heading>
        <Badge variant={activeCount > 0 ? "success" : "neutral"} label={`${activeCount} Aktif`} />
      </HStack>

      {error ? (
        <EmptyState title="Terjadi Kesalahan" description={error} />
      ) : pcs === null ? (
        <Text type="body">Memuat data...</Text>
      ) : pcs.length === 0 ? (
        <EmptyState
          icon={<ComputerDesktopIcon style={{ width: 40, height: 40 }} />}
          title="No Active Devices"
          description="Active devices will appear here once a workstation starts a session."
        />
      ) : (
        <Grid columns={{ minWidth: 240, repeat: "fill" }} gap={4}>
          {pcs.map((pc) => {
            const isUserActive = pc.status === "ACTIVE";
            const deviceName = pc.device_name || pc.hostname;
            const unread = unreadFor(pc.hostname);
            return (
              <ContextMenu key={pc.hostname} items={isUserActive ? menuItemsFor(pc) : []} isDisabled={!isUserActive} menuWidth={220}>
                <Card padding={4} variant={isUserActive ? "green" : "muted"}>
                  <VStack gap={2}>
                    <HStack gap={2} align="center" justify="between">
                      <HStack gap={2} align="center">
                        <StatusDot
                          variant={isUserActive ? "success" : "warning"}
                          label={isUserActive ? "Dalam Penggunaan" : "Terkunci"}
                          isPulsing={isUserActive}
                        />
                        <Text type="label">{deviceName}</Text>
                      </HStack>
                      {unread > 0 && (
                        <Button
                          label={`${unread} balasan`}
                          size="sm"
                          variant="ghost"
                          onClick={() => setReplyDialogHost(pc.hostname)}
                        />
                      )}
                    </HStack>
                    {pc.device_name && pc.device_name !== pc.hostname && (
                      <Text type="supporting" color="secondary">Hostname: {pc.hostname}</Text>
                    )}
                    <Text type="supporting" color="secondary">
                      Status: {isUserActive ? "Dalam Penggunaan" : "Terkunci"}
                    </Text>
                    <Text type="supporting" color="secondary">Aktif: {formatTime(pc.last_seen)}</Text>
                    {pc.username && (
                      <Text type="body">
                        Pengguna: <strong>{pc.username}</strong>
                      </Text>
                    )}
                    {isUserActive && (
                      <Text type="supporting" color="secondary">
                        Klik kanan untuk opsi (Remote, Lock, Screenshot, Message, Power)
                      </Text>
                    )}
                  </VStack>
                </Card>
              </ContextMenu>
            );
          })}
        </Grid>
      )}

      <Card padding={4} variant="muted">
        <VStack gap={3}>
          <Heading level={5}>Emergency Alert</Heading>
          <TextArea
            label="Pesan"
            isLabelHidden
            placeholder="Tulis pengumuman untuk semua workstation aktif..."
            value={broadcast}
            onChange={setBroadcast}
            rows={3}
          />
          <HStack gap={3} align="center" justify="between">
            <Text type="supporting" color="secondary">
              {activeCount > 0
                ? "Sent to every active device — no individual selection needed. For a single device, right-click its card instead."
                : "No active devices to alert right now."}
            </Text>
            <Button
              label="Kirim ke Semua"
              variant="primary"
              isDisabled={activeCount === 0}
              onClick={sendEmergencyAlert}
            />
          </HStack>
        </VStack>
      </Card>

      <Dialog isOpen={replyDialogHost !== null} onOpenChange={(open) => !open && setReplyDialogHost(null)} width={420}>
        <VStack gap={3}>
          <Heading level={5}>
            Balasan — {dialogReplies[0]?.device_name || replyDialogHost || ""}
          </Heading>
          <VStack gap={2}>
            {dialogReplies.map((r) => (
              <Card key={r.id} padding={2} variant={r.read_at ? "muted" : "default"}>
                <VStack gap={1}>
                  <Text type="body">{r.message}</Text>
                  <Text type="supporting" color="secondary">
                    {timeAgo(r.created_at)}
                    {r.read_at ? " · Dibaca" : ""}
                  </Text>
                </VStack>
              </Card>
            ))}
          </VStack>
          <HStack gap={2} justify="end">
            <Button label="Tutup" onClick={() => setReplyDialogHost(null)} />
            <Button
              label="Tandai semua dibaca"
              variant="primary"
              onClick={() => replyDialogHost && markAllRead(replyDialogHost)}
            />
          </HStack>
        </VStack>
      </Dialog>
    </VStack>
  );
}
