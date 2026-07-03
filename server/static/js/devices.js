// Devices tab (Dashboard roadmap item G): fleet-summary stat row, the full
// device registry (every device ever seen, not just currently active --
// see GET /api/devices), and a Device Detail modal with per-device sync
// health, recent command history, and Rename/Revoke actions.
import { fetchWithAuth, escapeHtml, showToast, renderError } from "./api.js";

const valTotal = document.getElementById("val-devices-total");
const valOnline = document.getElementById("val-devices-online");
const valStale = document.getElementById("val-devices-stale");
const valOffline = document.getElementById("val-devices-offline");
const valBacklog = document.getElementById("val-devices-backlog");
const devicesTbody = document.getElementById("devices-tbody");

const modal = document.getElementById("device-detail-modal");
const modalTitle = document.getElementById("device-detail-title");
const modalBody = document.getElementById("device-detail-body");
const btnCloseModal = document.getElementById("close-device-detail-modal");

let hasLoadedOnce = false;

// sync_status -> badge label/color, for the registry table and the detail
// modal's header. Distinct from AUDIT_STATUS_BADGES in analytics.js, which
// covers a different domain (per-command queued/done/failed/expired, not
// per-device online/stale/offline).
const SYNC_STATUS_BADGES = {
    online:     { label: "Online",      color: "var(--success-color)", border: "rgba(16,185,129,0.3)" },
    stale:      { label: "Stale",       color: "var(--warning-color)", border: "rgba(245,158,11,0.3)" },
    offline:    { label: "Offline",     color: "var(--muted-color)",   border: "rgba(71,85,105,0.4)" },
    never_seen: { label: "Never Seen",  color: "var(--muted-color)",   border: "rgba(71,85,105,0.4)" },
};

// Same 4-entry mapping analytics.js already defines locally as
// AUDIT_STATUS_BADGES -- duplicated here rather than imported, since the two
// tab modules aren't otherwise coupled and this is a tiny literal.
const COMMAND_STATUS_BADGES = {
    queued:  { label: "Menunggu",    color: "var(--warning-color)", border: "rgba(245,158,11,0.3)" },
    done:    { label: "Selesai",     color: "var(--success-color)", border: "rgba(16,185,129,0.3)" },
    failed:  { label: "Gagal",       color: "var(--danger-color)",  border: "rgba(239,68,68,0.3)" },
    expired: { label: "Kedaluwarsa", color: "var(--text-secondary)", border: "rgba(148,163,184,0.3)" },
};

const statusBadge = (map, status) => {
    const info = map[status] || { label: status, color: "var(--text-secondary)", border: "rgba(148,163,184,0.3)" };
    return `<span class="badge" style="border-color: ${info.border}; color: ${info.color}">${escapeHtml(info.label)}</span>`;
};

const timeAgo = (isoString) => {
    if (!isoString) return "Belum pernah";
    const seconds = Math.max(0, (Date.now() - new Date(isoString).getTime()) / 1000);
    if (seconds < 60) return "Baru saja";
    const minutes = Math.floor(seconds / 60);
    if (minutes < 60) return `${minutes} menit lalu`;
    const hours = Math.floor(minutes / 60);
    if (hours < 24) return `${hours} jam lalu`;
    const days = Math.floor(hours / 24);
    return `${days} hari lalu`;
};

export const fetchDevices = async () => {
    if (!hasLoadedOnce) {
        devicesTbody.innerHTML = `<tr><td colspan="6" class="text-center">Memuat data devices...</td></tr>`;
    }
    try {
        const res = await fetchWithAuth("/api/devices");
        if (!res.ok) throw new Error("Gagal memuat data devices");
        const devices = await res.json();
        hasLoadedOnce = true;

        const counts = { total: devices.length, online: 0, stale: 0, offline: 0 };
        devices.forEach(d => {
            if (d.sync_status === "online") counts.online++;
            else if (d.sync_status === "stale") counts.stale++;
            else counts.offline++; // offline + never_seen both read as "not reachable"
        });
        valTotal.textContent = counts.total;
        valOnline.textContent = counts.online;
        valStale.textContent = counts.stale;
        valOffline.textContent = counts.offline;

        if (devices.length === 0) {
            devicesTbody.innerHTML = `
                <tr><td colspan="6">
                    <div class="empty-state">
                        <i class="fa-solid fa-server"></i>
                        <p class="empty-title">No Devices Yet</p>
                        <p class="empty-helper">Devices will appear here once they send their first heartbeat.</p>
                    </div>
                </td></tr>
            `;
            return;
        }

        devicesTbody.innerHTML = devices.map(d => {
            const name = escapeHtml(d.display_name) || escapeHtml(d.hostname);
            return `
                <tr class="device-row" data-device-id="${escapeHtml(d.device_id)}" style="cursor: pointer;">
                    <td><strong>${name}</strong></td>
                    <td>${escapeHtml(d.hostname)}</td>
                    <td>${escapeHtml(d.category)}</td>
                    <td>${statusBadge(SYNC_STATUS_BADGES, d.sync_status)}</td>
                    <td>${timeAgo(d.last_seen)}</td>
                    <td>${escapeHtml(d.policy_profile) || "-"}</td>
                </tr>
            `;
        }).join("");
    } catch (err) {
        console.error(err);
        devicesTbody.innerHTML = `
            <tr><td colspan="6">
                <div class="empty-state">
                    <i class="fa-solid fa-triangle-exclamation" style="color: var(--danger-color)"></i>
                    <p class="empty-title">Terjadi Kesalahan</p>
                    <p class="empty-helper">Gagal memuat data devices.</p>
                </div>
            </td></tr>
        `;
    }
};

export const fetchBacklogCount = async () => {
    try {
        const res = await fetchWithAuth("/api/audit-log?status=queued&limit=1");
        if (!res.ok) throw new Error("Gagal memuat antrean perintah");
        const data = await res.json();
        valBacklog.textContent = data.total;
    } catch (err) {
        console.error(err);
    }
};

const closeModal = () => modal.classList.add("hidden");
btnCloseModal.addEventListener("click", closeModal);

const renameFromDetail = async (deviceId, hostname, currentName) => {
    const name = prompt(`Nama baru untuk ${hostname}:`, currentName || "");
    if (name === null) return;
    const trimmed = name.trim();
    if (!trimmed) {
        showToast("Nama tidak boleh kosong.", true);
        return;
    }
    try {
        const res = await fetchWithAuth("/api/devices/rename", {
            method: "PUT",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ hostname, display_name: trimmed })
        });
        if (!res.ok) throw new Error("Gagal mengubah nama device");
        showToast(`Device diganti nama menjadi "${trimmed}"`);
        openDeviceDetail(deviceId);
        fetchDevices();
    } catch (err) {
        showToast(err.message, true);
    }
};

const revokeFromDetail = async (deviceId, hostname) => {
    if (!confirm(`Cabut API key untuk ${hostname}? Device ini tidak akan bisa mengirim heartbeat sampai didaftarkan ulang.`)) return;
    try {
        const res = await fetchWithAuth(`/api/devices/${deviceId}/revoke`, { method: "POST" });
        if (!res.ok) throw new Error("Gagal mencabut API key device");
        showToast(`API key untuk ${hostname} telah dicabut.`);
        openDeviceDetail(deviceId);
        fetchDevices();
    } catch (err) {
        showToast(err.message, true);
    }
};

// Roadmap item J: retry a failed/expired command. The button only ever
// renders for rows the server already marked `retryable` (LOCK/BROADCAST,
// failed or expired, under max_retries -- see get_device_detail's comment
// on RETRYABLE_ACTION_TYPES); the endpoint enforces the same checks
// authoritatively regardless of what the UI shows.
const retryAction = async (deviceId, actionId) => {
    try {
        const res = await fetchWithAuth(`/api/devices/${deviceId}/actions/${actionId}/retry`, { method: "POST" });
        if (!res.ok) {
            const body = await res.json().catch(() => ({}));
            throw new Error(body.detail || "Gagal mengulangi perintah");
        }
        showToast("Perintah diulang dan dimasukkan ke antrean.");
        openDeviceDetail(deviceId);
        fetchDevices();
    } catch (err) {
        showToast(err.message, true);
    }
};

export const openDeviceDetail = async (deviceId) => {
    modal.classList.remove("hidden");
    modal.dataset.currentDeviceId = deviceId; // read by the delegated retry-button listener below
    modalTitle.textContent = "Device Detail";
    modalBody.innerHTML = `
        <div class="loading-placeholder">
            <i class="fa-solid fa-circle-notch fa-spin"></i>
            <p>Memuat detail device...</p>
        </div>
    `;
    try {
        const res = await fetchWithAuth(`/api/devices/${deviceId}`);
        if (!res.ok) throw new Error("Gagal memuat detail device");
        const { device, policy, recent_actions, sync_health } = await res.json();

        const name = escapeHtml(device.display_name) || escapeHtml(device.hostname);
        modalTitle.textContent = name;

        const actionsRows = recent_actions.length === 0
            ? `<tr><td colspan="5" class="text-center">Belum ada tindakan tercatat.</td></tr>`
            : recent_actions.map(a => {
                const retryNote = a.retry_count > 0
                    ? `<br><small class="text-secondary">Percobaan ke-${a.retry_count}</small>` : "";
                const retryBtn = a.retryable
                    ? `<button class="btn-action btn-sm btn-retry-action" data-action-id="${a.action_id}"><i class="fa-solid fa-rotate-right"></i> Retry</button>`
                    : "";
                return `
                    <tr>
                        <td>${new Date(a.timestamp).toLocaleString("id-ID")}</td>
                        <td>${escapeHtml(a.action_type)}${retryNote}</td>
                        <td>${statusBadge(COMMAND_STATUS_BADGES, a.status)}</td>
                        <td><small>${escapeHtml(a.result_summary) || escapeHtml(a.error_message) || "-"}</small></td>
                        <td>${retryBtn}</td>
                    </tr>
                `;
            }).join("");

        modalBody.innerHTML = `
            <div class="device-detail-grid">
                <div><span class="text-secondary">Hostname</span><br><strong>${escapeHtml(device.hostname)}</strong></div>
                <div><span class="text-secondary">Category</span><br><strong>${escapeHtml(device.category)}</strong></div>
                <div><span class="text-secondary">Status</span><br>${statusBadge(SYNC_STATUS_BADGES, device.sync_status)}</div>
                <div><span class="text-secondary">Last Seen</span><br><strong>${timeAgo(device.last_seen)}</strong></div>
                <div><span class="text-secondary">Policy</span><br><strong>${escapeHtml(device.policy_profile) || "-"}</strong>${policy ? ` <span class="text-secondary">(${escapeHtml(policy.description)})</span>` : ""}</div>
                <div><span class="text-secondary">Privacy Mode</span><br><strong>${escapeHtml(device.privacy_mode) || "-"}</strong></div>
            </div>

            <div class="section-header" style="margin-top: 20px; border-bottom: none;">
                <h2 style="font-size: 14px;"><i class="fa-solid fa-heart-pulse"></i> Sync Health</h2>
            </div>
            <div class="sync-health-badges">
                ${statusBadge(COMMAND_STATUS_BADGES, "queued")} ${sync_health.queued}
                &nbsp;&nbsp;${statusBadge(COMMAND_STATUS_BADGES, "done")} ${sync_health.done}
                &nbsp;&nbsp;${statusBadge(COMMAND_STATUS_BADGES, "failed")} ${sync_health.failed}
                &nbsp;&nbsp;${statusBadge(COMMAND_STATUS_BADGES, "expired")} ${sync_health.expired}
            </div>

            <div class="section-header" style="margin-top: 20px; border-bottom: none;">
                <h2 style="font-size: 14px;"><i class="fa-solid fa-clock-rotate-left"></i> Recent Commands</h2>
            </div>
            <div class="table-wrapper">
                <table class="logs-table">
                    <thead><tr><th>Timestamp</th><th>Tindakan</th><th>Status</th><th>Ringkasan</th><th>Aksi</th></tr></thead>
                    <tbody>${actionsRows}</tbody>
                </table>
            </div>

            <div class="message-card-footer" style="margin-top: 20px;">
                <button class="btn-action btn-sm" id="btn-detail-rename"><i class="fa-solid fa-pen"></i> Rename</button>
                <button class="btn-action btn-sm btn-danger" id="btn-detail-revoke"><i class="fa-solid fa-ban"></i> Revoke API Key</button>
            </div>
        `;

        document.getElementById("btn-detail-rename").addEventListener("click", () => {
            renameFromDetail(deviceId, device.hostname, device.display_name);
        });
        document.getElementById("btn-detail-revoke").addEventListener("click", () => {
            revokeFromDetail(deviceId, device.hostname);
        });
    } catch (err) {
        console.error(err);
        renderError(modalBody, "Gagal memuat detail device.");
    }
};

devicesTbody.addEventListener("click", (e) => {
    const row = e.target.closest(".device-row");
    if (!row) return;
    openDeviceDetail(row.dataset.deviceId);
});

// Delegated (not re-attached per open, unlike Rename/Revoke's by-id lookup)
// since Recent Commands can render zero-to-many Retry buttons per row.
modalBody.addEventListener("click", (e) => {
    const btn = e.target.closest(".btn-retry-action");
    if (!btn) return;
    retryAction(modal.dataset.currentDeviceId, btn.dataset.actionId);
});
