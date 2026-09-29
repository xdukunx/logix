// Wall / TV mode -- Monitoring for a screen on the lab wall. v4 "Denyut".
//
// Read-only by construction: nothing here is focusable or clickable, and there
// is no nav and no menu. It keeps what reads from across a room -- a large
// clock, how full the lab is, and one large tile per station carrying its live
// heartbeat trace -- and it is always dark. User names can be hidden from
// Settings > Privasi. Reachable at #wall.
//
// Data comes from ../lab: /api/devices merged with /api/active, plus
// today's usage from /api/sessions/spans as TOTALS only -- no name or purpose
// from a span ever reaches this screen. A beat is a last_seen we saw MOVE
// between two polls of /api/active, so a flat trace is a machine that has
// genuinely gone quiet.
import { useLayoutEffect, useMemo, useRef, useState, type CSSProperties, type ReactNode } from "react";

import { getJson } from "../api";
import Wordmark from "../components/Wordmark";
import { useThemeMode } from "../theme/ThemeMode";
import { ACCESS_LABEL, resolveAccessType } from "../tokens";
import type { LogixConfig } from "../types";
import { Card, EmptyState, Mono, SkeletonGrid, StatusDot } from "../ui/base";
import { useBreakpoint } from "../ui/hooks";
import { BigNumber, CardTitle, Delta, EcgTrace, FleetDial, SegmentGauge, WeekBars } from "../ui/viz";
import { durationSince, formatClock, formatSince, usePolling, useTicker } from "../util";
import {
  BEAT_WINDOW_MS,
  LAB_STATUSES,
  LAB_STATUS_LABEL,
  mergeStations,
  pad,
  useLabLive,
  weekUsage,
  type LabStation,
  type LabStatus,
} from "../lab";

// Five missed polls of /api/active before the header admits the board is stale.
const STALE_MS = 15_000;
// A tile's natural height at scale 1 (padding, ID, spec, label, value and the
// zoomed trace). Every size in a tile is multiplied by `scale`, so the height
// it needs is TILE_HEIGHT * scale -- which is how the rows are fitted below.
const TILE_HEIGHT = 240;
// Below this a tile no longer reads from across the room; past it the station
// grid scrolls instead of shrinking further.
const MIN_SCALE = 0.6;

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

const PILL: Record<LabStatus, CSSProperties> = {
  active: { background: "var(--lx-accent)", color: "var(--lx-on-accent)" },
  locked: { background: "var(--lx-ink)", color: "var(--lx-on-ink)" },
  idle: { boxShadow: "inset 0 0 0 2px var(--lx-text)", color: "var(--lx-text)" },
  offline: { border: "1.5px dashed var(--lx-border-dashed)", color: "var(--lx-muted)" },
};

const clip: CSSProperties = { overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap", minWidth: 0 };

const StationTile = ({
  s,
  beats,
  isNameVisible,
  scale,
  index,
}: {
  s: LabStation;
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
    // With the day, as the offline tile has: a lock from yesterday must not
    // read as a time later today.
    value = formatSince(since);
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
          {LAB_STATUS_LABEL[s.status]}
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

  // A wall display must not show an error card: every failed poll keeps the
  // last good board, and the header says when that board went stale.
  const { devices, active, spans, liveAt, lastBeatAt, beatsOf } = useLabLive();
  // null until /api/config has answered. Names stay hidden until then: the
  // old default of showing them flashed every name onto the room-facing
  // screen for as long as the config took to arrive, even with hiding on.
  const [hideNames, setHideNames] = useState<boolean | null>(null);
  const [labName, setLabName] = useState("Lab Komputasi FTMM");
  // The station grid's own height on desktop, where it takes whatever the
  // header and bento leave of the screen.
  const [gridEl, setGridEl] = useState<HTMLDivElement | null>(null);
  const [gridHeight, setGridHeight] = useState<number | null>(null);

  // The clock, durations and "x dtk lalu" are live.
  useTicker(1000);

  usePolling(async () => {
    try {
      const config = await getJson<LogixConfig>("/api/config", "");
      setHideNames(Boolean(config.privacy?.hide_names_on_wall));
      if (config.branding?.subtitle) setLabName(String(config.branding.subtitle));
    } catch {
      /* keep defaults */
    }
  }, 15000);

  useLayoutEffect(() => {
    if (!gridEl) return;
    const observer = new ResizeObserver(() => setGridHeight(gridEl.clientHeight));
    observer.observe(gridEl);
    return () => observer.disconnect();
  }, [gridEl]);

  const stations = useMemo(() => (devices ? mergeStations(devices, active) : []), [devices, active]);

  const count = (status: LabStatus) => stations.filter((s) => s.status === status).length;
  const total = stations.length;
  const inUse = count("active");
  const onlineCount = stations.filter((s) => s.status !== "offline").length;
  const free = stations.filter((s) => s.status === "idle");

  // ---- Usage, from the last 7 days of session spans (totals only) ----
  const now = Date.now();
  // `now` moves every second; the week only needs recomputing when data does,
  // or once a minute so an open session keeps adding up.
  const minute = Math.floor(now / 60000);
  const usage = useMemo(() => (Array.isArray(spans) ? weekUsage(spans, now) : null), [spans, minute]);

  // ---- Layout ----
  // Tiles are balanced into rows (8 stations = 4 + 4, never 6 + 2). On
  // desktop -- the wall TV -- the page is exactly one screen tall and tiles
  // shrink until their rows fit the height the bento leaves, so the whole lab
  // is on screen without scrolling.
  const maxCols = isDesktop ? (total <= 8 ? 4 : total <= 15 ? 5 : 6) : breakpoint === "tablet" ? 2 : 1;
  const rows = Math.max(1, Math.ceil(total / maxCols));
  const cols = Math.max(1, Math.ceil(total / rows));
  const gap = isPhone ? 10 : 18;
  const byCount = isPhone ? 0.78 : total <= 8 ? 1 : total <= 15 ? 0.84 : 0.7;
  const byHeight = isDesktop && gridHeight ? (gridHeight - (rows - 1) * gap) / rows / TILE_HEIGHT : byCount;
  const scale = Math.max(MIN_SCALE, Math.min(byCount, byHeight));
  const bentoColumns = isDesktop ? "repeat(12, 1fr)" : breakpoint === "tablet" ? "1fr 1fr" : "1fr";
  const bentoSpan = (desktop: number, tablet: number) =>
    isDesktop ? `span ${desktop}` : breakpoint === "tablet" ? `span ${tablet}` : undefined;

  const clockNow = new Date(now);
  const dateLabel = clockNow.toLocaleDateString("id-ID", { weekday: "long", day: "numeric", month: "long", year: "numeric" });
  const liveState = liveAt === null ? "connecting" : now - liveAt > STALE_MS ? "stale" : "live";
  const beatAgo = lastBeatAt ? Math.max(0, Math.round((now - lastBeatAt) / 1000)) : null;

  return (
    <div
      style={{
        ...(isDesktop ? { height: "100dvh" } : { minHeight: "100dvh" }),
        display: "flex",
        flexDirection: "column",
        background: "var(--lx-frame)",
      }}
    >
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
          minHeight: 0,
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
                  {LAB_STATUSES.map((status) => (
                    <span
                      key={status}
                      style={{ display: "inline-flex", alignItems: "center", gap: 7, fontSize: isPhone ? 13 : 15, color: "var(--lx-muted)" }}
                    >
                      <StatusDot status={status} size={10} />
                      {LAB_STATUS_LABEL[status]} <Mono style={{ color: "var(--lx-text)", fontWeight: 700 }}>{count(status)}</Mono>
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
                        <Mono style={{ color: "var(--lx-text)", fontWeight: 700 }}>{usage.todaySpans.length}</Mono> sesi
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
                      const beats = beatsOf(s.hostname);
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
              ref={setGridEl}
              style={{
                flex: 1,
                minHeight: 0,
                // Only past MIN_SCALE: a lab too big for the screen scrolls
                // here, inside the canvas, rather than shrinking unreadably.
                overflowY: isDesktop ? "auto" : undefined,
                display: "grid",
                gap,
                gridTemplateColumns: `repeat(${cols}, minmax(0, 1fr))`,
                gridAutoRows: `minmax(${Math.round(TILE_HEIGHT * scale)}px, 1fr)`,
              }}
            >
              {stations.map((s, i) => (
                <StationTile
                  key={s.hostname}
                  s={s}
                  beats={beatsOf(s.hostname)}
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
