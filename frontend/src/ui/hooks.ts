// Shared behavior hooks for the v3 UI layer.
import { useEffect, useRef, useState, type RefObject } from "react";

/** The three admin-dashboard breakpoints from README §4. */
export type Breakpoint = "phone" | "tablet" | "desktop";

const query = (q: string) => (typeof window === "undefined" ? false : window.matchMedia(q).matches);

export const useMediaQuery = (q: string): boolean => {
  const [matches, setMatches] = useState(() => query(q));
  useEffect(() => {
    const mql = window.matchMedia(q);
    const onChange = () => setMatches(mql.matches);
    onChange();
    mql.addEventListener("change", onChange);
    return () => mql.removeEventListener("change", onChange);
  }, [q]);
  return matches;
};

/**
 * Current breakpoint. Boundaries match the design exactly: >=1280 desktop,
 * 768-1279 tablet, <=767 phone.
 */
export const useBreakpoint = (): Breakpoint => {
  const isDesktop = useMediaQuery("(min-width: 1280px)");
  const isTablet = useMediaQuery("(min-width: 768px)");
  return isDesktop ? "desktop" : isTablet ? "tablet" : "phone";
};

/** True when the OS asks for reduced motion; drives the snap-instead-of-animate rule. */
export const useReducedMotion = (): boolean => useMediaQuery("(prefers-reduced-motion: reduce)");

/** Calls `onOutside` on pointerdown outside `ref`, and on Escape. */
export const useDismiss = (
  ref: RefObject<HTMLElement | null>,
  isOpen: boolean,
  onOutside: () => void,
) => {
  const cb = useRef(onOutside);
  cb.current = onOutside;
  useEffect(() => {
    if (!isOpen) return;
    const onPointer = (e: PointerEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) cb.current();
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") cb.current();
    };
    // Deferred so the click that opened the surface doesn't immediately close it.
    const id = window.setTimeout(() => document.addEventListener("pointerdown", onPointer), 0);
    document.addEventListener("keydown", onKey);
    return () => {
      window.clearTimeout(id);
      document.removeEventListener("pointerdown", onPointer);
      document.removeEventListener("keydown", onKey);
    };
  }, [isOpen, ref]);
};
