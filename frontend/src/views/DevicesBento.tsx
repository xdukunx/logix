// Perangkat's bento row. Status armada: is every machine reporting in. Versi
// agent: is every machine on the fleet's newest build. Perlu perhatian: which
// ones need a look. Every count on these cards is also a registry filter.
import { useState, type CSSProperties, type ReactNode } from "react";

import type { Device, SyncStatus } from "../types";
import { Card, Mono, StatusDot } from "../ui/base";
import { BigNumber, CardTitle } from "../ui/viz";
import { timeAgo } from "../util";
import {
  SYNC_LABEL,
  SYNC_ORDER,
  SYNC_STATUS,
  byId,
  nameOf,
  reasonText,
  type Filter,
  type Issue,
  type VersionSummary,
} from "./DevicesModel";

const ATTENTION_LIMIT = 4;

/** How a sync status is painted: the same on a fleet cell and on its legend swatch. */
const syncFill = (s: SyncStatus): { className?: string; style: CSSProperties } => {
  if (s === "online") return { style: { backgroundColor: "var(--lx-accent)" } };
  if (s === "stale") return { style: { backgroundColor: "var(--lx-status-locked)" } };
  // backgroundColor, never the `background` shorthand: that would wipe the hatch.
  if (s === "offline") {
    return { className: "lx-hatch", style: { backgroundColor: "var(--lx-card)", boxShadow: "inset 0 0 0 1px var(--lx-hatch)" } };
  }
  return { style: { border: "1.5px dashed var(--lx-border-dashed)" } };
};

export const Swatch = ({ status }: { status: SyncStatus }) => {
  const fill = syncFill(status);
  return (
    <span
      aria-hidden="true"
      className={fill.className}
      style={{ width: 14, height: 8, borderRadius: 999, flexShrink: 0, ...fill.style }}
    />
  );
};

/** Mono pill in ink or lime: a version tag, a count, a hover label. */
export const Tag = ({
  tone = "ink",
  className,
  style,
  title,
  children,
}: {
  tone?: "ink" | "accent";
  className?: string;
  style?: CSSProperties;
  title?: string;
  children: ReactNode;
}) => (
  <span
    className={className ? `lx-mono ${className}` : "lx-mono"}
    title={title}
    style={{
      fontSize: 11,
      fontWeight: 700,
      padding: "3px 9px",
      borderRadius: 999,
      whiteSpace: "nowrap",
      background: tone === "ink" ? "var(--lx-ink)" : "var(--lx-accent)",
      color: tone === "ink" ? "var(--lx-on-ink)" : "var(--lx-on-accent)",
      ...style,
    }}
  >
    {children}
  </span>
);

export const ARROW = (
  <svg width="12" height="12" viewBox="0 0 12 12" aria-hidden="true">
    <path
      d="M3.5 8.5 L8.5 3.5 M4.5 3.5 H8.5 V7.5"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.6"
      strokeLinecap="round"
      strokeLinejoin="round"
    />
  </svg>
);

const cardStyle = (gridColumn: string | undefined, i: number, extra?: CSSProperties) =>
  ({ gridColumn, "--i": i, display: "flex", flexDirection: "column", ...extra }) as CSSProperties;

// ---------------------------------------------------------------------------

export const FleetCard = ({
  gridColumn,
  devices,
  updatedAt,
  selectedId,
  onSelect,
  filter,
  onFilter,
}: {
  gridColumn: string | undefined;
  devices: Device[];
  updatedAt: string | null;
  selectedId: string | null;
  onSelect: (d: Device) => void;
  filter: Filter | null;
  onFilter: (f: Filter) => void;
}) => {
  const [hover, setHover] = useState<string | null>(null);
  const cells = byId(devices);
  const hasLabels = cells.length <= 12;
  return (
    <Card padding="20px 22px" className="lx-rise" style={cardStyle(gridColumn, 0)}>
      <CardTitle
        action={
          updatedAt && (
            <span style={{ fontSize: 12, color: "var(--lx-muted)" }}>
              diperbarui <Mono>{timeAgo(updatedAt)}</Mono>
            </span>
          )
        }
      >
        Status armada
      </CardTitle>
      <div style={{ display: "flex", alignItems: "flex-end", gap: 12, flexWrap: "wrap", marginBottom: 16 }}>
        <BigNumber value={devices.filter((d) => d.currently_online).length} size={50} suffix={`/${devices.length}`} />
        <span style={{ fontSize: 12.5, color: "var(--lx-muted)", paddingBottom: 5 }}>perangkat online</span>
      </div>

      {/* One cell per enrolled device, in ID order. Hover names it; click opens it. */}
      <div
        onMouseLeave={() => setHover(null)}
        style={{
          display: "flex",
          justifyContent: "center",
          gap: cells.length > 24 ? 3 : 6,
          background: "var(--lx-sunken)",
          borderRadius: 18,
          padding: `32px 12px ${hasLabels ? 10 : 14}px`,
          height: hasLabels ? 124 : 112,
        }}
      >
        {cells.map((d, i) => {
          const { id } = nameOf(d);
          const isSelected = d.device_id === selectedId;
          const isHover = hover === d.device_id;
          const fill = syncFill(d.sync_status);
          return (
            <div
              key={d.device_id}
              style={{ flex: 1, maxWidth: 46, minWidth: 0, display: "flex", flexDirection: "column", alignItems: "center", gap: 6 }}
            >
              <button
                type="button"
                aria-label={`${id}: ${SYNC_LABEL[d.sync_status]}`}
                onMouseEnter={() => setHover(d.device_id)}
                onFocus={() => setHover(d.device_id)}
                onBlur={() => setHover(null)}
                onClick={() => onSelect(d)}
                className="lx-tap"
                style={{
                  position: "relative",
                  flex: 1,
                  width: "100%",
                  padding: 0,
                  border: "none",
                  background: "transparent",
                  cursor: "pointer",
                  transform: isHover ? "translateY(-3px)" : undefined,
                }}
              >
                <span
                  className={`lx-grow-y${fill.className ? ` ${fill.className}` : ""}`}
                  style={{
                    "--i": i,
                    position: "absolute",
                    inset: 0,
                    borderRadius: 10,
                    ...fill.style,
                    boxShadow: isSelected ? "0 0 0 2px var(--lx-sunken), 0 0 0 3.5px var(--lx-ink)" : fill.style.boxShadow,
                  } as CSSProperties}
                />
                {isHover && (
                  <Tag
                    className="lx-anim-tag"
                    style={{
                      position: "absolute",
                      bottom: "calc(100% + 7px)",
                      left: "50%",
                      transform: "translateX(-50%)",
                      fontSize: 10.5,
                      zIndex: 2,
                      pointerEvents: "none",
                    }}
                  >
                    {id} · {timeAgo(d.last_seen)}
                  </Tag>
                )}
              </button>
              {hasLabels && (
                <span
                  className="lx-mono"
                  style={{
                    fontSize: 10.5,
                    color: isSelected || isHover ? "var(--lx-text)" : "var(--lx-muted)",
                    fontWeight: isSelected ? 700 : 500,
                    whiteSpace: "nowrap",
                    overflow: "hidden",
                    maxWidth: "100%",
                  }}
                >
                  {id}
                </span>
              )}
            </div>
          );
        })}
      </div>

      <div style={{ display: "flex", flexWrap: "wrap", gap: 6, marginTop: 14 }}>
        {SYNC_ORDER.map((s) => {
          const n = devices.filter((d) => d.sync_status === s).length;
          const isActive = filter?.kind === "sync" && filter.value === s;
          const isEmpty = n === 0 && !isActive;
          return (
            <button
              key={s}
              type="button"
              className="lx-tap"
              aria-pressed={isActive}
              disabled={isEmpty}
              onClick={() => onFilter({ kind: "sync", value: s })}
              style={{
                font: "inherit",
                display: "inline-flex",
                alignItems: "center",
                gap: 7,
                fontSize: 12,
                padding: "5px 11px",
                borderRadius: 999,
                border: `1px solid ${isActive ? "transparent" : "var(--lx-border)"}`,
                background: isActive ? "var(--lx-pill-active-bg)" : "var(--lx-card)",
                color: isActive ? "var(--lx-pill-active-fg)" : "var(--lx-muted)",
                cursor: isEmpty ? "default" : "pointer",
                opacity: isEmpty ? 0.55 : 1,
              }}
            >
              <Swatch status={s} />
              {SYNC_LABEL[s]}
              <Mono style={{ color: isActive ? "inherit" : "var(--lx-text)", fontWeight: 600 }}>{n}</Mono>
            </button>
          );
        })}
      </div>
    </Card>
  );
};

// ---------------------------------------------------------------------------

export const VersionCard = ({
  gridColumn,
  versions,
  total,
  filter,
  onFilter,
}: {
  gridColumn: string | undefined;
  versions: VersionSummary;
  total: number;
  filter: Filter | null;
  onFilter: (f: Filter) => void;
}) => {
  const { rows, newest, outdated } = versions;
  return (
    <Card padding="20px 22px" className="lx-rise" style={cardStyle(gridColumn, 1)}>
      <CardTitle>Versi agent</CardTitle>
      <div style={{ display: "flex", alignItems: "flex-end", gap: 12, flexWrap: "wrap" }}>
        <span className="lx-big" style={{ fontSize: 50 }}>
          {newest ?? "-"}
        </span>
        {newest && (
          <Tag tone={outdated > 0 ? "ink" : "accent"} style={{ marginBottom: 6 }}>
            {outdated > 0 ? `↘ ${outdated} tertinggal` : "✓ semua terbaru"}
          </Tag>
        )}
      </div>
      <div style={{ fontSize: 12, color: "var(--lx-muted)", margin: "8px 0 16px" }}>
        {newest ? "versi terbaru yang terlihat di armada ini" : "belum ada perangkat yang melaporkan versi agent"}
      </div>

      <div style={{ marginTop: "auto", display: "grid", gap: 4 }}>
        {rows.map((r, i) => {
          const isActive = filter?.kind === "version" && filter.value === r.version;
          const isNewest = r.version !== null && r.version === newest;
          return (
            <button
              key={r.version ?? "?"}
              type="button"
              className="lx-tap"
              aria-pressed={isActive}
              aria-label={`${r.version ? `Versi ${r.version}` : "Versi belum dilaporkan"}: ${r.count} perangkat`}
              onClick={() => onFilter({ kind: "version", value: r.version })}
              style={{
                font: "inherit",
                display: "grid",
                gridTemplateColumns: "92px 1fr 30px",
                alignItems: "center",
                gap: 10,
                padding: "4px 0",
                border: "none",
                background: "transparent",
                color: "var(--lx-text)",
                textAlign: "left",
                cursor: "pointer",
              }}
            >
              {r.version ? (
                <Mono style={{ fontSize: 12.5, fontWeight: isActive || isNewest ? 700 : 500, overflow: "hidden", textOverflow: "ellipsis" }}>
                  {r.version}
                </Mono>
              ) : (
                <span style={{ fontSize: 12, color: "var(--lx-muted)", fontWeight: isActive ? 700 : 400 }}>belum melapor</span>
              )}
              <span
                style={{
                  position: "relative",
                  height: 22,
                  borderRadius: 999,
                  background: "var(--lx-sunken)",
                  boxShadow: isActive ? "0 0 0 1.5px var(--lx-ink)" : undefined,
                }}
              >
                <span
                  className={`lx-grow-x${r.version ? "" : " lx-hatch"}`}
                  style={{
                    "--i": i,
                    position: "absolute",
                    inset: "0 auto 0 0",
                    width: `${Math.max(9, (r.count / Math.max(total, 1)) * 100)}%`,
                    borderRadius: 999,
                    backgroundColor: r.version ? (isNewest ? "var(--lx-accent)" : "var(--lx-ink)") : undefined,
                    boxShadow: r.version ? undefined : "inset 0 0 0 1px var(--lx-hatch)",
                  } as CSSProperties}
                />
              </span>
              <Mono style={{ fontSize: 12.5, textAlign: "right" }}>{r.count}</Mono>
            </button>
          );
        })}
      </div>
    </Card>
  );
};

// ---------------------------------------------------------------------------
// The ink card: one row per device with a problem, the worst problem named
// and the rest counted.

export const AttentionCard = ({
  gridColumn,
  issues,
  isFiltered,
  onSelect,
  onFilter,
}: {
  gridColumn: string | undefined;
  issues: Issue[];
  isFiltered: boolean;
  onSelect: (d: Device) => void;
  onFilter: () => void;
}) => {
  const [hover, setHover] = useState<string | null>(null);
  return (
    <Card
      padding="20px 22px 18px"
      className="lx-rise"
      style={cardStyle(gridColumn, 2, { background: "var(--lx-ink)", color: "var(--lx-on-ink)" })}
    >
      <CardTitle>Perlu perhatian</CardTitle>
      <div style={{ display: "flex", alignItems: "flex-end", gap: 10, marginBottom: 14 }}>
        <BigNumber value={issues.length} size={50} />
        <span style={{ fontSize: 12.5, opacity: 0.7, paddingBottom: 5 }}>perangkat perlu dicek</span>
      </div>
      {issues.length === 0 ? (
        <div style={{ display: "flex", alignItems: "center", gap: 10, marginTop: "auto" }}>
          <Tag tone="accent" style={{ fontSize: 14, padding: "6px 10px" }}>
            ✓
          </Tag>
          <span style={{ fontSize: 12.5, opacity: 0.75, lineHeight: 1.45 }}>
            Semua perangkat online, di versi terbaru, dan jamnya tepat.
          </span>
        </div>
      ) : (
        <>
          <div style={{ display: "grid", gap: 2, margin: "0 -10px 12px" }}>
            {issues.slice(0, ATTENTION_LIMIT).map(({ device, reasons }) => {
              const isHover = hover === device.device_id;
              return (
                <button
                  key={device.device_id}
                  type="button"
                  className="lx-tap"
                  onMouseEnter={() => setHover(device.device_id)}
                  onMouseLeave={() => setHover(null)}
                  onClick={() => onSelect(device)}
                  title={reasons.map(reasonText).join(" · ")}
                  style={{
                    font: "inherit",
                    display: "flex",
                    alignItems: "center",
                    gap: 9,
                    padding: "8px 10px",
                    borderRadius: 12,
                    border: "none",
                    background: isHover ? "color-mix(in srgb, var(--lx-on-ink) 12%, transparent)" : "transparent",
                    color: "inherit",
                    textAlign: "left",
                    cursor: "pointer",
                  }}
                >
                  <StatusDot status={SYNC_STATUS[device.sync_status]} />
                  <Mono style={{ fontSize: 12.5, fontWeight: 700, flexShrink: 0 }}>{nameOf(device).id}</Mono>
                  <span
                    style={{ fontSize: 12, opacity: 0.72, flex: 1, minWidth: 0, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}
                  >
                    {reasons[0].label}
                    {reasons[0].value && <Mono> {reasons[0].value}</Mono>}
                    {reasons.length > 1 && <Mono> +{reasons.length - 1}</Mono>}
                  </span>
                  <span
                    aria-hidden="true"
                    style={{
                      display: "inline-flex",
                      opacity: isHover ? 1 : 0.5,
                      transform: isHover ? "rotate(45deg)" : undefined,
                      transition: "transform var(--lx-motion) var(--lx-ease-spring), opacity var(--lx-motion) var(--lx-ease)",
                    }}
                  >
                    {ARROW}
                  </span>
                </button>
              );
            })}
          </div>
          <button
            type="button"
            className="lx-tap"
            onClick={onFilter}
            aria-pressed={isFiltered}
            style={{
              font: "inherit",
              marginTop: "auto",
              alignSelf: "flex-start",
              fontSize: 12,
              fontWeight: 650,
              padding: "6px 13px",
              borderRadius: 999,
              border: "1px solid color-mix(in srgb, var(--lx-on-ink) 22%, transparent)",
              background: isFiltered ? "var(--lx-on-ink)" : "transparent",
              color: isFiltered ? "var(--lx-ink)" : "inherit",
              cursor: "pointer",
            }}
          >
            {isFiltered
              ? "Tampilkan semua perangkat"
              : issues.length > ATTENTION_LIMIT
                ? `Saring registri · +${issues.length - ATTENTION_LIMIT} lainnya`
                : "Saring registri"}
          </button>
        </>
      )}
    </Card>
  );
};
