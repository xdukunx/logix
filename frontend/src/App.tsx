// Logix Admin Dashboard -- entry shell. Auth bootstrap (OAuth return token /
// localStorage), hash-based tab routing so sections stay bookmarkable, the
// sidebar connectivity indicator, and global chrome (alerts bell, report
// download, logout). Ported from server/static/app.js.
import { useCallback, useEffect, useState } from "react";
import { AppShell } from "@astryxdesign/core/AppShell";
import { Button } from "@astryxdesign/core/Button";
import { NavIcon } from "@astryxdesign/core/NavIcon";
import { SideNav, SideNavItem, SideNavSection } from "@astryxdesign/core/SideNav";
import { HStack } from "@astryxdesign/core/Stack";
import { StatusDot } from "@astryxdesign/core/StatusDot";
import { Text } from "@astryxdesign/core/Text";
import { useToast } from "@astryxdesign/core/Toast";
import { TopNav, TopNavHeading } from "@astryxdesign/core/TopNav";
import {
  ArrowRightStartOnRectangleIcon,
  ChartBarIcon,
  Cog6ToothIcon,
  CubeIcon,
  DocumentArrowDownIcon,
  ServerStackIcon,
  SignalIcon,
} from "@heroicons/react/24/outline";

import { clearToken, fetchWithAuth, getToken, setOnSessionExpired, setToken } from "./api";
import AlertsBell from "./chrome/AlertsBell";
import Login from "./chrome/Login";
import ReportDialog from "./chrome/ReportDialog";
import { usePolling } from "./util";
import Analytics from "./views/Analytics";
import Devices from "./views/Devices";
import Monitoring from "./views/Monitoring";
import Settings from "./views/Settings";

const TABS = {
  monitoring: { title: "Monitoring", icon: SignalIcon, view: Monitoring },
  analytics: { title: "Analytics", icon: ChartBarIcon, view: Analytics },
  devices: { title: "Devices", icon: ServerStackIcon, view: Devices },
  settings: { title: "Settings", icon: Cog6ToothIcon, view: Settings },
} as const;

type TabKey = keyof typeof TABS;

const normalizeTab = (hash: string): TabKey =>
  (hash in TABS ? hash : "monitoring") as TabKey;

// Sidebar connectivity indicator: browser online/offline events plus a 20s
// GET /api/health poll -- either failing reads as disconnected.
const ConnectivityStatus = () => {
  const [state, setState] = useState<"connected" | "disconnected" | "checking">("checking");

  const check = useCallback(async () => {
    if (!navigator.onLine) {
      setState("disconnected");
      return;
    }
    try {
      const res = await fetch("/api/health", { cache: "no-store" });
      setState(res.ok ? "connected" : "disconnected");
    } catch {
      setState("disconnected");
    }
  }, []);

  usePolling(check, 20000);

  useEffect(() => {
    const onOffline = () => setState("disconnected");
    window.addEventListener("online", check);
    window.addEventListener("offline", onOffline);
    return () => {
      window.removeEventListener("online", check);
      window.removeEventListener("offline", onOffline);
    };
  }, [check]);

  const labels = {
    connected: "Server Terhubung",
    disconnected: "Terputus dari Server",
    checking: "Memeriksa Koneksi...",
  };
  const variants = { connected: "success", disconnected: "error", checking: "warning" } as const;

  return (
    <HStack gap={2} align="center">
      <StatusDot variant={variants[state]} label={labels[state]} isPulsing={state === "disconnected"} />
      <Text type="supporting" color="secondary">{labels[state]}</Text>
    </HStack>
  );
};

const Dashboard = ({ onLogout }: { onLogout: () => void }) => {
  const [tab, setTab] = useState<TabKey>(normalizeTab(window.location.hash.slice(1)));
  const [isReportOpen, setIsReportOpen] = useState(false);

  useEffect(() => {
    const onHashChange = () => setTab(normalizeTab(window.location.hash.slice(1)));
    window.addEventListener("hashchange", onHashChange);
    return () => window.removeEventListener("hashchange", onHashChange);
  }, []);

  const switchTab = (name: TabKey) => {
    setTab(name);
    if (window.location.hash.slice(1) !== name) window.location.hash = name;
  };

  const ActiveView = TABS[tab].view;

  return (
    <AppShell
      contentPadding={6}
      style={{ height: "100%", minHeight: 0 }}
      topNav={
        <TopNav
          label="Main navigation"
          heading={
            <TopNavHeading
              heading="Logix"
              logo={<NavIcon icon={<CubeIcon style={{ width: 16, height: 16 }} />} />}
            />
          }
          endContent={
            <HStack gap={2} align="center">
              <Button
                label="Unduh Laporan"
                size="sm"
                variant="ghost"
                icon={<DocumentArrowDownIcon style={{ width: 16, height: 16 }} />}
                onClick={() => setIsReportOpen(true)}
              />
              <AlertsBell />
              <Button
                label="Keluar"
                size="sm"
                variant="ghost"
                icon={<ArrowRightStartOnRectangleIcon style={{ width: 16, height: 16 }} />}
                onClick={onLogout}
              />
            </HStack>
          }
        />
      }
      sideNav={
        <SideNav
          footer={<ConnectivityStatus />}
        >
          <SideNavSection title="Lab" isHeaderHidden>
            {(Object.keys(TABS) as TabKey[]).map((key) => (
              <SideNavItem
                key={key}
                label={TABS[key].title}
                icon={TABS[key].icon}
                isSelected={tab === key}
                onClick={() => switchTab(key)}
              />
            ))}
          </SideNavSection>
        </SideNav>
      }
    >
      <ActiveView />
      <ReportDialog isOpen={isReportOpen} onOpenChange={setIsReportOpen} />
    </AppShell>
  );
};

export default function App() {
  const toast = useToast();
  const [isAuthed, setIsAuthed] = useState<boolean>(() => {
    // OAuth return: /?token=... takes precedence, then strip it from the URL
    // (referrer/history leak mitigation).
    const queryToken = new URLSearchParams(window.location.search).get("token");
    if (queryToken) {
      setToken(queryToken);
      window.history.replaceState({}, document.title, window.location.pathname + window.location.hash);
      return true;
    }
    return Boolean(getToken());
  });

  useEffect(() => {
    setOnSessionExpired(() => setIsAuthed(false));
  }, []);

  const logout = async () => {
    try {
      await fetchWithAuth("/api/auth/logout", { method: "POST" });
    } catch {
      /* token already dead server-side is fine */
    }
    clearToken();
    setIsAuthed(false);
    toast({ body: "Berhasil keluar." });
  };

  return isAuthed ? <Dashboard onLogout={logout} /> : <Login />;
}
