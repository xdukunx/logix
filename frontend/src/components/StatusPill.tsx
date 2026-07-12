// Tinted status pill (dot + label) driven by the STATUS token map. Used in the
// Monitoring occupancy summary and station cards. Set pulse for the live
// "in use" halo (respects reduced-motion via tokens.css).
import { STATUS, type StationStatus } from "../tokens";

export function StatusPill({
  status,
  label,
  small = false,
  pulse = false,
}: {
  status: StationStatus;
  label?: string;
  small?: boolean;
  pulse?: boolean;
}) {
  const t = STATUS[status];
  return (
    <span
      style={{
        display: "inline-flex",
        alignItems: "center",
        gap: 6,
        padding: small ? "3px 10px" : "5px 12px",
        borderRadius: 999,
        background: t.bg,
        color: t.fg,
        fontSize: small ? 11 : 13,
        fontWeight: 700,
        lineHeight: 1,
        whiteSpace: "nowrap",
      }}
    >
      <span
        className={pulse ? "lx-pulse-dot" : undefined}
        style={{ width: small ? 7 : 8, height: small ? 7 : 8, borderRadius: "50%", background: t.dot }}
      />
      {label ?? t.label}
    </span>
  );
}

export default StatusPill;
