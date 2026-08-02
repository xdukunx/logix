// Login gate shown when there's no session token. Local admin auth: email +
// password checked against the server's ADMIN_EMAILS allowlist plus the
// LOGIX_ADMIN_PASSWORD it was started with. The auth call itself is unchanged;
// only the surface is restyled to v3 -- one centered card, flat, with the
// always-visible privacy line the client surfaces also carry.
import { useState, type FormEvent } from "react";

import { login } from "../api";
import Wordmark from "../components/Wordmark";
import { Button, TextField } from "../ui/controls";

export default function Login({ onAuthenticated }: { onAuthenticated: () => void }) {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [isBusy, setBusy] = useState(false);

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    if (!email.trim() || !password || isBusy) return;
    setBusy(true);
    setError(null);
    try {
      await login(email, password);
      onAuthenticated();
    } catch (err) {
      setError((err as Error).message);
      setBusy(false);
    }
  };

  return (
    <div
      style={{
        minHeight: "100dvh",
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        padding: 24,
      }}
    >
      <form
        onSubmit={submit}
        style={{
          width: 360,
          maxWidth: "100%",
          background: "var(--lx-card)",
          borderRadius: "var(--lx-radius-card)",
          boxShadow: "var(--lx-shadow-card)",
          padding: "28px 30px",
        }}
      >
        <div style={{ marginBottom: 20 }}>
          <Wordmark />
        </div>
        <h1 style={{ fontSize: 20, fontWeight: 600, margin: "0 0 4px" }}>Masuk</h1>
        <p style={{ fontSize: 13.5, color: "var(--lx-muted)", margin: "0 0 22px", lineHeight: 1.55 }}>
          Dasbor admin Lab Komputasi FTMM.
        </p>

        <div style={{ display: "grid", gap: 14 }}>
          <TextField
            label="Email admin"
            value={email}
            onChange={setEmail}
            placeholder="admin@lab.ac.id"
            autoFocus
          />
          <div>
            <label
              htmlFor="lx-password"
              style={{
                display: "block",
                fontSize: 11,
                fontWeight: 600,
                letterSpacing: ".06em",
                textTransform: "uppercase",
                color: "var(--lx-muted)",
                marginBottom: 6,
              }}
            >
              Password
            </label>
            <input
              id="lx-password"
              type="password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              aria-invalid={Boolean(error)}
              style={{
                font: "inherit",
                width: "100%",
                fontSize: 13.5,
                padding: "9px 14px",
                borderRadius: "var(--lx-radius-control)",
                border: `1px solid ${error ? "var(--lx-status-alert)" : "var(--lx-border)"}`,
                background: "var(--lx-card)",
                color: "var(--lx-text)",
              }}
            />
          </div>
        </div>

        {error && (
          <div style={{ display: "flex", alignItems: "center", gap: 7, marginTop: 10 }}>
            <span
              style={{
                width: 8,
                height: 8,
                borderRadius: 999,
                background: "var(--lx-status-alert)",
                flexShrink: 0,
              }}
            />
            <span style={{ fontSize: 12 }}>{error}</span>
          </div>
        )}

        <div style={{ marginTop: 20 }}>
          <Button
            label={isBusy ? "Memeriksa..." : "Masuk"}
            variant="primary"
            isFullWidth
            disabled={isBusy || !email.trim() || !password}
            onClick={() => {}}
            type="submit"
          />
        </div>

        <p
          style={{
            fontSize: 11,
            lineHeight: 1.5,
            color: "var(--lx-muted)",
            textAlign: "center",
            margin: "16px 0 0",
          }}
        >
          Sesi mencatat waktu, durasi &amp; tujuan.
          <br />
          Tanpa perekaman layar.
        </p>
      </form>
    </div>
  );
}
