import { useEffect, useRef } from "react";

export const timeAgo = (iso: string | null | undefined): string => {
  if (!iso) return "Belum pernah";
  const seconds = Math.max(0, (Date.now() - new Date(iso).getTime()) / 1000);
  if (seconds < 60) return "Baru saja";
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes} menit lalu`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours} jam lalu`;
  return `${Math.floor(hours / 24)} hari lalu`;
};

export const formatDateTime = (iso: string | null | undefined): string =>
  iso ? new Date(iso).toLocaleString("id-ID") : "-";

export const formatTime = (iso: string | null | undefined): string =>
  iso ? new Date(iso).toLocaleTimeString("id-ID", { hour: "2-digit", minute: "2-digit" }) : "-";

// Poll `fn` every `ms` while the component is mounted; fires once
// immediately. Matches the legacy per-tab polling (data refreshes only for
// the visible tab, since hidden views are unmounted).
export const usePolling = (fn: () => void, ms: number) => {
  const fnRef = useRef(fn);
  fnRef.current = fn;
  useEffect(() => {
    fnRef.current();
    const id = setInterval(() => fnRef.current(), ms);
    return () => clearInterval(id);
  }, [ms]);
};
