// Monitoring -- the dashboard's home and hero. Design: docs/design_handoff_
// logix_v3/LogiX Monitoring v2.dc.html (D-03) + README section 1.
//
// The station grid IS the page: no KPI cards, no occupancy chart, just a
// one-line summary sentence above a flat 4-column grid. Card anatomy is fixed
// and reused at every breakpoint -- 8px dot, one mono identity line, one muted
// session line, and the ⋯ menu.
//
// Stations come from merging two endpoints: /api/devices is the enrolled
// registry (so "6 dari 12" has a real denominator and idle/offline stations
// appear at all), /api/active carries the live session on the online ones.
// The action plumbing (message / lock / screenshot / power) is reused as-is.
import { useCallback, useMemo, useState } from "react";

import { getJson, sendJson } from "../api";
import { ACCESS_LABEL, categoryLabel, resolveAccessType, type StationStatus } from "../tokens";
import type { ActiveWorkstation, Device } from "../types";
import { Card, EmptyState, ErrorState, Mono, PageHeader, SkeletonGrid, StatusDot } from "../ui/base";
import { Button, TextArea } from "../ui/controls";
import { useBreakpoint } from "../ui/hooks";
import { Modal, ModalActions, MoreMenu, useToast, type MenuItem } from "../ui/overlays";
import { durationSince, formatClock, formatSince, splitDeviceName, timeAgo, useTicker, usePolling } from "../util";

/** One enrolled station, after merging the registry with live heartbeats. */
interface Station {
  hostname: string;
  id: string;
  spec: string;
  status: StationStatus;
  live: ActiveWorkstation | null;
  lastSeen: string | null;
  anydeskId: string;
}

const stationStatus = (device: Device, live: ActiveWorkstation | null): StationStatus => {
  if (!live) return "offline";
  if (live.status === "LOCKED") return "locked";
  // Online but nobody signed in -- the station is free.
  return live.username ? "active" : "idle";
};

export default function Monitoring() {
  const toast = useToast();
  const isPhone = useBreakpoint() === "phone";
  const [devices, setDevices] = useState<Device[] | null>(null);
  const [active, setActive] = useState<ActiveWorkstation[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [updatedAt, setUpdatedAt] = useState<string | null>(null);

  // Modal targets (null = closed).
  const [messageTarget, setMessageTarget] = useState<Station | null>(null);
  const [lockTarget, setLockTarget] = useState<Station | null>(null);
  const [shotTarget, setShotTarget] = useState<Station | null>(null);
  const [powerTarget, setPowerTarget] = useState<Station | null>(null);
  const [isBroadcastOpen, setBroadcastOpen] = useState(false);

  const [messageText, setMessageText] = useState("");
  const [shotReason, setShotReason] = useState("");
  const [broadcast, setBroadcast] = useState("");
  const [isAcknowledged, setAcknowledged] = useState(false);

  // Durations on the cards are live, so re-render once a second.
  useTicker(1000);

  const refresh = useCallback(async () => {
    try {
      const [deviceList, activeList] = await Promise.all([
        getJson<Device[]>("/api/devices", "Gagal mengambil daftar perangkat"),
        getJson<ActiveWorkstation[]>("/api/active", "Gagal mengambil data stasiun aktif"),
      ]);
      setDevices(deviceList);
      setActive(activeList);
      setUpdatedAt(new Date().toISOString());
      setError(null);
    } catch (err) {
      setError((err as Error).message);
    }
  }, []);

  usePolling(refresh, 10000);

  const stations = useMemo<Station[]>(() => {
    if (!devices) return [];
    const liveByHost = new Map(active.map((a) => [a.hostname, a]));
    return devices
      .map((d) => {
        const live = liveByHost.get(d.hostname) ?? null;
        const { id, spec } = splitDeviceName(d.display_name || live?.device_name || d.hostname);
        return {
          hostname: d.hostname,
          id,
          // A display_name with no " - <spec>" half leaves spec empty; falling
          // back to the raw category KEY printed "WS-01 - lab_workstation" at
          // a lab admin.
          spec: spec || categoryLabel(d.category),
          status: stationStatus(d, live),
          live,
          lastSeen: live?.last_seen ?? d.last_seen,
          anydeskId: live?.anydesk_id || "",
        };
      })
      .sort((a, b) => a.id.localeCompare(b.id, "id", { numeric: true }));
  }, [devices, active]);

  const inUse = stations.filter((s) => s.status === "active").length;
  const total = stations.length;
  const onlineCount = stations.filter((s) => s.status !== "offline").length;

  const act = async (fn: Promise<unknown>, success: string, done?: () => void) => {
    try {
      await fn;
      toast(success);
      done?.();
      refresh();
    } catch (err) {
      toast((err as Error).message, "alert");
    }
  };

  const closeMessage = () => {
    setMessageTarget(null);
    setMessageText("");
  };
  const closeShot = () => {
    setShotTarget(null);
    setShotReason("");
  };
  const closeBroadcast = () => {
    setBroadcastOpen(false);
    setBroadcast("");
    setAcknowledged(false);
  };

  const menuFor = (s: Station): MenuItem[] => [
    { label: "Pesan", onClick: () => setMessageTarget(s) },
    { label: "Kunci", onClick: () => setLockTarget(s) },
    { label: "Cuplikan layar", onClick: () => setShotTarget(s) },
    { label: "Daya", onClick: () => setPowerTarget(s), isDanger: true, isDivided: true },
  ];

  /** The card's second line, per status. */
  const sessionLine = (s: Station) => {
    if (s.status === "offline") {
      return (
        <>
          Offline sejak <Mono>{formatSince(s.lastSeen)}</Mono>
        </>
      );
    }
    if (s.status === "locked") {
      return (
        <>
          Dikunci admin · <Mono>{formatClock(s.live?.status_since ?? s.lastSeen)}</Mono>
        </>
      );
    }
    if (s.status === "idle") {
      return (
        <>
          Bebas · idle <Mono>{durationSince(s.live?.status_since ?? s.lastSeen)}</Mono>
        </>
      );
    }
    const access = ACCESS_LABEL[resolveAccessType(s.live?.access_type)];
    // Only the NAME may be clipped. Ellipsising the whole line truncates from
    // the right, which eats the duration -- the one number an admin is scanning
    // this board for -- leaving "Nama Yang Sangat Panjang - Fisik - 5...".
    // A long name is the expendable part; how long the machine has been in use
    // is not.
    return (
      <span style={{ display: "flex", minWidth: 0, alignItems: "baseline" }}>
        <span style={{ overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
          {s.live?.username || "-"}
        </span>
        <span style={{ flexShrink: 0, whiteSpace: "nowrap" }}>
          {" "}· {access} ·{" "}
          <Mono>{s.live?.session_started_at ? durationSince(s.live.session_started_at) : "-"}</Mono>
        </span>
      </span>
    );
  };

  const StationCard = ({ s }: { s: Station }) => {
    const isOffline = s.status === "offline";
    const identity = s.spec ? `${s.id} · ${s.spec}` : s.id;
    return (
      <Card
        variant={isOffline ? "dashed" : "solid"}
        isInteractive={!isOffline}
        padding={isPhone ? "13px 14px" : "16px 18px"}
      >
        <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
          <StatusDot status={s.status} label={s.status} />
          <span
            className="lx-mono"
            style={{
              fontSize: 13.5,
              fontWeight: 600,
              whiteSpace: "nowrap",
              overflow: "hidden",
              textOverflow: "ellipsis",
              color: isOffline ? "var(--lx-status-offline)" : undefined,
            }}
          >
            {isPhone ? s.id : identity}
          </span>
          {/* Offline cards carry no actions at all -- fully muted, per design. */}
          {!isOffline && <MoreMenu label={`Aksi untuk ${s.id}`} items={menuFor(s)} />}
        </div>
        <div
          style={{
            fontSize: 13,
            color: isOffline ? "var(--lx-status-offline)" : "var(--lx-muted)",
            marginTop: 9,
            paddingLeft: 18,
            whiteSpace: "nowrap",
            overflow: "hidden",
            textOverflow: "ellipsis",
            // minWidth:0 lets the flex child above actually shrink; without it a
            // flex item refuses to go below its content width and the ellipsis
            // never engages.
            minWidth: 0,
          }}
        >
          {sessionLine(s)}
        </div>
      </Card>
    );
  };

  return (
    <>
      <PageHeader
        title="Monitoring"
        summary={
          devices === null ? (
            "Memuat..."
          ) : (
            <>
              <Mono style={{ color: "var(--lx-text)" }}>{inUse}</Mono> dari <Mono>{total}</Mono> stasiun
              dipakai · diperbarui {timeAgo(updatedAt).replace(" lalu", " lalu")}
            </>
          )
        }
        action={
          <Button
            label={isPhone ? "Broadcast" : "Emergency broadcast"}
            variant="danger-outline"
            size="sm"
            onClick={() => setBroadcastOpen(true)}
          />
        }
      />

      {devices === null ? (
        <SkeletonGrid count={8} columns={isPhone ? 1 : 4} />
      ) : error ? (
        <ErrorState description={error} onRetry={refresh} />
      ) : stations.length === 0 ? (
        <EmptyState
          title="Belum ada perangkat terdaftar"
          description="Daftarkan workstation lewat tab Perangkat untuk mulai memantau."
        />
      ) : (
        <div
          style={{
            display: "grid",
            gap: isPhone ? 8 : 14,
            gridTemplateColumns: isPhone
              ? "1fr"
              : "repeat(auto-fill, minmax(clamp(220px, 24%, 320px), 1fr))",
          }}
        >
          {stations.map((s) => (
            <StationCard key={s.hostname} s={s} />
          ))}
        </div>
      )}

      {/* ---- Pesan ---- */}
      <Modal
        isOpen={messageTarget !== null}
        onClose={closeMessage}
        title={`Kirim pesan ke ${messageTarget?.id ?? ""}`}
        description={
          messageTarget?.live?.username
            ? `Pesan muncul di widget timer ${messageTarget.live.username}. Balasannya kembali ke sini.`
            : "Pesan muncul di widget timer pengguna."
        }
        footer={
          <ModalActions
            onCancel={closeMessage}
            confirmLabel="Kirim pesan"
            isConfirmDisabled={messageText.trim().length === 0}
            onConfirm={() =>
              act(
                sendJson(
                  "/api/control/broadcast",
                  "POST",
                  { hostname: messageTarget!.hostname, param: messageText.trim(), reason: "Direction Message" },
                  "Gagal mengirim pesan",
                ),
                `Pesan terkirim ke ${messageTarget!.id}`,
                closeMessage,
              )
            }
          />
        }
      >
        <TextArea
          label="Pesan"
          value={messageText}
          onChange={setMessageText}
          placeholder="Contoh: Lab tutup 17:00. Simpan pekerjaan sebelum pulang ya."
          maxLength={280}
          rows={3}
        />
      </Modal>

      {/* ---- Kunci ---- */}
      <Modal
        isOpen={lockTarget !== null}
        onClose={() => setLockTarget(null)}
        title={`Kunci ${lockTarget?.id ?? ""}?`}
        description={`Sesi ${lockTarget?.live?.username || "pengguna"} akan dijeda. Layar terkunci sampai admin membuka kembali.`}
        footer={
          <ModalActions
            onCancel={() => setLockTarget(null)}
            confirmLabel="Kunci"
            onConfirm={() =>
              act(
                sendJson(
                  "/api/control/lock",
                  "POST",
                  { hostname: lockTarget!.hostname },
                  "Gagal mengirim perintah kunci",
                ),
                `Perintah kunci dikirim ke ${lockTarget!.id}`,
                () => setLockTarget(null),
              )
            }
          />
        }
      />

      {/* ---- Cuplikan layar: privacy notice is visible, never behind a link ---- */}
      <Modal
        isOpen={shotTarget !== null}
        onClose={closeShot}
        title={`Ambil cuplikan layar ${shotTarget?.id ?? ""}?`}
        description={`Satu cuplikan diambil dari sesi ${shotTarget?.live?.username || "pengguna"} dan disimpan ke log audit.`}
        footer={
          <ModalActions
            onCancel={closeShot}
            confirmLabel="Ambil cuplikan"
            onConfirm={() =>
              act(
                sendJson(
                  "/api/control/screenshot",
                  "POST",
                  { hostname: shotTarget!.hostname, reason: shotReason.trim() || "Pemantauan rutin" },
                  "Gagal meminta cuplikan",
                ),
                `Permintaan cuplikan dikirim ke ${shotTarget!.id}. Hasilnya muncul di Perangkat.`,
                closeShot,
              )
            }
          />
        }
      >
        <div style={{ display: "grid", gap: 14 }}>
          <TextArea
            label="Alasan"
            value={shotReason}
            onChange={setShotReason}
            placeholder="Contoh: Verifikasi keluhan lag"
            rows={2}
            maxLength={140}
          />
          <div
            style={{
              borderLeft: "3px solid var(--lx-accent)",
              padding: "8px 14px",
              fontSize: 12.5,
              lineHeight: 1.5,
              background: "var(--lx-sunken)",
              borderRadius: "0 10px 10px 0",
            }}
          >
            Catatan privasi: pengguna <strong>selalu diberi tahu</strong> saat cuplikan diambil. Tidak ada
            pengambilan diam-diam.
          </div>
        </div>
      </Modal>

      {/* ---- Daya ---- */}
      <Modal
        isOpen={powerTarget !== null}
        onClose={() => setPowerTarget(null)}
        title={`Daya ${powerTarget?.id ?? ""}`}
        description="Pengguna menerima peringatan 30 detik sebelum perangkat dimatikan atau dimulai ulang."
        accentEdge="alert"
        footer={<Button label="Batal" variant="secondary" size="sm" onClick={() => setPowerTarget(null)} />}
      >
        <div style={{ display: "grid", gap: 8 }}>
          {(
            [
              ["logoff", "Log off pengguna"],
              ["restart", "Mulai ulang"],
              ["shutdown", "Matikan"],
            ] as const
          ).map(([action, label]) => (
            <Button
              key={action}
              label={label}
              variant="secondary"
              isFullWidth
              onClick={() =>
                act(
                  sendJson(
                    "/api/control/power",
                    "POST",
                    { hostname: powerTarget!.hostname, action, reason: `Aksi daya dari Monitoring: ${action}` },
                    "Gagal mengirim perintah daya",
                  ),
                  `Perintah ${label.toLowerCase()} dikirim ke ${powerTarget!.id}`,
                  () => setPowerTarget(null),
                )
              }
            />
          ))}
        </div>
      </Modal>

      {/* ---- Emergency broadcast ---- */}
      <Modal
        isOpen={isBroadcastOpen}
        onClose={closeBroadcast}
        title={`Emergency broadcast ke ${onlineCount} stasiun`}
        description="Pesan tampil sebagai overlay penuh di semua stasiun online — termasuk yang sedang fullscreen."
        accentEdge="alert"
        footer={
          <ModalActions
            onCancel={closeBroadcast}
            confirmLabel="Kirim broadcast"
            variant="danger"
            isConfirmDisabled={!isAcknowledged || broadcast.trim().length === 0 || onlineCount === 0}
            onConfirm={() =>
              act(
                sendJson(
                  "/api/control/broadcast",
                  "POST",
                  { hostname: "ALL", param: broadcast.trim(), reason: "Emergency Alert" },
                  "Gagal mengirim broadcast",
                ),
                "Siaran darurat dikirim ke semua stasiun online.",
                closeBroadcast,
              )
            }
          />
        }
      >
        <div style={{ display: "grid", gap: 14 }}>
          <TextArea
            label="Pesan broadcast"
            value={broadcast}
            onChange={setBroadcast}
            placeholder="Contoh: Evakuasi: alarm kebakaran gedung C. Simpan pekerjaan sekarang."
            rows={3}
            maxLength={280}
          />
          <label style={{ display: "flex", alignItems: "center", gap: 9, fontSize: 13, cursor: "pointer" }}>
            <input
              type="checkbox"
              checked={isAcknowledged}
              onChange={(e) => setAcknowledged(e.target.checked)}
              style={{ width: 16, height: 16, accentColor: "var(--lx-status-alert)", flexShrink: 0 }}
            />
            Saya paham ini menginterupsi semua sesi aktif
          </label>
        </div>
      </Modal>
    </>
  );
}
