// Dark-mode plumbing. A single mode state (light | dark | system, default
// system, persisted to localStorage) drives Astryx's <Theme mode>. Both
// Astryx's --color-* and our --lx-* tokens use light-dark(), so flipping this
// switches the whole app -- no per-component dark styling needed. We also mirror
// the mode onto documentElement.style.colorScheme so light-dark() resolves
// correctly for anything rendered outside the <Theme> subtree (e.g. body).
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
  type ReactNode,
} from "react";
import { Theme } from "@astryxdesign/core/theme";

import { logixTheme } from "../theme";

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
    /* localStorage unavailable (private mode / SSR) -- fall through */
  }
  return "system";
};

export function ThemeModeProvider({ children }: { children: ReactNode }) {
  const [mode, setModeState] = useState<ThemeMode>(readInitialMode);

  useEffect(() => {
    try {
      localStorage.setItem(STORAGE_KEY, mode);
    } catch {
      /* ignore persistence failures */
    }
    document.documentElement.style.colorScheme = mode === "system" ? "light dark" : mode;
  }, [mode]);

  const setMode = useCallback((next: ThemeMode) => setModeState(next), []);
  const cycleMode = useCallback(
    () =>
      setModeState((m) => (m === "light" ? "dark" : m === "dark" ? "system" : "light")),
    [],
  );

  const value = useMemo(
    () => ({ mode, setMode, cycleMode }),
    [mode, setMode, cycleMode],
  );

  return (
    <ThemeModeContext.Provider value={value}>
      <Theme theme={logixTheme} mode={mode}>
        {children}
      </Theme>
    </ThemeModeContext.Provider>
  );
}
