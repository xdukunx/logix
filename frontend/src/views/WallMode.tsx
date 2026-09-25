// Wall / TV mode -- Monitoring for a screen on the lab wall. v4 "Denyut".
//
// Read-only by construction: nothing here is focusable or clickable, and there
// is no nav and no menu. It keeps what reads from across a room -- a large
// clock, how full the lab is, and one large tile per station carrying its live
// heartbeat trace -- and it is always dark. User names can be hidden from
// Settings > Privasi. Reachable at #wall.
//
// Data is Monitoring's: /api/devices merged with /api/active, plus today's
// usage from /api/sessions/spans as TOTALS only -- no name or purpose from a
// span ever reaches this screen. Heartbeats are derived the way Monitoring
// derives them: a beat is a last_seen we saw MOVE between two polls of
// /api/active, so a flat trace is a machine that has genuinely gone quiet.
import { useCallback, useLayoutEffect, useMemo, useRef, useState, type CSSProperties, type ReactNode } from "react";

import { getJson } from "../api";
import Wordmark from "../components/Wordmark";
import { useThemeMode } from "../theme/ThemeMode";
import { ACCESS_LABEL, categoryLabel, resolveAccessType, type StationStatus } from "../tokens";
import type { ActiveWorkstation, Device, LogixConfig, SessionSpan } from "../types";
import { Card, EmptyState, Mono, SkeletonGrid, StatusDot } from "../ui/base";
import { useBreakpoint } from "../ui/hooks";
import { BigNumber, CardTitle, Delta, EcgTrace, FleetDial, SegmentGauge, WeekBars, type DayBar } from "../ui/viz";
import { durationSince, formatClock, formatSince, splitDeviceName, usePolling, useTicker } from "../util";

interface WallStation {
  hostname: string;
  id: string;
  spec: string;
  status: StationStatus;
  live: ActiveWorkstation | null;
  lastSeen: string | null;
}

const LEGEND: { status: StationStatus; label: string }[] = [
  { status: "active", label: "Dipakai" },
  { status: "locked", label: "Terkunci" },
  { status: "idle", label: "Bebas" },
  { status: "offline", label: "Offline" },
];
const STATUS_WORD = new Map(LEGEND.map((l) => [l.status, l.label]));

const BEAT_WINDOW_MS = 60_000;
// Five missed polls of /api/active before the header admits the board is stale.
const STALE_MS = 15_000;
const HOUR_MS = 3_600_000;
const DAY_MS = 24 * HOUR_MS;
const DAYS_SHORT = ["Min", "Sen", "Sel", "Rab", "Kam", "Jum", "Sab"];

const pad = (n: number) => String(n).padStart(2, "0");
const ymd = (t: number) => {
  const d = new Date(t);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
};
const startOfDay = (t: number) => {
  const d = new Date(t);
  d.setHours(0, 0, 0, 0);
  return d.getTime();
};
const spanStart = (s: SessionSpan) => Date.parse(s.timestamp);
/** An open span (no close event yet) runs until now. */
const spanEnd = (s: SessionSpan, now: number) =>
  s.duration_seconds === null ? now : spanStart(s) + s.duration_seconds * 1000;
const overlapMs = (a0: number, a1: number, b0: number, b1: number) => Math.max(0, Math.min(a1, b1) - Math.max(a0, b0));
const hoursLabel = (h: number) => `${h.toLocaleString("id-ID", { maximumFractionDigits: 1 })} j`;

const stationStatus = (live: ActiveWorkstation | null): StationStatus => {
  if (!live) return "offline";
  if (live.status === "LOCKED") return "locked";
  return live.username ? "active" : "idle";
};

/**
 * Pins the dark ramp while the wall is mounted. ForceDark set the attribute
 * once, but on a cold load of #wall -- which is how a TV boots -- the theme
 * provider's own effect runs after it (a parent's effects run after its
 * children's) and put the viewer's light theme straight back. Watching the
 * attribute holds dark whatever order effects run in; leaving restores the
 * viewer's CURRENT mode rather than a snapshot taken before the provider ran.
 */
const usePinnedDark = () => {
  const { mode } = useThemeMode();
  const modeRef = useRef(mode);
  modeRef.current = mode;
  useLayoutEffect(() => {
    const root = document.documentElement;
    const pin = () => {
      if (root.getAttribute("data-theme") !== "dark") root.setAttribute("data-theme", "dark");
    };
    pin();
    const observer = new MutationObserver(pin);
    observer.observe(root, { attributes: true, attributeFilter: ["data-theme"] });
    return () => {
      observer.disconnect();
      if (modeRef.current === "system") root.removeAttribute("data-theme");
      else root.setAttribute("data-theme", modeRef.current);
    };
  }, []);
};

// ---------------------------------------------------------------------------
// Station tile. The status pill uses the same fills as the gauge segments
// (lime = dipakai, ink = terkunci, outline = bebas, dashed = offline), so a
// tile and its segment in the arc read as the same thing.

const PILL: Record<StationStatus, CSSProperties> = {
  active: { background: "var(--lx-accent)", color: "var(--lx-on-accent)" },
  locked: { background: "var(--lx-ink)", color: "var(--lx-on-ink)" },
  idle: { boxShadow: "inset 0 0 0 2px var(--lx-text)", color: "var(--lx-text)" },
  offline: { border: "1.5px dashed var(--lx-border-dashed)", color: "var(--lx-muted)" },
  alert: { background: "var(--lx-status-alert)", color: "var(--lx-on-ink)" },
};

const clip: CSSProperties = { overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap", minWidth: 0 };

const StationTile = ({
  s,
  beats,
  isNameVisible,
  scale,
  index,
}: {
  s: WallStation;
  beats: number[];
  isNameVisible: boolean;
  scale: number;
  index: number;
}) => {
  const isOffline = s.status === "offline";
  const since = s.live?.status_since ?? s.lastSeen;
  let label: ReactNode;
  let value: string;
  let aside: string | null = null;
  if (s.status === "active") {
    // Privasi: a display facing the room may not name the person.
    label = isNameVisible ? s.live?.username || "-" : "Sesi berjalan";
    value = s.live?.session_started_at ? durationSince(s.live.session_started_at) : "-";
    aside = ACCESS_LABEL[resolveAccessType(s.live?.access_type)];
  } else if (s.status === "locked") {
    label = "Dikunci sejak";
    value = formatClock(since);
  } else if (s.status === "idle") {
    label = "Bebas · idle";
    value = durationSince(since);
  } else {
    label = "Offline sejak";
    value = formatSince(s.lastSeen);
  }
  const px = (n: number) => Math.round(n * scale);

  return (
    <Card
      variant={isOffline ? "dashed" : "solid"}
      padding={`${px(20)}px ${px(24)}px ${px(12)}px`}
      className="lx-rise"
      style={{ "--i": index, display: "flex", flexDirection: "column", minWidth: 0, minHeight: 0 } as CSSProperties}
    >
      <div style={{ display: "flex", alignItems: "flex-start", gap: 12 }}>
        <div style={{ minWidth: 0, flex: 1 }}>
          <div style={{ display: "flex", alignItems: "center", gap: px(12) }}>
            <StatusDot status={s.status} size={px(14)} />
            <span
              className="lx-mono"
              style={{
                fontSize: px(34),
                fontWeight: 700,
                lineHeight: 1,
                letterSpacing: "-0.02em",
                whiteSpace: "nowrap",
                color: isOffline ? "var(--lx-status-offline)" : undefined,
              }}
            >
              {s.id}
            </span>
          </div>
          {s.spec && (
            <div style={{ ...clip, fontSize: px(16), lineHeight: 1.3, color: "var(--lx-muted)", marginTop: px(8) }}>{s.spec}</div>
          )}
        </div>
        <span
          key={s.status}
          className="lx-anim-tag"
          style={{
            flexShrink: 0,
            fontSize: px(14),
            fontWeight: 700,
            letterSpacing: ".07em",
            textTransform: "uppercase",
            lineHeight: 1,
            padding: `${px(8)}px ${px(14)}px`,
            borderRadius: "var(--lx-radius-pill)",
            ...PILL[s.status],
          }}
        >
          {STATUS_WORD.get(s.status)}
        </span>
      </div>

      <div style={{ flex: 1, minHeight: px(10) }} />

      <div
        style={{
          ...clip,
          lineHeight: 1.3,
          fontSize: px(20),
          fontWeight: s.status === "active" && isNameVisible ? 650 : 500,
          color: s.status === "active" ? "var(--lx-text)" : "var(--lx-muted)",
        }}
      >
        {label}
      </div>
      <div style={{ display: "flex", alignItems: "baseline", gap: px(12), marginTop: px(6), minWidth: 0 }}>
        <span
          className="lx-big lx-mono"
          style={{
            fontSize: px(46),
            whiteSpace: "nowrap",
            color: isOffline ? "var(--lx-muted)" : "var(--lx-text)",
          }}
        >
          {value}
        </span>
        {aside && <span style={{ ...clip, fontSize: px(17), color: "var(--lx-muted)" }}>{aside}</span>}
      </div>
      {/* Monitoring's own trace, enlarged for the room. zoom rather than a
          transform: the trace is laid out at the larger size, so it still
          measures its own width and its spikes cross it in the full window. */}
      <div style={{ marginTop: px(8), zoom: 1.5 * scale }}>
        <EcgTrace beats={beats} isFlat={isOffline} windowMs={BEAT_WINDOW_MS} />
      </div>
    </Card>
  );
};

// ---------------------------------------------------------------------------

export default function WallMode() {
  usePinnedDark();
  const breakpoint = useBreakpoint();
  const isPhone = breakpoint === "phone";
  const isDesktop = breakpoint === "desktop";

  const [devices, setDevices] = useState<Device[] | null>(null);
  const [active, setActive] = useState<ActiveWorkstation[]>([]);
  // "unavailable": an account without sessions_read, or the server was away
  // before the first answer. The usage card says so instead of showing a zero
  // that would read as an empty lab.
  const [spans, setSpans] = useState<SessionSpan[] | "unavailable" | null>(null);
  // null until /api/config has answered. Names stay hidden until then: the
  // old default of showing them flashed every name onto the room-facing
  // screen for as long as the config took to arrive, even with hiding on.
  const [hideNames, setHideNames] = useState<boolean | null>(null);
  const [labName, setLabName] = useState("Lab Komputasi FTMM");
  const [liveAt, setLiveAt] = useState<number | null>(null);

  // Heartbeats observed per station, as the times we SAW last_seen move.
  // The first reading of a station is not a beat -- we did not see it arrive.
  const beatsRef = useRef(new Map<string, number[]>());
  const lastSeenRef = useRef(new Map<string, string>());
  const [lastBeatAt, setLastBeatAt] = useState<number | null>(null);

  // The clock, durations and "x dtk lalu" are live.
  useTicker(1000);

  // A wall display must not show an error card: every failure below keeps
  // the last good board, and the header says when that board went stale.
  const refreshRegistry = useCallback(async () => {
    try {
      setDevices(await getJson<Device[]>("/api/devices", ""));
    } catch {
      /* keep the last good board */
    }
    try {
      const config = await getJson<LogixConfig>("/api/config", "");
      setHideNames(Boolean(config.privacy?.hide_names_on_wall));
      if (config.branding?.subtitle) setLabName(String(config.branding.subtitle));
    } catch {
      /* keep defaults */
    }
  }, []);

  const refreshLive = useCallback(async () => {
    try {
      const list = await getJson<ActiveWorkstation[]>("/api/active", "");
      const now = Date.now();
      let sawBeat = false;
      for (const a of list) {
        const prev = lastSeenRef.current.get(a.hostname);
        if (prev !== undefined && prev !== a.last_seen) {
          beatsRef.current.set(a.hostname, [...(beatsRef.current.get(a.hostname) ?? []), now]);
          sawBeat = true;
        }
        lastSeenRef.current.set(a.hostname, a.last_seen);
      }
      for (const [host, beats] of beatsRef.current) {
        beatsRef.current.set(host, beats.filter((t) => now - t < BEAT_WINDOW_MS));
      }
      setActive(list);
      setLiveAt(now);
      if (sawBeat) setLastBeatAt(now);
    } catch {
      /* keep the last good board */
    }
  }, []);

  const refreshSpans = useCallback(async () => {
    try {
      const page = await getJson<{ sessions: SessionSpan[] }>(
        `/api/sessions/spans?start_date=${ymd(Date.now() - 6 * DAY_MS)}&limit=5000`,
        "",
      );
      setSpans(page.sessions);
    } catch {
      setSpans((prev) => prev ?? "unavailable");
    }
  }, []);

  usePolling(refreshRegistry, 15000);
  usePolling(refreshLive, 3000);
  usePolling(refreshSpans, 60000);

  const stations = useMemo<WallStation[]>(() => {
    if (!devices) return [];
    const liveByHost = new Map(active.map((a) => [a.hostname, a]));
    return devices
      .map((d) => {
        const live = liveByHost.get(d.hostname) ?? null;
        const { id, spec } = splitDeviceName(d.display_name || live?.device_name || d.hostname);
        return {
          hostname: d.hostname,
          id,
          spec: spec || categoryLabel(d.category),
          status: stationStatus(live),
          live,
          lastSeen: live?.last_seen ?? d.last_seen,
        };
      })
      .sort((a, b) => a.id.localeCompare(b.id, "id", { numeric: true }));
  }, [devices, active]);

  const count = (status: StationStatus) => stations.filter((s) => s.status === status).length;
  const total = stations.length;
  const inUse = count("active");
  const onlineCount = stations.filter((s) => s.status !== "offline").length;
  const free = stations.filter((s) => s.status === "idle");

  // ---- Usage, from the last 7 days of session spans (totals only) ----
  const now = Date.now();
  const today0 = startOfDay(now);
  const usage = useMemo(() => {
    if (!Array.isArray(spans)) return null;
    const hoursIn = (d0: number, d1: number) =>
      spans.reduce((sum, s) => sum + overlapMs(spanStart(s), spanEnd(s, now), d0, d1), 0) / HOUR_MS;
    const days: DayBar[] = [];
    for (let i = 6; i >= 0; i -= 1) {
      const d0 = today0 - i * DAY_MS;
      const hours = hoursIn(d0, d0 + DAY_MS);
      days.push({
        key: ymd(d0),
        label: i === 0 ? "Hari ini" : DAYS_SHORT[new Date(d0).getDay()],
        value: hours,
        tag: hoursLabel(hours),
        isToday: i === 0,
      });
    }
    const todayHours = days[6].value;
    // Yesterday only up to this same time of day, as on Monitoring: a whole
    // day against half of one would always read as a drop.
    const yesterdaySoFar = hoursIn(today0 - DAY_MS, now - DAY_MS);
    const todaySpans = spans.filter((s) => spanEnd(s, now) > today0);
    // Identity is used to COUNT people and goes no further.
    const people = new Set(todaySpans.map((s) => s.nim || s.nama || s.username).filter(Boolean));
    return {
      days,
      todayHours,
      delta: yesterdaySoFar > 0 ? ((todayHours - yesterdaySoFar) / yesterdaySoFar) * 100 : null,
      sessionsToday: todaySpans.length,
      peopleToday: people.size,
    };
    // `now` moves every second; the week only needs recomputing when data does.
  }, [spans, today0, Math.floor(now / 60000)]);

  // ---- Layout ----
  // Tiles are balanced into rows (8 stations = 4 + 4, never 6 + 2) and
  // shrink as the lab grows so a whole lab still fits one screen.
  const maxCols = isDesktop ? (total <= 8 ? 4 : total <= 15 ? 5 : 6) : breakpoint === "tablet" ? 2 : 1;
  const rows = Math.max(1, Math.ceil(total / maxCols));
  const cols = Math.max(1, Math.ceil(total / rows));
  const scale = isPhone ? 0.78 : total <= 8 ? 1 : total <= 15 ? 0.84 : 0.7;
  const gap = isPhone ? 10 : 18;
  const bentoColumns = isDesktop ? "repeat(12, 1fr)" : breakpoint === "tablet" ? "1fr 1fr" : "1fr";
  const bentoSpan = (desktop: number, tablet: number) =>
    isDesktop ? `span ${desktop}` : breakpoint === "tablet" ? `span ${tablet}` : undefined;

  const clockNow = new Date(now);
  const dateLabel = clockNow.toLocaleDateString("id-ID", { weekday: "long", day: "numeric", month: "long", year: "numeric" });
  const liveState = liveAt === null ? "connecting" : now - liveAt > STALE_MS ? "stale" : "live";
  const beatAgo = lastBeatAt ? Math.max(0, Math.round((now - lastBeatAt) / 1000)) : null;

  return (
    <div style={{ minHeight: "100dvh", display: "flex", flexDirection: "column", background: "var(--lx-frame)" }}>
      {/* ---- Frame: lab name, live state, clock ---- */}
      <header
        className="lx-frame-scope"
        style={{
          display: "flex",
          alignItems: "center",
          flexWrap: "wrap",
          gap: isPhone ? "10px 14px" : "12px 26px",
          padding: isPhone ? "16px 16px 14px" : "14px 36px 14px",
        }}
      >
        <Wordmark markSize={isPhone ? 26 : 34} size={isPhone ? 12 : 15} />
        {!isPhone && <span aria-hidden="true" style={{ width: 1, alignSelf: "stretch", margin: "10px 0", background: "var(--lx-border)" }} />}
        <h1
          style={{
            margin: 0,
            fontSize: isPhone ? 17 : "clamp(22px, 1.8vw, 34px)",
            fontWeight: 550,
            letterSpacing: "-0.02em",
            lineHeight: 1.1,
            minWidth: 0,
          }}
        >
          {labName}
        </h1>
        <span
          style={{
            display: "inline-flex",
            alignItems: "center",
            gap: 10,
            padding: isPhone ? "6px 12px" : "9px 16px",
            borderRadius: "var(--lx-radius-pill)",
            background: "var(--lx-frame-raise)",
            fontSize: isPhone ? 12.5 : 15,
            fontWeight: 600,
            whiteSpace: "nowrap",
            color: liveState === "stale" ? "var(--lx-status-alert)" : "var(--lx-text)",
          }}
        >
          {/* Flashes on every heartbeat actually observed -- the only loop
              here is the lab's own. */}
          <span
            key={lastBeatAt ?? 0}
            className={liveState === "live" && lastBeatAt ? "lx-flash" : undefined}
            style={{
              width: 10,
              height: 10,
              borderRadius: 999,
              flexShrink: 0,
              background:
                liveState === "live"
                  ? "var(--lx-status-active)"
                  : liveState === "stale"
                    ? "var(--lx-status-alert)"
                    : "var(--lx-frame-muted)",
            }}
          />
          {liveState === "live" ? (
            "Langsung"
          ) : liveState === "stale" ? (
            <>
              Terputus · data <Mono>{formatClock(new Date(liveAt!).toISOString())}</Mono>
            </>
          ) : (
            "Menghubungkan..."
          )}
        </span>

        <div style={{ marginLeft: "auto", textAlign: "right" }}>
          <div style={{ display: "flex", alignItems: "baseline", justifyContent: "flex-end", gap: 6 }}>
            <span className="lx-big lx-mono" style={{ fontSize: isPhone ? 40 : "clamp(48px, 4vw, 78px)" }}>
              {pad(clockNow.getHours())}:{pad(clockNow.getMinutes())}
            </span>
            <span className="lx-mono" style={{ fontSize: isPhone ? 17 : "clamp(20px, 1.5vw, 28px)", color: "var(--lx-muted)" }}>
              {pad(clockNow.getSeconds())}
            </span>
          </div>
          <div style={{ fontSize: isPhone ? 12.5 : "clamp(14px, 0.9vw, 17px)", lineHeight: 1.3, color: "var(--lx-muted)", marginTop: 6 }}>
            {dateLabel}
          </div>
        </div>
      </header>

      {/* ---- Canvas ---- */}
      <main
        style={{
          flex: 1,
          display: "flex",
          flexDirection: "column",
          gap,
          background: "var(--lx-bg)",
          color: "var(--lx-text)",
          margin: isPhone ? 0 : "0 12px 12px",
          borderRadius: isPhone ? "22px 22px 0 0" : 30,
          padding: isPhone ? 12 : "22px 24px 24px",
        }}
      >
        {devices === null ? (
          <SkeletonGrid count={8} columns={isPhone ? 1 : 4} />
        ) : total === 0 ? (
          <EmptyState
            title="Belum ada perangkat terdaftar"
            description="Daftarkan workstation lewat tab Perangkat agar muncul di layar ini."
          />
        ) : (
          <>
            {/* ---- Bento ---- */}
            <div style={{ display: "grid", gridTemplateColumns: bentoColumns, gap }}>
              <Card padding="20px 24px 22px" className="lx-rise" style={{ gridColumn: bentoSpan(4, 1), "--i": 0 } as CSSProperties}>
                <CardTitle>Stasiun dipakai</CardTitle>
                <SegmentGauge segments={stations.map((s) => s.status)}>
                  <BigNumber value={inUse} size={isPhone ? 50 : 66} suffix={`/${total}`} />
                  <div style={{ fontSize: isPhone ? 12.5 : 15, color: "var(--lx-muted)", marginTop: 6 }}>stasiun sedang dipakai</div>
                </SegmentGauge>
                <div style={{ display: "flex", flexWrap: "wrap", justifyContent: "center", gap: "8px 18px", marginTop: 18 }}>
                  {LEGEND.map((l) => (
                    <span
                      key={l.status}
                      style={{ display: "inline-flex", alignItems: "center", gap: 7, fontSize: isPhone ? 13 : 15, color: "var(--lx-muted)" }}
                    >
                      <StatusDot status={l.status} size={10} />
                      {l.label} <Mono style={{ color: "var(--lx-text)", fontWeight: 700 }}>{count(l.status)}</Mono>
                    </span>
                  ))}
                </div>
                {free.length > 0 && (
                  <div style={{ display: "flex", flexWrap: "wrap", justifyContent: "center", alignItems: "center", gap: 8, marginTop: 14 }}>
                    <span style={{ fontSize: isPhone ? 13 : 15, color: "var(--lx-muted)" }}>Bebas sekarang</span>
                    {free.map((s) => (
                      <span
                        key={s.hostname}
                        className="lx-mono lx-anim-tag"
                        style={{
                          fontSize: isPhone ? 13 : 15,
                          fontWeight: 700,
                          padding: "5px 12px",
                          borderRadius: "var(--lx-radius-pill)",
                          ...PILL.idle,
                        }}
                      >
                        {s.id}
                      </span>
                    ))}
                  </div>
                )}
              </Card>

              <Card padding="20px 24px 22px" className="lx-rise" style={{ gridColumn: bentoSpan(5, 2), "--i": 1 } as CSSProperties}>
                <CardTitle>Jam pakai hari ini</CardTitle>
                {spans === "unavailable" ? (
                  <div style={{ fontSize: 15, color: "var(--lx-muted)" }}>Riwayat sesi tidak tersedia untuk akun ini.</div>
                ) : usage ? (
                  <>
                    <div style={{ display: "flex", alignItems: "flex-end", gap: 16, flexWrap: "wrap", marginBottom: 18 }}>
                      <BigNumber value={usage.todayHours} decimals={1} size={isPhone ? 50 : 66} suffix="jam" />
                      <Delta percent={usage.delta} caption="vs kemarin di jam yang sama" />
                    </div>
                    <WeekBars days={usage.days} height={isPhone ? 130 : 128} />
                    <div style={{ display: "flex", gap: 24, marginTop: 14, fontSize: isPhone ? 13 : 15, color: "var(--lx-muted)" }}>
                      <span>
                        <Mono style={{ color: "var(--lx-text)", fontWeight: 700 }}>{usage.sessionsToday}</Mono> sesi
                      </span>
                      <span>
                        <Mono style={{ color: "var(--lx-text)", fontWeight: 700 }}>{usage.peopleToday}</Mono> pengguna
                      </span>
                    </div>
                  </>
                ) : (
                  <div style={{ fontSize: 15, color: "var(--lx-muted)" }}>Memuat riwayat sesi...</div>
                )}
              </Card>

              <Card
                padding="20px 24px 22px"
                className="lx-rise"
                style={{ gridColumn: bentoSpan(3, 1), "--i": 2, display: "flex", flexDirection: "column" } as CSSProperties}
              >
                <CardTitle>Denyut jaringan</CardTitle>
                <div style={{ flex: 1, display: "flex", alignItems: "center" }}>
                  <FleetDial
                    dots={stations.map((s) => {
                      const beats = beatsRef.current.get(s.hostname) ?? [];
                      return {
                        hostname: s.id,
                        isOnline: s.status !== "offline",
                        beatKey: beats.length ? String(beats[beats.length - 1]) : "",
                      };
                    })}
                  >
                    <BigNumber value={onlineCount} size={isPhone ? 44 : 54} />
                    <div style={{ fontSize: 13, opacity: 0.7, marginTop: 4 }}>online dari {total}</div>
                  </FleetDial>
                </div>
                <div style={{ textAlign: "center", fontSize: isPhone ? 13 : 15, color: "var(--lx-muted)", marginTop: 14 }}>
                  {beatAgo === null ? (
                    "menunggu denyut..."
                  ) : (
                    <>
                      denyut terakhir <Mono style={{ color: "var(--lx-text)" }}>{beatAgo}</Mono> dtk lalu
                    </>
                  )}
                </div>
              </Card>
            </div>

            {/* ---- Stations ---- */}
            <div
              style={{
                flex: 1,
                display: "grid",
                gap,
                gridTemplateColumns: `repeat(${cols}, minmax(0, 1fr))`,
                gridAutoRows: `minmax(${Math.round(210 * scale)}px, 1fr)`,
              }}
            >
              {stations.map((s, i) => (
                <StationTile
                  key={s.hostname}
                  s={s}
                  beats={beatsRef.current.get(s.hostname) ?? []}
                  isNameVisible={hideNames === false}
                  scale={scale}
                  index={i + 3}
                />
              ))}
            </div>
          </>
        )}
      </main>
    </div>
  );
}
