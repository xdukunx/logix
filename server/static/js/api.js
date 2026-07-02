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
