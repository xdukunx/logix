// Shared, security-critical helpers: auth token storage, the authenticated
// fetch wrapper, HTML escaping, and the toast utility. Logic here is moved
// verbatim from the pre-redesign app.js, not rewritten -- these are the
// pieces every other module depends on.

const TOKEN_KEY = "logix_admin_token";

export const getToken = () => localStorage.getItem(TOKEN_KEY);
export const setToken = (token) => localStorage.setItem(TOKEN_KEY, token);
export const clearToken = () => localStorage.removeItem(TOKEN_KEY);

// Called by app.js once at bootstrap so this module stays UI-agnostic --
// it doesn't know about the login screen, it just reports "session expired".
let onSessionExpired = () => {};
export const setOnSessionExpired = (callback) => {
    onSessionExpired = callback;
};

export const fetchWithAuth = async (url, options = {}) => {
    const token = getToken();
    if (!options.headers) options.headers = {};
    if (token) {
        options.headers["Authorization"] = `Bearer ${token}`;
    }

    const res = await fetch(url, options);
    if (res.status === 401) {
        clearToken();
        onSessionExpired();
        throw new Error("Sesi berakhir. Silakan masuk kembali.");
    }
    return res;
};

// HTML-escaping helper. Server-ingested fields (hostname, username, nama,
// nim, tujuan, keterangan, etc.) come from unauthenticated/agent-supplied
// data and must never be interpolated raw into innerHTML.
export const escapeHtml = (value) => {
    if (value === null || value === undefined) return "";
    return String(value)
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;")
        .replace(/'/g, "&#39;");
};

// Toast Utility
const toastEl = document.getElementById("toast");
export const showToast = (message, isError = false) => {
    toastEl.textContent = message;
    toastEl.style.borderColor = isError ? "var(--danger-color)" : "var(--primary-color)";
    toastEl.classList.remove("hidden");
    setTimeout(() => {
        toastEl.classList.add("hidden");
    }, 3000);
};

// Shared loading/empty/error state markup (roadmap item G) -- factors out
// what monitoring.js and analytics.js each used to hand-roll slightly
// differently, and gives new views (Devices) one consistent look from the
// start. Callers pass the container they want the state rendered into.
export const renderLoading = (container, message = "Memuat data...") => {
    container.innerHTML = `
        <div class="loading-placeholder">
            <i class="fa-solid fa-circle-notch fa-spin"></i>
            <p>${escapeHtml(message)}</p>
        </div>`;
};

export const renderError = (container, message = "Gagal memuat data dari server.") => {
    container.innerHTML = `
        <div class="empty-state">
            <i class="fa-solid fa-triangle-exclamation" style="color: var(--danger-color)"></i>
            <p class="empty-title">Terjadi Kesalahan</p>
            <p class="empty-helper">${escapeHtml(message)}</p>
        </div>`;
};

export const renderEmpty = (container, { icon = "fa-inbox", title = "Tidak ada data", helper = "" } = {}) => {
    container.innerHTML = `
        <div class="empty-state">
            <i class="fa-solid ${icon}"></i>
            <p class="empty-title">${escapeHtml(title)}</p>
            ${helper ? `<p class="empty-helper">${escapeHtml(helper)}</p>` : ""}
        </div>`;
};

// Offline banner -- wired once here so every module gets it for free rather
// than each tab reinventing connectivity detection. Pure network-adapter
// state (navigator.onLine / online/offline events), not a fetch failure --
// a fetch can still fail while the browser reports itself online, which is
// what renderError above is for.
let offlineBannerEl = null;
const ensureOfflineBanner = () => {
    if (offlineBannerEl) return offlineBannerEl;
    offlineBannerEl = document.createElement("div");
    offlineBannerEl.id = "offline-banner";
    offlineBannerEl.className = "offline-banner hidden";
    offlineBannerEl.innerHTML = `<i class="fa-solid fa-plug-circle-xmark"></i> Koneksi terputus — data mungkin tidak terbaru.`;
    document.body.prepend(offlineBannerEl);
    return offlineBannerEl;
};
window.addEventListener("online", () => ensureOfflineBanner().classList.add("hidden"));
window.addEventListener("offline", () => ensureOfflineBanner().classList.remove("hidden"));
if (!navigator.onLine) ensureOfflineBanner().classList.remove("hidden");
