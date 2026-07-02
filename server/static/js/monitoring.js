// Monitoring tab: active-device summary, workstation cards, empty state,
// lock command, and the inline message/broadcast card.
import { fetchWithAuth, escapeHtml, showToast } from "./api.js";

const pcsGrid = document.getElementById("pcs-grid");
const valActivePcs = document.getElementById("val-active-pcs");
const pcCountBadge = document.getElementById("pc-count-badge");

const messageTextarea = document.getElementById("message-textarea");
const btnSendMessage = document.getElementById("btn-send-message");
const messageHelperText = document.getElementById("message-helper-text");
const messageTypeButtons = document.querySelectorAll(".message-type-btn");

let activeDeviceCount = 0;
let selectedMessageType = "direction"; // "direction" | "emergency"

// Send Lock Command
const lockWorkstation = async (hostname) => {
    if (!confirm(`Apakah Anda yakin ingin mengunci stasiun ${hostname} secara paksa?`)) return;
    try {
        const res = await fetchWithAuth("/api/control/lock", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ hostname })
        });
        if (!res.ok) throw new Error("Gagal mengirim perintah kunci");
        showToast(`Perintah KUNCI ditambahkan ke antrean stasiun ${hostname}`);
        fetchActiveWorkstations();
    } catch (err) {
        showToast(err.message, true);
    }
};

// Delegated listener for lock buttons (data-attribute + event delegation,
// not inline onclick -- avoids JS-string-context injection via
// agent-supplied hostname).
pcsGrid.addEventListener("click", (e) => {
    const btn = e.target.closest("[data-lock-hostname]");
    if (btn) lockWorkstation(btn.dataset.lockHostname);
});

const updateMessageCardGating = () => {
    const hasActiveDevices = activeDeviceCount > 0;
    btnSendMessage.disabled = !hasActiveDevices;
    messageHelperText.textContent = hasActiveDevices
        ? "Everything active is the target — no device selection needed."
        : "No active devices to message right now.";
};

// Fetch and Render Active Workstations
export const fetchActiveWorkstations = async () => {
    try {
        const res = await fetchWithAuth("/api/active");
        if (!res.ok) throw new Error("Gagal mengambil data workstation aktif");
        const pcs = await res.json();

        activeDeviceCount = pcs.length;
        valActivePcs.textContent = pcs.length;
        pcCountBadge.textContent = `${pcs.length} Aktif`;
        updateMessageCardGating();

        if (pcs.length === 0) {
            pcsGrid.innerHTML = `
                <div class="empty-state">
                    <i class="fa-solid fa-laptop-slash"></i>
                    <p class="empty-title">No Active Devices</p>
                    <p class="empty-helper">Active devices will appear here once a workstation starts a session.</p>
                </div>
            `;
            return;
        }

        pcsGrid.innerHTML = pcs.map(pc => {
            const lastSeenDate = new Date(pc.last_seen);
            const timeStr = lastSeenDate.toLocaleTimeString("id-ID", { hour: "2-digit", minute: "2-digit" });
            const statusClass = pc.status.toLowerCase();
            const statusLabel = pc.status === "ACTIVE" ? "Dalam Penggunaan" : "Terkunci";
            const isUserActive = pc.status === "ACTIVE";
            const hostname = escapeHtml(pc.hostname);
            const deviceName = escapeHtml(pc.device_name) || hostname;
            const showHostnameMeta = pc.device_name && pc.device_name !== pc.hostname;

            return `
                <div class="workstation-card">
                    <div class="ws-status-light ${statusClass}"></div>
                    <div class="ws-host">${deviceName}</div>
                    ${showHostnameMeta ? `<div class="ws-meta">Hostname: ${hostname}</div>` : ""}
                    <div class="ws-meta">Status: ${statusLabel}</div>
                    <div class="ws-meta"><i class="fa-regular fa-clock"></i> Aktif: ${timeStr}</div>
                    ${pc.username ? `
                        <div class="ws-user-box">
                            <p>Pengguna:</p>
                            <strong>${escapeHtml(pc.username)}</strong>
                        </div>
                    ` : ""}
                    <div class="ws-controls">
                        ${pc.anydesk_id ? `
                            <a href="anydesk:${escapeHtml(pc.anydesk_id)}" class="btn-anydesk-remote" title="Remote via AnyDesk">
                                <i class="fa-solid fa-desktop"></i> Remote
                            </a>
                        ` : `
                            <button class="btn-anydesk-remote" style="opacity:0.4; cursor:not-allowed;" title="AnyDesk ID tidak terdeteksi" disabled>
                                <i class="fa-solid fa-desktop"></i> Remote
                            </button>
                        `}
                        ${isUserActive ? `
                            <button class="btn-ws-lock" data-lock-hostname="${hostname}">
                                <i class="fa-solid fa-lock"></i> Lock
                            </button>
                        ` : `
                            <button class="btn-ws-lock" style="opacity:0.4; cursor:not-allowed;" disabled>
                                <i class="fa-solid fa-lock"></i> Lock
                            </button>
                        `}
                    </div>
                </div>
            `;
        }).join("");

    } catch (err) {
        console.error(err);
    }
};

// Message type selector (Direction Message / Emergency Alert)
messageTypeButtons.forEach(btn => {
    btn.addEventListener("click", () => {
        selectedMessageType = btn.dataset.type;
        messageTypeButtons.forEach(b => b.classList.toggle("active", b === btn));
    });
});

// Send message/broadcast to all active workstations. Both message types
// target every active device automatically -- Direction Message is a
// general instruction, Emergency Alert additionally requires confirmation.
// Both reuse the existing /api/control/broadcast endpoint (hostname: "ALL"),
// which already produces an audit-log row via the `reason` field.
btnSendMessage.addEventListener("click", async () => {
    const message = messageTextarea.value.trim();
    if (!message) {
        showToast("Tulis pesan terlebih dahulu.", true);
        return;
    }
    if (activeDeviceCount === 0) return;

    if (selectedMessageType === "emergency") {
        if (!confirm("Emergency alert will be sent to all active workstations. Continue?")) return;
    }

    const reason = selectedMessageType === "emergency" ? "Emergency Alert" : "Direction Message";

    try {
        const res = await fetchWithAuth("/api/control/broadcast", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ hostname: "ALL", param: message, reason })
        });
        if (!res.ok) throw new Error("Gagal mengirim pesan");
        showToast(`${reason} sent to all active workstations.`);
        messageTextarea.value = "";
    } catch (err) {
        showToast(err.message, true);
    }
});
