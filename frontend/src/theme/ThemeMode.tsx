// Dark-mode plumbing. A single mode (light | dark | system, default light --
// the dark-framed light canvas is the primary design, full dark is opt-in --
// persisted to localStorage) is mirrored onto documentElement's `data-theme`
// attribute, which tokens.css keys its dark ramp off. An attribute is what
// makes the switch reliable: overriding the custom properties themselves is
// plain cascade and always invalidates, whereas a light-dark() value baked
// into a property does not re-resolve when color-scheme changes at runtime.
// There is no per-component dark styling anywhere.
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
  type ReactNode,
} from "react";

export type ThemeMode = "light" | "dark" | "system";

const STORAGE_KEY = "lx-theme";

interface ThemeModeContextValue {
  mode: ThemeMode;
  setMode: (mode: ThemeMode) => void;
  /** Cycles light -> dark -> system -> light. */
  cycleMode: () => void;
}

const ThemeModeContext = createContext<ThemeModeContextValue | null>(null);

export const useThemeMode = (): ThemeModeContextValue => {
  const ctx = useContext(ThemeModeContext);
  if (!ctx) throw new Error("useThemeMode must be used within ThemeModeProvider");
  return ctx;
};

const readInitialMode = (): ThemeMode => {
  try {
    const stored = localStorage.getItem(STORAGE_KEY);
    if (stored === "light" || stored === "dark" || stored === "system") return stored;
  } catch {
    /* localStorage unavailable (private mode) -- fall through */
  }
  return "light";
};

export function ThemeModeProvider({ children }: { children: ReactNode }) {
  const [mode, setModeState] = useState<ThemeMode>(readInitialMode);

  useEffect(() => {
    try {
      localStorage.setItem(STORAGE_KEY, mode);
    } catch {
      /* ignore persistence failures */
    }
    // "system" removes the attribute entirely so the prefers-color-scheme
    // media query in tokens.css is what decides.
    if (mode === "system") document.documentElement.removeAttribute("data-theme");
    else document.documentElement.setAttribute("data-theme", mode);
  }, [mode]);

  const setMode = useCallback((next: ThemeMode) => setModeState(next), []);
  const cycleMode = useCallback(
    () => setModeState((m) => (m === "light" ? "dark" : m === "dark" ? "system" : "light")),
    [],
  );

  const value = useMemo(() => ({ mode, setMode, cycleMode }), [mode, setMode, cycleMode]);

  return <ThemeModeContext.Provider value={value}>{children}</ThemeModeContext.Provider>;
}
