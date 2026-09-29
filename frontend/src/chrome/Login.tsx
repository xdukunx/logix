// Login gate shown when there's no session token. Local admin auth: email +
// password checked against the server's ADMIN_EMAILS allowlist plus the
// LOGIX_ADMIN_PASSWORD it was started with.
//
// ONE purpose: signing an administrator in. The student-facing privacy notice
// belongs on the agent's sign-in popup (windows/logbook_popup.ps1), not here.
//
// v4 "Denyut": the screen has the app's own shape -- the dark frame beside a
// light canvas holding the form card. The one moving thing is real: the
// server's own heartbeat. /api/health needs no session, so every answer lands
// as a spike on the trace and a silent server flatlines. An admin sees the
// server is down before typing a password, and "server down" never reads as
// "wrong password".
import { useRef, useState, type CSSProperties, type FormEvent } from "react";

import { login } from "../api";
import Wordmark from "../components/Wordmark";
import { Card, Mono } from "../ui/base";
import { Button, TextField } from "../ui/controls";
import { useBreakpoint } from "../ui/hooks";
import { EcgTrace } from "../ui/viz";
import { usePolling } from "../util";

const PULSE_EVERY_MS = 3000;
// Short, so the beats of the few seconds a sign-in takes are all on screen.
const PULSE_WINDOW_MS = 15_000;

const useServerPulse = () => {
  const [beats, setBeats] = useState<number[]>([]);
  const [latencyMs, setLatencyMs] = useState<number | null>(null);
  const [isDown, setDown] = useState(false);
  const sentRef = useRef(0);
  const handledRef = useRef(0);
  usePolling(async () => {
    const seq = ++sentRef.current;
    const started = performance.now();
    let isOk = false;
    try {
      // A server that takes the connection and never answers is down too: the
      // timeout turns that hang into a failure within one pulse.
      isOk = (await fetch("/api/health", { signal: AbortSignal.timeout(PULSE_EVERY_MS) })).ok;
    } catch {
      /* no answer: isOk stays false */
    }
    // Pulses can overlap; a slow answer must not overwrite a newer one.
    if (seq < handledRef.current) return;
    handledRef.current = seq;
    setDown(!isOk);
    if (!isOk) return;
    const now = Date.now();
    setLatencyMs(Math.round(performance.now() - started));
    setBeats((prev) => [...prev.filter((t) => now - t < PULSE_WINDOW_MS), now]);
  }, PULSE_EVERY_MS);
  return { beats, latencyMs, isDown, lastBeat: beats[beats.length - 1] };
};

export default function Login({ onAuthenticated }: { onAuthenticated: () => void }) {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [isBusy, setBusy] = useState(false);
  const isPhone = useBreakpoint() === "phone";
  const pulse = useServerPulse();

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
      // fetch rejects with a TypeError only when no answer came back at all.
      setError(err instanceof TypeError ? "Server tidak menjawab. Coba lagi sebentar lagi." : (err as Error).message);
      setBusy(false);
    }
  };

  const isUp = pulse.latencyMs !== null && !pulse.isDown;

  return (
    <div
      style={{
        minHeight: "100dvh",
        display: "grid",
        gridTemplateColumns: isPhone ? "1fr" : "minmax(0, 1fr) minmax(0, 1.15fr)",
        gridTemplateRows: isPhone ? "auto 1fr" : undefined,
        gap: isPhone ? 0 : 12,
        padding: isPhone ? 0 : 12,
      }}
    >
      {/* ---- Frame ---- */}
      <section
        className="lx-frame-scope"
        style={{
          display: "flex",
          flexDirection: "column",
          gap: isPhone ? 18 : 28,
          padding: isPhone ? "20px 16px 22px" : "22px 26px 26px",
          minWidth: 0,
        }}
      >
        <Wordmark markSize={isPhone ? 26 : 34} size={isPhone ? 12 : 15} />
        {!isPhone && <div style={{ flex: 1 }} />}
        <p
          className="lx-big lx-rise"
          style={{ margin: 0, fontSize: isPhone ? 34 : "clamp(44px, 4.8vw, 76px)", lineHeight: 1.04 }}
        >
          <span
            style={{
              background: "var(--lx-accent)",
              color: "var(--lx-on-accent)",
              borderRadius: "0.24em",
              padding: "0 0.14em",
            }}
          >
            Denyut
          </span>{" "}
          lab,
          <br />
          terbaca sekilas.
        </p>

        <Card padding={isPhone ? "14px 16px 12px" : "18px 22px 16px"} className="lx-rise" style={{ "--i": 1 } as CSSProperties}>
          <div
            style={{
              display: "flex",
              alignItems: "center",
              flexWrap: "wrap",
              gap: "4px 10px",
              fontSize: isPhone ? 13 : 14,
              marginBottom: isPhone ? 6 : 10,
            }}
          >
            {/* Flashes on each answer the server actually gave. */}
            <span
              key={pulse.lastBeat ?? 0}
              className={isUp ? "lx-flash" : undefined}
              aria-hidden="true"
              style={{
                width: 9,
                height: 9,
                borderRadius: 999,
                flexShrink: 0,
                background: pulse.isDown
                  ? "var(--lx-status-alert)"
                  : isUp
                    ? "var(--lx-status-active)"
                    : "var(--lx-frame-muted)",
              }}
            />
            <span style={{ fontWeight: 600 }}>Denyut server</span>
            <span style={{ marginLeft: "auto", color: pulse.isDown ? "var(--lx-status-alert)" : "var(--lx-muted)" }}>
              {pulse.isDown ? (
                "Tidak menjawab"
              ) : isUp ? (
                <>
                  Aktif · <Mono style={{ color: "var(--lx-text)" }}>{pulse.latencyMs} ms</Mono>
                </>
              ) : (
                "Menghubungi..."
              )}
            </span>
          </div>
          {/* Monitoring's trace, enlarged with zoom so it still lays out and
              measures at its drawn size. */}
          <div style={{ zoom: isPhone ? 1.3 : 2 }}>
            <EcgTrace beats={pulse.beats} isFlat={pulse.isDown} windowMs={PULSE_WINDOW_MS} />
          </div>
        </Card>
      </section>

      {/* ---- Canvas ---- */}
      <main
        style={{
          display: "grid",
          // On a phone the card sits under the frame, not adrift mid-panel.
          placeItems: isPhone ? "start center" : "center",
          background: "var(--lx-bg)",
          borderRadius: isPhone ? "22px 22px 0 0" : 30,
          padding: isPhone ? "28px 16px 32px" : 32,
        }}
      >
        <Card
          padding={isPhone ? "26px 22px 22px" : "34px 34px 30px"}
          className="lx-rise"
          style={{ width: 400, maxWidth: "100%", "--i": 2 } as CSSProperties}
        >
          <form onSubmit={submit}>
            <h1 style={{ margin: 0, fontSize: 28, fontWeight: 600, letterSpacing: "-0.03em", lineHeight: 1.1 }}>Masuk</h1>
            <p style={{ fontSize: 13.5, color: "var(--lx-muted)", margin: "8px 0 26px", lineHeight: 1.5 }}>
              Khusus admin Lab Komputasi FTMM.
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

            <Button
              label={isBusy ? "Memeriksa..." : "Masuk"}
              variant="primary"
              isFullWidth
              disabled={!canSubmit}
              type="submit"
              style={{ marginTop: 24, padding: "13px 20px", fontSize: 14.5 }}
            />
          </form>
        </Card>
      </main>
    </div>
  );
}
