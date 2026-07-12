// Screen monitoring wall (design: docs/design/LogiX Screens Wall.dc.html).
// A manual "Ambil Semua" grid of the active workstations' screens. Reuses the
// on-demand screenshot endpoints only (no backend/agent changes): POST
// /api/control/screenshot queues a capture, the agent captures + uploads
// (ALWAYS notifying the user on the device — never silent), and GET
// /api/devices/{id}/screenshot returns the latest image. Deliberately manual,
// not continuous: every capture notifies the user, so an auto-refreshing wall
// would spam them (see docs/PRIVACY.md). "Masuk Wall Mode" opens the read-only
// kiosk board (#wall), which shows status only and captures nothing.
import { useCallback, useEffect, useRef, useState } from "react";
import { Button } from "@astryxdesign/core/Button";
import { Card } from "@astryxdesign/core/Card";
import { Dialog } from "@astryxdesign/core/Dialog";
import { HStack, VStack } from "@astryxdesign/core/Stack";
import { Spinner } from "@astryxdesign/core/Spinner";
import { Heading, Text } from "@astryxdesign/core/Text";
import { useToast } from "@astryxdesign/core/Toast";
import { ArrowsPointingOutIcon, CameraIcon, ShieldCheckIcon } from "@heroicons/react/24/outline";

import { fetchWithAuth, getJson, sendJson } from "../api";
import AccessTypeBadge from "../components/AccessTypeBadge";
import StatusPill from "../components/StatusPill";
import EmptyState from "../components/states/EmptyState";
import ErrorState from "../components/states/ErrorState";
import { SkeletonGrid } from "../components/states/Skeleton";
import { resolveAccessType, type StationStatus } from "../tokens";
import type { ActiveWorkstation, Device, DeviceScreenshot } from "../types";
import { formatDateTime } from "../util";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

interface Tile {
  hostname: string;
  device_name: string;
  username: string | null;
  status: string;
  device_id: string | null;
  shot: DeviceScreenshot | null;
  capturing: boolean;
}

const tileStatus = (t: Tile): StationStatus => (t.status === "LOCKED" ? "locked" : "inuse");

// 404 (no capture yet) / 403 (no permission) resolve to null rather than throw.
const loadShot = async (deviceId: string): Promise<DeviceScreenshot | null> => {
  try {
    const res = await fetchWithAuth(`/api/devices/${deviceId}/screenshot`);
    if (!res.ok) return null;
    return await res.json();
  } catch {
    return null;
  }
};

export default function Screens() {
  const toast = useToast();
  const [tiles, setTiles] = useState<Tile[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [enlarged, setEnlarged] = useState<Tile | null>(null);
  const mounted = useRef(true);
  useEffect(() => {
    mounted.current = true;
    return () => { mounted.current = false; };
  }, []);

  const refresh = useCallback(async () => {
    try {
      const [active, devices] = await Promise.all([
        getJson<ActiveWorkstation[]>("/api/active", "Gagal mengambil workstation aktif"),
        getJson<Device[]>("/api/devices", "Gagal memuat data devices"),
      ]);
      const idByHost = new Map(devices.map((d) => [d.hostname, d.device_id]));
      const base: Tile[] = active.map((a) => ({
        hostname: a.hostname,
        device_name: a.device_name || a.hostname,
        username: a.username,
        status: a.status,
        device_id: idByHost.get(a.hostname) ?? null,
        shot: null,
        capturing: false,
      }));
      if (mounted.current) setTiles(base);
      setError(null);
      const withShots = await Promise.all(
        base.map(async (t) => ({ ...t, shot: t.device_id ? await loadShot(t.device_id) : null })),
      );
      if (mounted.current) setTiles(withShots);
    } catch (err) {
      if (mounted.current) setError((err as Error).message);
    }
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  const capture = useCallback(async (tile: Tile) => {
    if (!tile.device_id) return;
    const prevAt = tile.shot?.captured_at ?? "";
    setTiles((ts) => ts?.map((t) => (t.hostname === tile.hostname ? { ...t, capturing: true } : t)) ?? ts);
    try {
      await sendJson("/api/control/screenshot", "POST", { hostname: tile.hostname, reason: "Monitoring wall" }, "Gagal meminta screenshot");
    } catch (err) {
      toast({ body: (err as Error).message, type: "error" });
      setTiles((ts) => ts?.map((t) => (t.hostname === tile.hostname ? { ...t, capturing: false } : t)) ?? ts);
      return;
    }
    for (let i = 0; i < 12 && mounted.current; i++) {
      await sleep(1500);
      const shot = tile.device_id ? await loadShot(tile.device_id) : null;
      if (shot && shot.captured_at !== prevAt) {
        setTiles((ts) => ts?.map((t) => (t.hostname === tile.hostname ? { ...t, shot, capturing: false } : t)) ?? ts);
        return;
      }
    }
    setTiles((ts) => ts?.map((t) => (t.hostname === tile.hostname ? { ...t, capturing: false } : t)) ?? ts);
  }, [toast]);

  const captureAll = useCallback(async () => {
    if (!tiles || tiles.length === 0) return;
    setBusy(true);
    toast({ body: "Meminta screenshot ke semua device aktif. Tiap pengguna diberi tahu di perangkatnya." });
    await Promise.all(tiles.filter((t) => t.device_id).map((t) => capture(t)));
    if (mounted.current) setBusy(false);
  }, [tiles, capture, toast]);

  const count = tiles?.length ?? 0;

  return (
    <VStack gap={5}>
      <HStack gap={3} align="center" justify="between" wrap="wrap">
        <VStack gap={1}>
          <Heading level={3}>Layar</Heading>
          <Text type="supporting" color="secondary">
            Cuplikan manual dari device aktif · {count} perangkat
          </Text>
        </VStack>
        <HStack gap={2} align="center">
          <Button
            label="Masuk Wall Mode"
            size="sm"
            variant="secondary"
            icon={<ArrowsPointingOutIcon style={{ width: 16, height: 16 }} />}
            onClick={() => (window.location.hash = "wall")}
          />
          <Button label="Muat ulang" size="sm" variant="ghost" onClick={refresh} isDisabled={busy} />
          <Button
            label="Ambil Semua"
            variant="primary"
            icon={<CameraIcon style={{ width: 16, height: 16 }} />}
            onClick={captureAll}
            isLoading={busy}
            isDisabled={count === 0}
          />
        </HStack>
      </HStack>

      {/* Privacy banner */}
      <HStack
        gap={2}
        align="start"
        style={{ background: "var(--lx-accent-weak)", border: "1px solid var(--color-border)", borderRadius: 10, padding: "12px 14px" }}
      >
        <ShieldCheckIcon style={{ width: 18, height: 18, color: "var(--lx-accent)", flexShrink: 0, marginTop: 1 }} />
        <Text type="supporting">
          Cuplikan tidak pernah diam-diam. Setiap kali Anda mengambil layar, pengguna di perangkat
          langsung diberi tahu. Karena itu halaman ini manual — tidak menyegar otomatis.
        </Text>
      </HStack>

      {error ? (
        <ErrorState description={error} onRetry={refresh} />
      ) : tiles === null ? (
        <SkeletonGrid count={6} />
      ) : tiles.length === 0 ? (
        <EmptyState
          title="Tidak ada device aktif"
          description="Layar device akan muncul di sini setelah workstation memulai sesi."
        />
      ) : (
        <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(280px, 1fr))", gap: 16 }}>
          {tiles.map((t) => {
            const accessType = resolveAccessType(null); // TODO(backend): session access_type
            return (
              <Card key={t.hostname} padding={3}>
                <VStack gap={2}>
                  <HStack gap={2} align="center" justify="between">
                    <VStack gap={1} style={{ minWidth: 0 }}>
                      <HStack gap={2} align="center">
                        <StatusPill status={tileStatus(t)} small pulse={t.status === "ACTIVE"} />
                        <Text type="label">{t.device_name}</Text>
                      </HStack>
                      <HStack gap={2} align="center">
                        <AccessTypeBadge type={accessType} size="sm" />
                        {t.username && <Text type="supporting" color="secondary">{t.username}</Text>}
                      </HStack>
                    </VStack>
                    <Button
                      label="Ambil"
                      size="sm"
                      variant="secondary"
                      isLoading={t.capturing}
                      isDisabled={!t.device_id || busy}
                      onClick={() => capture(t)}
                    />
                  </HStack>
                  <div
                    style={{
                      aspectRatio: "16 / 10",
                      borderRadius: 8,
                      overflow: "hidden",
                      background: "var(--lx-skeleton-base)",
                      display: "flex",
                      alignItems: "center",
                      justifyContent: "center",
                      cursor: t.shot ? "pointer" : "default",
                    }}
                    onClick={() => t.shot && setEnlarged(t)}
                  >
                    {t.capturing ? (
                      <VStack gap={1} align="center">
                        <Spinner label="Mengambil cuplikan…" />
                        <Text type="supporting" color="secondary">memberi tahu pengguna</Text>
                      </VStack>
                    ) : t.shot ? (
                      <img
                        src={`data:${t.shot.content_type || "image/jpeg"};base64,${t.shot.image_base64}`}
                        alt={`Layar ${t.device_name}`}
                        style={{ width: "100%", height: "100%", objectFit: "cover" }}
                      />
                    ) : (
                      <Text type="supporting" color="secondary">Belum ada cuplikan</Text>
                    )}
                  </div>
                  <Text type="supporting" color="secondary">
                    {t.shot ? `Diambil ${formatDateTime(t.shot.captured_at)}` : "Klik Ambil untuk menangkap layar"}
                  </Text>
                </VStack>
              </Card>
            );
          })}
        </div>
      )}

      <Dialog isOpen={enlarged !== null} onOpenChange={(open) => !open && setEnlarged(null)} width={900}>
        <VStack gap={3}>
          <HStack gap={3} align="center" justify="between">
            <VStack gap={0.5}>
              <Heading level={5}>{enlarged?.device_name}</Heading>
              {enlarged?.shot && (
                <Text type="supporting" color="secondary">
                  {enlarged.username ? `${enlarged.username} · ` : ""}diambil {formatDateTime(enlarged.shot.captured_at)}
                </Text>
              )}
            </VStack>
            {enlarged && (
              <Button
                label="Ambil ulang"
                size="sm"
                variant="secondary"
                icon={<CameraIcon style={{ width: 15, height: 15 }} />}
                onClick={() => capture(enlarged)}
              />
            )}
          </HStack>
          {enlarged?.shot && (
            <img
              src={`data:${enlarged.shot.content_type || "image/jpeg"};base64,${enlarged.shot.image_base64}`}
              alt={enlarged.device_name}
              style={{ maxWidth: "100%", borderRadius: 8 }}
            />
          )}
          <HStack gap={2} align="center">
            <ShieldCheckIcon style={{ width: 15, height: 15, color: "var(--lx-text-muted)", flexShrink: 0 }} />
            <Text type="supporting" color="secondary">
              Pengguna telah diberi tahu tentang cuplikan ini. Tersimpan di log audit.
            </Text>
          </HStack>
        </VStack>
      </Dialog>
    </VStack>
  );
}
