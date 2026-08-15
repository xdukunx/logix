import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import type { APIRequestContext, Page } from "@playwright/test";

// The package is ESM ("type": "module"), so __dirname does not exist. This is
// the portable equivalent and does not depend on the working directory.
const HERE = path.dirname(fileURLToPath(import.meta.url));
const REPO = path.resolve(HERE, "..", "..");

/**
 * Read the server's real production secrets. The suite deliberately does not
 * hardcode credentials -- it authenticates the same way an admin does, with
 * whatever ops/go_live.py generated, so a broken login is a real failure and
 * not a fixture mismatch.
 */
export function serverEnv(): Record<string, string> {
  const file = path.join(REPO, "server", ".env.production");
  const out: Record<string, string> = {};
  if (!fs.existsSync(file)) return out;
  for (const line of fs.readFileSync(file, "utf8").split(/\r?\n/)) {
    const m = /^([A-Z_]+)=(.*)$/.exec(line.trim());
    if (m) out[m[1]] = m[2];
  }
  return out;
}

export const adminEmail = () => serverEnv().ADMIN_EMAILS ?? "";
export const adminPassword = () => serverEnv().LOGIX_ADMIN_PASSWORD ?? "";

/** Log in through the real endpoint and hand the page a session. */
export async function signIn(page: Page, request: APIRequestContext) {
  const res = await request.post("/api/auth/login", {
    data: { email: adminEmail(), password: adminPassword() },
  });
  if (!res.ok()) throw new Error(`login failed: ${res.status()} ${await res.text()}`);
  const { token } = await res.json();
  await page.addInitScript((t) => localStorage.setItem("logix_admin_token", t), token);
  return token;
}

/**
 * Put a station on the board by enrolling a device and heartbeating as it --
 * the same two calls a real workstation makes. Returns its per-device key so a
 * test can keep beating (or prove the key is refused after lockdown).
 */
export async function seedStation(
  request: APIRequestContext,
  token: string,
  opts: { hostname: string; displayName: string; username?: string; accessType?: string },
) {
  const auth = { Authorization: `Bearer ${token}` };
  const invite = await request.post("/api/enroll/invite", {
    headers: auth,
    data: { category: "lab_workstation", display_name: opts.displayName, hostname: opts.hostname },
  });
  const { invite_code } = await invite.json();

  const enrolled = await request.post("/api/enroll", {
    data: { invite_code, hostname: opts.hostname, os: "windows", agent_version: "e2e" },
  });
  const { api_key } = await enrolled.json();

  await request.post("/api/heartbeat", {
    headers: { "X-API-Key": api_key },
    data: {
      hostname: opts.hostname,
      device_name: opts.displayName,
      status: "ACTIVE",
      username: opts.username ?? "Mahasiswa Uji",
      session_started_at: new Date(Date.now() - 134 * 60_000).toISOString(),
      access_type: opts.accessType ?? "SSH",
      purpose: "Komputasi DFT",
    },
  });
  return api_key;
}

/** The station card for a given ID, located the way a person would. */
export const stationCard = (page: Page, id: string) =>
  page.locator("main div").filter({ hasText: new RegExp(`^${id}\\b`) }).first();
