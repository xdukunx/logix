// Shared, security-critical helpers ported from server/static/js/api.js:
// auth token storage and the authenticated fetch wrapper. React components
// get user feedback via useToast instead of the old DOM toast element.

const TOKEN_KEY = "logix_admin_token";

export const getToken = () => localStorage.getItem(TOKEN_KEY);
export const setToken = (token: string) => localStorage.setItem(TOKEN_KEY, token);
export const clearToken = () => localStorage.removeItem(TOKEN_KEY);

// Registered once by App so this module stays UI-agnostic -- it doesn't know
// about the login screen, it just reports "session expired".
let onSessionExpired: () => void = () => {};
export const setOnSessionExpired = (callback: () => void) => {
  onSessionExpired = callback;
};

// Local admin login (email + password). On success the session token is
// stored; callers then flip the app into its authenticated state. Replaces the
// former Google OAuth redirect flow.
export const login = async (email: string, password: string): Promise<void> => {
  const res = await fetch("/api/auth/login", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email: email.trim(), password }),
  });
  if (!res.ok) throw new Error(await errorDetail(res, "Gagal masuk. Periksa email dan password."));
  const body = await res.json();
  if (!body?.token) throw new Error("Respons login tidak valid dari server.");
  setToken(body.token as string);
};

export const fetchWithAuth = async (url: string, options: RequestInit = {}) => {
  const token = getToken();
  const headers = new Headers(options.headers);
  if (token) headers.set("Authorization", `Bearer ${token}`);

  const res = await fetch(url, { ...options, headers });
  if (res.status === 401) {
    clearToken();
    onSessionExpired();
    throw new Error("Sesi berakhir. Silakan masuk kembali.");
  }
  return res;
};

// JSON convenience wrappers. `getJson` throws on non-2xx with the server's
// `detail` message when present, so views can surface it in a toast.
const errorDetail = async (res: Response, fallback: string) => {
  const body = await res.json().catch(() => ({}));
  return body.detail || fallback;
};

export const getJson = async <T>(url: string, fallbackError: string): Promise<T> => {
  const res = await fetchWithAuth(url);
  if (!res.ok) throw new Error(await errorDetail(res, fallbackError));
  return res.json();
};

export const sendJson = async (
  url: string,
  method: "POST" | "PUT",
  body: unknown,
  fallbackError: string,
): Promise<Response> => {
  const res = await fetchWithAuth(url, {
    method,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(await errorDetail(res, fallbackError));
  return res;
};

export const postEmpty = async (url: string, fallbackError: string): Promise<Response> => {
  const res = await fetchWithAuth(url, { method: "POST" });
  if (!res.ok) throw new Error(await errorDetail(res, fallbackError));
  return res;
};
