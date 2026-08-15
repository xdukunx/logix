import { expect, test } from "@playwright/test";
import { adminEmail, adminPassword, seedStation, signIn } from "./helpers";

/**
 * Every admin-facing function, exercised against a live server.
 *
 * Each test is written as named steps so the HTML report reads as a
 * walkthrough: what was tried, and the screenshot of what happened.
 */

let token = "";
const STATION = { hostname: "E2E-WS-07", displayName: "WS-07 - GPU-A100" };

test.beforeAll(async ({ playwright, baseURL }) => {
  const request = await playwright.request.newContext({ baseURL, ignoreHTTPSErrors: true });
  const res = await request.post("/api/auth/login", {
    data: { email: adminEmail(), password: adminPassword() },
  });
  token = (await res.json()).token;
  await seedStation(request, token, { ...STATION, username: "Mahasiswa Uji" });
  await request.dispose();
});

test.beforeEach(async ({ page }) => {
  await page.addInitScript((t) => localStorage.setItem("logix_admin_token", t), token);
});

test("Masuk: password benar diterima, password salah ditolak", async ({ page, request }) => {
  await test.step("password salah ditolak", async () => {
    const bad = await request.post("/api/auth/login", {
      data: { email: adminEmail(), password: "salah-sekali" },
    });
    expect(bad.status()).toBe(401);
  });

  await test.step("dashboard terbuka dengan sesi yang sah", async () => {
    await page.goto("/#monitoring");
    await expect(page.getByRole("heading", { name: "Monitoring" })).toBeVisible();
  });
});

test("Monitoring: stasiun tampil dengan anatomi kartu yang benar", async ({ page }) => {
  await page.goto("/#monitoring");

  await test.step("kalimat ringkasan, bukan kartu KPI", async () => {
    await expect(page.locator("main").getByText(/dari .* stasiun dipakai/)).toBeVisible();
    // The design forbids KPI cards and an occupancy chart on this screen.
    await expect(page.locator("canvas")).toHaveCount(0);
  });

  await test.step("kartu stasiun: ID mono + baris sesi", async () => {
    const card = page.locator("main").getByText("WS-07 · GPU-A100").first();
    await expect(card).toBeVisible();
    await expect(page.locator("main").getByText(/Mahasiswa Uji · SSH ·/)).toBeVisible();
  });
});

test("Monitoring: menu aksi membuka keempat perintah", async ({ page }) => {
  await page.goto("/#monitoring");
  await page.getByRole("button", { name: /Aksi untuk WS-07/ }).click();

  const menu = page.getByRole("menu");
  await expect(menu).toBeVisible();
  for (const label of ["Pesan", "Kunci", "Cuplikan layar", "Daya"]) {
    await expect(menu.getByRole("menuitem", { name: label })).toBeVisible();
  }
});

test("Monitoring: kirim pesan ke stasiun benar-benar terkirim", async ({ page }) => {
  await page.goto("/#monitoring");
  await page.getByRole("button", { name: /Aksi untuk WS-07/ }).click();
  await page.getByRole("menuitem", { name: "Pesan" }).click();

  const dialog = page.getByRole("dialog");
  await expect(dialog).toBeVisible();
  await dialog.getByRole("textbox").fill("Lab tutup 17:00, mohon simpan pekerjaan.");
  await dialog.getByRole("button", { name: "Kirim pesan" }).click();

  await expect(page.getByText(/Pesan terkirim ke WS-07/)).toBeVisible();
});

test("Monitoring: Cuplikan layar selalu menampilkan catatan privasi", async ({ page }) => {
  await page.goto("/#monitoring");
  await page.getByRole("button", { name: /Aksi untuk WS-07/ }).click();
  await page.getByRole("menuitem", { name: "Cuplikan layar" }).click();

  const dialog = page.getByRole("dialog");
  // The privacy notice must be on the surface, never behind a link.
  await expect(dialog.getByText(/selalu diberi tahu/)).toBeVisible();
  await dialog.getByRole("button", { name: "Batal" }).click();
});

test("Monitoring: Emergency broadcast wajib dicentang dulu", async ({ page }) => {
  await page.goto("/#monitoring");
  await page.getByRole("button", { name: /Emergency broadcast/ }).click();

  const dialog = page.getByRole("dialog");
  const send = dialog.getByRole("button", { name: "Kirim broadcast" });

  await test.step("tombol mati sebelum pesan + centang", async () => {
    await expect(send).toBeDisabled();
    await dialog.getByRole("textbox").fill("Evakuasi: alarm kebakaran gedung C.");
    await expect(send).toBeDisabled();
  });

  await test.step("aktif setelah admin mengakui dampaknya", async () => {
    await dialog.getByRole("checkbox").check();
    await expect(send).toBeEnabled();
  });

  await dialog.getByRole("button", { name: "Batal" }).click();
});

test("Riwayat: tiga angka ringkasan, dua sub-tab, nol chart", async ({ page }) => {
  await page.goto("/#riwayat");
  await expect(page.getByRole("heading", { name: "Riwayat" })).toBeVisible();

  await test.step("ringkasan inline dalam satu kalimat", async () => {
    await expect(page.locator("main").getByText(/j total ·.*sesi ·.*pengguna/)).toBeVisible();
  });

  await test.step("Log Sesi / Log Audit sebagai pill toggle", async () => {
    await expect(page.getByRole("tab", { name: "Log Sesi" })).toBeVisible();
    await page.getByRole("tab", { name: "Log Audit" }).click();
    await expect(page.getByRole("tab", { name: "Log Audit" })).toHaveAttribute("aria-selected", "true");
  });

  await test.step("tidak ada chart sama sekali", async () => {
    await expect(page.locator("canvas, .recharts-wrapper")).toHaveCount(0);
  });
});

test("Riwayat: unduh Excel dan CSV menghasilkan berkas", async ({ page }) => {
  await page.goto("/#riwayat");

  for (const label of ["CSV", "Excel (.xlsx)"]) {
    await test.step(`unduh ${label}`, async () => {
      await page.getByRole("button", { name: /Unduh/ }).click();
      const [download] = await Promise.all([
        page.waitForEvent("download"),
        page.getByRole("option", { name: label }).click(),
      ]);
      expect(download.suggestedFilename()).toMatch(/\.(csv|xlsx)$/);
    });
  }
});

test("Perangkat: tabel registri + kode pendaftaran sekali pakai", async ({ page }) => {
  await page.goto("/#perangkat");
  await expect(page.getByRole("heading", { name: "Perangkat" })).toBeVisible();
  await expect(page.locator("main").getByText("WS-07").first()).toBeVisible();

  await test.step("sinkronisasi ditampilkan sebagai titik + waktu, tanpa sparkline", async () => {
    await expect(page.locator("main").getByText(/dtk lalu|mnt lalu|jam lalu/).first()).toBeVisible();
    await expect(page.locator("svg.sparkline")).toHaveCount(0);
  });

  await test.step("membuat kode pendaftaran", async () => {
    await page.getByRole("button", { name: "Tambah perangkat" }).click();
    const dialog = page.getByRole("dialog");
    await dialog.getByRole("button", { name: "Buat kode" }).click();
    // A one-time code, grouped for reading aloud.
    await expect(dialog.getByText(/kedaluwarsa dalam \d{2}:\d{2}/)).toBeVisible();
  });
});

test("Pengaturan: kebijakan Idle auto-end tersimpan dan kembali lagi", async ({ page }) => {
  await page.goto("/#pengaturan");
  await expect(page.getByRole("heading", { name: "Pengaturan" })).toBeVisible();

  const gpu = page.getByRole("switch", { name: /Idle auto-end untuk GPU/ });

  await test.step("peringatan job panjang selalu terlihat", async () => {
    // Long DFT/training runs must not be mistaken for an idle machine.
    await expect(page.getByText(/idle diukur dari input \+ beban proses/)).toBeVisible();
  });

  // Deliberately state-independent: this runs against a live server whose
  // config may already have been changed by an operator (or an earlier run).
  // Asserting a fixed starting value would make the test fail for a reason
  // that has nothing to do with the behaviour under test.
  const before = await gpu.getAttribute("aria-checked");
  const after = before === "true" ? "false" : "true";

  await test.step(`ubah GPU ${before} -> ${after} lalu simpan`, async () => {
    await gpu.click();
    await expect(gpu).toHaveAttribute("aria-checked", after);
    await page.getByRole("button", { name: "Simpan" }).click();
    await expect(page.getByText(/Pengaturan tersimpan/)).toBeVisible();
  });

  await test.step("muat ulang: pilihan benar-benar tersimpan di server", async () => {
    await page.reload();
    await expect(page.getByRole("switch", { name: /Idle auto-end untuk GPU/ })).toHaveAttribute(
      "aria-checked",
      after,
    );
  });

  await test.step("kembalikan seperti semula", async () => {
    await page.getByRole("switch", { name: /Idle auto-end untuk GPU/ }).click();
    await page.getByRole("button", { name: "Simpan" }).click();
    await expect(page.getByText(/Pengaturan tersimpan/)).toBeVisible();
  });
});

test("Mode dinding: gelap, hanya-baca, tanpa nav dan tanpa menu", async ({ page }) => {
  await page.goto("/#wall");
  await expect(page.getByText(/stasiun dipakai/)).toBeVisible();

  expect(await page.locator("nav").count()).toBe(0);
  expect(await page.locator('[aria-haspopup="menu"]').count()).toBe(0);
  expect(await page.locator("button").count()).toBe(0);
});

test("Responsif: sidebar, top bar, lalu bottom tab bar", async ({ page }) => {
  await test.step("desktop >=1280: sidebar", async () => {
    await page.setViewportSize({ width: 1440, height: 900 });
    await page.goto("/#monitoring");
    await expect(page.locator("aside")).toBeVisible();
  });

  await test.step("tablet 768-1279: nav pindah ke atas", async () => {
    await page.setViewportSize({ width: 1024, height: 800 });
    await expect(page.locator("aside")).toHaveCount(0);
    await expect(page.locator("header")).toBeVisible();
  });

  await test.step("hp <=767: bottom tab bar, target sentuh >=44px", async () => {
    await page.setViewportSize({ width: 390, height: 844 });
    const bottomNav = page.getByRole("navigation", { name: "Navigasi utama" });
    await expect(bottomNav).toBeVisible();
    const box = await bottomNav.getByRole("button").first().boundingBox();
    expect(box!.height).toBeGreaterThanOrEqual(44);
  });
});
