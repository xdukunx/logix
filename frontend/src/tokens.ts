// Typed accessors for the Logix token layer (tokens.css). Components read
// these maps instead of hardcoding var() names or hex, so the design system
// stays the single source of truth. Bilingual labels are ID-primary.

export type StationStatus = "inuse" | "locked" | "idle" | "offline" | "alert";

export interface StatusToken {
  /** ID-primary label. */
  label: string;
  /** Solid status color (the dot). */
  dot: string;
  /** Tinted pill background. */
  bg: string;
  /** Pill / label text color. */
  fg: string;
}

export const STATUS: Record<StationStatus, StatusToken> = {
  inuse: {
    label: "Digunakan",
    dot: "var(--lx-status-inuse)",
    bg: "var(--lx-status-inuse-bg)",
    fg: "var(--lx-status-inuse-fg)",
  },
  locked: {
    label: "Terkunci",
    dot: "var(--lx-status-locked)",
    bg: "var(--lx-status-locked-bg)",
    fg: "var(--lx-status-locked-fg)",
  },
  idle: {
    label: "Idle",
    dot: "var(--lx-status-idle)",
    bg: "var(--lx-status-idle-bg)",
    fg: "var(--lx-status-idle-fg)",
  },
  offline: {
    label: "Luring",
    dot: "var(--lx-status-offline)",
    bg: "var(--lx-status-offline-bg)",
    fg: "var(--lx-status-offline-fg)",
  },
  alert: {
    label: "Peringatan",
    dot: "var(--lx-status-alert)",
    bg: "var(--lx-status-alert-bg)",
    fg: "var(--lx-status-alert-fg)",
  },
};

// The unified access-type taxonomy (web + client): exactly three.
export type AccessType = "physical" | "ssh" | "anydesk";

export interface AccessToken {
  /** Short label shown in the pill. */
  label: string;
  /** One-line descriptor for the large icon tile. */
  sub: string;
  iconBg: string;
  icon: string;
  badgeBg: string;
  badgeFg: string;
}

export const ACCESS_TYPE: Record<AccessType, AccessToken> = {
  physical: {
    label: "Fisik",
    sub: "Di keyboard",
    iconBg: "var(--lx-access-physical-icon-bg)",
    icon: "var(--lx-access-physical-icon)",
    badgeBg: "var(--lx-access-physical-badge-bg)",
    badgeFg: "var(--lx-access-physical-badge-fg)",
  },
  ssh: {
    label: "SSH",
    sub: "Sesi terminal",
    iconBg: "var(--lx-access-ssh-icon-bg)",
    icon: "var(--lx-access-ssh-icon)",
    badgeBg: "var(--lx-access-ssh-badge-bg)",
    badgeFg: "var(--lx-access-ssh-badge-fg)",
  },
  anydesk: {
    label: "AnyDesk",
    sub: "Remote desktop",
    iconBg: "var(--lx-access-anydesk-icon-bg)",
    icon: "var(--lx-access-anydesk-icon)",
    badgeBg: "var(--lx-access-anydesk-badge-bg)",
    badgeFg: "var(--lx-access-anydesk-badge-fg)",
  },
};

// Map a raw API session/access descriptor to an AccessType. The backend does
// not yet expose a canonical access-type field, so we infer from what's
// available and default to physical (at-keyboard).
// TODO(backend): expose an explicit access_type on the session/active shape.
export const resolveAccessType = (raw: string | null | undefined): AccessType => {
  const v = (raw || "").toLowerCase();
  if (v.includes("ssh") || v.includes("terminal") || v.includes("shell")) return "ssh";
  if (v.includes("anydesk") || v.includes("remote")) return "anydesk";
  return "physical";
};
