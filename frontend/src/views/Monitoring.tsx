// Monitoring tab (design: docs/design/LogiX Monitoring.dc.html). Live
// occupancy summary, station cards with status border + access badge + visible
// actions (Message, Lock, Screenshot, and a More menu for Remote / Rename /
// Power), per-card unread-reply indicator, and the Emergency Broadcast card.
// Every browser prompt()/confirm() is gone — actions open styled modals
// (C3, components/modals/*). Data from /api/active.
import { useCallback, useMemo, useState } from "react";
import { Button } from "@astryxdesign/core/Button";
import { Card } from "@astryxdesign/core/Card";
import { IconButton } from "@astryxdesign/core/IconButton";
import { MoreMenu } from "@astryxdesign/core/MoreMenu";
import { HStack, VStack } from "@astryxdesign/core/Stack";
import { Heading, Text } from "@astryxdesign/core/Text";
import { TextArea } from "@astryxdesign/core/TextArea";
import { useToast } from "@astryxdesign/core/Toast";
import {
  ArrowRightOnRectangleIcon,
  ArrowPathIcon,
  ArrowTopRightOnSquareIcon,
  CameraIcon,
  ChatBubbleLeftRightIcon,
  LockClosedIcon,
  PencilSquareIcon,
  PowerIcon,
} from "@heroicons/react/24/outline";

import { getJson, postEmpty, sendJson } from "../api";
import AccessTypeBadge from "../components/AccessTypeBadge";
import StatusPill from "../components/StatusPill";
import EmptyState from "../components/states/EmptyState";
import ErrorState from "../components/states/ErrorState";
import { SkeletonGrid } from "../components/states/Skeleton";
import EmergencyBroadcastModal from "../components/modals/EmergencyBroadcastModal";
import PowerActionModal, { type PowerAction } from "../components/modals/PowerActionModal";
import RenameModal from "../components/modals/RenameModal";
import RepliesModal from "../components/modals/RepliesModal";
import ScreenshotRequestModal from "../components/modals/ScreenshotRequestModal";
import SendMessageModal from "../components/modals/SendMessageModal";
import { resolveAccessType, type StationStatus } from "../tokens";
import type { ActiveWorkstation, Reply } from "../types";
import { timeAgo, usePolling } from "../util";

const stationStatus = (pc: ActiveWorkstation): StationStatus =>
  pc.status === "LOCKED" ? "locked" : "inuse";

const labelFor = (pc: ActiveWorkstation) => pc.device_name || pc.hostname;

export default function Monitoring() {
  const toast = useToast();
  const [pcs, setPcs] = useState<ActiveWorkstation[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [updatedAt, setUpdatedAt] = useState<string | null>(null);
  const [repliesByHost, setRepliesByHost] = useState<Record<string, Reply[]>>({});
  const [broadcast, setBroadcast] = useState("");

  // Modal targets (null = closed).
  const [messageTarget, setMessageTarget] = useState<ActiveWorkstation | null>(null);
  const [screenshotTarget, setScreenshotTarget] = useState<ActiveWorkstation | null>(null);
  const [renameTarget, setRenameTarget] = useState<ActiveWorkstation | null>(null);
  const [powerTarget, setPowerTarget] = useState<{ pc: ActiveWorkstation; action: PowerAction } | null>(null);
  const [repliesTarget, setRepliesTarget] = useState<string | null>(null);
  const [isBroadcastConfirmOpen, setBroadcastConfirmOpen] = useState(false);

  const notify = useCallback(
    (message: string, isError = false) => toast({ body: message, type: isError ? "error" : "info" }),
    [toast],
  );

  const refresh = useCallback(async () => {
    try {
      setPcs(await getJson<ActiveWorkstation[]>("/api/active", "Gagal mengambil data workstation aktif"));
      setUpdatedAt(new Date().toISOString());
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
      await fn();
      notify(successMessage);
      refresh();
    },
    [notify, refresh],
  );

  const lockWorkstation = (pc: ActiveWorkstation) =>
    act(
      () => sendJson("/api/control/lock", "POST", { hostname: pc.hostname }, "Gagal mengirim perintah kunci"),
      `Perintah KUNCI ditambahkan ke antrean ${labelFor(pc)}`,
    ).catch((err) => notify((err as Error).message, true));

  const submitMessage = (hostname: string, message: string) =>
    act(
      () =>
        sendJson(
          "/api/control/broadcast",
          "POST",
          { hostname, param: message, reason: "Direction Message" },
          "Gagal mengirim pesan",
        ),
      `Pesan dikirim ke ${hostname}`,
    );

  const submitScreenshot = (hostname: string, reason: string) =>
    act(
      () => sendJson("/api/control/screenshot", "POST", { hostname, reason }, "Gagal meminta screenshot"),
      `Permintaan screenshot dikirim ke ${hostname}. Hasilnya muncul di Device Detail (tab Devices).`,
    );

  const submitPower = (hostname: string, action: PowerAction, reason: string) =>
    act(
      () => sendJson("/api/control/power", "POST", { hostname, action, reason }, "Gagal mengirim perintah daya"),
      `Perintah ${action.toUpperCase()} ditambahkan ke antrean ${hostname}.`,
    );

  const submitRename = (hostname: string, display_name: string) =>
    act(
      () => sendJson("/api/devices/rename", "PUT", { hostname, display_name }, "Gagal mengubah nama device"),
      `Device diganti nama menjadi "${display_name}"`,
    );

  const sendEmergency = () =>
    act(
      () =>
        sendJson(
          "/api/control/broadcast",
          "POST",
          { hostname: "ALL", param: broadcast.trim(), reason: "Emergency Alert" },
          "Gagal mengirim pesan",
        ),
      "Siaran darurat dikirim ke semua stasiun aktif.",
    ).then(() => setBroadcast(""));

  const unreadFor = (hostname: string) =>
    (repliesByHost[hostname] || []).filter((r) => !r.read_at).length;

  const markAllRead = async (hostname: string) => {
    const unread = (repliesByHost[hostname] || []).filter((r) => !r.read_at);
    await Promise.all(unread.map((r) => postEmpty(`/api/replies/${r.id}/read`, "").catch(() => {})));
    refresh();
  };

  const list = pcs ?? [];
  const inUse = list.filter((p) => p.status === "ACTIVE").length;
  const locked = list.filter((p) => p.status === "LOCKED").length;
  // TODO(backend): /api/active only returns currently-online stations, so this
  // denominator is "signed-in" not "enrolled". Expose an enrolled total (and a
  // per-session access_type) for the true "X / 12" occupancy + type breakdown.
  const total = list.length;
  const pct = total ? Math.round((inUse / total) * 100) : 0;

  const repliesForTarget = repliesTarget ? repliesByHost[repliesTarget] || [] : [];
  const repliesTargetPc = list.find((p) => p.hostname === repliesTarget) || null;

  return (
    <VStack gap={5}>
      {/* Header */}
      <HStack gap={3} align="center" wrap="wrap">
        <Heading level={3}>Monitoring</Heading>
        <StatusPill status="inuse" label={`${inUse} Aktif`} pulse={inUse > 0} />
        <span style={{ marginLeft: "auto" }}>
          <Text type="supporting" color="secondary">
            {updatedAt ? `Diperbarui ${timeAgo(updatedAt)} · otomatis` : "Memuat…"}
          </Text>
        </span>
      </HStack>

      {/* Occupancy summary */}
      <Card padding={5}>
        <VStack gap={4}>
          <HStack gap={4} justify="between" align="end" wrap="wrap">
            <VStack gap={1}>
              <Text type="supporting" color="secondary">
                <span style={{ textTransform: "uppercase", letterSpacing: "0.06em", fontWeight: 700 }}>
                  Okupansi Lab
                </span>
              </Text>
              <span style={{ fontSize: 42, fontWeight: 800, letterSpacing: "-0.03em", lineHeight: 1, color: "var(--color-text-primary)" }}>
                {inUse}
                <span style={{ color: "var(--lx-text-muted)", fontSize: 26, fontWeight: 700 }}> / {total}</span>{" "}
                <span style={{ fontSize: 17, fontWeight: 600, color: "var(--color-text-secondary)" }}>
                  stasiun dipakai
                </span>
              </span>
            </VStack>
            <HStack gap={2} wrap="wrap">
              <StatusPill status="inuse" label={`${inUse} Aktif`} />
              {locked > 0 && <StatusPill status="locked" label={`${locked} Terkunci`} />}
            </HStack>
          </HStack>
          {/* Utilisation meter */}
          <VStack gap={1.5}>
            <div style={{ height: 10, borderRadius: 999, background: "var(--color-background-muted, var(--lx-skeleton-base))", overflow: "hidden", display: "flex" }}>
              <div style={{ width: `${total ? (inUse / total) * 100 : 0}%`, background: "var(--lx-status-inuse)" }} />
              <div style={{ width: `${total ? (locked / total) * 100 : 0}%`, background: "var(--lx-status-locked)" }} />
            </div>
            <HStack justify="between">
              <Text type="supporting" color="secondary">Utilisasi {pct}%</Text>
              <Text type="supporting" color="secondary">{total} stasiun online</Text>
            </HStack>
          </VStack>
        </VStack>
      </Card>

      {/* Station grid */}
      {pcs === null ? (
        <SkeletonGrid count={6} />
      ) : error ? (
        <ErrorState description={error} onRetry={refresh} />
      ) : list.length === 0 ? (
        <EmptyState
          title="Belum ada stasiun aktif"
          description="Aktivitas muncul begitu ada yang masuk. Logi sedang berjaga."
        />
      ) : (
        <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(240px, 1fr))", gap: 14 }}>
          {list.map((pc) => {
            const status = stationStatus(pc);
            const isActive = pc.status === "ACTIVE";
            const unread = unreadFor(pc.hostname);
            const accessType = resolveAccessType(null); // TODO(backend): expose session access_type

            const menuItems = [
              pc.anydesk_id
                ? {
                    label: "Remote (AnyDesk)",
                    icon: <ArrowTopRightOnSquareIcon style={{ width: 15, height: 15 }} />,
                    onClick: () => (window.location.href = `anydesk:${pc.anydesk_id}`),
                  }
                : { label: "Remote (AnyDesk tidak terdeteksi)", isDisabled: true },
              {
                label: "Ubah Nama",
                icon: <PencilSquareIcon style={{ width: 15, height: 15 }} />,
                onClick: () => setRenameTarget(pc),
              },
              ...(unread > 0
                ? [
                    {
                      label: `Lihat ${unread} balasan`,
                      icon: <ChatBubbleLeftRightIcon style={{ width: 15, height: 15 }} />,
                      onClick: () => setRepliesTarget(pc.hostname),
                    },
                  ]
                : []),
              { type: "divider" as const },
              {
                type: "section" as const,
                title: "Daya",
                items: [
                  {
                    label: "Log Off",
                    icon: <ArrowRightOnRectangleIcon style={{ width: 15, height: 15 }} />,
                    onClick: () => setPowerTarget({ pc, action: "logoff" }),
                  },
                  {
                    label: "Restart",
                    icon: <ArrowPathIcon style={{ width: 15, height: 15 }} />,
                    onClick: () => setPowerTarget({ pc, action: "restart" }),
                  },
                  {
                    label: "Shut Down",
                    icon: <PowerIcon style={{ width: 15, height: 15 }} />,
                    onClick: () => setPowerTarget({ pc, action: "shutdown" }),
                  },
                ],
              },
            ];

            return (
              <Card key={pc.hostname} padding={4} style={{ borderLeft: `3px solid var(--lx-status-${status})` }}>
                <VStack gap={3}>
                  <HStack gap={2} align="center" justify="between">
                    <HStack gap={2} align="center" style={{ minWidth: 0 }}>
                      <span
                        className={isActive ? "lx-pulse-dot" : undefined}
                        style={{ width: 9, height: 9, borderRadius: "50%", background: `var(--lx-status-${status})`, flexShrink: 0 }}
                      />
                      <Text type="label">{labelFor(pc)}</Text>
                    </HStack>
                    {unread > 0 && (
                      <button
                        onClick={() => setRepliesTarget(pc.hostname)}
                        title={`${unread} balasan belum dibaca`}
                        style={{ border: "none", background: "var(--lx-status-alert)", color: "#fff", fontSize: 11, fontWeight: 700, padding: "2px 8px", borderRadius: 999, cursor: "pointer" }}
                      >
                        {unread} baru
                      </button>
                    )}
                  </HStack>

                  <span>
                    <AccessTypeBadge type={accessType} size="sm" />
                  </span>

                  <span style={{ fontSize: 18, fontWeight: 800, letterSpacing: "-0.01em", color: `var(--lx-status-${status}-fg)` }}>
                    {isActive ? "Digunakan" : "Terkunci"}
                  </span>

                  <VStack gap={0.5}>
                    <Text type="supporting" color="secondary">
                      Pengguna: <strong>{pc.username || "—"}</strong>
                    </Text>
                    <Text type="supporting" color="secondary">
                      <span style={{ fontFamily: "ui-monospace, Menlo, Consolas, monospace" }}>{pc.hostname}</span>
                    </Text>
                    <Text type="supporting" color="secondary">Terlihat: {timeAgo(pc.last_seen)}</Text>
                  </VStack>

                  <HStack gap={1.5} align="center">
                    <span style={{ flex: 1 }}>
                      <Button
                        label="Pesan"
                        size="sm"
                        variant="secondary"
                        icon={<ChatBubbleLeftRightIcon style={{ width: 15, height: 15 }} />}
                        onClick={() => setMessageTarget(pc)}
                        style={{ width: "100%" }}
                      />
                    </span>
                    <span style={{ flex: 1 }}>
                      <Button
                        label="Kunci"
                        size="sm"
                        variant="secondary"
                        icon={<LockClosedIcon style={{ width: 15, height: 15 }} />}
                        onClick={() => lockWorkstation(pc)}
                        style={{ width: "100%" }}
                      />
                    </span>
                    <IconButton
                      label="Minta screenshot"
                      size="sm"
                      variant="secondary"
                      icon={<CameraIcon style={{ width: 15, height: 15 }} />}
                      onClick={() => setScreenshotTarget(pc)}
                    />
                    <MoreMenu label={`Aksi lain untuk ${labelFor(pc)}`} items={menuItems} />
                  </HStack>
                </VStack>
              </Card>
            );
          })}
        </div>
      )}

      {/* Emergency broadcast */}
      <Card padding={0} style={{ overflow: "hidden", border: "1px solid var(--lx-status-alert)" }}>
        <HStack gap={2} align="center" style={{ padding: "14px 18px", background: "var(--lx-status-alert-bg)", borderBottom: "1px solid var(--lx-status-alert)" }}>
          <span style={{ width: 30, height: 30, borderRadius: 8, background: "var(--lx-status-alert)", color: "#fff", display: "inline-flex", alignItems: "center", justifyContent: "center", flexShrink: 0 }}>
            <PowerIcon style={{ width: 17, height: 17 }} />
          </span>
          <VStack gap={0}>
            <Text type="label">
              <span style={{ color: "var(--lx-status-alert-fg)" }}>Siaran Darurat</span>
            </Text>
            <Text type="supporting">
              <span style={{ color: "var(--lx-status-alert-fg)" }}>
                Pesan ini tampil di layar SEMUA stasiun aktif secara langsung.
              </span>
            </Text>
          </VStack>
        </HStack>
        <VStack gap={3} style={{ padding: "16px 18px" }}>
          <TextArea
            label="Pesan siaran darurat"
            isLabelHidden
            placeholder="Contoh: Lab akan ditutup dalam 10 menit. Mohon simpan pekerjaan Anda."
            value={broadcast}
            onChange={setBroadcast}
            rows={3}
          />
          <HStack gap={3} justify="between" align="center" wrap="wrap">
            <Text type="supporting" color="secondary">
              {total > 0
                ? `Dikirim ke ${total} stasiun aktif. Untuk satu stasiun, gunakan tombol Pesan pada kartunya.`
                : "Tidak ada stasiun aktif untuk disiarkan."}
            </Text>
            <Button
              label="Kirim ke Semua"
              variant="destructive"
              isDisabled={total === 0 || broadcast.trim().length === 0}
              onClick={() => setBroadcastConfirmOpen(true)}
            />
          </HStack>
        </VStack>
      </Card>

      {/* Modals */}
      <SendMessageModal
        isOpen={messageTarget !== null}
        onClose={() => setMessageTarget(null)}
        deviceLabel={messageTarget ? labelFor(messageTarget) : ""}
        username={messageTarget?.username}
        onSubmit={(msg) => submitMessage(messageTarget!.hostname, msg)}
      />
      <ScreenshotRequestModal
        isOpen={screenshotTarget !== null}
        onClose={() => setScreenshotTarget(null)}
        deviceLabel={screenshotTarget ? labelFor(screenshotTarget) : ""}
        onSubmit={(reason) => submitScreenshot(screenshotTarget!.hostname, reason)}
      />
      <RenameModal
        isOpen={renameTarget !== null}
        onClose={() => setRenameTarget(null)}
        hostname={renameTarget?.hostname || ""}
        currentName={renameTarget ? labelFor(renameTarget) : ""}
        onSubmit={(name) => submitRename(renameTarget!.hostname, name)}
      />
      <PowerActionModal
        isOpen={powerTarget !== null}
        onClose={() => setPowerTarget(null)}
        hostname={powerTarget?.pc.hostname || ""}
        deviceName={powerTarget ? labelFor(powerTarget.pc) : ""}
        action={powerTarget?.action ?? null}
        onSubmit={(action, reason) => submitPower(powerTarget!.pc.hostname, action, reason)}
      />
      <EmergencyBroadcastModal
        isOpen={isBroadcastConfirmOpen}
        onClose={() => setBroadcastConfirmOpen(false)}
        activeCount={total}
        message={broadcast.trim()}
        onSubmit={sendEmergency}
      />
      <RepliesModal
        isOpen={repliesTarget !== null}
        onClose={() => setRepliesTarget(null)}
        deviceName={repliesTargetPc ? labelFor(repliesTargetPc) : repliesTarget || ""}
        username={repliesTargetPc?.username}
        replies={repliesForTarget}
        onMarkAllRead={() => repliesTarget && markAllRead(repliesTarget)}
        onReply={
          repliesTargetPc
            ? () => {
                const pc = repliesTargetPc;
                setRepliesTarget(null);
                setMessageTarget(pc);
              }
            : undefined
        }
      />
    </VStack>
  );
}
