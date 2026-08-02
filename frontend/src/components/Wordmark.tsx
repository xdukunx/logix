// The LOGIX lockup: an accent rounded square holding a mono ">_" prompt next
// to the wordmark in wide tracking. Design: the header of every v3 canvas
// (LogiX Style Tile v2.dc.html and the Monitoring sidebar).
export function LogixMark({ size = 24 }: { size?: number }) {
  return (
    <span
      className="lx-mono"
      aria-hidden="true"
      style={{
        width: size,
        height: size,
        borderRadius: Math.round(size * 0.29),
        background: "var(--lx-accent)",
        display: "inline-flex",
        alignItems: "center",
        justifyContent: "center",
        fontWeight: 700,
        color: "var(--lx-on-accent)",
        fontSize: Math.round(size * 0.46),
        flexShrink: 0,
      }}
    >
      &gt;_
    </span>
  );
}

export function Wordmark({
  size = 13,
  isMarkOnly = false,
  markSize = 24,
}: {
  size?: number;
  isMarkOnly?: boolean;
  markSize?: number;
}) {
  return (
    <span style={{ display: "inline-flex", alignItems: "center", gap: 9 }} title="Logix">
      <LogixMark size={markSize} />
      {!isMarkOnly && (
        <span style={{ fontSize: size, fontWeight: 700, letterSpacing: "0.16em", lineHeight: 1 }}>
          LOGIX
        </span>
      )}
    </span>
  );
}

export default Wordmark;
