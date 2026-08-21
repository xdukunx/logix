// Login gate shown when there's no session token. Local admin auth: email +
// password checked against the server's ADMIN_EMAILS allowlist plus the
// LOGIX_ADMIN_PASSWORD it was started with.
//
// ONE purpose: signing an administrator in. The previous version closed with
// the client-side privacy notice ("Sesi mencatat waktu, durasi & tujuan --
// tanpa perekaman layar"), which is written for the STUDENT at a workstation,
// not the admin at this screen. Two audiences in one card read as two
// different screens stacked on top of each other. That line belongs on the
// sign-in popup the agent shows (windows/logbook_popup.ps1), where it already
// is, and it is gone from here.
//
// The password field is the shared TextField too. It was a hand-rolled
// <input> with its own copy of the label markup, so it drifted a pixel off the
// email field above it -- the visual "off" that has no single cause.
import { useState, type FormEvent } from "react";

import { login } from "../api";
import Wordmark from "../components/Wordmark";
import { Button, TextField } from "../ui/controls";

export default function Login({ onAuthenticated }: { onAuthenticated: () => void }) {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [isBusy, setBusy] = useState(false);

  const canSubmit = Boolean(email.trim() && password) && !isBusy;

  const submit = async (e: FormEvent) => {
    e.preventDefault();
    if (!canSubmit) return;
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
          padding: "30px 30px 26px",
        }}
      >
        {/* Wordmark and heading are one block: the product name IS the title
            of this screen, so a separate 20px "Masuk" underneath it was the
            same statement twice. The single muted line below says who the
            screen is for. */}
        <Wordmark />
        <p
          style={{
            fontSize: 13,
            color: "var(--lx-muted)",
            margin: "10px 0 24px",
            lineHeight: 1.5,
          }}
        >
          Masuk sebagai admin Lab Komputasi FTMM.
        </p>

        <div style={{ display: "grid", gap: 14 }}>
          <TextField
            label="Email admin"
            value={email}
            onChange={setEmail}
            placeholder="admin@lab.ac.id"
            autoComplete="username"
            autoFocus
          />
          <TextField
            label="Password"
            type="password"
            value={password}
            onChange={setPassword}
            autoComplete="current-password"
            error={error ?? undefined}
          />
        </div>

        <div style={{ marginTop: 22 }}>
          <Button
            label={isBusy ? "Memeriksa..." : "Masuk"}
            variant="primary"
            isFullWidth
            disabled={!canSubmit}
            onClick={() => {}}
            type="submit"
          />
        </div>
      </form>
    </div>
  );
}
