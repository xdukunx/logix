// Analytics tab: the 3 charts, the session-logs table, and the Control
// audit-log table. Logic moved as-is from the pre-redesign app.js.
import { fetchWithAuth, escapeHtml } from "./api.js";

const logsTbody = document.getElementById("logs-tbody");
const auditLogTbody = document.getElementById("audit-log-tbody");
const valTotalLogs = document.getElementById("val-total-logs");
const btnPrev = document.getElementById("btn-prev");
const btnNext = document.getElementById("btn-next");
const pageIndicator = document.getElementById("page-indicator");
const searchInput = document.getElementById("log-search-input");

let currentPage = 1;
const itemsPerPage = 15;
let searchQuery = "";
let totalLogs = 0;

// Riwayat summary. v3 removed every chart from this screen; what replaces
// them is three numbers inline in a sentence. Sourced from
// /api/sessions/summary, the same endpoint the React dashboard reads, so the
// two surfaces can never disagree about the totals.
export const fetchAnalytics = async () => {
    const hoursEl = document.getElementById("val-total-hours");
    const sessionsEl = document.getElementById("val-total-logs");
    const usersEl = document.getElementById("val-total-users");
    if (!hoursEl && !sessionsEl && !usersEl) return;
    try {
        const res = await fetchWithAuth("/api/sessions/summary");
        if (!res.ok) throw new Error("Gagal memuat ringkasan");
        const data = await res.json();
        if (hoursEl) hoursEl.textContent = `${data.hours} j`;
        if (sessionsEl) sessionsEl.textContent = data.sessions;
        if (usersEl) usersEl.textContent = data.users;
    } catch (err) {
        console.error(err);
        [hoursEl, sessionsEl, usersEl].forEach(el => { if (el) el.textContent = "-"; });
    }
};

// Fetch and Render Session Logs Table
export const fetchSessionLogs = async () => {
    try {
        const offset = (currentPage - 1) * itemsPerPage;
        let url = `/api/sessions?limit=${itemsPerPage}&offset=${offset}`;
        if (searchQuery) {
            url += `&username=${encodeURIComponent(searchQuery)}&hostname=${encodeURIComponent(searchQuery)}`;
        }

        const res = await fetchWithAuth(url);
        if (!res.ok) throw new Error("Gagal mengambil data catatan sesi");
        const data = await res.json();

        totalLogs = data.total;
        valTotalLogs.textContent = totalLogs;

        if (data.sessions.length === 0) {
            logsTbody.innerHTML = `
                <tr>
                    <td colspan="8" class="text-center">Tidak ada catatan sesi ditemukan.</td>
                </tr>
            `;
            btnNext.disabled = true;
            return;
        }

        logsTbody.innerHTML = data.sessions.map(s => {
            const dateStr = new Date(s.timestamp).toLocaleString("id-ID");
            const eventText = escapeHtml(s.event);
            let eventBadge = `<span class="badge">${eventText}</span>`;
            if (s.event === "START" || s.event === "UNLOCK") {
                eventBadge = `<span class="badge" style="border-color: rgba(16,185,129,0.3); color: var(--success-color)">${eventText}</span>`;
            } else if (s.event === "END" || s.event === "LOCK" || (s.event || "").includes("AUTO")) {
                eventBadge = `<span class="badge" style="border-color: rgba(239,68,68,0.3); color: var(--danger-color)">${eventText}</span>`;
            }

            return `
                <tr>
                    <td>${dateStr}</td>
                    <td><strong>${escapeHtml(s.hostname) || "-"}</strong></td>
                    <td>${eventBadge}</td>
                    <td>${escapeHtml(s.session_type) || "-"}</td>
                    <td>${escapeHtml(s.nama || s.username) || "-"}</td>
                    <td>${escapeHtml(s.nim) || "-"}</td>
                    <td>${escapeHtml(s.tujuan) || "-"}</td>
                    <td><small>${escapeHtml(s.keterangan) || "-"}</small></td>
                </tr>
            `;
        }).join("");

        btnPrev.disabled = currentPage === 1;
        btnNext.disabled = offset + data.sessions.length >= totalLogs;
        pageIndicator.textContent = `Halaman ${currentPage} dari ${Math.ceil(totalLogs / itemsPerPage) || 1}`;

    } catch (err) {
        console.error(err);
        logsTbody.innerHTML = `
            <tr>
                <td colspan="8" class="text-center" style="color: var(--danger-color)">
                    Gagal memuat data dari server.
                </td>
            </tr>
        `;
    }
};

// status -> badge label/color. "queued" only means an admin queued the
// command; "done"/"failed" are agent-reported outcomes on a later
// heartbeat; "expired" means it sat past the TTL and was withheld,
// never delivered. See docs/LOGIX_CONTROL.md §6.
const AUDIT_STATUS_BADGES = {
    queued:  { label: "Menunggu",    color: "var(--warning-color)", border: "rgba(245,158,11,0.3)" },
    done:    { label: "Selesai",     color: "var(--success-color)", border: "rgba(16,185,129,0.3)" },
    failed:  { label: "Gagal",       color: "var(--danger-color)",  border: "rgba(239,68,68,0.3)" },
    expired: { label: "Kedaluwarsa", color: "var(--text-secondary)", border: "rgba(148,163,184,0.3)" },
};

// Fetch and Render Control Audit Log (Logix Control, Milestone 3).
export const fetchAuditLog = async () => {
    try {
        const res = await fetchWithAuth("/api/audit-log?limit=20");
        if (!res.ok) throw new Error("Gagal mengambil audit log");
        const data = await res.json();

        if (data.actions.length === 0) {
            auditLogTbody.innerHTML = `
                <tr>
                    <td colspan="7" class="text-center">Belum ada tindakan admin tercatat.</td>
                </tr>
            `;
            return;
        }

        auditLogTbody.innerHTML = data.actions.map(a => {
            const dateStr = new Date(a.timestamp).toLocaleString("id-ID");
            const badgeInfo = AUDIT_STATUS_BADGES[a.status] || { label: a.status, color: "var(--text-secondary)", border: "rgba(148,163,184,0.3)" };
            const statusBadge = `<span class="badge" style="border-color: ${badgeInfo.border}; color: ${badgeInfo.color}">${escapeHtml(badgeInfo.label)}</span>`;

            return `
                <tr>
                    <td>${dateStr}</td>
                    <td>${escapeHtml(a.actor_email)}</td>
                    <td><strong>${escapeHtml(a.target_device) || "-"}</strong></td>
                    <td>${escapeHtml(a.action_type)}</td>
                    <td>${statusBadge}</td>
                    <td>${escapeHtml(a.reason) || "-"}</td>
                    <td><small>${escapeHtml(a.result_summary) || "-"}</small></td>
                </tr>
            `;
        }).join("");

    } catch (err) {
        console.error(err);
        auditLogTbody.innerHTML = `
            <tr>
                <td colspan="7" class="text-center" style="color: var(--danger-color)">
                    Gagal memuat audit log dari server.
                </td>
            </tr>
        `;
    }
};

// Pagination Click Events
btnPrev.addEventListener("click", () => {
    if (currentPage > 1) {
        currentPage--;
        fetchSessionLogs();
    }
});

btnNext.addEventListener("click", () => {
    currentPage++;
    fetchSessionLogs();
});

// Search Input Event
let searchDebounce;
searchInput.addEventListener("input", (e) => {
    clearTimeout(searchDebounce);
    searchDebounce = setTimeout(() => {
        searchQuery = e.target.value.trim();
        currentPage = 1;
        fetchSessionLogs();
    }, 400);
});
