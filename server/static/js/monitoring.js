// Monitoring tab: active-device summary, workstation cards, empty state,
// lock command, the right-click context menu (active sessions only), and
// the inline message/broadcast card.
import { fetchWithAuth, escapeHtml, showToast, renderError } from "./api.js";

const pcsGrid = document.getElementById("pcs-grid");
const valActivePcs = document.getElementById("val-active-pcs");
const pcCountBadge = document.getElementById("pc-count-badge");
const contextMenu = document.getElementById("ws-context-menu");

const messageTextarea = document.getElementById("message-textarea");
const btnSendMessage = document.getElementById("btn-send-message");
const messageHelperText = document.getElementById("message-helper-text");

let activeDeviceCount = 0;

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

// Send a direct message to one specific workstation -- shows inline near
// the user's session timer, not a modal (see windows/logbook_timer.ps1).
// Distinct from the Emergency Alert card below, which always targets every
// active device. Reuses /api/control/broadcast, which already accepts a
// single hostname.
const sendDirectMessage = async (hostname) => {
    const message = prompt(`Pesan untuk ${hostname}:`, "");
    if (!message || !message.trim()) return;
    try {
        const res = await fetchWithAuth("/api/control/broadcast", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ hostname, param: message.trim(), reason: "Direction Message" })
        });
        if (!res.ok) throw new Error("Gagal mengirim pesan");
        showToast(`Pesan dikirim ke ${hostname}`);
    } catch (err) {
        showToast(err.message, true);
    }
};

// Rename a device from the dashboard. Sticks across future heartbeats --
// see display_name_set_by_admin in server/main.py.
const renameWorkstation = async (hostname, currentName) => {
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
        fetchActiveWorkstations();
    } catch (err) {
        showToast(err.message, true);
    }
};

// --- Right-click context menu (active sessions only) -----------------------
// Built and positioned on demand rather than kept in the DOM per-card --
// one shared <ul>, populated from the clicked card's data-* attributes.

const hideContextMenu = () => {
    contextMenu.classList.remove("visible");
    contextMenu.innerHTML = "";
};

const menuItem = (label, icon, { disabled = false, danger = false, onClick = null, title = "" } = {}) => {
    const li = document.createElement("li");
    li.className = "context-menu-item" + (disabled ? " disabled" : "") + (danger ? " danger" : "");
    li.innerHTML = `<i class="fa-solid ${icon}"></i> ${escapeHtml(label)}`;
    if (title) li.title = title;
    if (!disabled && onClick) {
        li.addEventListener("click", () => {
            hideContextMenu();
            onClick();
        });
    }
    return li;
};

const showContextMenu = (x, y, card) => {
    const hostname = card.dataset.hostname;
    const deviceName = card.dataset.deviceName;
    const anydeskId = card.dataset.anydeskId;

    contextMenu.innerHTML = "";
    if (anydeskId) {
        const link = document.createElement("a");
        link.href = `anydesk:${anydeskId}`;
        link.className = "context-menu-item";
        link.innerHTML = `<i class="fa-solid fa-desktop"></i> Remote`;
        link.addEventListener("click", hideContextMenu);
        contextMenu.appendChild(link);
    } else {
        contextMenu.appendChild(menuItem("Remote", "fa-desktop", { disabled: true, title: "AnyDesk ID tidak terdeteksi" }));
    }
    contextMenu.appendChild(menuItem("Lock", "fa-lock", { onClick: () => lockWorkstation(hostname) }));
    contextMenu.appendChild(menuItem("Rename", "fa-pen", { onClick: () => renameWorkstation(hostname, deviceName) }));
    const sep = document.createElement("li");
    sep.className = "context-menu-separator";
    contextMenu.appendChild(sep);
    contextMenu.appendChild(menuItem("Send Message", "fa-message", { onClick: () => sendDirectMessage(hostname) }));

    contextMenu.classList.add("visible");
    // Clamp so the menu never renders off-screen.
    const rect = contextMenu.getBoundingClientRect();
    const maxX = window.innerWidth - rect.width - 8;
    const maxY = window.innerHeight - rect.height - 8;
    contextMenu.style.left = `${Math.max(8, Math.min(x, maxX))}px`;
    contextMenu.style.top = `${Math.max(8, Math.min(y, maxY))}px`;
};

pcsGrid.addEventListener("contextmenu", (e) => {
    const card = e.target.closest(".workstation-card");
    if (!card || card.dataset.active !== "true") return; // let the browser's default menu show
    e.preventDefault();
    showContextMenu(e.clientX, e.clientY, card);
});

document.addEventListener("click", (e) => {
    if (!contextMenu.contains(e.target)) hideContextMenu();
});
document.addEventListener("keydown", (e) => {
    if (e.key === "Escape") hideContextMenu();
});
window.addEventListener("scroll", hideContextMenu, true);
window.addEventListener("resize", hideContextMenu);

const updateMessageCardGating = () => {
    const hasActiveDevices = activeDeviceCount > 0;
    btnSendMessage.disabled = !hasActiveDevices;
    messageHelperText.textContent = hasActiveDevices
        ? "Sent to every active device — no individual selection needed. For a single device, right-click its card instead."
        : "No active devices to alert right now.";
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
                <div class="workstation-card"
                     data-hostname="${hostname}"
                     data-device-name="${deviceName}"
                     data-anydesk-id="${escapeHtml(pc.anydesk_id) || ""}"
                     data-active="${isUserActive}">
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
                    ${isUserActive ? `
                        <div class="ws-meta ws-context-hint"><i class="fa-solid fa-computer-mouse"></i> Klik kanan untuk opsi (Remote, Lock, Rename, Send Message)</div>
                    ` : ""}
                </div>
            `;
        }).join("");

    } catch (err) {
        console.error(err);
        renderError(pcsGrid, "Gagal memuat status workstation.");
    }
};

// Send an Emergency Alert to every active workstation. Always targets
// "ALL" and always confirms -- this card no longer has a non-emergency
// mode; a targeted message to one device is the context menu's "Send
// Message" action above. Reuses the existing /api/control/broadcast
// endpoint, which already produces an audit-log row via the `reason` field.
btnSendMessage.addEventListener("click", async () => {
    const message = messageTextarea.value.trim();
    if (!message) {
        showToast("Tulis pesan terlebih dahulu.", true);
        return;
    }
    if (activeDeviceCount === 0) return;

    if (!confirm("Emergency alert will be sent to all active workstations. Continue?")) return;

    try {
        const res = await fetchWithAuth("/api/control/broadcast", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ hostname: "ALL", param: message, reason: "Emergency Alert" })
        });
        if (!res.ok) throw new Error("Gagal mengirim pesan");
        showToast("Emergency Alert sent to all active workstations.");
        messageTextarea.value = "";
    } catch (err) {
        showToast(err.message, true);
    }
});
