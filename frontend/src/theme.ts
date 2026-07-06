// Logix brand theme: extends Astryx neutral with the legacy dashboard's
// identity -- the blue primary (#2563eb) and cool slate neutrals from
// server/static/style.css -- so the React port reads as Logix, not as a
// stock component demo. System fonts only: lab servers may be offline, so
// no webfont URLs here.
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
  components: {
    // Legacy cards had a subtle lift; neutral's are flat.
    card: {
      base: {
        boxShadow: "0 1px 3px rgba(15, 23, 42, 0.08)",
      },
    },
  },
});
