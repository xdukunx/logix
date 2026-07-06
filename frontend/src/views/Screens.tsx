// Screen monitoring wall (Veyon-like) -- a manual "Capture All" grid of the
// active workstations' screens. Reuses the existing on-demand screenshot
// endpoints only (no backend or agent changes): POST /api/control/screenshot
// queues a capture, the agent captures + uploads (always notifying the user on
// the device, never silent), and GET /api/devices/{id}/screenshot returns the
// latest image. Deliberately manual, not continuous: every capture notifies
// the user, so an auto-refreshing wall would spam them -- see docs/PRIVACY.md.
import { useCallback, useEffect, useRef, useState } from "react";
import { Badge } from "@astryxdesign/core/Badge";
import { Button } from "@astryxdesign/core/Button";
import { Card } from "@astryxdesign/core/Card";
import { Dialog } from "@astryxdesign/core/Dialog";
import { EmptyState } from "@astryxdesign/core/EmptyState";
import { Grid } from "@astryxdesign/core/Grid";
import { HStack, VStack } from "@astryxdesign/core/Stack";
import { Spinner } from "@astryxdesign/core/Spinner";
import { Heading, Text } from "@astryxdesign/core/Text";
import { useToast } from "@astryxdesign/core/Toast";
import { CameraIcon, ComputerDesktopIcon } from "@heroicons/react/24/outline";

import { fetchWithAuth, getJson, sendJson } from "../api";
import type { ActiveWorkstation, Device, DeviceScreenshot } from "../types";
import { formatDateTime } from "../util";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

interface Tile {
  hostname: string;
  device_name: string;
  device_id: string | null;
  shot: DeviceScreenshot | null;
  capturing: boolean;
}

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
  const [enlarged, setEnlarged] = useState<{ src: string; name: string; at: string } | null>(null);
  const mounted = useRef(true);
  useEffect(() => () => { mounted.current = false; }, []);

  // Build the tile list from the active hosts, mapping each to its device_id
  // (needed to read its screenshot) and its last stored capture.
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
        device_id: idByHost.get(a.hostname) ?? null,
        shot: null,
        capturing: false,
      }));
      if (mounted.current) setTiles(base);
      setError(null);
      // Pull whatever captures already exist so the wall isn't empty on open.
      const withShots = await Promise.all(
        base.map(async (t) => ({ ...t, shot: t.device_id ? await loadShot(t.device_id) : null })),
      );
      if (mounted.current) setTiles(withShots);
    } catch (err) {
      if (mounted.current) setError((err as Error).message);
    }
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  // Queue a capture, then poll that device's screenshot until captured_at
  // advances past what we had (or a timeout), updating the tile in place.
  const capture = useCallback(async (tile: Tile) => {
    if (!tile.device_id) return;
    const prevAt = tile.shot?.captured_at ?? "";
    setTiles((ts) => ts?.map((t) => (t.hostname === tile.hostname ? { ...t, capturing: true } : t)) ?? ts);
    try {
      await sendJson("/api/control/screenshot", "POST", { hostname: tile.hostname }, "Gagal meminta screenshot");
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
    // Timed out waiting for the device to answer (offline / slow heartbeat).
    setTiles((ts) => ts?.map((t) => (t.hostname === tile.hostname ? { ...t, capturing: false } : t)) ?? ts);
  }, [toast]);

  const captureAll = useCallback(async () => {
    if (!tiles || tiles.length === 0) return;
    setBusy(true);
    toast({ body: "Meminta screenshot ke semua device aktif. Tiap pengguna diberi tahu di perangkatnya." });
    await Promise.all(tiles.filter((t) => t.device_id).map((t) => capture(t)));
    if (mounted.current) setBusy(false);
  }, [tiles, capture, toast]);

  const activeCount = tiles?.length ?? 0;

  return (
    <VStack gap={5}>
      <HStack gap={3} align="center" justify="between">
        <HStack gap={3} align="center">
          <Heading level={3}>Layar</Heading>
          <Badge variant={activeCount > 0 ? "success" : "neutral"} label={`${activeCount} aktif`} />
        </HStack>
        <HStack gap={2} align="center">
          <Button label="Muat ulang" size="sm" variant="ghost" onClick={refresh} isDisabled={busy} />
          <Button
            label="Ambil Semua"
            variant="primary"
            icon={<CameraIcon style={{ width: 16, height: 16 }} />}
            onClick={captureAll}
            isLoading={busy}
            isDisabled={activeCount === 0}
          />
        </HStack>
      </HStack>

      <Text type="supporting" color="secondary">
        Menyimpan satu tangkapan layar per device aktif. Pengguna di perangkat selalu diberi tahu saat layarnya diambil — tidak ada pemantauan diam-diam.
      </Text>

      {error ? (
        <EmptyState title="Terjadi Kesalahan" description={error} />
      ) : tiles === null ? (
        <Text type="body">Memuat...</Text>
      ) : tiles.length === 0 ? (
        <EmptyState
          icon={<ComputerDesktopIcon style={{ width: 40, height: 40 }} />}
          title="Tidak ada device aktif"
          description="Layar device akan muncul di sini setelah workstation memulai sesi."
        />
      ) : (
        <Grid columns={{ minWidth: 280, repeat: "fill" }} gap={4}>
          {tiles.map((t) => (
            <Card key={t.hostname} padding={3}>
              <VStack gap={2}>
                <HStack gap={2} align="center" justify="between">
                  <Text type="label">{t.device_name}</Text>
                  <Button
                    label="Ambil"
                    size="sm"
                    variant="ghost"
                    isLoading={t.capturing}
                    isDisabled={!t.device_id || busy}
                    onClick={() => capture(t)}
                  />
                </HStack>
                <div
                  style={{
                    aspectRatio: "16 / 10",
                    borderRadius: "var(--radius-element, 6px)",
                    overflow: "hidden",
                    background: "var(--color-background-wash, #eee)",
                    display: "flex",
                    alignItems: "center",
                    justifyContent: "center",
                    cursor: t.shot ? "pointer" : "default",
                  }}
                  onClick={() =>
                    t.shot &&
                    setEnlarged({
                      src: `data:${t.shot.content_type || "image/jpeg"};base64,${t.shot.image_base64}`,
                      name: t.device_name,
                      at: t.shot.captured_at,
                    })
                  }
                >
                  {t.capturing ? (
                    <Spinner label="Mengambil..." />
                  ) : t.shot ? (
                    <img
                      src={`data:${t.shot.content_type || "image/jpeg"};base64,${t.shot.image_base64}`}
                      alt={`Layar ${t.device_name}`}
                      style={{ width: "100%", height: "100%", objectFit: "cover" }}
                    />
                  ) : (
                    <Text type="supporting" color="secondary">Belum ada tangkapan</Text>
                  )}
                </div>
                <Text type="supporting" color="secondary">
                  {t.shot ? `Diambil ${formatDateTime(t.shot.captured_at)}` : "Klik Ambil untuk menangkap layar"}
                </Text>
              </VStack>
            </Card>
          ))}
        </Grid>
      )}

      <Dialog isOpen={enlarged !== null} onOpenChange={(open) => !open && setEnlarged(null)} width={900}>
        <VStack gap={3}>
          <Heading level={5}>{enlarged?.name}</Heading>
          {enlarged && (
            <img src={enlarged.src} alt={enlarged.name} style={{ maxWidth: "100%", borderRadius: "var(--radius-element, 6px)" }} />
          )}
          <Text type="supporting" color="secondary">Diambil {enlarged ? formatDateTime(enlarged.at) : ""}</Text>
        </VStack>
      </Dialog>
    </VStack>
  );
}
