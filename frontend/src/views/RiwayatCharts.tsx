// Page-local charts for Riwayat, drawn in the same hand as ui/viz.tsx: pill
// bars on a sunken tray, ink value tags, lime for the one thing that leads,
// hatching for "no data here". Divs and SVG only -- no chart library.
import { Fragment, useState, type CSSProperties, type ReactNode } from "react";

import { useCountUp } from "../ui/hooks";
import { DAYS_LONG, DAYS_SHORT, hoursText, pad, type Bar, type HeatMap, type Ranked } from "./RiwayatAnalysis";

const stationsText = (v: number) => v.toLocaleString("id-ID", { maximumFractionDigits: 1 });

const TAG: CSSProperties = {
  position: "absolute",
  whiteSpace: "nowrap",
  fontSize: 10.5,
  fontWeight: 700,
  padding: "3px 8px",
  borderRadius: 999,
  background: "var(--lx-ink)",
  color: "var(--lx-on-ink)",
  zIndex: 5,
  pointerEvents: "none",
};

/** Keeps a tag on an edge bar inside the card instead of hanging off it. */
const tagAlign = (i: number, n: number): CSSProperties =>
  i < n * 0.2 ? { left: 0 } : i >= n * 0.8 ? { right: 0 } : { left: "50%", transform: "translateX(-50%)" };

// ---------------------------------------------------------------------------
// Pill bars, for the hours trend (hour / day / week / month buckets) and the
// session-length histogram. Monitoring's WeekBars in the same hand, plus what
// 24-31 bars need: thinned axis labels, tags kept inside the card, and an
// optional dashed average. The lead bar is lime and carries the ink tag until
// another bar is hovered.

export const PillBars = ({
  bars,
  average = 0,
  height = 150,
  maxLabels = 10,
}: {
  bars: Bar[];
  average?: number;
  height?: number;
  maxLabels?: number;
}) => {
  const [hover, setHover] = useState<number | null>(null);
  const n = bars.length;
  const max = Math.max(...bars.map((b) => b.value), average, 0.001);
  const current = bars.findIndex((b) => b.isLead);
  const tagAt = hover ?? current;
  const gap = n <= 8 ? 8 : n <= 16 ? 5 : 3;
  const labelEvery = Math.max(1, Math.ceil(n / maxLabels));
  // Long periods would stagger for over a second; squeeze the wave instead.
  const stagger = Math.min(1, 14 / Math.max(n, 1));
  const avgPct = (average / max) * 100;

  return (
    <div
      style={{ background: "var(--lx-sunken)", borderRadius: 18, padding: "34px 12px 10px" }}
      onMouseLeave={() => setHover(null)}
    >
      <div style={{ position: "relative", height, display: "grid", gridTemplateColumns: `repeat(${n}, minmax(0, 1fr))`, gap }}>
        {average > 0 && (
          <div
            aria-hidden="true"
            style={{
              position: "absolute",
              left: 0,
              right: 0,
              bottom: `${avgPct}%`,
              borderTop: "1px dashed var(--lx-muted)",
              opacity: 0.55,
              pointerEvents: "none",
            }}
          >
            <span
              className="lx-mono"
              style={{ position: "absolute", left: 0, bottom: 3, fontSize: 10, color: "var(--lx-muted)", whiteSpace: "nowrap" }}
            >
              rata-rata {hoursText(average)}
            </span>
          </div>
        )}
        {bars.map((b, i) => {
          const pct = b.value > 0 ? Math.max(5, (b.value / max) * 100) : 4;
          return (
            <div
              key={b.key}
              onMouseEnter={() => setHover(i)}
              style={{ position: "relative", display: "flex", justifyContent: "center", minWidth: 0 }}
            >
              <div
                className={`lx-grow-y${b.value > 0 ? "" : " lx-hatch"}`}
                style={
                  {
                    "--i": i * stagger,
                    position: "absolute",
                    bottom: 0,
                    width: "min(100%, 22px)",
                    height: `${pct}%`,
                    borderRadius: 999,
                    opacity: b.isFuture ? 0.45 : 1,
                    background: b.isLead
                      ? "var(--lx-accent)"
                      : i === hover
                        ? "var(--lx-ink)"
                        : b.value > 0
                          ? "var(--lx-hatch)"
                          : undefined,
                    transition: "background-color var(--lx-motion) var(--lx-ease)",
                  } as CSSProperties
                }
              />
              {i === tagAt && (
                <span
                  key={`tag-${i}`}
                  className="lx-mono lx-anim-tag"
                  style={{ ...TAG, bottom: `calc(${pct}% + 6px)`, ...tagAlign(i, n) }}
                >
                  {b.tag}
                </span>
              )}
            </div>
          );
        })}
      </div>
      <div style={{ display: "grid", gridTemplateColumns: `repeat(${n}, minmax(0, 1fr))`, gap, marginTop: 7 }}>
        {bars.map((b, i) => {
          // Every labelEvery-th label, but never one crowding the lead's.
          const isShown =
            b.isLead || i === hover || (i % labelEvery === 0 && !(current >= 0 && Math.abs(i - current) < labelEvery));
          return (
            <span
              key={b.key}
              style={{
                fontSize: 10.5,
                textAlign: "center",
                whiteSpace: "nowrap",
                color: b.isLead ? "var(--lx-text)" : "var(--lx-muted)",
                fontWeight: b.isLead ? 650 : 400,
                visibility: isShown ? "visible" : "hidden",
              }}
            >
              {b.label}
            </span>
          );
        })}
      </div>
    </div>
  );
};

// ---------------------------------------------------------------------------
// Jam sibuk: weekday x hour occupancy. Each cell is how many stations were in
// use on average in that hour of that weekday across the period. The busiest
// cell is lime; an hour the period never contained is hatched.

const HEAT_MIX = [0, 16, 34, 56, 82];
const heatFill = (level: number) =>
  level === 0 ? "var(--lx-sunken)" : `color-mix(in srgb, var(--lx-ink) ${HEAT_MIX[level]}%, var(--lx-card))`;

export const HeatLegend = () => (
  <span style={{ display: "inline-flex", alignItems: "center", gap: 5, fontSize: 11.5, color: "var(--lx-muted)" }}>
    sepi
    {[0, 1, 2, 3, 4].map((l) => (
      <span key={l} style={{ width: 11, height: 11, borderRadius: 3, background: heatFill(l) }} />
    ))}
    ramai
    <span style={{ width: 11, height: 11, borderRadius: 3, background: "var(--lx-accent)", marginLeft: 4 }} />
    puncak
  </span>
);

export const HeatGrid = ({
  heat,
  stationCount,
  todayWeekday,
  isCompact = false,
}: {
  heat: HeatMap;
  stationCount: number;
  todayWeekday: number;
  isCompact?: boolean;
}) => {
  const [hover, setHover] = useState<{ day: number; hour: number } | null>(null);
  const hours: number[] = [];
  for (let h = heat.hourFrom; h <= heat.hourTo; h += 1) hours.push(h);
  const labelW = isCompact ? 30 : 38;
  const columns = `${labelW}px repeat(${hours.length}, minmax(0, 1fr))`;
  const gap = isCompact ? 2 : 4;
  const cellH = isCompact ? 20 : 26;
  const labelEvery = isCompact ? 3 : 2;
  const level = (v: number) => (v <= 0 || heat.max <= 0 ? 0 : Math.max(1, Math.min(4, Math.ceil((v / heat.max) * 4))));
  const share = (v: number) => (stationCount > 0 ? ` (${Math.round((v / stationCount) * 100)}%)` : "");

  return (
    // A weekday the period never reached ("Hari ini", a fresh week) is left
    // out rather than drawn as a row of hatching. The top padding is room for
    // the first row's tag.
    <div role="img" aria-label={peakSentence(heat, stationCount)} onMouseLeave={() => setHover(null)} style={{ paddingTop: 30 }}>
      <div style={{ display: "grid", gridTemplateColumns: columns, gap }}>
        {DAYS_SHORT.map((dayLabel, day) => heat.cells[day].every((v) => v === null) ? null : (
          <Fragment key={dayLabel}>
            <span
              style={{
                fontSize: 11.5,
                alignSelf: "center",
                color: day === todayWeekday ? "var(--lx-text)" : "var(--lx-muted)",
                fontWeight: day === todayWeekday ? 650 : 400,
              }}
            >
              {dayLabel}
            </span>
            {hours.map((h, i) => {
              const v = heat.cells[day][h];
              const isPeak = heat.peak !== null && heat.peak.day === day && heat.peak.hour === h;
              const isHover = hover?.day === day && hover.hour === h;
              return (
                <div
                  key={h}
                  style={{ position: "relative" }}
                  onMouseEnter={() => setHover({ day, hour: h })}
                >
                  <div
                    className={`lx-seg${v === null ? " lx-hatch" : ""}`}
                    style={
                      {
                        "--i": i * 0.45 + day * 0.35,
                        height: cellH,
                        borderRadius: isCompact ? 4 : 7,
                        background: v === null ? undefined : isPeak ? "var(--lx-accent)" : heatFill(level(v)),
                        boxShadow: isHover ? "0 0 0 1.5px var(--lx-ink)" : undefined,
                      } as CSSProperties
                    }
                  />
                  {isHover && (
                    <span className="lx-mono lx-anim-tag" style={{ ...TAG, bottom: "calc(100% + 6px)", ...tagAlign(i, hours.length) }}>
                      {v === null
                        ? `${DAYS_SHORT[day]} ${pad(h)}:00 · tidak ada di periode ini`
                        : `${DAYS_SHORT[day]} ${pad(h)}–${pad(h + 1)} · ${stationsText(v)} stasiun${share(v)}`}
                    </span>
                  )}
                </div>
              );
            })}
          </Fragment>
        ))}
        <span />
        {hours.map((h, i) => (
          <span
            key={h}
            className="lx-mono"
            style={{
              fontSize: 10,
              color: "var(--lx-muted)",
              textAlign: "center",
              marginTop: 4,
              visibility: i % labelEvery === 0 ? "visible" : "hidden",
            }}
          >
            {pad(h)}
          </span>
        ))}
      </div>
    </div>
  );
};

export const peakSentence = (heat: HeatMap, stationCount: number) => {
  if (!heat.peak) return "Belum ada pemakaian pada periode ini.";
  const { day, hour, value } = heat.peak;
  return `Paling ramai ${DAYS_LONG[day]} ${pad(hour)}:00–${pad(hour + 1)}:00, rata-rata ${stationsText(value)} dari ${stationCount} stasiun dipakai.`;
};

// ---------------------------------------------------------------------------
// Station bars: one row per station, the leader in lime, a hatched track for
// a station nobody used. Each row is a button that filters the log below to
// that station (pressing the selected one again clears it).

export const RankBars = ({
  rows,
  selectedKey,
  onSelect,
}: {
  rows: Ranked[];
  selectedKey: string;
  onSelect: (row: Ranked) => void;
}) => {
  const max = Math.max(...rows.map((r) => r.hours), 0.001);
  return (
    <div style={{ display: "grid", gap: 2 }}>
      {rows.map((r, i) => {
        const isEmpty = r.hours <= 0 && r.sessions === 0;
        const isSelected = selectedKey.toUpperCase() === r.key.toUpperCase();
        const pct = r.hours > 0 ? Math.max(3, (r.hours / max) * 100) : 0;
        return (
          <button
            key={r.key}
            type="button"
            className="lx-tap lx-row-hover"
            aria-pressed={isSelected}
            title={`Tampilkan sesi di ${r.label}`}
            onClick={() => onSelect(r)}
            style={{
              display: "grid",
              gridTemplateColumns: "64px minmax(0, 1fr) 118px",
              alignItems: "center",
              gap: 12,
              padding: "7px 10px",
              borderRadius: 12,
              font: "inherit",
              width: "100%",
              textAlign: "left",
              border: "none",
              color: "var(--lx-text)",
              cursor: "pointer",
              background: isSelected ? "var(--lx-sunken)" : "transparent",
              boxShadow: isSelected ? "inset 0 0 0 1.5px var(--lx-ink)" : undefined,
            }}
          >
            <span className="lx-mono" style={{ fontSize: 12.5, fontWeight: 650, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>
              {r.label}
            </span>
            <span
              className={isEmpty ? "lx-hatch" : undefined}
              style={{ position: "relative", height: 12, borderRadius: 999, background: isEmpty ? undefined : "var(--lx-sunken)", overflow: "hidden" }}
            >
              {pct > 0 && (
                <span
                  className="lx-grow-x"
                  style={
                    {
                      "--i": i,
                      position: "absolute",
                      inset: 0,
                      width: `${pct}%`,
                      borderRadius: 999,
                      background: i === 0 ? "var(--lx-accent)" : "var(--lx-ink)",
                    } as CSSProperties
                  }
                />
              )}
            </span>
            <span style={{ fontSize: 12, color: "var(--lx-muted)", whiteSpace: "nowrap", textAlign: "right" }}>
              {isEmpty ? (
                "tidak dipakai"
              ) : (
                <>
                  <span className="lx-mono" style={{ color: "var(--lx-text)", fontWeight: 600 }}>
                    {hoursText(r.hours)}
                  </span>{" "}
                  · <span className="lx-mono">{r.sessions}</span> sesi
                </>
              )}
            </span>
          </button>
        );
      })}
    </div>
  );
};

// ---------------------------------------------------------------------------
// Share: one pill split by share of hours, and the legend under it. Hovering
// either side lights up the same item on the other.

const SHARE_MIX = [100, 72, 52, 36, 24, 14];
const shareFill = (i: number) =>
  i === 0 ? "var(--lx-accent)" : `color-mix(in srgb, var(--lx-ink) ${SHARE_MIX[Math.min(i, SHARE_MIX.length - 1)]}%, var(--lx-card))`;

export const ShareBreakdown = ({ rows, total }: { rows: Ranked[]; total: number }) => {
  const [hover, setHover] = useState<number | null>(null);
  const dim = (i: number) => (hover === null || hover === i ? 1 : 0.3);
  return (
    <div onMouseLeave={() => setHover(null)}>
      <div style={{ display: "flex", gap: 3, height: 16, marginBottom: 16 }}>
        {rows.map((r, i) => (
          <span
            key={r.key}
            className="lx-grow-x"
            onMouseEnter={() => setHover(i)}
            style={
              {
                "--i": i * 2,
                flex: `${Math.max(r.hours, total * 0.004)} 1 0`,
                minWidth: 4,
                borderRadius: 999,
                background: shareFill(i),
                opacity: dim(i),
                transition: "opacity var(--lx-motion) var(--lx-ease)",
              } as CSSProperties
            }
          />
        ))}
      </div>
      <div style={{ display: "grid" }}>
        {rows.map((r, i) => (
          <div
            key={r.key}
            onMouseEnter={() => setHover(i)}
            style={{
              display: "grid",
              gridTemplateColumns: "10px minmax(0, 1fr) auto 64px 42px",
              alignItems: "center",
              gap: 10,
              padding: "7px 0",
              borderTop: i === 0 ? undefined : "1px solid var(--lx-hairline)",
              fontSize: 13,
              opacity: hover === null || hover === i ? 1 : 0.55,
              transition: "opacity var(--lx-motion) var(--lx-ease)",
            }}
          >
            <span style={{ width: 10, height: 10, borderRadius: 999, background: shareFill(i) }} />
            <span style={{ minWidth: 0, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{r.label}</span>
            <span style={{ fontSize: 12, color: "var(--lx-muted)", whiteSpace: "nowrap" }}>
              <span className="lx-mono">{r.sessions}</span> sesi
            </span>
            <span className="lx-mono" style={{ fontSize: 12.5, textAlign: "right" }}>
              {hoursText(r.hours)}
            </span>
            <span className="lx-mono" style={{ fontSize: 12.5, fontWeight: 700, textAlign: "right" }}>
              {total > 0 ? Math.round((r.hours / total) * 100) : 0}%
            </span>
          </div>
        ))}
      </div>
    </div>
  );
};

// ---------------------------------------------------------------------------
// Split bar: a thin segmented pill for a small categorical split (access
// types), leader in lime.

export const SplitBar = ({ parts }: { parts: { key: string; label: string; count: number }[] }) => {
  const total = parts.reduce((sum, p) => sum + p.count, 0);
  if (total === 0) return <div className="lx-hatch" style={{ height: 10, borderRadius: 999 }} />;
  return (
    <div>
      <div style={{ display: "flex", gap: 3, height: 10 }}>
        {parts.map((p, i) => (
          <span
            key={p.key}
            className="lx-grow-x"
            title={`${p.label}: ${p.count}`}
            style={{ "--i": i * 3, flex: `${p.count} 1 0`, minWidth: 4, borderRadius: 999, background: shareFill(i) } as CSSProperties}
          />
        ))}
      </div>
      <div style={{ display: "flex", flexWrap: "wrap", gap: "4px 12px", marginTop: 9 }}>
        {parts.map((p, i) => (
          <span key={p.key} style={{ display: "inline-flex", alignItems: "center", gap: 6, fontSize: 12, color: "var(--lx-muted)" }}>
            <span style={{ width: 8, height: 8, borderRadius: 999, background: shareFill(i) }} />
            {p.label}
            <span className="lx-mono" style={{ color: "var(--lx-text)" }}>
              {p.count}
            </span>
          </span>
        ))}
      </div>
    </div>
  );
};

// ---------------------------------------------------------------------------
// Data dial, for the ink card: the share of the period's hours that come from
// sessions observed end to end (closed by a real event, not inferred, not
// capped, not still running).

export const DataDial = ({ fraction, children }: { fraction: number | null; children?: ReactNode }) => {
  const shown = useCountUp(fraction ?? 0);
  const r = 70;
  const circ = 2 * Math.PI * r;
  return (
    <div style={{ position: "relative", width: "100%", maxWidth: 150, aspectRatio: "1", margin: "0 auto" }}>
      <svg viewBox="0 0 200 200" style={{ position: "absolute", inset: 0, width: "100%", height: "100%" }} aria-hidden="true">
        <circle cx="100" cy="100" r={r} fill="none" stroke="currentColor" strokeOpacity="0.14" strokeWidth="14" />
        {fraction !== null && (
          <circle
            cx="100"
            cy="100"
            r={r}
            fill="none"
            stroke="var(--lx-accent)"
            strokeWidth="14"
            strokeLinecap="round"
            strokeDasharray={`${shown * circ} ${circ}`}
            transform="rotate(-90 100 100)"
          />
        )}
      </svg>
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
