import { defineConfig } from "@playwright/test";

/**
 * End-to-end suite for the Logix dashboard.
 *
 * Runs against a REAL server (ops/serve.py in production posture) with a real
 * database, not mocks -- the bugs this project has actually hit (a one-line
 * config.env, an unauthenticated endpoint, a widget that never launched) were
 * all integration failures that a mocked suite would have reported as green.
 *
 * Uses the installed Chrome rather than downloading a browser: it is the
 * browser the lab actually uses, and it keeps `npm ci` from pulling ~400MB.
 *
 * Every test records a screenshot and a video, and the HTML reporter collects
 * them into one page -- that page is the demo. `npm run demo` opens it.
 */
export default defineConfig({
  testDir: "./e2e",
  // The dashboard polls every 10s; give assertions room to catch up without
  // making a genuine hang look like a slow pass.
  timeout: 45_000,
  expect: { timeout: 10_000 },
  fullyParallel: false,
  workers: 1,
  retries: 0,
  reporter: [
    ["list"],
    ["html", { outputFolder: "playwright-report", open: "never" }],
  ],
  use: {
    baseURL: process.env.LOGIX_E2E_URL ?? "http://127.0.0.1:8791",
    channel: "chrome",
    headless: true,
    // A lab admin is on a desktop; this is the breakpoint that matters most.
    viewport: { width: 1440, height: 900 },
    screenshot: "on",
    video: "on",
    trace: "retain-on-failure",
    // The lab server issues its own certificate, so an HTTPS run has to accept
    // it. Harmless over http; required over https://localhost.
    ignoreHTTPSErrors: true,
  },
});
