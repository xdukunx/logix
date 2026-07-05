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
    // No confirmation (product decision): lock fires immediately.
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

// Request an on-demand screenshot (Logix Control screen view). The agent
// notifies the person at the device that a capture happened -- never
// silent -- and only the latest capture per device is kept server-side.
// View it from the device's row in the Devices tab (Device Detail modal).
const requestScreenshot = async (hostname) => {
    const reason = prompt(`Alasan mengambil screenshot ${hostname} (kebijakan device dapat mewajibkan ini):`, "");
    if (reason === null) return;
    try {
        const res = await fetchWithAuth("/api/control/screenshot", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ hostname, reason: reason.trim() })
        });
        if (!res.ok) {
            const body = await res.json().catch(() => ({}));
            throw new Error(body.detail || "Gagal meminta screenshot");
        }
        showToast(`Permintaan screenshot dikirim ke ${hostname}. Hasilnya muncul di Device Detail (tab Devices).`);
    } catch (err) {
        showToast(err.message, true);
    }
};

// Power actions (Logix Control): shutdown / restart / logoff. The agent
// gives the user a 30-second on-screen warning before executing.
const POWER_LABELS = {
    shutdown: "mematikan",
    restart: "memulai ulang",
    logoff: "mengeluarkan pengguna dari",
};

const sendPowerCommand = async (hostname, action) => {
    if (!confirm(`Yakin ingin ${POWER_LABELS[action]} ${hostname}? Pengguna diberi peringatan 30 detik.`)) return;
    const reason = prompt(`Alasan (kebijakan device dapat mewajibkan ini):`, "");
    if (reason === null) return;
    try {
        const res = await fetchWithAuth("/api/control/power", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ hostname, action, reason: reason.trim() })
        });
        if (!res.ok) {
            const body = await res.json().catch(() => ({}));
            throw new Error(body.detail || "Gagal mengirim perintah daya");
        }
        showToast(`Perintah ${action.toUpperCase()} ditambahkan ke antrean ${hostname}.`);
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
    contextMenu.appendChild(menuItem("Screenshot", "fa-camera", { onClick: () => requestScreenshot(hostname) }));
    contextMenu.appendChild(menuItem("Rename", "fa-pen", { onClick: () => renameWorkstation(hostname, deviceName) }));
    const sep = document.createElement("li");
    sep.className = "context-menu-separator";
    contextMenu.appendChild(sep);
    contextMenu.appendChild(menuItem("Send Message", "fa-message", { onClick: () => sendDirectMessage(hostname) }));
    const sep2 = document.createElement("li");
    sep2.className = "context-menu-separator";
    contextMenu.appendChild(sep2);
    contextMenu.appendChild(menuItem("Log Off User", "fa-user-slash", { onClick: () => sendPowerCommand(hostname, "logoff") }));
    contextMenu.appendChild(menuItem("Restart", "fa-rotate", { danger: true, onClick: () => sendPowerCommand(hostname, "restart") }));
    contextMenu.appendChild(menuItem("Shut Down", "fa-power-off", { danger: true, onClick: () => sendPowerCommand(hostname, "shutdown") }));

    contextMenu.classList.add("visible");
    // Clamp so the menu never renders off-screen.
    const rect = contextMenu.getBoundingClientRect();
    const maxX = window.innerWidth - rect.width - 8;
    const maxY = window.innerHeight - rect.height - 8;
    contextMenu.style.left = `${Math.max(8, Math.min(x, maxX))}px`;
    contextMenu.style.top = `${Math.max(8, Math.min(y, maxY))}px`;
};

// Document-level, not grid-only: after the first open the menu sits under the
// cursor, so a second right-click landed ON the menu (not a card), the old
// handler's closest(".workstation-card") returned null, preventDefault never
// ran, and the browser's Inspect/Reload menu appeared -- the "works once" bug.
// Card -> our menu; on our menu -> keep it (no native menu); anywhere else ->
// dismiss ours and let the native menu through.
document.addEventListener("contextmenu", (e) => {
    const card = e.target.closest(".workstation-card");
    if (card && card.dataset.active === "true") {
        e.preventDefault();
        showContextMenu(e.clientX, e.clientY, card);
    } else if (contextMenu.contains(e.target)) {
        e.preventDefault();
    } else {
        hideContextMenu();
    }
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
                    <button class="ws-reply-badge hidden" data-hostname="${hostname}" title="Balasan pengguna belum dibaca">
                        <i class="fa-solid fa-comment-dots"></i> <span class="ws-reply-count">0</span>
                    </button>
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
                        <div class="ws-meta ws-context-hint"><i class="fa-solid fa-computer-mouse"></i> Klik kanan untuk opsi (Remote, Lock, Screenshot, Message, Power)</div>
                    ` : ""}
                </div>
            `;
        }).join("");

        renderReplyBadges();
    } catch (err) {
        console.error(err);
        renderError(pcsGrid, "Gagal memuat status workstation.");
    }
};

// --- User replies as a per-card notification badge -------------------------
// Replies surface on the device's own workstation card (a badge), not a
// separate section. Clicking the badge opens a floating popover listing that
// device's replies with a "mark all read" action.
const replyPopover = document.getElementById("reply-popover");
let repliesByHost = {};

const timeAgo = (iso) => {
    if (!iso) return "";
    const s = Math.max(0, (Date.now() - new Date(iso).getTime()) / 1000);
    if (s < 60) return "Baru saja";
    const m = Math.floor(s / 60);
    if (m < 60) return `${m} menit lalu`;
    const h = Math.floor(m / 60);
    if (h < 24) return `${h} jam lalu`;
    return `${Math.floor(h / 24)} hari lalu`;
};

const unreadFor = (hostname) => (repliesByHost[hostname] || []).filter(r => !r.read_at).length;

const renderReplyBadges = () => {
    pcsGrid.querySelectorAll(".workstation-card").forEach(card => {
        const badge = card.querySelector(".ws-reply-badge");
        if (!badge) return;
        const n = unreadFor(card.dataset.hostname);
        const countEl = badge.querySelector(".ws-reply-count");
        if (countEl) countEl.textContent = n;
        badge.classList.toggle("hidden", n === 0);
    });
};

export const fetchReplies = async () => {
    try {
        const res = await fetchWithAuth("/api/replies?limit=100");
        if (!res.ok) return; // 403 (role can't read) or transient error: leave badges as-is
        const data = await res.json();
        repliesByHost = {};
        for (const r of (data.replies || [])) {
            (repliesByHost[r.hostname] = repliesByHost[r.hostname] || []).push(r);
        }
        renderReplyBadges();
    } catch (err) {
        console.error(err);
    }
};

const hideReplyPopover = () => { replyPopover.classList.add("hidden"); replyPopover.innerHTML = ""; };

const showReplyPopover = (hostname, anchor) => {
    const replies = (repliesByHost[hostname] || []).slice()
        .sort((a, b) => new Date(b.created_at) - new Date(a.created_at));
    if (replies.length === 0) return;
    replyPopover.innerHTML = `
        <div class="reply-popover-head">
            <span><i class="fa-solid fa-comments"></i> ${escapeHtml(replies[0].device_name || hostname)}</span>
            <button class="reply-popover-close" aria-label="Tutup">&times;</button>
        </div>
        <div class="reply-popover-body">
            ${replies.map(r => `
                <div class="reply-row ${r.read_at ? "" : "unread"}">
                    <div class="reply-row-msg">${escapeHtml(r.message)}</div>
                    <div class="reply-row-meta">${timeAgo(r.created_at)}${r.read_at ? " · Dibaca" : ""}</div>
                </div>`).join("")}
        </div>
        <div class="reply-popover-foot">
            <button class="btn-action btn-sm" id="reply-mark-all" data-hostname="${escapeHtml(hostname)}">Tandai semua dibaca</button>
        </div>`;
    replyPopover.classList.remove("hidden");
    const rect = anchor.getBoundingClientRect();
    const pr = replyPopover.getBoundingClientRect();
    let left = Math.min(rect.right - pr.width, window.innerWidth - pr.width - 8);
    let top = rect.bottom + 6;
    if (top + pr.height > window.innerHeight - 8) top = rect.top - pr.height - 6;
    replyPopover.style.left = `${Math.max(8, left)}px`;
    replyPopover.style.top = `${Math.max(8, top)}px`;
};

const markAllRead = async (hostname) => {
    const unread = (repliesByHost[hostname] || []).filter(r => !r.read_at);
    await Promise.all(unread.map(r =>
        fetchWithAuth(`/api/replies/${r.id}/read`, { method: "POST" }).catch(() => {})));
    hideReplyPopover();
    fetchReplies();
};

pcsGrid.addEventListener("click", (e) => {
    const badge = e.target.closest(".ws-reply-badge");
    if (badge) { e.stopPropagation(); showReplyPopover(badge.dataset.hostname, badge); }
});
replyPopover.addEventListener("click", (e) => {
    if (e.target.closest(".reply-popover-close")) { hideReplyPopover(); return; }
    const markBtn = e.target.closest("#reply-mark-all");
    if (markBtn) markAllRead(markBtn.dataset.hostname);
});
document.addEventListener("click", (e) => {
    if (!replyPopover.classList.contains("hidden")
        && !replyPopover.contains(e.target)
        && !e.target.closest(".ws-reply-badge")) hideReplyPopover();
});

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

    // No confirmation (product decision): the emergency alert sends immediately.
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
