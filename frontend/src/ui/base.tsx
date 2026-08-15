// v3 structural primitives: the two status primitives, the card, page header,
// and the empty/error/loading states. Everything reads tokens.css -- no hex here.
import type { CSSProperties, ReactNode } from "react";

import { statusColor, type StationStatus } from "../tokens";

/** Mono tabular. Wraps EVERY time / ID / duration value in the product. */
export const Mono = ({ children, style }: { children: ReactNode; style?: CSSProperties }) => (
  <span className="lx-mono" style={style}>
    {children}
  </span>
);

/**
 * Status primitive 1 of 2: an 8px dot. The `size` escape exists only for the
 * /wall TV view (12px) and the strip sliver (6px) -- never to make it a badge.
 */
export const StatusDot = ({
  status,
  size = 8,
  label,
}: {
  status: StationStatus;
  size?: number;
  label?: string;
}) => (
  <span
    // Keyed on status so React remounts the node on a state change, replaying
    // the one-shot arrival pop. It never animates at rest.
    key={status}
    className="lx-anim-dot"
    role={label ? "img" : undefined}
    aria-label={label}
    aria-hidden={label ? undefined : true}
    style={{
      width: size,
      height: size,
      borderRadius: 999,
      background: statusColor(status),
      flexShrink: 0,
      display: "inline-block",
    }}
  />
);

/**
 * Status primitive 2 of 2: a 3px edge. `side` picks which edge carries it.
 * Returns a style fragment rather than an element so it can ride on any box.
 */
export const statusEdge = (status: StationStatus, side: "left" | "top" = "left"): CSSProperties =>
  side === "left"
    ? { borderLeft: `3px solid ${statusColor(status)}` }
    : { borderTop: `3px solid ${statusColor(status)}` };

/** Accent edge for informational callouts (privacy notice, idle-policy note). */
export const Callout = ({
  tone = "accent",
  children,
}: {
  tone?: "accent" | "warning";
  children: ReactNode;
}) => (
  <div
    style={{
      borderLeft: `3px solid ${tone === "accent" ? "var(--lx-accent)" : "var(--lx-status-locked)"}`,
      padding: "8px 14px",
      fontSize: 12.5,
      lineHeight: 1.5,
      background: "var(--lx-sunken)",
      borderRadius: "0 10px 10px 0",
    }}
  >
    {children}
  </div>
);

/**
 * The one card. Flat white, radius 16, the subtle two-layer shadow. `variant`
 * covers the three station-card states; `isSelected` draws the accent ring.
 */
export const Card = ({
  variant = "solid",
  isSelected = false,
  isInteractive = false,
  padding = "16px 18px",
  style,
  className,
  children,
  ...rest
}: {
  variant?: "solid" | "dashed";
  isSelected?: boolean;
  /** Opts into the hover-lift treatment. Only for cards the user acts on. */
  isInteractive?: boolean;
  padding?: CSSProperties["padding"];
  style?: CSSProperties;
  children: ReactNode;
} & Omit<React.HTMLAttributes<HTMLDivElement>, "style" | "children">) => (
  <div
    {...rest}
    className={[isInteractive ? "lx-interactive" : "", className].filter(Boolean).join(" ") || undefined}
    style={{
      background: variant === "dashed" ? "transparent" : "var(--lx-card)",
      border: variant === "dashed" ? "1px dashed var(--lx-border-dashed)" : undefined,
      borderRadius: "var(--lx-radius-card)",
      boxShadow:
        variant === "dashed"
          ? undefined
          : isSelected
            ? "0 0 0 1.5px var(--lx-accent), 0 4px 16px rgba(16,24,40,.06)"
            : "var(--lx-shadow-card)",
      padding,
      ...style,
    }}
  >
    {children}
  </div>
);

/** Screen header: 22px title + one muted summary sentence + right-aligned slot. */
export const PageHeader = ({
  title,
  summary,
  action,
}: {
  title: string;
  summary?: ReactNode;
  action?: ReactNode;
}) => (
  <div style={{ display: "flex", alignItems: "center", gap: 14, marginBottom: 24, flexWrap: "wrap" }}>
    <div>
      <h1 style={{ fontSize: 22, fontWeight: 650, letterSpacing: "-0.01em", margin: 0 }}>{title}</h1>
      {summary !== undefined && (
        <div style={{ fontSize: 13.5, color: "var(--lx-muted)", marginTop: 3 }}>{summary}</div>
      )}
    </div>
    {action && <div style={{ marginLeft: "auto" }}>{action}</div>}
  </div>
);

/** Section label: 11px uppercase tracking, used above grouped content. */
export const SectionLabel = ({ children }: { children: ReactNode }) => (
  <div
    style={{
      fontSize: 11,
      fontWeight: 600,
      letterSpacing: ".05em",
      textTransform: "uppercase",
      color: "var(--lx-muted)",
    }}
  >
    {children}
  </div>
);

export const EmptyState = ({ title, description }: { title: string; description?: string }) => (
  <Card padding="40px 24px" style={{ textAlign: "center" }}>
    <div style={{ fontSize: 15, fontWeight: 600, marginBottom: 6 }}>{title}</div>
    {description && (
      <div style={{ fontSize: 13.5, color: "var(--lx-muted)", lineHeight: 1.55 }}>{description}</div>
    )}
  </Card>
);

export const ErrorState = ({ description, onRetry }: { description: string; onRetry?: () => void }) => (
  <Card padding="24px" style={{ ...statusEdge("alert") }}>
    <div style={{ fontSize: 14.5, fontWeight: 600, marginBottom: 4 }}>Gagal memuat data</div>
    <div style={{ fontSize: 13.5, color: "var(--lx-muted)", lineHeight: 1.55 }}>{description}</div>
    {onRetry && (
      <button
        type="button"
        onClick={onRetry}
        style={{
          marginTop: 14,
          font: "inherit",
          fontSize: 13,
          fontWeight: 600,
          padding: "8px 18px",
          borderRadius: "var(--lx-radius-pill)",
          border: "1px solid var(--lx-border)",
          background: "var(--lx-card)",
          color: "var(--lx-text)",
          cursor: "pointer",
        }}
      >
        Coba lagi
      </button>
    )}
  </Card>
);

/**
 * Loading placeholder. A flat muted block -- the old shimmer gradient is a v3
 * anti-pattern, so this deliberately does not animate.
 */
export const Skeleton = ({ height = 74 }: { height?: number }) => (
  <div
    style={{
      height,
      borderRadius: "var(--lx-radius-card)",
      background: "var(--lx-sunken)",
      border: "1px solid var(--lx-border)",
    }}
  />
);

export const SkeletonGrid = ({ count = 8, columns = 4 }: { count?: number; columns?: number }) => (
  <div style={{ display: "grid", gridTemplateColumns: `repeat(${columns}, 1fr)`, gap: 14 }}>
    {Array.from({ length: count }, (_, i) => (
      <Skeleton key={i} />
    ))}
  </div>
);
