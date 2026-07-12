// The LOGIX wordmark + brand mark. Weight 800 with wide tracking carries the
// identity (no display face needed); the mark is a blue rounded square holding
// the terminal ">_" glyph. Used in the SideNav header and the login card.
// Matches docs/design/LogiX App Shell & Login.dc.html + Style Tile §Wordmark.

export function LogixMark({ size = 28 }: { size?: number }) {
  const glyph = Math.round(size * 0.57);
  return (
    <span
      style={{
        width: size,
        height: size,
        borderRadius: Math.round(size * 0.25),
        background: "var(--lx-accent)",
        display: "inline-flex",
        alignItems: "center",
        justifyContent: "center",
        boxShadow: "0 2px 6px rgba(37, 99, 235, 0.35)",
        flexShrink: 0,
      }}
    >
      <svg
        width={glyph}
        height={glyph}
        viewBox="0 0 24 24"
        fill="none"
        stroke="#fff"
        strokeWidth={2.2}
        strokeLinecap="round"
        strokeLinejoin="round"
        aria-hidden
      >
        <rect x="3" y="4" width="18" height="16" rx="2" />
        <path d="M7 9l3 3-3 3" />
        <line x1="12.5" y1="15" x2="16" y2="15" />
      </svg>
    </span>
  );
}

export function Wordmark({
  size = 17,
  tracking = "0.14em",
  showMark = true,
  markSize,
}: {
  size?: number;
  tracking?: string;
  showMark?: boolean;
  markSize?: number;
}) {
  return (
    <span style={{ display: "inline-flex", alignItems: "center", gap: 9 }}>
      {showMark && <LogixMark size={markSize ?? Math.round(size * 1.6)} />}
      <span
        style={{
          fontSize: size,
          fontWeight: 800,
          letterSpacing: tracking,
          color: "var(--color-text-primary)",
          lineHeight: 1,
        }}
      >
        LOGI<span style={{ color: "var(--lx-accent)" }}>X</span>
      </span>
    </span>
  );
}

export default Wordmark;
