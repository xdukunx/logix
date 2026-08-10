import { expect, test } from "@playwright/test";
import { adminEmail, adminPassword } from "./helpers";

/**
 * Reproduces what a person actually does, which the rest of the suite does not.
 *
 * Every existing test reaches a screen with page.goto("/#monitoring") -- it
 * never CLICKS the nav. So a nav item that does nothing when clicked passes the
 * whole suite while being completely broken for a human. That gap is the reason
 * the dashboard could be reported as "Monitoring tab does not respond" with 19
 * green tests behind it.
 */

let token = "";

test.beforeAll(async ({ playwright, baseURL }) => {
  const request = await playwright.request.newContext({ baseURL, ignoreHTTPSErrors: true });
  const res = await request.post("/api/auth/login", {
    data: { email: adminEmail(), password: adminPassword() },
  });
  token = (await res.json()).token;
  await request.dispose();
});

test.beforeEach(async ({ page }) => {
  await page.addInitScript((t) => localStorage.setItem("logix_admin_token", t), token);
});

// All three breakpoints, because the nav is a different component in each
// (sidebar >=1280, top bar 768-1279, bottom tab bar <=767) and "the Monitoring
// tab does nothing when I click it" was reported from a window whose width
// nobody recorded.
// The bottom tab bar abbreviates: "Monitor"/"Atur" rather than
// "Monitoring"/"Pengaturan", to fit four tabs on a 390px screen. So each
// viewport declares the label it actually renders, paired with the heading
// that proves the click landed. Asserting the long names everywhere reported a
// product bug that did not exist -- the tabs were fine, the test was wrong.
const VIEWPORTS = [
  {
    name: "desktop 1440 (sidebar)",
    width: 1440,
    height: 900,
    tabs: [["Monitoring", "Monitoring"], ["Riwayat", "Riwayat"], ["Perangkat", "Perangkat"], ["Pengaturan", "Pengaturan"]],
  },
  {
    name: "tablet 1024 (top bar)",
    width: 1024,
    height: 800,
    tabs: [["Monitoring", "Monitoring"], ["Riwayat", "Riwayat"], ["Perangkat", "Perangkat"], ["Pengaturan", "Pengaturan"]],
  },
  {
    name: "phone 390 (bottom tabs)",
    width: 390,
    height: 844,
    tabs: [["Monitor", "Monitoring"], ["Riwayat", "Riwayat"], ["Perangkat", "Perangkat"], ["Atur", "Pengaturan"]],
  },
] as const;

for (const vp of VIEWPORTS) {
  test(`nav: every item navigates when CLICKED -- ${vp.name}`, async ({ page }) => {
    const problems: string[] = [];
    await page.setViewportSize({ width: vp.width, height: vp.height });
    await page.goto("/");
    await page.waitForLoadState("networkidle");

    for (const [tabLabel, heading] of vp.tabs) {
      const item = page
        .getByRole("button", { name: tabLabel, exact: true })
        .or(page.getByRole("link", { name: tabLabel, exact: true }))
        .first();
      if ((await item.count()) === 0) {
        problems.push(`[${vp.name}] "${tabLabel}": no clickable nav item found at all`);
        continue;
      }
      const before = page.url();
      try {
        await item.click({ timeout: 4000 });
      } catch (e) {
        problems.push(`[${vp.name}] "${tabLabel}": could not be clicked -- ${(e as Error).message.split("\n")[0]}`);
        continue;
      }
      await page.waitForTimeout(500);
      const landed = await page.getByRole("heading", { name: heading, exact: true }).count();
      console.log(`[${vp.name}] click "${tabLabel}": ${before} -> ${page.url()} heading(${heading})=${landed > 0}`);
      if (landed === 0) {
        problems.push(`[${vp.name}] "${tabLabel}": clicked but "${heading}" never rendered`);
      }
    }

    await page.screenshot({ path: `diagnose-nav-${vp.width}.png` });
    expect(problems, `nav problems:\n${problems.join("\n")}`).toEqual([]);
  });
}

test("visual: capture the surfaces that were reported as ugly", async ({ page }) => {
  await page.goto("/#monitoring");
  await page.waitForLoadState("networkidle");
  await page.waitForTimeout(800);
  await page.screenshot({ path: "diagnose-monitoring.png", fullPage: true });

  // The station card, on its own, at real size.
  const card = page.locator("main").getByText(/WS-01|ASUS/).first();
  if (await card.count()) {
    const box = await card.boundingBox();
    console.log(`station card box: ${JSON.stringify(box)}`);
  }

  await page.goto("/#perangkat");
  await page.waitForLoadState("networkidle");
  await page.waitForTimeout(500);
  await page.screenshot({ path: "diagnose-perangkat.png", fullPage: true });
});

test("visual: the login screen, logged out", async ({ page, context }) => {
  await context.clearCookies();
  await page.addInitScript(() => localStorage.clear());
  await page.goto("/");
  await page.waitForLoadState("networkidle");
  await page.screenshot({ path: "diagnose-login.png", fullPage: true });
});
