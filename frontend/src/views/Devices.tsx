// Perangkat -- the device registry. Design: docs/design_handoff_logix_v3/
// LogiX Devices & Settings v2.dc.html (D-05) + README section 3.
//
// A flat table plus a 330px detail drawer. The 7-day sync sparkline column was
// explicitly cut: sync status is now just a dot plus a "X ago" timestamp. The
// one-time, 15-minute invite-code flow keeps its behaviour exactly and is only
// restyled.
import { useCallback, useEffect, useMemo, useState, type ReactNode } from "react";

import { del, getJson, sendJson } from "../api";
import { DEVICE_CATEGORIES, categoryLabel, type StationStatus } from "../tokens";
import type { Device, DeviceDetail, DeviceScreenshot, SyncStatus } from "../types";
import { Mono, PageHeader, SectionLabel, Skeleton, StatusDot } from "../ui/base";
import { Button, PillSelect, SearchChip } from "../ui/controls";
import { useBreakpoint } from "../ui/hooks";
import { Drawer, Modal, ModalActions, useToast } from "../ui/overlays";
import { Table, type Column } from "../ui/table";
import { formatLogTime, splitDeviceName, timeAgo, useTicker } from "../util";

const SYNC_STATUS: Record<SyncStatus, StationStatus> = {
  online: "active",
  stale: "locked",
  offline: "offline",
  never_seen: "idle",
};

/**
 * Enrolment categories. These are the server's CATEGORY_PROFILES keys, which
 * set the heartbeat cadence and popup frequency -- NOT the lab's GPU/CPU/Umum
 * hardware taxonomy from Settings (that lives in devices.device_types and is
 * what the idle policy keys on). The two are easy to confuse; sending a
 * hardware category here is rejected with "Unknown category".
 */
// Moved to tokens.ts so Monitoring shares it -- see DEVICE_CATEGORIES there.
const CATEGORIES = DEVICE_CATEGORIES;

/** Countdown to the invite's expiry, in the mm:ss the design shows. */
const expiryLabel = (expiresAt: string | null | undefined): string => {
  if (!expiresAt) return "-";
  const left = Math.max(0, (new Date(expiresAt).getTime() - Date.now()) / 1000);
  if (left <= 0) return "kedaluwarsa";
  return `${String(Math.floor(left / 60)).padStart(2, "0")}:${String(Math.floor(left % 60)).padStart(2, "0")}`;
};

export default function Devices() {
  const toast = useToast();
  const isDesktop = useBreakpoint() === "desktop";
  const [devices, setDevices] = useState<Device[] | null>(null);
  const [selected, setSelected] = useState<string | null>(null);
  const [detail, setDetail] = useState<DeviceDetail | null>(null);
  const [search, setSearch] = useState("");

  const [isInviteOpen, setInviteOpen] = useState(false);
  const [inviteCategory, setInviteCategory] = useState("lab_workstation");
  const [invite, setInvite] = useState<{ invite_code: string; expires_at: string } | null>(null);
  const [revokeTarget, setRevokeTarget] = useState<Device | null>(null);
  // Last screenshot for the selected device. `undefined` = not loaded yet,
  // `null` = the server has none (404), which is a normal state, not an error.
  const [shot, setShot] = useState<DeviceScreenshot | null | undefined>(undefined);
  const [isRequestingShot, setRequestingShot] = useState(false);
  const [isShotOpen, setShotOpen] = useState(false);

  useTicker(1000); // keeps the invite countdown and the "X ago" column live

  const refresh = useCallback(async () => {
    try {
      setDevices(await getJson<Device[]>("/api/devices", "Gagal memuat daftar perangkat"));
    } catch (err) {
      toast((err as Error).message, "alert");
    }
  }, [toast]);

  useEffect(() => {
    refresh();
  }, [refresh]);

  useEffect(() => {
    if (!selected) {
      setDetail(null);
      return;
    }
    let isCurrent = true;
    getJson<DeviceDetail>(`/api/devices/${selected}`, "Gagal memuat detail perangkat")
      .then((d) => {
        if (isCurrent) setDetail(d);
      })
      .catch(() => {
        /* the row still renders from the list payload */
      });
    return () => {
      isCurrent = false;
    };
  }, [selected]);

  // The capture the agent last uploaded. GET /api/devices/{id}/screenshot has
  // existed since Logix Control shipped, but nothing in this dashboard ever
  // called it -- so Monitoring's "Hasilnya muncul di Perangkat" toast pointed
  // at a screen that did not show screenshots. This is that screen.
  const loadShot = useCallback(async (deviceId: string) => {
    try {
      setShot(await getJson<DeviceScreenshot>(`/api/devices/${deviceId}/screenshot`, ""));
    } catch {
      setShot(null); // 404 = nothing captured yet, which the UI states plainly
    }
  }, []);

  useEffect(() => {
    setShot(undefined);
    setShotOpen(false);
    if (selected) loadShot(selected);
  }, [selected, loadShot]);

  const rows = useMemo(() => {
    const list = devices ?? [];
    const needle = search.trim().toLowerCase();
    if (!needle) return list;
    return list.filter((d) =>
      `${d.hostname} ${d.display_name ?? ""} ${d.category}`.toLowerCase().includes(needle),
    );
  }, [devices, search]);

  const onlineCount = (devices ?? []).filter((d) => d.currently_online).length;

  const createInvite = async () => {
    try {
      const res = await sendJson(
        "/api/enroll/invite",
        "POST",
        { category: inviteCategory },
        "Gagal membuat kode undangan",
      );
      setInvite(await res.json());
    } catch (err) {
      toast((err as Error).message, "alert");
    }
  };

  // DELETE, not the old POST .../revoke. Revoke only nulled the API key: the
  // row stayed in the registry, kept its last_seen, kept status 'active', and
  // -- if the fleet still had a shared ingest key -- came straight back on the
  // next heartbeat. The button said "Hapus" and did not delete.
  const removeDevice = async (device: Device) => {
    try {
      await del(`/api/devices/${device.device_id}`, "Gagal menghapus perangkat");
      toast("Perangkat dihapus dari registri.");
      setRevokeTarget(null);
      setSelected(null);
      refresh();
    } catch (err) {
      toast((err as Error).message, "alert");
    }
  };

  const requestShot = async (device: Device) => {
    setRequestingShot(true);
    try {
      await sendJson(
        "/api/control/screenshot",
        "POST",
        { hostname: device.hostname, reason: "Pemeriksaan dari tab Perangkat" },
        "Gagal meminta cuplikan",
      );
      toast("Permintaan dikirim. Cuplikan muncul di sini setelah client merespons.");
    } catch (err) {
      toast((err as Error).message, "alert");
    } finally {
      setRequestingShot(false);
    }
  };

  const columns: Column<Device>[] = [
    {
      key: "id",
      header: "ID",
      width: "120px",
      phone: "primary",
      render: (d) => (
        <Mono style={{ fontSize: 12.5, fontWeight: 600 }}>
          {splitDeviceName(d.display_name || d.hostname).id}
        </Mono>
      ),
    },
    {
      key: "spec",
      header: "Spesifikasi",
      width: "1fr",
      phone: "secondary",
      render: (d) => (
        <span style={{ color: "var(--lx-muted)" }}>
          {splitDeviceName(d.display_name || d.hostname).spec || d.hostname}
        </span>
      ),
    },
    { key: "kategori", header: "Kategori", width: "100px", phone: "secondary",
      // Humanised, not the raw CATEGORY_PROFILES key -- "lab_workstation"
      // is an API detail, not something to show a lab admin.
      render: (d) => categoryLabel(d.category) },
    {
      key: "sync",
      header: "Sinkronisasi",
      width: "170px",
      phone: "secondary",
      // Dot + "X ago" only -- the 7-day sparkline that lived here was cut.
      render: (d) => (
        <span style={{ display: "inline-flex", alignItems: "center", gap: 7 }}>
          <StatusDot status={SYNC_STATUS[d.sync_status] ?? "idle"} label={d.sync_status} />
          <Mono style={{ fontSize: 12 }}>{timeAgo(d.last_seen)}</Mono>
        </span>
      ),
    },
    {
      key: "versi",
      header: "Versi client",
      width: "130px",
      render: (d) => <Mono style={{ fontSize: 12 }}>{String(d.client_version ?? "-")}</Mono>,
    },
  ];

  const selectedDevice = (devices ?? []).find((d) => d.device_id === selected) ?? null;
  const selectedName = selectedDevice
    ? splitDeviceName(selectedDevice.display_name || selectedDevice.hostname)
    : null;

  const detailRow = (label: string, value: ReactNode) => (
    <div style={{ display: "flex", fontSize: 12.5 }}>
      <span style={{ color: "var(--lx-muted)", width: 110, flexShrink: 0 }}>{label}</span>
      <span style={{ minWidth: 0 }}>{value}</span>
    </div>
  );

  const inviteBox = (fontSize: number) => (
    <div
      style={{
        border: "1px dashed var(--lx-border-dashed)",
        borderRadius: "var(--lx-radius-menu)",
        padding: 14,
        textAlign: "center",
        marginBottom: 10,
      }}
    >
      <div className="lx-mono" style={{ fontSize, letterSpacing: ".18em" }}>
        {invite?.invite_code}
      </div>
      <div className="lx-mono" style={{ fontSize: 11, color: "var(--lx-status-locked)", marginTop: 4 }}>
        kedaluwarsa dalam {expiryLabel(invite?.expires_at)}
      </div>
    </div>
  );

  return (
    <>
      <PageHeader
        title="Perangkat"
        summary={
          devices === null ? (
            "Memuat..."
          ) : (
            <>
              <Mono style={{ color: "var(--lx-text)" }}>{devices.length}</Mono> terdaftar ·{" "}
              <Mono style={{ color: "var(--lx-text)" }}>{onlineCount}</Mono> online
            </>
          )
        }
        action={
          <Button
            label="Tambah perangkat"
            variant="primary"
            size="sm"
            onClick={() => {
              setInvite(null);
              setInviteOpen(true);
            }}
          />
        }
      />

      <div style={{ marginBottom: 16 }}>
        <SearchChip value={search} onChange={setSearch} placeholder="Cari ID / spesifikasi" width={280} />
      </div>

      <div style={{ display: "flex", gap: 16, alignItems: "flex-start" }}>
        <div style={{ flex: 1, minWidth: 0 }}>
          <Table
            columns={columns}
            rows={rows}
            getRowKey={(d) => d.device_id}
            selectedKey={selected}
            onRowClick={(d) => setSelected(d.device_id === selected ? null : d.device_id)}
            emptyLabel="Belum ada perangkat terdaftar."
          />
        </div>

        {isDesktop && selectedDevice && selectedName && (
          <Drawer
            isOpen
            onClose={() => setSelected(null)}
            title={
              <>
                <StatusDot status={SYNC_STATUS[selectedDevice.sync_status] ?? "idle"} />
                <Mono style={{ fontSize: 16, fontWeight: 600 }}>{selectedName.id}</Mono>
              </>
            }
            subtitle={selectedName.spec || selectedDevice.hostname}
          >
            <div style={{ display: "grid", rowGap: 10, marginBottom: 24 }}>
              {detailRow("Sinkronisasi", <Mono>{timeAgo(selectedDevice.last_seen)}</Mono>)}
              {detailRow("Versi client", <Mono>{String(selectedDevice.client_version ?? "-")}</Mono>)}
              {detailRow("Kategori", categoryLabel(selectedDevice.category))}
              {detailRow("Kebijakan", detail?.policy?.description ?? "-")}
            </div>

            <div style={{ marginBottom: 10 }}>
              <SectionLabel>Cuplikan layar terakhir</SectionLabel>
            </div>
            {shot === undefined ? (
              <Skeleton height={124} />
            ) : shot === null ? (
              <div
                style={{
                  border: "1px dashed var(--lx-border-dashed)",
                  borderRadius: "var(--lx-radius-menu)",
                  padding: "18px 14px",
                  textAlign: "center",
                  fontSize: 12,
                  lineHeight: 1.5,
                  color: "var(--lx-muted)",
                }}
              >
                Belum ada cuplikan untuk perangkat ini.
              </div>
            ) : (
              <button
                type="button"
                onClick={() => setShotOpen(true)}
                title="Perbesar cuplikan"
                style={{
                  display: "block",
                  width: "100%",
                  padding: 0,
                  border: "1px solid var(--lx-border)",
                  borderRadius: "var(--lx-radius-menu)",
                  overflow: "hidden",
                  background: "var(--lx-sunken)",
                  cursor: "zoom-in",
                }}
              >
                <img
                  src={`data:${shot.content_type || "image/jpeg"};base64,${shot.image_base64}`}
                  alt={`Cuplikan layar ${selectedName.id}`}
                  style={{ display: "block", width: "100%", height: "auto" }}
                />
              </button>
            )}
            <p style={{ fontSize: 12, lineHeight: 1.5, color: "var(--lx-muted)", margin: "8px 0 10px" }}>
              {shot
                ? `Diambil ${formatLogTime(shot.captured_at)}. Pengguna selalu diberi tahu saat cuplikan diambil.`
                : "Pengguna selalu diberi tahu saat cuplikan diambil. Tidak ada pengambilan diam-diam."}
            </p>
            <div style={{ display: "flex", gap: 8, marginBottom: 24 }}>
              <Button
                label={isRequestingShot ? "Meminta..." : "Minta cuplikan"}
                variant="secondary"
                size="sm"
                style={{ flex: 1 }}
                disabled={isRequestingShot || !selectedDevice.currently_online}
                onClick={() => requestShot(selectedDevice)}
              />
              <Button
                label="Muat ulang"
                variant="ghost"
                size="sm"
                style={{ flex: 1 }}
                onClick={() => loadShot(selectedDevice.device_id)}
              />
            </div>

            <div style={{ marginBottom: 10 }}>
              <SectionLabel>Invite code — sekali pakai</SectionLabel>
            </div>
            {invite && inviteBox(20)}
            <p style={{ fontSize: 12, lineHeight: 1.5, color: "var(--lx-muted)", margin: "0 0 20px" }}>
              {invite
                ? "Masukkan kode ini di client Windows untuk mengikat ulang perangkat. Berlaku 15 menit, satu kali pakai."
                : "Buat kode sekali-pakai untuk mengikat ulang perangkat ini ke server."}
            </p>
            <div style={{ display: "flex", gap: 8 }}>
              <Button
                label="Buat kode baru"
                variant="secondary"
                size="sm"
                style={{ flex: 1 }}
                onClick={createInvite}
              />
              <Button
                label="Hapus"
                variant="secondary"
                size="sm"
                style={{ flex: 1, color: "var(--lx-status-alert)" }}
                onClick={() => setRevokeTarget(selectedDevice)}
              />
            </div>
          </Drawer>
        )}
      </div>

      {/* Enrolment: pick a category, get a one-time code. */}
      <Modal
        isOpen={isInviteOpen}
        onClose={() => setInviteOpen(false)}
        title="Tambah perangkat"
        description="Pilih kategori, lalu masukkan kode yang muncul di client Windows perangkat baru."
        footer={
          invite ? (
            <Button label="Selesai" variant="primary" size="sm" onClick={() => setInviteOpen(false)} />
          ) : (
            <ModalActions
              onCancel={() => setInviteOpen(false)}
              confirmLabel="Buat kode"
              onConfirm={createInvite}
            />
          )
        }
      >
        {invite ? (
          inviteBox(22)
        ) : (
          <PillSelect
            label="Kategori"
            value={inviteCategory}
            options={CATEGORIES}
            onChange={setInviteCategory}
            width={180}
          />
        )}
      </Modal>

      <Modal
        isOpen={revokeTarget !== null}
        onClose={() => setRevokeTarget(null)}
        title={`Hapus ${revokeTarget ? splitDeviceName(revokeTarget.display_name || revokeTarget.hostname).id : ""}?`}
        description="Perangkat hilang dari daftar, kehilangan kredensialnya, dan tidak bisa mendaftar ulang sendiri lewat heartbeat — hanya lewat kode undangan baru. Riwayat sesinya tetap tersimpan."
        accentEdge="alert"
        footer={
          <ModalActions
            onCancel={() => setRevokeTarget(null)}
            confirmLabel="Hapus perangkat"
            variant="danger"
            onConfirm={() => removeDevice(revokeTarget!)}
          />
        }
      />

      {/* Full-size capture. A 300px drawer thumbnail is enough to see THAT a
          screenshot exists, never enough to read what is on the screen. */}
      <Modal
        isOpen={isShotOpen && shot !== null && shot !== undefined}
        onClose={() => setShotOpen(false)}
        title={`Cuplikan layar ${selectedName?.id ?? ""}`}
        description={shot ? `Diambil ${formatLogTime(shot.captured_at)}` : undefined}
        width={860}
        footer={<Button label="Tutup" variant="secondary" size="sm" onClick={() => setShotOpen(false)} />}
      >
        {shot && (
          <img
            src={`data:${shot.content_type || "image/jpeg"};base64,${shot.image_base64}`}
            alt={`Cuplikan layar ${selectedName?.id ?? shot.hostname}`}
            style={{
              display: "block",
              width: "100%",
              height: "auto",
              borderRadius: "var(--lx-radius-menu)",
              border: "1px solid var(--lx-border)",
            }}
          />
        )}
      </Modal>
    </>
  );
}
