// Logix Admin Dashboard -- v3 "Clean Calibration" shell.
// Design: docs/design_handoff_logix_v3/LogiX Monitoring v2.dc.html (sidebar)
// and LogiX Responsive.dc.html (tablet top bar / phone bottom tab bar).
//
// Four destinations, active state = dark pill. The old Analytics and Layar
// routes are gone; their hashes redirect so existing bookmarks still land
// somewhere sensible.
import { useCallback, useEffect, useState, type ReactNode } from "react";

import { clearToken, fetchWithAuth, getToken, setOnSessionExpired } from "./api";
import AlertsBell from "./chrome/AlertsBell";
import Login from "./chrome/Login";
import RepliesInbox from "./chrome/RepliesInbox";
import Wordmark from "./components/Wordmark";
import { useThemeMode } from "./theme/ThemeMode";
import { useBreakpoint } from "./ui/hooks";
import { ToastProvider, useToast } from "./ui/overlays";
import Devices from "./views/Devices";
import Monitoring from "./views/Monitoring";
import Riwayat from "./views/Riwayat";
import Settings from "./views/Settings";
import WallMode from "./views/WallMode";

const LAB_NAME = "Lab Komputasi FTMM";

const TABS = {
  monitoring: { title: "Monitoring", short: "Monitor", view: Monitoring },
  riwayat: { title: "Riwayat", short: "Riwayat", view: Riwayat },
  perangkat: { title: "Perangkat", short: "Perangkat", view: Devices },
  pengaturan: { title: "Pengaturan", short: "Atur", view: Settings },
} as const;

type TabKey = keyof typeof TABS;

// Retired routes. Analytics became Riwayat; the standalone Layar/Screens tab
// was removed and screenshot is now a per-device action on Monitoring.
const REDIRECTS: Record<string, TabKey> = {
  analytics: "riwayat",
  screens: "monitoring",
  layar: "monitoring",
  devices: "perangkat",
  settings: "pengaturan",
};

const normalizeTab = (hash: string): TabKey => {
  if (hash in TABS) return hash as TabKey;
  return REDIRECTS[hash] ?? "monitoring";
};

const NAV_ICONS: Record<TabKey, ReactNode> = {
  monitoring: (
    <>
      <rect x="3.5" y="3.5" width="7.5" height="7.5" rx="1.5" />
      <rect x="13" y="3.5" width="7.5" height="7.5" rx="1.5" />
      <rect x="3.5" y="13" width="7.5" height="7.5" rx="1.5" />
      <rect x="13" y="13" width="7.5" height="7.5" rx="1.5" />
    </>
  ),
  riwayat: (
    <>
      <circle cx="12" cy="12" r="8.5" />
      <path d="M12 7.5 L12 12 L15.5 14" />
    </>
  ),
  perangkat: (
    <>
      <rect x="3.5" y="5" width="17" height="12" rx="2" />
      <path d="M9 20.5 L15 20.5" />
    </>
  ),
  pengaturan: (
    <>
      <circle cx="12" cy="12" r="3" />
      <path d="M12 3.5 L12 6 M12 18 L12 20.5 M3.5 12 L6 12 M18 12 L20.5 12 M6 6 L7.8 7.8 M16.2 16.2 L18 18 M18 6 L16.2 7.8 M7.8 16.2 L6 18" />
    </>
  ),
};

const NavIcon = ({ tab, color }: { tab: TabKey; color: string }) => (
  <svg
    width="16"
    height="16"
    viewBox="0 0 24 24"
    fill="none"
    stroke={color}
    strokeWidth="2"
    strokeLinecap="round"
    aria-hidden="true"
  >
    {NAV_ICONS[tab]}
  </svg>
);

const THEME_LABEL = { light: "Tema: terang", dark: "Tema: gelap", system: "Tema: sistem" } as const;

/** Sidebar footer / top-bar utilities: theme cycle, alerts, sign out. */
const Utilities = ({ onLogout, isCompact }: { onLogout: () => void; isCompact?: boolean }) => {
  const { mode, cycleMode } = useThemeMode();
  const button: React.CSSProperties = {
    font: "inherit",
    fontSize: 12,
    color: "var(--lx-muted)",
    background: "transparent",
    border: "none",
    padding: "4px 0",
    cursor: "pointer",
    textAlign: "left",
  };
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 14, flexWrap: "wrap" }}>
      <AlertsBell />
      <RepliesInbox />
      <button type="button" style={button} onClick={cycleMode} title={THEME_LABEL[mode]}>
        {THEME_LABEL[mode]}
      </button>
      {!isCompact && (
        <button type="button" style={button} onClick={onLogout}>
          Keluar
        </button>
      )}
    </div>
  );
};

const NAV_ITEM_H = 42;
const NAV_GAP = 4;

/**
 * Desktop sidebar nav. The active pill is ONE element that slides between
 * items (spring easing) rather than each item toggling its own background --
 * the move itself tells you where you went.
 */
const SideNav = ({
  tab,
  keys,
  onSelect,
}: {
  tab: TabKey;
  keys: TabKey[];
  onSelect: (key: TabKey) => void;
}) => (
  <nav aria-label="Navigasi utama" style={{ position: "relative", display: "grid", gap: NAV_GAP }}>
    <span
      aria-hidden="true"
      style={{
        position: "absolute",
        left: 0,
        right: 0,
        top: 0,
        height: NAV_ITEM_H,
        borderRadius: "var(--lx-radius-pill)",
        background: "var(--lx-accent)",
        transform: `translateY(${keys.indexOf(tab) * (NAV_ITEM_H + NAV_GAP)}px)`,
        transition: "transform var(--lx-motion-enter) var(--lx-ease-spring)",
      }}
    />
    {keys.map((key) => {
      const isActive = key === tab;
      const color = isActive ? "var(--lx-on-accent)" : "var(--lx-muted)";
      return (
        <button
          key={key}
          type="button"
          className="lx-tap"
          aria-current={isActive ? "page" : undefined}
          onClick={() => onSelect(key)}
          style={{
            font: "inherit",
            position: "relative",
            height: NAV_ITEM_H,
            display: "flex",
            alignItems: "center",
            gap: 11,
            width: "100%",
            textAlign: "left",
            fontSize: 13.5,
            fontWeight: isActive ? 650 : 500,
            padding: "0 16px",
            borderRadius: "var(--lx-radius-pill)",
            border: "none",
            background: "transparent",
            color,
            cursor: "pointer",
          }}
        >
          <NavIcon tab={key} color={color} />
          {TABS[key].title}
        </button>
      );
    })}
  </nav>
);

/** The light canvas the pages sit on, inset into the dark frame. */
const Canvas = ({ children, style }: { children: ReactNode; style?: React.CSSProperties }) => (
  <main
    style={{
      flex: 1,
      minWidth: 0,
      background: "var(--lx-bg)",
      color: "var(--lx-text)",
      ...style,
    }}
  >
    {children}
  </main>
);

const Dashboard = ({ onLogout }: { onLogout: () => void }) => {
  const [tab, setTab] = useState<TabKey>(normalizeTab(window.location.hash.slice(1)));
  const breakpoint = useBreakpoint();

  useEffect(() => {
    const onHashChange = () => setTab(normalizeTab(window.location.hash.slice(1)));
    window.addEventListener("hashchange", onHashChange);
    return () => window.removeEventListener("hashchange", onHashChange);
  }, []);

  // Rewrite a retired hash in place so the address bar matches what's shown.
  useEffect(() => {
    const current = window.location.hash.slice(1);
    if (current && !(current in TABS) && current in REDIRECTS) {
      window.location.replace(`#${REDIRECTS[current]}`);
    }
  }, []);

  const switchTab = (name: TabKey) => {
    setTab(name);
    if (window.location.hash.slice(1) !== name) window.location.hash = name;
  };

  const ActiveView = TABS[tab].view;
  const keys = Object.keys(TABS) as TabKey[];

  // Phone: frame header + frame bottom tab bar around a full-bleed canvas.
  if (breakpoint === "phone") {
    return (
      <div style={{ minHeight: "100dvh", display: "flex", flexDirection: "column" }}>
        <header
          className="lx-frame-scope"
          style={{
            padding: "14px 18px",
            display: "flex",
            alignItems: "center",
            gap: 10,
            position: "sticky",
            top: 0,
            zIndex: 20,
          }}
        >
          <Wordmark isMarkOnly />
          <span style={{ fontSize: 15, fontWeight: 650 }}>{TABS[tab].title}</span>
          <span style={{ marginLeft: "auto" }}>
            <Utilities onLogout={onLogout} isCompact />
          </span>
        </header>
        <Canvas style={{ padding: 12, borderRadius: "22px 22px 0 0" }}>
          <ActiveView />
        </Canvas>
        <nav
          aria-label="Navigasi utama"
          className="lx-frame-scope"
          style={{
            position: "sticky",
            bottom: 0,
            padding: "8px 10px",
            display: "flex",
            gap: 4,
            zIndex: 20,
          }}
        >
          {keys.map((key) => {
            const isActive = key === tab;
            const color = isActive ? "var(--lx-on-accent)" : "var(--lx-muted)";
            return (
              <button
                key={key}
                type="button"
                className="lx-tap"
                aria-current={isActive ? "page" : undefined}
                onClick={() => switchTab(key)}
                style={{
                  font: "inherit",
                  flex: 1,
                  minHeight: 44,
                  display: "flex",
                  flexDirection: "column",
                  alignItems: "center",
                  justifyContent: "center",
                  gap: 3,
                  padding: "7px 0",
                  borderRadius: 16,
                  border: "none",
                  background: isActive ? "var(--lx-accent)" : "transparent",
                  cursor: "pointer",
                }}
              >
                <NavIcon tab={key} color={color} />
                <span style={{ fontSize: 9.5, fontWeight: 650, color }}>{TABS[key].short}</span>
              </button>
            );
          })}
        </nav>
      </div>
    );
  }

  if (breakpoint === "tablet") {
    return (
      <div style={{ minHeight: "100dvh", display: "flex", flexDirection: "column" }}>
        <header
          className="lx-frame-scope"
          style={{
            padding: "12px 20px",
            display: "flex",
            alignItems: "center",
            gap: 14,
            flexWrap: "wrap",
          }}
        >
          <Wordmark isMarkOnly />
          <div style={{ display: "flex", gap: 4 }}>
            {keys.map((key) => {
              const isActive = key === tab;
              return (
                <button
                  key={key}
                  type="button"
                  className="lx-tap"
                  aria-current={isActive ? "page" : undefined}
                  onClick={() => switchTab(key)}
                  style={{
                    font: "inherit",
                    fontSize: 12.5,
                    fontWeight: 650,
                    padding: "7px 15px",
                    borderRadius: "var(--lx-radius-pill)",
                    border: "none",
                    background: isActive ? "var(--lx-accent)" : "transparent",
                    color: isActive ? "var(--lx-on-accent)" : "var(--lx-muted)",
                    cursor: "pointer",
                  }}
                >
                  {TABS[key].title}
                </button>
              );
            })}
          </div>
          <span style={{ marginLeft: "auto" }}>
            <Utilities onLogout={onLogout} />
          </span>
        </header>
        <Canvas style={{ padding: 20, margin: "0 10px 10px", borderRadius: 26 }}>
          <ActiveView />
        </Canvas>
      </div>
    );
  }

  return (
    <div style={{ minHeight: "100dvh", display: "flex" }}>
      <aside
        className="lx-frame-scope"
        style={{
          width: 232,
          flexShrink: 0,
          padding: "24px 14px 20px",
          display: "flex",
          flexDirection: "column",
          position: "sticky",
          top: 0,
          height: "100dvh",
        }}
      >
        <div style={{ padding: "0 12px", marginBottom: 30 }}>
          <Wordmark />
        </div>
        <SideNav tab={tab} keys={keys} onSelect={switchTab} />
        <div style={{ marginTop: "auto", padding: "16px 12px 0", fontSize: 12, color: "var(--lx-muted)" }}>
          <div style={{ color: "var(--lx-text)", fontWeight: 600 }}>{LAB_NAME}</div>
          <span className="lx-mono" style={{ fontSize: 11 }}>
            admin
          </span>
          <div style={{ marginTop: 12 }}>
            <Utilities onLogout={onLogout} />
          </div>
        </div>
      </aside>
      <Canvas
        style={{
          margin: "10px 10px 10px 0",
          borderRadius: 30,
          padding: "30px 34px 40px",
          minHeight: "calc(100dvh - 20px)",
        }}
      >
        <ActiveView />
      </Canvas>
    </div>
  );
};

const AuthedApp = () => {
  const toast = useToast();
  const [hash, setHash] = useState(window.location.hash);

  useEffect(() => {
    const onHash = () => setHash(window.location.hash);
    window.addEventListener("hashchange", onHash);
    return () => window.removeEventListener("hashchange", onHash);
  }, []);

  const [isAuthed, setIsAuthed] = useState<boolean>(() => Boolean(getToken()));

  useEffect(() => {
    setOnSessionExpired(() => setIsAuthed(false));
  }, []);

  const logout = useCallback(async () => {
    try {
      await fetchWithAuth("/api/auth/logout", { method: "POST" });
    } catch {
      /* token already dead server-side is fine */
    }
    clearToken();
    setIsAuthed(false);
    toast("Berhasil keluar.");
  }, [toast]);

  if (!isAuthed) return <Login onAuthenticated={() => setIsAuthed(true)} />;
  // Wall/TV mode: dark, read-only, no nav or menus at all.
  if (hash === "#wall") return <WallMode />;
  return <Dashboard onLogout={logout} />;
};

export default function App() {
  return (
    <ToastProvider>
      <AuthedApp />
    </ToastProvider>
  );
}
