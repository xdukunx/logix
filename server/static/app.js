// Logix Admin Dashboard — entry point. Tab routing (hash-based, so
// sections are bookmarkable/refreshable), auth bootstrap, and polling.
// Feature logic lives in js/*.js, imported below.
import { getToken, setToken, clearToken, fetchWithAuth, setOnSessionExpired, showToast } from "./js/api.js";
import { fetchActiveWorkstations } from "./js/monitoring.js";
import { fetchAnalytics, fetchSessionLogs, fetchAuditLog } from "./js/analytics.js";
import { loadConfiguration } from "./js/settings.js";
import "./js/report-modal.js"; // self-wires its own listeners on import

const loginOverlay = document.getElementById("login-overlay");
const appWrapper = document.getElementById("app-wrapper");
const btnLogout = document.getElementById("btn-logout");
const pageTitle = document.getElementById("page-title");
const navButtons = document.querySelectorAll(".sidebar-nav-item[data-tab]");

const TABS = {
    monitoring: { title: "Monitoring", onShow: () => fetchActiveWorkstations() },
    analytics: { title: "Analytics", onShow: () => { fetchAnalytics(); fetchSessionLogs(); fetchAuditLog(); } },
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
};

setOnSessionExpired(showLoginScreen);

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
    if (currentTab === "monitoring") fetchActiveWorkstations();
    if (currentTab === "analytics") fetchAnalytics();
}, 10000);

setInterval(() => {
    if (!getToken()) return;
    if (currentTab === "analytics") {
        fetchSessionLogs();
        fetchAuditLog();
    }
}, 30000);
