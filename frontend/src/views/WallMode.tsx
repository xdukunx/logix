// Wall / TV mode. Design: docs/design_handoff_logix_v3/LogiX Responsive.dc.html
// ("TV — mode wall") + README section 4.
//
// Dark, read-only, no nav and no menus at all -- just the lab name, a live
// counter, a clock, and a dense station grid with 21px mono IDs meant to be
// read from about four metres. User names can be hidden from
// Settings > Privasi. Reachable at #wall.
import { useCallback, useMemo, useState } from "react";

import { getJson } from "../api";
import type { StationStatus } from "../tokens";
import { ForceDark } from "../theme/ThemeMode";
import type { ActiveWorkstation, Device, LogixConfig } from "../types";
import { StatusDot } from "../ui/base";
import { durationSince, formatClock, splitDeviceName, usePolling, useTicker } from "../util";

interface WallStation {
  hostname: string;
  id: string;
  status: StationStatus;
  line: string;
}

export default function WallMode() {
  const [devices, setDevices] = useState<Device[]>([]);
  const [active, setActive] = useState<ActiveWorkstation[]>([]);
  const [hideNames, setHideNames] = useState(false);
  const [labName, setLabName] = useState("Lab Komputasi FTMM");

  useTicker(1000); // clock + live durations

  const refresh = useCallback(async () => {
    try {
      const [deviceList, activeList] = await Promise.all([
        getJson<Device[]>("/api/devices", ""),
        getJson<ActiveWorkstation[]>("/api/active", ""),
      ]);
      setDevices(deviceList);
      setActive(activeList);
    } catch {
      // A wall display must not show an error card -- keep the last good board.
    }
    try {
      const config = await getJson<LogixConfig>("/api/config", "");
      setHideNames(Boolean((config.privacy as Record<string, unknown>)?.hide_names_on_wall));
      if (config.branding?.subtitle) setLabName(String(config.branding.subtitle));
    } catch {
      /* keep defaults */
    }
  }, []);

  usePolling(refresh, 15000);

  const stations = useMemo<WallStation[]>(() => {
    const liveByHost = new Map(active.map((a) => [a.hostname, a]));
    return devices
      .map((d) => {
        const live = liveByHost.get(d.hostname) ?? null;
        const { id } = splitDeviceName(d.display_name || d.hostname);
        if (!live) return { hostname: d.hostname, id, status: "offline" as const, line: "Offline" };
        if (live.status === "LOCKED") {
          return {
            hostname: d.hostname,
            id,
            status: "locked" as const,
            line: `Dikunci · ${formatClock(live.status_since ?? live.last_seen)}`,
          };
        }
        if (!live.username) return { hostname: d.hostname, id, status: "idle" as const, line: "Bebas" };
        const elapsed = live.session_started_at ? durationSince(live.session_started_at) : "";
        // Privasi: names can be suppressed for a display facing the room.
        const who = hideNames ? "Dipakai" : live.username;
        return {
          hostname: d.hostname,
          id,
          status: "active" as const,
          line: elapsed ? `${who} · ${elapsed}` : who,
        };
      })
      .sort((a, b) => a.id.localeCompare(b.id, "id", { numeric: true }));
  }, [devices, active, hideNames]);

  const inUse = stations.filter((s) => s.status === "active").length;
  const now = new Date();

  return (
    <ForceDark>
      <div style={{ padding: "40px 48px", minHeight: "100dvh", display: "flex", flexDirection: "column" }}>
        <header style={{ display: "flex", alignItems: "baseline", gap: 20, marginBottom: 28, flexWrap: "wrap" }}>
          <span style={{ fontSize: 26, fontWeight: 650 }}>{labName}</span>
          <span style={{ fontSize: 18, color: "var(--lx-muted)" }}>
            <span className="lx-mono" style={{ color: "var(--lx-text)" }}>
              {inUse}
            </span>{" "}
            / <span className="lx-mono">{stations.length}</span> stasiun dipakai
          </span>
          <span className="lx-mono" style={{ marginLeft: "auto", fontSize: 26 }}>
            {formatClock(now.toISOString())}
          </span>
        </header>

        <div
          style={{
            flex: 1,
            display: "grid",
            gridTemplateColumns: "repeat(auto-fill, minmax(240px, 1fr))",
            gridAutoRows: "minmax(96px, 1fr)",
            gap: 16,
          }}
        >
          {stations.map((s) => {
            const isOffline = s.status === "offline";
            return (
              <div
                key={s.hostname}
                style={{
                  background: isOffline ? "transparent" : "var(--lx-card)",
                  border: isOffline
                    ? "1px dashed var(--lx-border-dashed)"
                    : "1px solid var(--lx-border)",
                  borderRadius: "var(--lx-radius-card)",
                  padding: "18px 20px",
                }}
              >
                <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
                  <StatusDot status={s.status} size={12} label={s.status} />
                  <span
                    className="lx-mono"
                    style={{
                      fontSize: 21,
                      fontWeight: 600,
                      whiteSpace: "nowrap",
                      color: isOffline ? "var(--lx-status-offline)" : undefined,
                    }}
                  >
                    {s.id}
                  </span>
                </div>
                <div
                  style={{
                    fontSize: 15,
                    color: isOffline ? "var(--lx-status-offline)" : "var(--lx-muted)",
                    marginTop: 8,
                  }}
                >
                  {s.line}
                </div>
              </div>
            );
          })}
        </div>
      </div>
    </ForceDark>
  );
}
