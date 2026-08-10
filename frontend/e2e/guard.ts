import type { FullConfig } from "@playwright/test";
import { adminEmail, adminPassword } from "./helpers";

/**
 * Refuse to run the suite against a server that holds real records.
 *
 * These tests are not read-only: they enrol devices (E2E-WS-07, E2E-PIN) and
 * write session rows. Pointed at a production server -- which is a single
 * environment variable away, and happened twice on this project -- they seed
 * fake workstations into a real registry, where they then show up on the
 * Monitoring board as offline stations nobody can explain.
 *
 * The check is deliberately about the DATA, not the URL. "Is this localhost"
 * proves nothing: the lab server, the dev box and the production host in this
 * project have all been localhost at some point. What actually matters is
 * whether anything real would be damaged, so that is what gets asked.
 *
 * Override with LOGIX_E2E_ALLOW_DIRTY=1 when you genuinely mean it.
 */
export default async function guard(config: FullConfig) {
  if (process.env.LOGIX_E2E_ALLOW_DIRTY === "1") return;

  const baseURL = config.projects[0]?.use?.baseURL ?? "http://127.0.0.1:8791";
  const { request } = await import("@playwright/test");
  const ctx = await request.newContext({ baseURL, ignoreHTTPSErrors: true });

  try {
    const login = await ctx.post("/api/auth/login", {
      data: { email: adminEmail(), password: adminPassword() },
    });
    if (!login.ok()) return; // Can't inspect it; the suite's own login will fail loudly.

    const { token } = await login.json();
    const res = await ctx.get("/api/devices", { headers: { Authorization: `Bearer ${token}` } });
    if (!res.ok()) return;

    const devices: Array<{ hostname: string }> = await res.json();
    const real = devices.filter((d) => !d.hostname.startsWith("E2E-")).map((d) => d.hostname);

    if (real.length > 0) {
      throw new Error(
        `\n\nRefusing to run: ${baseURL} has ${real.length} real device(s) enrolled ` +
          `(${real.slice(0, 5).join(", ")}${real.length > 5 ? ", ..." : ""}).\n\n` +
          `This suite ENROLS devices and writes session rows. Running it here would ` +
          `seed E2E-* fixtures into a registry somebody depends on -- they then appear ` +
          `on the Monitoring board as unexplained offline stations.\n\n` +
          `Point LOGIX_E2E_URL at a throwaway server, or set ` +
          `LOGIX_E2E_ALLOW_DIRTY=1 if you really mean to write to this one.\n`,
      );
    }
  } finally {
    await ctx.dispose();
  }
}
