import { expect, test } from "@playwright/test";
import { adminEmail, adminPassword, serverEnv } from "./helpers";

/**
 * The guarantees that matter once this holds real students' data. Every one of
 * these has been a live defect at some point in this project, so they are
 * asserted against the running server rather than trusted.
 */

test("Endpoint data menolak permintaan tanpa kredensial", async ({ request }) => {
  for (const path of ["/api/active", "/api/devices", "/api/sessions", "/api/audit-log", "/api/config"]) {
    const res = await request.get(path);
    expect(res.status(), `${path} harus 401 tanpa login`).toBe(401);
  }
});

test("Pintu belakang dev-login tidak ada di posture produksi", async ({ request }) => {
  const res = await request.post("/api/auth/dev-login");
  expect(res.status()).toBe(404);
});

test("Login: email di luar allowlist ditolak", async ({ request }) => {
  const res = await request.post("/api/auth/login", {
    data: { email: "orang.lain@example.net", password: adminPassword() },
  });
  expect(res.status()).toBe(401);
});

test("Konfigurasi: dashboard boleh baca, anonim tidak", async ({ request }) => {
  expect((await request.get("/api/config")).status()).toBe(401);

  const login = await request.post("/api/auth/login", {
    data: { email: adminEmail(), password: adminPassword() },
  });
  const { token } = await login.json();
  const ok = await request.get("/api/config", { headers: { Authorization: `Bearer ${token}` } });
  expect(ok.status()).toBe(200);
});

test("Menulis konfigurasi butuh sesi admin, bukan kunci perangkat", async ({ request }) => {
  const env = serverEnv();
  const res = await request.put("/api/config", {
    headers: { "X-API-Key": env.LOGIX_INGEST_API_KEY ?? "x" },
    data: {},
  });
  expect(res.status()).toBe(401);
});

test("Kode pendaftaran terkunci ke satu komputer", async ({ request }) => {
  const login = await request.post("/api/auth/login", {
    data: { email: adminEmail(), password: adminPassword() },
  });
  const { token } = await login.json();

  const invite = await request.post("/api/enroll/invite", {
    headers: { Authorization: `Bearer ${token}` },
    data: { category: "lab_workstation", display_name: "E2E-PIN", hostname: "E2E-PIN" },
  });
  const { invite_code } = await invite.json();

  await test.step("komputer lain ditolak", async () => {
    const wrong = await request.post("/api/enroll", {
      data: { invite_code, hostname: "KOMPUTER-LAIN" },
    });
    expect(wrong.status()).toBe(400);
  });

  await test.step("komputer yang dimaksud diterima", async () => {
    const right = await request.post("/api/enroll", {
      data: { invite_code, hostname: "E2E-PIN" },
    });
    expect(right.status()).toBe(200);
    expect((await right.json()).api_key).toHaveLength(64);
  });

  await test.step("kode tidak bisa dipakai dua kali", async () => {
    const replay = await request.post("/api/enroll", {
      data: { invite_code, hostname: "E2E-PIN" },
    });
    expect(replay.status()).toBe(400);
  });
});

test("Kunci bersama ditolak saat mode kunci-per-device aktif", async ({ request }) => {
  const env = serverEnv();
  test.skip(env.LOGIX_REQUIRE_DEVICE_KEY !== "1", "server belum di-lockdown");

  const res = await request.post("/api/heartbeat", {
    headers: { "X-API-Key": env.LOGIX_INGEST_API_KEY ?? "" },
    data: { hostname: "PENYUSUP", status: "ACTIVE" },
  });
  expect(res.status()).toBe(401);
});
