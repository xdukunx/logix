// Typed accessors for the v3 token layer (tokens.css). Components read these
// instead of hardcoding var() names or hex, so the design system stays the
// single source of truth. Copy is Indonesian per the Copy Deck.

/**
 * Station status. Matches the five status colors in the v3 README exactly.
 * `active` replaces the old `inuse` naming so code and design agree.
 */
export type StationStatus = "active" | "locked" | "idle" | "offline" | "alert";

/** The CSS var carrying a status color. Consumed only by StatusDot/StatusEdge. */
export const statusColor = (status: StationStatus): string => `var(--lx-status-${status})`;

/** ID-primary status labels. Used in the audit log and drawer, never as a badge. */
export const STATUS_LABEL: Record<StationStatus, string> = {
  active: "Aktif",
  locked: "Terkunci",
  idle: "Idle",
  offline: "Offline",
  alert: "Peringatan",
};

// The unified access-type taxonomy (web + client): exactly three. v3 renders
// these as plain text inside the card's session line -- the tinted badges the
// old design used are an explicit anti-pattern now.
export type AccessType = "physical" | "ssh" | "anydesk";

export const ACCESS_LABEL: Record<AccessType, string> = {
  physical: "Fisik",
  ssh: "SSH",
  anydesk: "AnyDesk",
};

/**
 * Map a raw API session/access descriptor to an AccessType, defaulting to
 * physical (at-keyboard). The server now sends an explicit `access_type`, but
 * older client builds still report free-text, so the string sniff stays as a
 * fallback for rows written before the upgrade.
 */
export const resolveAccessType = (raw: string | null | undefined): AccessType => {
  const v = (raw || "").toLowerCase();
  if (v === "physical" || v === "ssh" || v === "anydesk") return v;
  if (v.includes("ssh") || v.includes("terminal") || v.includes("shell")) return "ssh";
  if (v.includes("anydesk") || v.includes("remote")) return "anydesk";
  return "physical";
};
