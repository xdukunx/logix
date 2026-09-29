// Perangkat -- the device registry. v4 "Denyut".
//
// A bento row answers what an admin opens this page for -- is every machine
// still reporting in, is every machine on the current agent build, which ones
// need a look -- then the registry, with a detail panel per device (the same
// SidePanel Monitoring and Riwayat use). The one-time, 15-minute invite-code
// flow and the delete confirmation behave as before; only their surfaces
// changed.
//
// Everything comes from /api/devices, polled so the fleet counts stay true,
// plus /api/devices/{id} and the last screenshot for the device that is open.
// The rules live in DevicesModel, the bento cards in DevicesBento, the panel
// in DevicesDetail.
import { useCallback, useEffect, useMemo, useRef, useState, type CSSProperties } from "react";

import { del, getJson, sendJson } from "../api";
import { DEVICE_CATEGORIES, categoryLabel } from "../tokens";
import type { Device, DeviceDetail, DeviceScreenshot } from "../types";
import { EmptyState, ErrorState, Mono, PageHeader, Skeleton, StatusDot } from "../ui/base";
import { Button, PillSelect, SearchChip } from "../ui/controls";
import { useBreakpoint, useReducedMotion } from "../ui/hooks";
import { Modal, ModalActions, SidePanel, useToast } from "../ui/overlays";
import { Table, type Column } from "../ui/table";
import { formatLogTime, timeAgo, usePolling, useTicker } from "../util";
import { ARROW, AttentionCard, FleetCard, Tag, VersionCard } from "./DevicesBento";
import { DetailBody, DetailHeader, InviteTicket, shotSrc, type Invite } from "./DevicesDetail";
import {
  SORT_OPTIONS,
  SYNC_LABEL,
  SYNC_STATUS,
  agentVersion,
  attentionList,
  filterLabel,
  isOutdated,
  nameOf,
  registryRows,
  sameFilter,
  summariseVersions,
  type Filter,
  type SortKey,
} from "./DevicesModel";

const REGISTRY_POLL_MS = 15_000;
// After "Minta cuplikan" the capture arrives on the agent's next heartbeat,
// so the drawer keeps asking for a while instead of leaving the admin to
// guess when to press "Muat ulang".
const SHOT_POLL_MS = 4_000;
const SHOT_WAIT_MS = 90_000;

/**
 * Enrolment categories are the server's CATEGORY_PROFILES keys, which set the
 * heartbeat cadence and popup frequency -- NOT the lab's GPU/CPU/Umum hardware
 * taxonomy from Settings, which the server rejects here as "Unknown category".
 */
const ENROL_CATEGORIES = new Set(DEVICE_CATEGORIES.map((c) => c.value));

/**
 * The round ↗ closing a row: ink while its device is open. Otherwise it is only
 * a ring, with no inline fill or colour, which would beat lx-round's ink hover.
 */
const roundArrow = (isOpen: boolean): CSSProperties => ({
  width: 30,
  height: 30,
  borderRadius: 999,
  display: "inline-flex",
  alignItems: "center",
  justifyContent: "center",
  verticalAlign: "middle",
  ...(isOpen
    ? { background: "var(--lx-ink)", color: "var(--lx-on-ink)" }
    : { boxShadow: "inset 0 0 0 1px var(--lx-border)" }),
});

export default function Devices() {
  const toast = useToast();
  const breakpoint = useBreakpoint();
  const isDesktop = breakpoint === "desktop";
  const isPhone = breakpoint === "phone";
  const isReducedMotion = useReducedMotion();
  const [devices, setDevices] = useState<Device[] | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [updatedAt, setUpdatedAt] = useState<string | null>(null);
  const [selected, setSelected] = useState<string | null>(null);
  const [detail, setDetail] = useState<DeviceDetail | null>(null);
  const [search, setSearch] = useState("");
  const [filter, setFilter] = useState<Filter | null>(null);
  const [sort, setSort] = useState<SortKey>("status");

  const [isInviteOpen, setInviteOpen] = useState(false);
  const [inviteCategory, setInviteCategory] = useState("lab_workstation");
  const [invite, setInvite] = useState<Invite | null>(null);
  const [deleteTarget, setDeleteTarget] = useState<Device | null>(null);
  // Last screenshot for the selected device. `undefined` = not loaded yet,
  // `null` = the server has none (404), which is a normal state, not an error.
  const [shot, setShot] = useState<DeviceScreenshot | null | undefined>(undefined);
  const [isRequestingShot, setRequestingShot] = useState(false);
  const [isShotOpen, setShotOpen] = useState(false);
  const [shotWait, setShotWait] = useState<{ deviceId: string; after: string | null; until: number } | null>(null);

  const selectedRef = useRef(selected);
  selectedRef.current = selected;
  const registryRef = useRef<HTMLDivElement>(null);
  const hasLoadedRef = useRef(false);

  useTicker(1000); // keeps the invite countdown and every "X ago" live

  const load = useCallback(
    async (isBackground: boolean) => {
      try {
        setDevices(await getJson<Device[]>("/api/devices", "Gagal memuat daftar perangkat"));
        setLoadError(null);
        setUpdatedAt(new Date().toISOString());
      } catch (err) {
        setLoadError((err as Error).message);
        // A poll failing every 15s must not stack a toast each time; the
        // header already says the data is stale.
        if (!isBackground) toast((err as Error).message, "alert");
      }
    },
    [toast],
  );
  const refresh = useCallback(() => load(false), [load]);

  usePolling(() => {
    load(hasLoadedRef.current);
    hasLoadedRef.current = true;
  }, REGISTRY_POLL_MS);

  // Responses for a device the admin has already moved away from are dropped:
  // switching rows quickly used to paint the previous device's screenshot
  // into the next one's drawer.
  const loadDetail = useCallback(async (deviceId: string) => {
    try {
      const d = await getJson<DeviceDetail>(`/api/devices/${deviceId}`, "Gagal memuat detail perangkat");
      if (selectedRef.current === deviceId) setDetail(d);
    } catch {
      /* the drawer still renders from the list payload */
    }
  }, []);

  // GET /api/devices/{id}/screenshot: the capture the agent last uploaded.
  // Monitoring's "Hasilnya muncul di Perangkat" toast points here.
  const loadShot = useCallback(async (deviceId: string) => {
    try {
      const s = await getJson<DeviceScreenshot>(`/api/devices/${deviceId}/screenshot`, "");
      if (selectedRef.current === deviceId) setShot(s);
    } catch {
      if (selectedRef.current === deviceId) setShot(null); // 404 = nothing captured yet
    }
  }, []);

  useEffect(() => {
    setDetail(null);
    setShot(undefined);
    setShotOpen(false);
    setShotWait(null);
    if (!selected) return;
    loadDetail(selected);
    loadShot(selected);
  }, [selected, loadDetail, loadShot]);

  useEffect(() => {
    if (!shotWait) return;
    const id = window.setInterval(() => {
      if (Date.now() < shotWait.until) {
        loadShot(shotWait.deviceId);
        return;
      }
      setShotWait(null);
      toast("Cuplikan belum masuk. Coba muat ulang sebentar lagi.", "locked");
    }, SHOT_POLL_MS);
    return () => window.clearInterval(id);
  }, [shotWait, loadShot, toast]);

  useEffect(() => {
    if (!shotWait || shotWait.deviceId !== selected || !shot || shot.captured_at === shotWait.after) return;
    setShotWait(null);
    toast("Cuplikan baru diterima.");
    loadDetail(shotWait.deviceId);
  }, [shot, shotWait, selected, toast, loadDetail]);

  const list = useMemo(() => devices ?? [], [devices]);
  const versions = useMemo(() => summariseVersions(list), [list]);
  const newest = versions.newest;
  // Not memoised: the reasons carry "x mnt lalu" text the ticker keeps live.
  const issues = attentionList(list, newest);
  const rows = registryRows(list, { search, filter, sort, attention: issues });
  const onlineCount = list.filter((d) => d.currently_online).length;
  const selectedDevice = list.find((d) => d.device_id === selected) ?? null;
  const selectedName = selectedDevice ? nameOf(selectedDevice) : null;

  const createInvite = async (device: Device | null) => {
    // A rebind code carries the device's own category, name and hostname.
    // Redeeming an invite overwrites the first two, so without them a rebind
    // quietly recategorised and renamed the device; the hostname pin means
    // only that machine can redeem the code.
    const body = device
      ? {
          category: ENROL_CATEGORIES.has(device.category) ? device.category : "custom",
          display_name: device.display_name ?? "",
          hostname: device.hostname,
        }
      : { category: inviteCategory };
    try {
      const res = await sendJson("/api/enroll/invite", "POST", body, "Gagal membuat kode undangan");
      const { invite_code, expires_at } = (await res.json()) as { invite_code: string; expires_at: string };
      setInvite({ invite_code, expires_at, issuedAt: Date.now(), deviceId: device?.device_id ?? null });
    } catch (err) {
      toast((err as Error).message, "alert");
    }
  };

  // The Clipboard API only exists on a secure origin; served over plain http on
  // the lab LAN there is none, and the Salin button is simply not offered.
  const copyInvite = navigator.clipboard
    ? () =>
        invite &&
        navigator.clipboard
          .writeText(invite.invite_code)
          .then(() => toast("Kode undangan disalin."))
          .catch(() => toast("Gagal menyalin.", "alert"))
    : undefined;

  // DELETE, not the old POST .../revoke. Revoke only nulled the API key: the
  // row stayed in the registry, kept its last_seen, kept status 'active', and
  // -- if the fleet still had a shared ingest key -- came straight back on the
  // next heartbeat. The button said "Hapus" and did not delete.
  const removeDevice = async (device: Device) => {
    try {
      await del(`/api/devices/${device.device_id}`, "Gagal menghapus perangkat");
      toast("Perangkat dihapus dari registri.");
      setDeleteTarget(null);
      setSelected(null);
      refresh();
    } catch (err) {
      toast((err as Error).message, "alert");
    }
  };

  const requestShot = async (device: Device) => {
    const after = shot?.captured_at ?? null;
    setRequestingShot(true);
    try {
      await sendJson(
        "/api/control/screenshot",
        "POST",
        { hostname: device.hostname, reason: "Pemeriksaan dari tab Perangkat" },
        "Gagal meminta cuplikan",
      );
      toast("Permintaan dikirim. Cuplikan muncul di sini setelah client merespons.");
      // The panel may have been closed or switched while the POST was in flight.
      if (selectedRef.current !== device.device_id) return;
      setShotWait({ deviceId: device.device_id, after, until: Date.now() + SHOT_WAIT_MS });
      loadDetail(device.device_id);
    } catch (err) {
      toast((err as Error).message, "alert");
    } finally {
      setRequestingShot(false);
    }
  };

  const pick = (d: Device) => setSelected(d.device_id);

  const toggleFilter = (next: Filter) => {
    const isSame = sameFilter(filter, next);
    setFilter(isSame ? null : next);
    // Picked from the bento on a narrow screen, the filter changes a registry
    // far below it; bring the registry up so the click visibly did something.
    if (!isSame && !isDesktop) {
      window.setTimeout(
        () => registryRef.current?.scrollIntoView({ behavior: isReducedMotion ? "auto" : "smooth", block: "start" }),
        0,
      );
    }
  };

  // minmax(0, …): a plain 1fr track grows to its widest child, and one wide
  // chip or row of fleet labels then pushed the whole canvas sideways on phone.
  const bentoColumns = isDesktop
    ? "repeat(12, minmax(0, 1fr))"
    : breakpoint === "tablet"
      ? "repeat(2, minmax(0, 1fr))"
      : "minmax(0, 1fr)";
  const bentoSpan = (desktop: number, tablet: number) =>
    isDesktop ? `span ${desktop}` : breakpoint === "tablet" ? `span ${tablet}` : undefined;
  const gap = isPhone ? 10 : 16;

  // ---- Registry ----
  const versionCell = (d: Device) => {
    const v = agentVersion(d);
    if (!v) return <Mono style={{ fontSize: 12.5, color: "var(--lx-muted)" }}>-</Mono>;
    if (isOutdated(d, newest)) return <Tag title={`Tertinggal dari ${newest}`}>↓ {v}</Tag>;
    return <Mono style={{ fontSize: 12.5 }}>{v}</Mono>;
  };

  const columns: Column<Device>[] = [
    {
      key: "id",
      header: "ID",
      width: "110px",
      phone: "primary",
      render: (d) => <Mono style={{ fontSize: 13, fontWeight: 700 }}>{nameOf(d).id}</Mono>,
    },
    {
      key: "spec",
      header: "Spesifikasi",
      width: "minmax(0, 1fr)",
      phone: "secondary",
      render: (d) => <span style={{ color: "var(--lx-muted)" }}>{nameOf(d).spec || d.hostname}</span>,
    },
    // Humanised: "lab_workstation" is an API key, not something to show a lab admin.
    { key: "category", header: "Kategori", width: "130px", phone: "secondary", render: (d) => categoryLabel(d.category) },
    {
      key: "sync",
      header: "Sinkronisasi",
      width: "180px",
      phone: "secondary",
      render: (d) => (
        <span style={{ display: "inline-flex", alignItems: "center", gap: 7 }}>
          <StatusDot status={SYNC_STATUS[d.sync_status] ?? "idle"} label={SYNC_LABEL[d.sync_status]} />
          <Mono style={{ fontSize: 12 }}>{timeAgo(d.last_seen)}</Mono>
          {d.sync_status !== "online" && (
            <span style={{ fontSize: 12, color: "var(--lx-muted)" }}>· {SYNC_LABEL[d.sync_status]}</span>
          )}
        </span>
      ),
    },
    { key: "version", header: "Versi agent", width: "110px", phone: "primary", render: versionCell },
    {
      key: "open",
      header: "",
      width: "30px",
      render: (d) => (
        <span className="lx-round" aria-hidden="true" style={roundArrow(d.device_id === selected)}>
          {ARROW}
        </span>
      ),
    },
  ];

  const registry = (
    <section className="lx-rise" style={{ "--i": 3 } as CSSProperties}>
      <div
        ref={registryRef}
        style={{
          scrollMarginTop: 36,
          display: "flex",
          alignItems: "center",
          gap: 10,
          flexWrap: "wrap",
          padding: "0 4px",
          marginBottom: 12,
        }}
      >
        <span style={{ fontSize: 15, fontWeight: 550, letterSpacing: "-0.01em" }}>Registri</span>
        <Mono style={{ fontSize: 12, color: "var(--lx-muted)" }}>
          {rows.length === list.length ? list.length : `${rows.length}/${list.length}`}
        </Mono>
        {filter && (
          <Button
            size="sm"
            aria-label={`Hapus filter ${filterLabel(filter)}`}
            label={`${filterLabel(filter)}  ×`}
            onClick={() => setFilter(null)}
            style={{ fontSize: 12, padding: "6px 12px", whiteSpace: "pre", background: "var(--lx-ink)", color: "var(--lx-on-ink)", border: "none" }}
          />
        )}
        <div
          style={{
            marginLeft: isPhone ? 0 : "auto",
            width: isPhone ? "100%" : undefined,
            display: "flex",
            gap: 8,
            flexWrap: "wrap",
            alignItems: "center",
          }}
        >
          <SearchChip value={search} onChange={setSearch} placeholder="Cari ID / spesifikasi" />
          <PillSelect label="Urutkan" value={sort} options={SORT_OPTIONS} onChange={setSort} width={196} />
        </div>
      </div>
      <Table
        columns={columns}
        rows={rows}
        getRowKey={(d) => d.device_id}
        selectedKey={selected}
        onRowClick={pick}
        emptyLabel="Tidak ada perangkat yang cocok."
      />
    </section>
  );

  return (
    <>
      <PageHeader
        title="Perangkat"
        summary={
          devices === null ? (
            loadError ? "Gagal memuat" : "Memuat..."
          ) : (
            <>
              <Mono style={{ color: "var(--lx-text)" }}>{devices.length}</Mono> terdaftar ·{" "}
              <Mono style={{ color: "var(--lx-text)" }}>{onlineCount}</Mono> online
              {loadError && <span style={{ color: "var(--lx-status-alert)" }}> · gagal diperbarui</span>}
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

      {devices === null ? (
        loadError ? (
          <ErrorState description={loadError} onRetry={refresh} />
        ) : (
          <div style={{ display: "grid", gridTemplateColumns: bentoColumns, gap }}>
            {[5, 4, 3].map((span, i) => (
              <div key={span} style={{ gridColumn: bentoSpan(span, i === 0 ? 2 : 1) }}>
                <Skeleton height={290} />
              </div>
            ))}
            <div style={{ gridColumn: "1 / -1" }}>
              <Skeleton height={380} />
            </div>
          </div>
        )
      ) : list.length === 0 ? (
        <EmptyState
          title="Belum ada perangkat terdaftar"
          description="Buat kode undangan lewat tombol di kanan atas, lalu masukkan kodenya di client Windows perangkat baru."
        />
      ) : (
        <div style={{ display: "grid", gridTemplateColumns: "minmax(0, 1fr)", gap }}>
          <div style={{ display: "grid", gridTemplateColumns: bentoColumns, gap }}>
            <FleetCard
              gridColumn={bentoSpan(5, 2)}
              devices={list}
              updatedAt={updatedAt}
              selectedId={selected}
              onSelect={pick}
              filter={filter}
              onFilter={toggleFilter}
            />
            <VersionCard
              gridColumn={bentoSpan(4, 1)}
              versions={versions}
              total={list.length}
              filter={filter}
              onFilter={toggleFilter}
            />
            <AttentionCard
              gridColumn={bentoSpan(3, 1)}
              issues={issues}
              isFiltered={filter?.kind === "attention"}
              onSelect={pick}
              onFilter={() => toggleFilter({ kind: "attention" })}
            />
          </div>
          {registry}
        </div>
      )}

      {/* Outside-click dismissal is held off while one of the panel's own
          modals is up: a click inside that modal is "outside" the panel. */}
      <SidePanel
        isOpen={selectedDevice !== null}
        onClose={() => {
          if (deleteTarget || isShotOpen) return;
          setSelected(null);
        }}
        label={`Detail ${selectedName?.id ?? ""}`}
        header={selectedDevice && <DetailHeader device={selectedDevice} />}
      >
        {selectedDevice && (
          <DetailBody
            device={selectedDevice}
            detail={detail}
            newest={newest}
            shot={shot}
            isWaitingShot={shotWait?.deviceId === selectedDevice.device_id}
            isRequestingShot={isRequestingShot}
            invite={invite?.deviceId === selectedDevice.device_id ? invite : null}
            onRequestShot={() => requestShot(selectedDevice)}
            onReloadShot={() => loadShot(selectedDevice.device_id)}
            onOpenShot={() => setShotOpen(true)}
            onCreateInvite={() => createInvite(selectedDevice)}
            onCopyInvite={copyInvite}
            onDelete={() => setDeleteTarget(selectedDevice)}
          />
        )}
      </SidePanel>

      {/* Enrolment: pick a category, get a one-time code. */}
      <Modal
        isOpen={isInviteOpen}
        onClose={() => setInviteOpen(false)}
        title="Tambah perangkat"
        description="Pilih kategori, lalu masukkan kode yang muncul di client Windows perangkat baru."
        footer={
          invite?.deviceId === null ? (
            <Button label="Selesai" variant="primary" size="sm" onClick={() => setInviteOpen(false)} />
          ) : (
            <ModalActions onCancel={() => setInviteOpen(false)} confirmLabel="Buat kode" onConfirm={() => createInvite(null)} />
          )
        }
      >
        {invite?.deviceId === null ? (
          <InviteTicket invite={invite} onCopy={copyInvite} />
        ) : (
          <PillSelect label="Kategori" value={inviteCategory} options={DEVICE_CATEGORIES} onChange={setInviteCategory} width={180} />
        )}
      </Modal>

      <Modal
        isOpen={deleteTarget !== null}
        onClose={() => setDeleteTarget(null)}
        title={`Hapus ${deleteTarget ? nameOf(deleteTarget).id : ""}?`}
        description="Perangkat hilang dari daftar, kehilangan kredensialnya, dan tidak bisa mendaftar ulang sendiri lewat heartbeat — hanya lewat kode undangan baru. Riwayat sesinya tetap tersimpan."
        accentEdge="alert"
        footer={
          <ModalActions
            onCancel={() => setDeleteTarget(null)}
            confirmLabel="Hapus perangkat"
            variant="danger"
            onConfirm={() => deleteTarget && removeDevice(deleteTarget)}
          />
        }
      />

      {/* Full-size capture. The drawer thumbnail is enough to see THAT a
          screenshot exists, never enough to read what is on the screen. */}
      <Modal
        isOpen={isShotOpen && !!shot}
        onClose={() => setShotOpen(false)}
        title={`Cuplikan layar ${selectedName?.id ?? ""}`}
        description={shot ? `Diambil ${formatLogTime(shot.captured_at)}` : undefined}
        width={860}
        footer={<Button label="Tutup" variant="secondary" size="sm" onClick={() => setShotOpen(false)} />}
      >
        {shot && (
          <img
            src={shotSrc(shot)}
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
