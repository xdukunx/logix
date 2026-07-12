// AccessTypeBadge — the core "how the session happened" differentiator.
// One consistent 24px stroke set, always paired with a tinted pill + label
// (never a bare icon), reading the same in light and dark. Colors come from
// the token layer (tokens.ts / tokens.css); geometry uses fixed px to match
// the Style Tile (docs/design/LogiX Style Tile.dc.html §02).
import { ACCESS_TYPE, type AccessType } from "../tokens";

const GLYPH_PATHS: Record<AccessType, React.ReactNode> = {
  physical: (
    <>
      <rect x="2" y="6" width="20" height="12" rx="2" />
      <line x1="8" y1="14.5" x2="16" y2="14.5" />
    </>
  ),
  // SSH glyph is the mono ">_" prompt, handled as text below.
  ssh: null,
  anydesk: (
    <>
      <rect x="3" y="4" width="18" height="13" rx="2" />
      <path d="M9 8.5l4.5 1.8-1.9 0.9 1.2 2.3" />
    </>
  ),
};

// The larger tile glyphs (24px) used by AccessTypeTile.
const TILE_PATHS: Record<AccessType, React.ReactNode> = {
  physical: (
    <>
      <rect x="2" y="6" width="20" height="12" rx="2" />
      <line x1="6" y1="10" x2="6" y2="10" />
      <line x1="10" y1="10" x2="10" y2="10" />
      <line x1="14" y1="10" x2="14" y2="10" />
      <line x1="18" y1="10" x2="18" y2="10" />
      <line x1="8" y1="14.5" x2="16" y2="14.5" />
    </>
  ),
  ssh: (
    <>
      <rect x="3" y="4" width="18" height="16" rx="2" />
      <path d="M7 9l3 3-3 3" />
      <line x1="12.5" y1="15" x2="16" y2="15" />
    </>
  ),
  anydesk: (
    <>
      <rect x="3" y="4" width="18" height="13" rx="2" />
      <path d="M9 20h6" />
      <path d="M12 17v3" />
      <path d="M9 8.5l4.5 1.8-1.9 0.9 1.2 2.3" />
    </>
  ),
};

function Stroke({ children, size }: { children: React.ReactNode; size: number }) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={size >= 20 ? 1.8 : 2}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden
    >
      {children}
    </svg>
  );
}

export function AccessTypeBadge({
  type,
  detail,
  size = "md",
}: {
  type: AccessType;
  /** Optional trailing detail, e.g. "sejak 09:14 · 2j 41m". */
  detail?: string;
  size?: "sm" | "md";
}) {
  const t = ACCESS_TYPE[type];
  const isSm = size === "sm";
  const glyphSize = isSm ? 11 : 13;

  return (
    <span style={{ display: "inline-flex", alignItems: "center", gap: 8, minWidth: 0 }}>
      <span
        style={{
          display: "inline-flex",
          alignItems: "center",
          gap: 6,
          padding: isSm ? "3px 9px" : "4px 11px",
          borderRadius: 999,
          background: t.badgeBg,
          color: t.badgeFg,
          fontSize: isSm ? 11 : 12,
          fontWeight: 700,
          lineHeight: 1,
          whiteSpace: "nowrap",
          flexShrink: 0,
        }}
      >
        {type === "ssh" ? (
          <span style={{ fontFamily: "ui-monospace, Menlo, Consolas, monospace" }}>&gt;_</span>
        ) : (
          <Stroke size={glyphSize}>{GLYPH_PATHS[type]}</Stroke>
        )}
        {t.label}
      </span>
      {detail && (
        <span
          style={{
            fontSize: isSm ? 11 : 12,
            color: "var(--lx-text-muted)",
            fontFamily: "ui-monospace, Menlo, Consolas, monospace",
            overflow: "hidden",
            textOverflow: "ellipsis",
            whiteSpace: "nowrap",
          }}
        >
          {detail}
        </span>
      )}
    </span>
  );
}

// Larger presentation used on detail views / the token demo: icon square +
// title + one-line descriptor.
export function AccessTypeTile({ type }: { type: AccessType }) {
  const t = ACCESS_TYPE[type];
  return (
    <span style={{ display: "inline-flex", alignItems: "center", gap: 12 }}>
      <span
        style={{
          width: 46,
          height: 46,
          borderRadius: 10,
          background: t.iconBg,
          color: t.icon,
          display: "inline-flex",
          alignItems: "center",
          justifyContent: "center",
          flexShrink: 0,
        }}
      >
        <Stroke size={24}>{TILE_PATHS[type]}</Stroke>
      </span>
      <span style={{ display: "inline-flex", flexDirection: "column" }}>
        <span style={{ fontSize: 16, fontWeight: 700, color: "var(--color-text-primary)" }}>
          {t.label}
        </span>
        <span style={{ fontSize: 12, color: "var(--lx-text-muted)" }}>{t.sub}</span>
      </span>
    </span>
  );
}

export default AccessTypeBadge;
