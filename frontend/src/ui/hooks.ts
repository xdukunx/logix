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

/**
 * A number that counts from its previous value to `target` whenever the
 * target changes (ease-out cubic), and snaps under reduced motion. Only a
 * CHANGE animates: a re-render with the same target does nothing, so a view
 * that re-renders every second does not keep replaying it.
 */
export const useCountUp = (target: number, ms = 700): number => {
  const isReduced = useReducedMotion();
  const [value, setValue] = useState(isReduced ? target : 0);
  const shown = useRef(isReduced ? target : 0);
  useEffect(() => {
    if (isReduced) {
      shown.current = target;
      setValue(target);
      return;
    }
    const from = shown.current;
    const start = performance.now();
    let raf = 0;
    const step = (now: number) => {
      const p = Math.min(1, (now - start) / ms);
      const v = from + (target - from) * (1 - Math.pow(1 - p, 3));
      shown.current = v;
      setValue(v);
      if (p < 1) raf = requestAnimationFrame(step);
    };
    raf = requestAnimationFrame(step);
    return () => cancelAnimationFrame(raf);
  }, [target, ms, isReduced]);
  return value;
};

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
