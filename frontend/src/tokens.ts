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

/**
 * Enrolment categories -- the server's CATEGORY_PROFILES keys, paired with the
 * Indonesian label a person should actually see.
 *
 * Lives here rather than in Devices.tsx because Monitoring needs it too: a
 * station whose display_name carries no " - <spec>" half fell back to printing
 * the raw key, so a real workstation rendered as "WS-01 - lab_workstation".
 * Two screens showing the same taxonomy two different ways is how that
 * happened; one source stops it recurring.
 */
// Not `as const`: PillSelect takes a mutable {value,label}[], and a readonly
// tuple cannot be assigned to it.
export const DEVICE_CATEGORIES: { value: string; label: string }[] = [
  { value: "lab_workstation", label: "Workstation lab" },
  { value: "office_workstation", label: "Workstation kantor" },
  { value: "loaned_laptop", label: "Laptop pinjaman" },
  { value: "server", label: "Server" },
  { value: "custom", label: "Lainnya" },
];

const CATEGORY_LABEL = new Map(DEVICE_CATEGORIES.map((c) => [c.value, c.label]));

/** Human label for an enrolment category; unknown keys degrade to themselves. */
export const categoryLabel = (key: string | null | undefined): string =>
  (key && CATEGORY_LABEL.get(key)) || key || "";

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
