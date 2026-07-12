// Logix brand theme: extends Astryx neutral with the finished design system's
// identity -- the blue primary (#2563eb) and the cool-slate / navy surfaces
// from the Style Tile (docs/design/LogiX Style Tile.dc.html, brief §1). Base
// surface/text/border tokens are set here via the sanctioned `tokens` override
// (light/dark tuples) rather than a raw :root override, so dark mode reads as
// the design's navy -- not Astryx neutral's near-black default. System fonts
// only: lab machines may be offline, so no webfont URLs.
import { defineTheme } from "@astryxdesign/core/theme";
import { neutralTheme } from "@astryxdesign/theme-neutral";

export const logixTheme = defineTheme({
  name: "logix",
  extends: neutralTheme,
  color: {
    accent: "#2563eb",
    neutralStyle: "cool",
  },
  radius: {
    base: 6,
    multiplier: 1,
  },
  // [light, dark] tuples. Surfaces/text/border pinned to brief §1 so both
  // modes match the canvases exactly.
  tokens: {
    "--color-accent": ["#2563eb", "#2563eb"],
    "--color-background-body": ["#eef1f5", "#0b1120"],
    "--color-background-surface": ["#ffffff", "#0f172a"],
    "--color-background-card": ["#ffffff", "#0f172a"],
    "--color-background-popover": ["#ffffff", "#1e293b"],
    "--color-border": ["#dbe1ea", "#1e293b"],
    "--color-border-emphasized": ["#ccd3db", "#334155"],
    "--color-text-primary": ["#0f172a", "#e2e8f0"],
    "--color-text-secondary": ["#475569", "#94a3b8"],
  },
  components: {
    // Legacy cards had a subtle lift; neutral's are flat.
    card: {
      base: {
        boxShadow: "0 1px 3px rgba(15, 23, 42, 0.08)",
      },
    },
  },
});
