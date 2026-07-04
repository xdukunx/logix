// Balasan Pengguna (Monitoring tab): messages typed by the person at a
// workstation in answer to an admin broadcast/direct message -- the other
// half of the send-message flow in monitoring.js. See POST /api/replies
// (agent-side) and windows/logbook_timer.ps1's reply box.
import { fetchWithAuth, escapeHtml, showToast, renderError, renderEmpty } from "./api.js";

const repliesList = document.getElementById("replies-list");
const unreadBadge = document.getElementById("replies-unread-badge");

let hasLoadedOnce = false;

const timeAgo = (isoString) => {
    if (!isoString) return "";
    const seconds = Math.max(0, (Date.now() - new Date(isoString).getTime()) / 1000);
    if (seconds < 60) return "Baru saja";
    const minutes = Math.floor(seconds / 60);
    if (minutes < 60) return `${minutes} menit lalu`;
    const hours = Math.floor(minutes / 60);
    if (hours < 24) return `${hours} jam lalu`;
    return `${Math.floor(hours / 24)} hari lalu`;
};

const markReplyRead = async (replyId) => {
    try {
        const res = await fetchWithAuth(`/api/replies/${replyId}/read`, { method: "POST" });
        if (!res.ok) throw new Error("Gagal menandai balasan");
        fetchReplies();
    } catch (err) {
        showToast(err.message, true);
    }
};

export const fetchReplies = async () => {
    try {
        const res = await fetchWithAuth("/api/replies?limit=20");
        if (!res.ok) {
            // A 403 just means this role can't read replies -- hide the
            // card's badge rather than painting an error.
            if (res.status === 403) return;
            throw new Error("Gagal memuat balasan pengguna");
        }
        const data = await res.json();
        hasLoadedOnce = true;

        unreadBadge.textContent = `${data.unread} belum dibaca`;
        unreadBadge.classList.toggle("hidden", data.unread === 0);

        if (data.replies.length === 0) {
            renderEmpty(repliesList, {
                icon: "fa-comments",
                title: "Belum ada balasan",
                helper: "Balasan yang diketik pengguna di widget timer akan muncul di sini.",
            });
            return;
        }

        repliesList.innerHTML = data.replies.map(r => {
            const isUnread = !r.read_at;
            const deviceLabel = escapeHtml(r.device_name || r.hostname);
            const context = r.in_reply_to
                ? `<div class="reply-item-context">Membalas: “${escapeHtml(r.in_reply_to)}”</div>`
                : "";
            return `
                <div class="reply-item ${isUnread ? "unread" : ""}">
                    <div class="reply-item-icon"><i class="fa-solid fa-reply"></i></div>
                    <div class="reply-item-body">
                        <div class="reply-item-device">${deviceLabel} <span class="text-secondary" style="font-weight: 400;">(${escapeHtml(r.hostname)})</span></div>
                        <div class="reply-item-message">${escapeHtml(r.message)}</div>
                        ${context}
                        <div class="reply-item-meta">${timeAgo(r.created_at)}${isUnread ? "" : " · Dibaca"}</div>
                    </div>
                    ${isUnread ? `<button class="btn-action btn-sm btn-read-reply" data-reply-id="${r.id}">Tandai Dibaca</button>` : ""}
                </div>
            `;
        }).join("");
    } catch (err) {
        console.error(err);
        if (!hasLoadedOnce) renderError(repliesList, "Gagal memuat balasan pengguna.");
    }
};

repliesList.addEventListener("click", (e) => {
    const btn = e.target.closest(".btn-read-reply");
    if (!btn) return;
    markReplyRead(btn.dataset.replyId);
});
