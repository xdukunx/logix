// Wall / Kiosk mode (design: docs/design/LogiX Wall Mode.dc.html). A dark,
// read-only, full-screen board for a wall display: live clock, lab occupancy,
// and a grid of station tiles. Read-only by design — it polls /api/active and
// carries NO controls (no capture, no power). Reachable at #wall.
import { useEffect, useState } from "react";

import { getJson } from "../api";
import Wordmark from "../components/Wordmark";
import { resolveAccessType, ACCESS_TYPE, STATUS, type StationStatus } from "../tokens";
import type { ActiveWorkstation } from "../types";
import { usePolling } from "../util";

const DAYS = ["Minggu", "Senin", "Selasa", "Rabu", "Kamis", "Jumat", "Sabtu"];
const MONTHS = [
  "Januari", "Februari", "Maret", "April", "Mei", "Juni",
  "Juli", "Agustus", "September", "Oktober", "November", "Desember",
];
const pad = (n: number) => String(n).padStart(2, "0");

const stationStatus = (pc: ActiveWorkstation): StationStatus =>
  pc.status === "LOCKED" ? "locked" : "inuse";

export default function WallMode() {
  const [now, setNow] = useState(new Date());
  const [pcs, setPcs] = useState<ActiveWorkstation[] | null>(null);
  const [connected, setConnected] = useState(true);

  useEffect(() => {
    const id = setInterval(() => setNow(new Date()), 1000);
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") window.location.hash = "screens";
    };
    window.addEventListener("keydown", onKey);
    return () => {
      clearInterval(id);
      window.removeEventListener("keydown", onKey);
    };
  }, []);

  usePolling(async () => {
    try {
      setPcs(await getJson<ActiveWorkstation[]>("/api/active", "Gagal memuat"));
      setConnected(true);
    } catch {
      setConnected(false);
    }
  }, 10000);

  const list = pcs ?? [];
  const inUse = list.filter((p) => p.status === "ACTIVE").length;
  const total = list.length; // TODO(backend): enrolled total for true "/12"
  const clock = `${pad(now.getHours())}:${pad(now.getMinutes())}:${pad(now.getSeconds())}`;
  const dateStr = `${DAYS[now.getDay()]}, ${now.getDate()} ${MONTHS[now.getMonth()]} ${now.getFullYear()}`;

  return (
    <div
      style={{
        // Force the dark kiosk palette regardless of the app theme.
        colorScheme: "dark",
        minHeight: "100vh",
        background: "#0b1120",
        color: "#e2e8f0",
        padding: "32px 40px",
        display: "flex",
        flexDirection: "column",
        gap: 28,
        fontFamily: "inherit",
      }}
    >
      {/* Header: brand + clock */}
      <div style={{ display: "flex", alignItems: "flex-start", justifyContent: "space-between", gap: 24 }}>
        <div>
          <Wordmark size={30} tracking="0.2em" />
          <div style={{ fontSize: 14, color: "#94a3b8", marginTop: 8 }}>Lab Kimia Komputasi · FTMM</div>
        </div>
        <div style={{ textAlign: "right" }}>
          <div style={{ fontSize: 46, fontWeight: 800, letterSpacing: "-0.02em", lineHeight: 1, fontFamily: "ui-monospace, Consolas, monospace", color: "#f1f5f9" }}>
            {clock}
          </div>
          <div style={{ fontSize: 14, color: "#94a3b8", marginTop: 6 }}>{dateStr}</div>
        </div>
      </div>

      {/* Occupancy */}
      <div style={{ display: "flex", alignItems: "baseline", gap: 16 }}>
        <span style={{ fontSize: 40, fontWeight: 800, letterSpacing: "-0.03em", color: "#f1f5f9" }}>
          {inUse} <span style={{ color: "#64748b" }}>/ {total}</span>
        </span>
        <span style={{ fontSize: 18, color: "#94a3b8" }}>stasiun dipakai</span>
      </div>

      {/* Station grid */}
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(220px, 1fr))", gap: 16, flex: 1, alignContent: "start" }}>
        {list.map((pc) => {
          const status = stationStatus(pc);
          const s = STATUS[status];
          const at = resolveAccessType(null); // TODO(backend): session access_type
          const accent = s.dot;
          return (
            <div
              key={pc.hostname}
              style={{
                background: "#0f172a",
                border: "1px solid #1e293b",
                borderLeft: `3px solid ${accent}`,
                borderRadius: 12,
                padding: 18,
                display: "flex",
                flexDirection: "column",
                gap: 8,
              }}
            >
              <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                <span style={{ width: 9, height: 9, borderRadius: "50%", background: accent }} />
                <span style={{ fontSize: 17, fontWeight: 800, color: "#f1f5f9" }}>{pc.device_name || pc.hostname}</span>
              </div>
              <div style={{ fontSize: 13, color: "#94a3b8" }}>{pc.username || "—"}</div>
              <div style={{ marginTop: "auto", display: "flex", alignItems: "center", justifyContent: "space-between", gap: 8 }}>
                <span style={{ fontSize: 14, fontWeight: 700, color: s.fg }}>
                  {pc.status === "ACTIVE" ? "Aktif" : "Terkunci"} · {ACCESS_TYPE[at].label}
                </span>
              </div>
            </div>
          );
        })}
        {list.length === 0 && (
          <div style={{ color: "#64748b", fontSize: 15 }}>Belum ada stasiun aktif.</div>
        )}
      </div>

      {/* Footer */}
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", gap: 16, borderTop: "1px solid #1e293b", paddingTop: 16 }}>
        <div style={{ display: "flex", alignItems: "center", gap: 8, fontSize: 13, color: "#94a3b8" }}>
          <span style={{ width: 8, height: 8, borderRadius: "50%", background: connected ? "#22c55e" : "#ef4444" }} />
          {connected ? "Server Terhubung" : "Terputus dari Server"} · Diperbarui {clock}
        </div>
        <div style={{ display: "flex", alignItems: "center", gap: 16 }}>
          <span style={{ fontSize: 13, color: "#64748b" }}>Mode tampilan · hanya lihat, tanpa kontrol</span>
          <button
            onClick={() => (window.location.hash = "screens")}
            style={{ background: "#1e293b", color: "#cbd5e1", border: "1px solid #334155", borderRadius: 6, padding: "7px 14px", fontSize: 13, fontWeight: 600, cursor: "pointer", fontFamily: "inherit" }}
          >
            Keluar (Esc)
          </button>
        </div>
      </div>
    </div>
  );
}
