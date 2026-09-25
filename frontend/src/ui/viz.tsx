// Data visualisations for the v4 "Denyut" bento dashboard: the station gauge,
// the week bars, the fleet dial, the session timeline (Pita Waktu) and the
// per-station heartbeat trace. SVG + CSS only -- no chart library; React is
// still the only runtime dependency.
//
// Everything that moves is driven by real data: a spike on a trace is a
// heartbeat that was actually observed, a breathing bar is a session that is
// actually open. See the motion rules in tokens.css.
import { useId, useLayoutEffect, useRef, useState, type CSSProperties, type ReactNode } from "react";

import type { StationStatus } from "../tokens";
import { useCountUp } from "./hooks";

/** Bento card title row: a label, optional right-hand control. */
export const CardTitle = ({ children, action }: { children: ReactNode; action?: ReactNode }) => (
  <div style={{ display: "flex", alignItems: "center", gap: 10, marginBottom: 14 }}>
    <span style={{ fontSize: 15, fontWeight: 550, letterSpacing: "-0.01em" }}>{children}</span>
    {action && <span style={{ marginLeft: "auto" }}>{action}</span>}
  </div>
);

/** A number that counts up to its value when it changes. */
export const BigNumber = ({
  value,
  decimals = 0,
  size = 52,
  suffix,
}: {
  value: number;
  decimals?: number;
  size?: number;
  suffix?: ReactNode;
}) => {
  const shown = useCountUp(value);
  return (
    <span className="lx-big" style={{ fontSize: size }}>
      {shown.toLocaleString("id-ID", { minimumFractionDigits: decimals, maximumFractionDigits: decimals })}
      {suffix && <span style={{ fontSize: size * 0.42, color: "var(--lx-muted)", marginLeft: 4 }}>{suffix}</span>}
    </span>
  );
};

/** The small ↗ / ↘ change pill beside a big number. */
export const Delta = ({ percent, caption }: { percent: number | null; caption: string }) => {
  if (percent === null || !Number.isFinite(percent)) return null;
  const isUp = percent >= 0;
  return (
    <span style={{ display: "inline-flex", alignItems: "center", gap: 7, fontSize: 12, color: "var(--lx-muted)" }}>
      <span
        className="lx-mono"
        style={{
          fontSize: 11,
          fontWeight: 700,
          padding: "3px 8px",
          borderRadius: 999,
          background: isUp ? "var(--lx-accent)" : "var(--lx-ink)",
          color: isUp ? "var(--lx-on-accent)" : "var(--lx-on-ink)",
        }}
      >
        {isUp ? "↗" : "↘"} {Math.abs(percent).toFixed(0)}%
      </span>
      {caption}
    </span>
  );
};

// ---------------------------------------------------------------------------
// Station gauge: one rounded segment per enrolled station, fanned over a
// half circle (the "Sales Goals" arc from the reference board).

const SEGMENT_FILL: Record<StationStatus, string> = {
  active: "var(--lx-accent)",
  locked: "var(--lx-ink)",
  idle: "var(--lx-sunken)",
  offline: "hatch",
  alert: "var(--lx-status-alert)",
};

export const SegmentGauge = ({ segments, children }: { segments: StationStatus[]; children?: ReactNode }) => {
  const patternId = useId();
  const W = 320;
  const cx = 160;
  const cy = 170;
  const outer = 150;
  const depth = 50;
  const n = Math.max(segments.length, 1);
  const midArc = Math.PI * (outer - depth / 2);
  // Segments fill most of their slot so a small lab still reads as one arc,
  // not a scatter of pills; a large lab thins them out instead of overlapping.
  const segW = Math.max(4, Math.min(56, (midArc / n) * 0.84));
  return (
    <div style={{ position: "relative", width: "100%", maxWidth: 380, margin: "0 auto" }}>
      <svg viewBox={`0 0 ${W} 176`} width="100%" style={{ display: "block", overflow: "visible" }} aria-hidden="true">
        <defs>
          <pattern id={patternId} width="7" height="7" patternUnits="userSpaceOnUse" patternTransform="rotate(45)">
            <rect width="7" height="7" fill="var(--lx-sunken)" />
            <line x1="0" y1="0" x2="0" y2="7" stroke="var(--lx-hatch)" strokeWidth="3" />
          </pattern>
        </defs>
        {segments.map((status, i) => {
          const angle = -90 + (180 * (i + 0.5)) / n;
          const fill = SEGMENT_FILL[status] === "hatch" ? `url(#${patternId})` : SEGMENT_FILL[status];
          return (
            <g key={i} transform={`rotate(${angle} ${cx} ${cy})`}>
              <rect
                className="lx-seg"
                style={{ "--i": i } as CSSProperties}
                x={cx - segW / 2}
                y={cy - outer}
                width={segW}
                height={depth}
                rx={Math.min(segW / 2, 11)}
                fill={fill}
                stroke={status === "idle" ? "var(--lx-border)" : "none"}
              />
            </g>
          );
        })}
      </svg>
      <div style={{ position: "absolute", left: 0, right: 0, bottom: 0, textAlign: "center" }}>{children}</div>
    </div>
  );
};

// ---------------------------------------------------------------------------
// Week bars: hours per day, today in accent with the ink value tag riding on
// top; hovering another day moves the tag to it.

export interface DayBar {
  key: string;
  label: string;
  value: number;
  tag: string;
  isToday: boolean;
}

export const WeekBars = ({ days, height = 150 }: { days: DayBar[]; height?: number }) => {
  const [hover, setHover] = useState<number | null>(null);
  const max = Math.max(...days.map((d) => d.value), 0.001);
  const tagAt = hover ?? days.findIndex((d) => d.isToday);
  return (
    <div
      style={{
        display: "grid",
        gridTemplateColumns: `repeat(${days.length}, 1fr)`,
        gap: 8,
        height,
        background: "var(--lx-sunken)",
        borderRadius: 18,
        padding: "34px 12px 10px",
      }}
      onMouseLeave={() => setHover(null)}
    >
      {days.map((d, i) => {
        const pct = d.value > 0 ? Math.max(6, (d.value / max) * 100) : 4;
        return (
          <div
            key={d.key}
            onMouseEnter={() => setHover(i)}
            style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: 6, minWidth: 0 }}
          >
            <div style={{ position: "relative", flex: 1, width: "100%", display: "flex", justifyContent: "center" }}>
              <div
                className={`lx-grow-y${d.value > 0 ? "" : " lx-hatch"}`}
                style={{
                  "--i": i,
                  position: "absolute",
                  bottom: 0,
                  width: "min(100%, 22px)",
                  height: `${pct}%`,
                  borderRadius: 999,
                  background: d.isToday
                    ? "var(--lx-accent)"
                    : i === hover
                      ? "var(--lx-ink)"
                      : d.value > 0
                        ? "var(--lx-hatch)"
                        : undefined,
                  transition: "background-color var(--lx-motion) var(--lx-ease)",
                } as CSSProperties}
              />
              {i === tagAt && (
                <span
                  key={`tag-${i}`}
                  className="lx-mono lx-anim-tag"
                  style={{
                    position: "absolute",
                    bottom: `calc(${pct}% + 6px)`,
                    whiteSpace: "nowrap",
                    fontSize: 10.5,
                    fontWeight: 700,
                    padding: "3px 8px",
                    borderRadius: 999,
                    background: "var(--lx-ink)",
                    color: "var(--lx-on-ink)",
                  }}
                >
                  {d.tag}
                </span>
              )}
            </div>
            <span style={{ fontSize: 11, color: d.isToday ? "var(--lx-text)" : "var(--lx-muted)", fontWeight: d.isToday ? 650 : 400 }}>
              {d.label}
            </span>
          </div>
        );
      })}
    </div>
  );
};

// ---------------------------------------------------------------------------
// Fleet dial: the black disc from the reference board. The arc is the share of
// stations online; each dot around the rim is one station, and it flashes the
// moment that station's heartbeat is observed.

export interface DialDot {
  hostname: string;
  isOnline: boolean;
  /** Changes whenever a new heartbeat from this station is observed. */
  beatKey: string;
}

export const FleetDial = ({ dots, children }: { dots: DialDot[]; children?: ReactNode }) => {
  const online = dots.filter((d) => d.isOnline).length;
  const fraction = useCountUp(dots.length ? online / dots.length : 0);
  const r = 70;
  const circ = 2 * Math.PI * r;
  return (
    <div
      style={{
        position: "relative",
        width: "100%",
        maxWidth: 230,
        aspectRatio: "1",
        margin: "0 auto",
        borderRadius: "50%",
        background: "var(--lx-ink)",
        color: "var(--lx-on-ink)",
      }}
    >
      <svg viewBox="0 0 200 200" style={{ position: "absolute", inset: 0, width: "100%", height: "100%" }} aria-hidden="true">
        <circle cx="100" cy="100" r={r} fill="none" stroke="currentColor" strokeOpacity="0.14" strokeWidth="9" />
        <circle
          cx="100"
          cy="100"
          r={r}
          fill="none"
          stroke="var(--lx-accent)"
          strokeWidth="9"
          strokeLinecap="round"
          strokeDasharray={`${fraction * circ} ${circ}`}
          transform="rotate(-90 100 100)"
        />
      </svg>
      {dots.map((d, i) => {
        const a = (i / Math.max(dots.length, 1)) * 2 * Math.PI - Math.PI / 2;
        return (
          <span
            key={`${d.hostname}-${d.beatKey}`}
            title={d.hostname}
            className={d.beatKey ? "lx-flash" : undefined}
            style={{
              position: "absolute",
              width: 7,
              height: 7,
              marginLeft: -3.5,
              marginTop: -3.5,
              left: `${50 + 44 * Math.cos(a)}%`,
              top: `${50 + 44 * Math.sin(a)}%`,
              borderRadius: 999,
              background: "currentColor",
              opacity: d.isOnline ? 1 : 0.22,
            }}
          />
        );
      })}
      <div
        style={{
          position: "absolute",
          inset: 0,
          display: "flex",
          flexDirection: "column",
          alignItems: "center",
          justifyContent: "center",
          textAlign: "center",
        }}
      >
        {children}
      </div>
    </div>
  );
};

// ---------------------------------------------------------------------------
// Heartbeat trace. One spike per heartbeat actually observed, entering at the
// right edge and travelling left across a fixed window. A station with no
// heartbeat in the window draws a flat line -- a flatline, literally.

const Spike = ({ at, windowMs, color }: { at: number; windowMs: number; color: string }) => {
  // Fixed at mount. Recomputing the (negative) delay on every render would
  // shift a running animation and make spikes jump.
  const [delay] = useState(() => -(Date.now() - at));
  if (-delay > windowMs) return null;
  return (
    <svg
      className="lx-travel"
      width="22"
      height="30"
      viewBox="0 0 22 30"
      style={{ position: "absolute", right: -22, top: 0, animationDelay: `${delay}ms` }}
      aria-hidden="true"
    >
      <path
        d="M0 15 H6 L8.5 5 L12 25 L14.5 15 H22"
        fill="none"
        stroke={color}
        strokeWidth="1.8"
        strokeLinejoin="round"
        strokeLinecap="round"
      />
    </svg>
  );
};

export const EcgTrace = ({
  beats,
  isFlat,
  windowMs = 60000,
}: {
  beats: number[];
  isFlat?: boolean;
  windowMs?: number;
}) => {
  const ref = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(240);
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setWidth(el.clientWidth));
    ro.observe(el);
    setWidth(el.clientWidth);
    return () => ro.disconnect();
  }, []);
  return (
    <div
      ref={ref}
      aria-hidden="true"
      style={{
        position: "relative",
        height: 30,
        overflow: "hidden",
        "--lx-trace-w": `${width}px`,
        "--lx-trace-s": `${windowMs}ms`,
        maskImage: "linear-gradient(90deg, transparent, #000 14%, #000)",
        WebkitMaskImage: "linear-gradient(90deg, transparent, #000 14%, #000)",
      } as CSSProperties}
    >
      <div
        style={{
          position: "absolute",
          left: 0,
          right: 0,
          top: 14.5,
          borderTop: isFlat ? "1.5px dashed var(--lx-border-dashed)" : "1.5px solid var(--lx-hairline)",
        }}
      />
      {!isFlat &&
        beats.map((t) => <Spike key={t} at={t} windowMs={windowMs} color="var(--lx-accent-text)" />)}
    </div>
  );
};

// ---------------------------------------------------------------------------
// Pita Waktu: today's sessions per station on one time axis, with the "now"
// line sweeping across and the hours still ahead hatched.

export interface TimelineSpan {
  start: number;
  end: number;
  isLive: boolean;
  label: string;
}

export interface TimelineRow {
  hostname: string;
  id: string;
  spans: TimelineSpan[];
}

const hourLabel = (t: number) => `${String(new Date(t).getHours()).padStart(2, "0")}:00`;
const clockLabel = (t: number) => {
  const d = new Date(t);
  return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
};

export const Timeline = ({
  rows,
  from,
  to,
  now,
  labelWidth = 70,
}: {
  rows: TimelineRow[];
  from: number;
  to: number;
  now: number;
  labelWidth?: number;
}) => {
  const [hover, setHover] = useState<{ row: number; span: number } | null>(null);
  const pct = (t: number) => Math.min(100, Math.max(0, ((t - from) / (to - from)) * 100));
  const nowPct = pct(now);
  const hours: number[] = [];
  const firstHour = new Date(from);
  firstHour.setMinutes(0, 0, 0);
  for (let t = firstHour.getTime() + 3600000; t < to; t += 3600000) hours.push(t);
  const step = hours.length > 12 ? 2 : 1;

  return (
    <div style={{ position: "relative" }}>
      {/* Hour axis */}
      <div style={{ display: "flex", marginBottom: 10 }}>
        <div style={{ width: labelWidth, flexShrink: 0 }} />
        <div style={{ position: "relative", flex: 1, height: 16 }}>
          {hours
            .filter((_, i) => i % step === 0)
            .map((t) => (
              <span
                key={t}
                className="lx-mono"
                style={{
                  position: "absolute",
                  left: `${pct(t)}%`,
                  transform: "translateX(-50%)",
                  fontSize: 10.5,
                  color: "var(--lx-muted)",
                }}
              >
                {hourLabel(t)}
              </span>
            ))}
        </div>
      </div>

      <div style={{ position: "relative" }}>
        {/* The hours still ahead, hatched, behind every row. */}
        <div
          className="lx-hatch"
          style={{
            position: "absolute",
            top: 0,
            bottom: 0,
            left: `calc(${labelWidth}px + (100% - ${labelWidth}px) * ${nowPct / 100})`,
            right: 0,
            borderRadius: 12,
            opacity: 0.7,
          }}
        />
        {rows.map((row, r) => (
          <div key={row.hostname} style={{ display: "flex", alignItems: "center", height: 30 }}>
            <span
              className="lx-mono"
              style={{ width: labelWidth, flexShrink: 0, fontSize: 12, fontWeight: 600, whiteSpace: "nowrap" }}
            >
              {row.id}
            </span>
            <div
              style={{
                position: "relative",
                flex: 1,
                height: 20,
                borderRadius: 999,
                background: "color-mix(in srgb, var(--lx-sunken) 70%, transparent)",
              }}
            >
              {row.spans.map((s, i) => {
                const left = pct(s.start);
                const width = Math.max(0.8, pct(s.end) - left);
                const isHover = hover?.row === r && hover.span === i;
                return (
                  <div
                    key={i}
                    className="lx-grow-x"
                    onMouseEnter={() => setHover({ row: r, span: i })}
                    onMouseLeave={() => setHover(null)}
                    style={{
                      "--i": r,
                      position: "absolute",
                      top: 2,
                      bottom: 2,
                      left: `${left}%`,
                      width: `${width}%`,
                      borderRadius: 999,
                      background: s.isLive ? "var(--lx-accent)" : "var(--lx-ink)",
                      opacity: s.isLive || isHover ? 1 : 0.82,
                      cursor: "default",
                    } as CSSProperties}
                  >
                    {s.isLive && (
                      <span
                        className="lx-breathe"
                        style={{
                          position: "absolute",
                          right: 3,
                          top: "50%",
                          width: 8,
                          height: 8,
                          marginTop: -4,
                          borderRadius: 999,
                          background: "var(--lx-on-accent)",
                        }}
                      />
                    )}
                    {isHover && (
                      <span
                        className="lx-anim-tag"
                        style={{
                          position: "absolute",
                          bottom: "calc(100% + 8px)",
                          left: "50%",
                          transform: "translateX(-50%)",
                          whiteSpace: "nowrap",
                          fontSize: 11.5,
                          padding: "5px 10px",
                          borderRadius: 999,
                          background: "var(--lx-ink)",
                          color: "var(--lx-on-ink)",
                          zIndex: 5,
                          pointerEvents: "none",
                        }}
                      >
                        {s.label}
                      </span>
                    )}
                  </div>
                );
              })}
            </div>
          </div>
        ))}

        {/* Now line + its time tag. */}
        <div
          style={{
            position: "absolute",
            top: -6,
            bottom: -4,
            left: `calc(${labelWidth}px + (100% - ${labelWidth}px) * ${nowPct / 100})`,
            width: 0,
            borderLeft: "1.5px solid var(--lx-text)",
            transition: "left 1s linear",
            pointerEvents: "none",
          }}
        >
          <span
            className="lx-mono"
            style={{
              position: "absolute",
              bottom: "100%",
              left: 0,
              transform: "translate(-50%, -2px)",
              fontSize: 10.5,
              fontWeight: 700,
              padding: "2px 7px",
              borderRadius: 999,
              background: "var(--lx-text)",
              color: "var(--lx-bg)",
              whiteSpace: "nowrap",
            }}
          >
            {clockLabel(now)}
          </span>
        </div>
      </div>
    </div>
  );
};
