import { expect, test } from "@playwright/test";
import { adminEmail, adminPassword, seedStation } from "./helpers";

/**
 * The station card's "..." action menu, measured rather than asserted-visible.
 *
 * The existing Monitoring test only checks the four menuitems EXIST. A menu can
 * exist, be reported visible, and still be unusable because it is clipped by an
 * ancestor's overflow, painted under a later sibling's stacking context, or
 * hanging off the bottom of the viewport -- all of which read to a person as
 * "the bottom disappears and I cannot click Kunci or Pesan".
 */

let token = "";

test.beforeAll(async ({ playwright, baseURL }) => {
  const request = await playwright.request.newContext({ baseURL, ignoreHTTPSErrors: true });
  const res = await request.post("/api/auth/login", {
    data: { email: adminEmail(), password: adminPassword() },
  });
  token = (await res.json()).token;
  // Seed our own station rather than depending on a real agent still being
  // within its heartbeat window -- an offline card carries no action menu at
  // all, so the thing under test would simply not exist.
  await seedStation(request, token, {
    hostname: "E2E-MENU-01",
    displayName: "E2E-MENU-01 - GPU-A100",
    username: "Mahasiswa Uji",
  });
  await request.dispose();
});

test.beforeEach(async ({ page }) => {
  await page.addInitScript((t) => localStorage.setItem("logix_admin_token", t), token);
});

test("action menu is fully reachable, not clipped or covered", async ({ page }) => {
  await page.goto("/#monitoring");
  await page.waitForLoadState("networkidle");

  const trigger = page.getByRole("button", { name: /Aksi untuk/ }).first();
  await expect(trigger).toBeVisible();
  await trigger.click();

  const menu = page.getByRole("menu");
  await expect(menu).toBeVisible();

  const report = await page.evaluate(() => {
    const menuEl = document.querySelector('[role="menu"]') as HTMLElement | null;
    if (!menuEl) return { error: "no menu in DOM" };
    const m = menuEl.getBoundingClientRect();

    // Every ancestor that could clip or trap the menu.
    const ancestors: unknown[] = [];
    let el = menuEl.parentElement;
    while (el && el !== document.body) {
      const cs = getComputedStyle(el);
      const clips = cs.overflow !== "visible" || cs.overflowY !== "visible" || cs.overflowX !== "visible";
      const traps = cs.transform !== "none" || cs.filter !== "none" || cs.willChange !== "auto";
      if (clips || traps) {
        const r = el.getBoundingClientRect();
        ancestors.push({
          tag: el.tagName,
          cls: el.className?.toString().slice(0, 40),
          overflow: `${cs.overflow}/${cs.overflowX}/${cs.overflowY}`,
          transform: cs.transform === "none" ? "none" : "SET",
          rect: { top: Math.round(r.top), bottom: Math.round(r.bottom) },
          clipsMenuBottom: clips && r.bottom < m.bottom,
        });
      }
      el = el.parentElement;
    }

    // What is actually painted at the menu's bottom-most item?
    const probeY = m.bottom - 12;
    const probeX = m.left + m.width / 2;
    const hit = document.elementFromPoint(probeX, probeY) as HTMLElement | null;

    return {
      menuRect: { top: Math.round(m.top), bottom: Math.round(m.bottom), height: Math.round(m.height) },
      viewportH: window.innerHeight,
      offBottom: m.bottom > window.innerHeight,
      clippingAncestors: ancestors,
      elementAtMenuBottom: hit ? `${hit.tagName}.${hit.className?.toString().slice(0, 40)}` : null,
      menuContainsThatElement: hit ? menuEl.contains(hit) : false,
    };
  });

  console.log(JSON.stringify(report, null, 2));

  // The real question: can the last item actually be clicked?
  const items = menu.getByRole("menuitem");
  const n = await items.count();
  const last = items.nth(n - 1);
  await expect(last).toBeVisible();
  await last.click({ timeout: 3000 });
});

test("action menu survives a poll tick (it must not close by itself)", async ({ page }) => {
  await page.goto("/#monitoring");
  await page.waitForLoadState("networkidle");

  await page.getByRole("button", { name: /Aksi untuk/ }).first().click();
  const menu = page.getByRole("menu");
  await expect(menu).toBeVisible();
  const before = await menu.getByRole("menuitem").count();

  // Monitoring polls every 10s. Sit past one tick, touching nothing.
  await page.waitForTimeout(12_000);

  const stillOpen = await menu.count();
  const after = stillOpen ? await menu.getByRole("menuitem").count() : 0;
  console.log(`menuitems before poll: ${before}, after: ${after}, menu still in DOM: ${stillOpen > 0}`);

  expect(
    stillOpen,
    "the menu closed on its own after a poll tick -- a user reaching for Kunci/Pesan loses it mid-click",
  ).toBeGreaterThan(0);
});
