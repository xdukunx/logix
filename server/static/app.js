// Logix Admin Dashboard — entry point. Tab routing (hash-based, so
// sections are bookmarkable/refreshable), auth bootstrap, and polling.
// Feature logic lives in js/*.js, imported below.
import { getToken, setToken, clearToken, fetchWithAuth, setOnSessionExpired, showToast } from "./js/api.js";
import { fetchActiveWorkstations, fetchReplies } from "./js/monitoring.js";
import { fetchAnalytics, fetchSessionLogs, fetchAuditLog } from "./js/analytics.js";
import { loadConfiguration } from "./js/settings.js";
import { fetchDevices, fetchBacklogCount } from "./js/devices.js";
import { fetchAlerts } from "./js/alerts.js";
import "./js/report-modal.js"; // self-wires its own listeners on import

const loginOverlay = document.getElementById("login-overlay");
const appWrapper = document.getElementById("app-wrapper");
const btnLogout = document.getElementById("btn-logout");
const pageTitle = document.getElementById("page-title");
const navButtons = document.querySelectorAll(".sidebar-nav-item[data-tab]");

const serverStatusEl = document.getElementById("server-status");
const serverStatusDot = document.getElementById("server-status-dot");
const serverStatusText = document.getElementById("server-status-text");

const TABS = {
    monitoring: { title: "Monitoring", onShow: () => { fetchActiveWorkstations(); fetchReplies(); } },
    analytics: { title: "Analytics", onShow: () => { fetchAnalytics(); fetchSessionLogs(); fetchAuditLog(); } },
    devices: { title: "Devices", onShow: () => { fetchDevices(); fetchBacklogCount(); } },
    settings: { title: "Settings", onShow: () => loadConfiguration() },
};

let currentTab = "monitoring";

const switchTab = (tabName) => {
    if (!TABS[tabName]) tabName = "monitoring";
    currentTab = tabName;
    Object.keys(TABS).forEach(name => {
        document.getElementById(`tab-${name}`).hidden = name !== tabName;
        document.getElementById(`nav-${name}`).classList.toggle("active", name === tabName);
    });
    pageTitle.textContent = TABS[tabName].title;
    if (window.location.hash.slice(1) !== tabName) {
        window.location.hash = tabName;
    }
    TABS[tabName].onShow();
};

navButtons.forEach(btn => btn.addEventListener("click", () => switchTab(btn.dataset.tab)));
window.addEventListener("hashchange", () => switchTab(window.location.hash.slice(1)));

const showLoginScreen = () => {
    loginOverlay.classList.remove("hidden");
    appWrapper.classList.add("hidden");
};

const showAppScreen = () => {
    loginOverlay.classList.add("hidden");
    appWrapper.classList.remove("hidden");
    switchTab(window.location.hash.slice(1) || "monitoring");
    fetchAlerts();
};

setOnSessionExpired(showLoginScreen);

// Local admin login (email + password). Google OAuth was removed; this posts
// to /api/auth/login and stores the returned session token.
const loginForm = document.getElementById("login-form");
if (loginForm) {
    loginForm.addEventListener("submit", async (e) => {
        e.preventDefault();
        const email = document.getElementById("login-email").value.trim();
        const password = document.getElementById("login-password").value;
        const errEl = document.getElementById("login-error");
        const btn = document.getElementById("login-submit");
        errEl.style.display = "none";
        btn.disabled = true;
        try {
            const res = await fetch("/api/auth/login", {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({ email, password }),
            });
            if (!res.ok) {
                const body = await res.json().catch(() => ({}));
                throw new Error(body.detail || "Gagal masuk. Periksa email dan password.");
            }
            const body = await res.json();
            setToken(body.token);
            showToast("Login berhasil!");
            showAppScreen();
        } catch (err) {
            errEl.textContent = err.message;
            errEl.style.display = "block";
        } finally {
            btn.disabled = false;
        }
    });
}

// Real sidebar connectivity indicator (roadmap item H) -- replaces the old
// static "Server Terhubung" dot, which stayed green even while the offline
// banner (js/api.js) was red. Reuses the same browser online/offline signal
// as that banner, plus a lightweight GET /api/health poll so "the network
// adapter is up" and "the server process is actually answering" are both
// covered -- either one failing should read as disconnected.
const STATUS_LABELS = {
    connected: "Server Terhubung",
    disconnected: "Terputus dari Server",
    checking: "Memeriksa Koneksi...",
};

const setConnectivityState = (state) => {
    serverStatusEl.classList.remove("connected", "disconnected", "checking");
    serverStatusEl.classList.add(state);
    serverStatusDot.classList.remove("online", "offline", "checking");
    serverStatusDot.classList.add(state === "connected" ? "online" : state === "disconnected" ? "offline" : "checking");
    serverStatusText.textContent = STATUS_LABELS[state];
};

let serverReachable = null; // unknown until the first check resolves

const checkServerHealth = async () => {
    if (!navigator.onLine) {
        serverReachable = false;
        setConnectivityState("disconnected");
        return;
    }
    if (serverReachable !== true) setConnectivityState("checking");
    try {
        const res = await fetch("/api/health", { cache: "no-store" });
        serverReachable = res.ok;
        setConnectivityState(res.ok ? "connected" : "disconnected");
    } catch (err) {
        serverReachable = false;
        setConnectivityState("disconnected");
    }
};

window.addEventListener("online", checkServerHealth);
window.addEventListener("offline", () => {
    serverReachable = false;
    setConnectivityState("disconnected");
});

checkServerHealth();
setInterval(checkServerHealth, 20000);

// Logout Handler
btnLogout.addEventListener("click", async () => {
    try {
        await fetchWithAuth("/api/auth/logout", { method: "POST" });
    } catch (e) {}
    clearToken();
    showLoginScreen();
    showToast("Berhasil keluar.");
});

// Initial Setup: check URL for OAuth return token, else localStorage.
const urlParams = new URLSearchParams(window.location.search);
const queryToken = urlParams.get("token");
if (queryToken) {
    setToken(queryToken);
    // Strip token query param from browser bar to clean up (referrer/history leak mitigation).
    window.history.replaceState({}, document.title, window.location.pathname + window.location.hash);
    showToast("Login berhasil!");
    showAppScreen();
} else if (getToken()) {
    showAppScreen();
} else {
    showLoginScreen();
}

// Auto Polling -- only refreshes data for the currently visible tab.
setInterval(() => {
    if (!getToken()) return;
    if (currentTab === "monitoring") { fetchActiveWorkstations(); fetchReplies(); }
    if (currentTab === "analytics") fetchAnalytics();
    if (currentTab === "devices") { fetchDevices(); fetchBacklogCount(); }
}, 10000);

setInterval(() => {
    if (!getToken()) return;
    if (currentTab === "analytics") {
        fetchSessionLogs();
        fetchAuditLog();
    }
}, 30000);

// Alerts are global chrome (the header bell), not tied to any one tab, so
// this poll runs regardless of currentTab -- same footing as the sidebar
// connectivity check. 30s matches the other "not urgent, not slow" polls
// above rather than the 10s tab-refresh cadence, per "no heavy polling".
setInterval(() => {
    if (!getToken()) return;
    fetchAlerts();
}, 30000);
