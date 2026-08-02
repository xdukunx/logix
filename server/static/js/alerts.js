// System Alerts (roadmap item I): the header bell + dropdown panel. Global
// chrome, not tab content -- visible and polled regardless of which tab
// (Monitoring/Analytics/Devices/Settings) is currently open, same footing
// as the sidebar connectivity indicator and offline banner.
import { fetchWithAuth, escapeHtml, showToast, renderError } from "./api.js";

const bellBtn = document.getElementById("btn-alerts-bell");
const badge = document.getElementById("alerts-badge");
const panel = document.getElementById("alerts-panel");
const panelBody = document.getElementById("alerts-panel-body");

let hasLoadedOnce = false;

// Distinct from devices.js's SYNC_STATUS_BADGES / COMMAND_STATUS_BADGES --
// a different domain (alert severity, not device or command status) --
// duplicated locally rather than imported, matching this codebase's
// existing per-tab-module convention for these small literal mappings.
const SEVERITY_BADGES = {
    info:     { icon: "fa-circle-info",         color: "var(--primary-color)" },
    warning:  { icon: "fa-triangle-exclamation", color: "var(--warning-color)" },
    critical: { icon: "fa-circle-exclamation",   color: "var(--danger-color)" },
};

const timeAgo = (isoString) => {
    if (!isoString) return "";
    const seconds = Math.max(0, (Date.now() - new Date(isoString).getTime()) / 1000);
    if (seconds < 60) return "Baru saja";
    const minutes = Math.floor(seconds / 60);
    if (minutes < 60) return `${minutes} menit lalu`;
    const hours = Math.floor(minutes / 60);
    if (hours < 24) return `${hours} jam lalu`;
    const days = Math.floor(hours / 24);
    return `${days} hari lalu`;
};

const acknowledgeAlert = async (alertId) => {
    try {
        const res = await fetchWithAuth(`/api/alerts/${alertId}/acknowledge`, { method: "POST" });
        if (!res.ok) throw new Error("Gagal menandai peringatan");
        showToast("Peringatan ditandai sebagai diketahui.");
        fetchAlerts();
    } catch (err) {
        showToast(err.message, true);
    }
};

const renderAlerts = (alerts) => {
    if (alerts.length === 0) {
        panelBody.innerHTML = `
            <div class="empty-state">
                <p class="empty-title">Tidak ada peringatan aktif.</p>
            </div>
        `;
        return;
    }

    panelBody.innerHTML = alerts.map(a => {
        const badgeInfo = SEVERITY_BADGES[a.severity] || SEVERITY_BADGES.info;
        const isAcknowledged = a.status === "acknowledged";
        return `
            <div class="alert-item ${isAcknowledged ? "acknowledged" : ""}" data-alert-id="${a.id}">
                <div class="alert-item-icon"><span class="status-dot" style="background: ${badgeInfo.color}"></span></div>
                <div class="alert-item-body">
                    <div class="alert-item-title">${escapeHtml(a.title)}</div>
                    <div class="alert-item-message">${escapeHtml(a.message)}</div>
                    <div class="alert-item-meta">${timeAgo(a.created_at)}${isAcknowledged ? " · Diketahui" : ""}</div>
                </div>
                ${!isAcknowledged ? `<button class="btn-action btn-sm btn-ack-alert" data-alert-id="${a.id}">Tandai Diketahui</button>` : ""}
            </div>
        `;
    }).join("");
};

export const fetchAlerts = async () => {
    if (!hasLoadedOnce) {
        panelBody.innerHTML = `
            <div class="loading-placeholder">
                <p>Memuat peringatan...</p>
            </div>
        `;
    }
    try {
        const res = await fetchWithAuth("/api/alerts?active=true");
        if (!res.ok) throw new Error("Gagal memuat peringatan");
        const data = await res.json();
        hasLoadedOnce = true;

        const unacknowledgedCount = data.alerts.filter(a => a.status === "active").length;
        badge.textContent = unacknowledgedCount;
        badge.classList.toggle("hidden", unacknowledgedCount === 0);

        renderAlerts(data.alerts);
    } catch (err) {
        console.error(err);
        renderError(panelBody, "Gagal memuat peringatan.");
    }
};

panelBody.addEventListener("click", (e) => {
    const btn = e.target.closest(".btn-ack-alert");
    if (!btn) return;
    acknowledgeAlert(btn.dataset.alertId);
});

bellBtn.addEventListener("click", (e) => {
    e.stopPropagation();
    const willOpen = panel.classList.contains("hidden");
    panel.classList.toggle("hidden", !willOpen);
    if (willOpen) fetchAlerts();
});

document.addEventListener("click", (e) => {
    if (!panel.contains(e.target) && e.target !== bellBtn) {
        panel.classList.add("hidden");
    }
});
