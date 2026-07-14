// Login gate shown when there's no session token. Local admin auth: email +
// password checked against the server's ADMIN_EMAILS allowlist + the
// LOGIX_ADMIN_PASSWORD it was started with (Google OAuth was removed). Matches
// docs/design/LogiX App Shell & Login.dc.html: centered mascot + LOGIX
// wordmark, an ID/EN language toggle, two privacy-forward value props, the
// sign-in form, and a privacy footer stating what we do (and don't) log.
import { useState } from "react";
import { Button } from "@astryxdesign/core/Button";
import { Card } from "@astryxdesign/core/Card";
import { Center } from "@astryxdesign/core/Center";
import { SegmentedControl, SegmentedControlItem } from "@astryxdesign/core/SegmentedControl";
import { HStack, VStack } from "@astryxdesign/core/Stack";
import { Text } from "@astryxdesign/core/Text";
import { TextInput } from "@astryxdesign/core/TextInput";
import { ArrowRightEndOnRectangleIcon } from "@heroicons/react/24/outline";
import { CheckIcon, ShieldCheckIcon } from "@heroicons/react/24/solid";

import { login } from "../api";
import mascot from "../assets/mascot.png";
import Wordmark from "../components/Wordmark";

type Lang = "id" | "en";

const COPY: Record<
  Lang,
  {
    subtitle: string;
    bullets: [string, string];
    emailLabel: string;
    emailPlaceholder: string;
    passwordLabel: string;
    passwordPlaceholder: string;
    signIn: string;
    privacy: string;
  }
> = {
  id: {
    subtitle: "Lab Access Logbook",
    bullets: [
      "Lihat siapa memakai tiap stasiun — fisik, SSH, atau AnyDesk.",
      "Laporan kehadiran & penggunaan otomatis, adil, transparan.",
    ],
    emailLabel: "Email admin",
    emailPlaceholder: "admin@lab.ac.id",
    passwordLabel: "Password",
    passwordPlaceholder: "••••••••",
    signIn: "Masuk",
    privacy: "Kami mencatat siapa, cara, dan kapan — bukan keystroke atau isi layar.",
  },
  en: {
    subtitle: "Lab Access Logbook",
    bullets: [
      "See who is at each station — physical, SSH, or AnyDesk.",
      "Automatic attendance & usage reports — fair and transparent.",
    ],
    emailLabel: "Admin email",
    emailPlaceholder: "admin@lab.ac.id",
    passwordLabel: "Password",
    passwordPlaceholder: "••••••••",
    signIn: "Sign in",
    privacy: "We log who, how, and when — never keystrokes or screen contents.",
  },
};

const CheckBullet = ({ children }: { children: React.ReactNode }) => (
  <HStack gap={2} align="start">
    <span
      style={{
        width: 20,
        height: 20,
        borderRadius: 5,
        background: "var(--lx-status-inuse-bg)",
        color: "var(--lx-status-inuse)",
        display: "inline-flex",
        alignItems: "center",
        justifyContent: "center",
        flexShrink: 0,
        marginTop: 1,
      }}
    >
      <CheckIcon style={{ width: 12, height: 12 }} />
    </span>
    <Text type="supporting">{children}</Text>
  </HStack>
);

export default function Login({ onAuthenticated }: { onAuthenticated: () => void }) {
  const [lang, setLang] = useState<Lang>("id");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const t = COPY[lang];

  const canSubmit = email.trim().length > 0 && password.length > 0 && !busy;

  const submit = async () => {
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
    <Center height="100vh" style={{ background: "var(--color-background-body)" }}>
      <Card padding={8} width={380}>
        <VStack gap={5} align="stretch">
          <VStack gap={2} align="center">
            <img src={mascot} alt="" style={{ height: 58, width: "auto" }} />
            <Wordmark size={30} tracking="0.2em" showMark={false} />
            <Text type="supporting" color="secondary">{t.subtitle}</Text>
          </VStack>

          <SegmentedControl
            value={lang}
            onChange={(v) => setLang(v as Lang)}
            label="Bahasa"
            size="sm"
            layout="fill"
          >
            <SegmentedControlItem value="id" label="ID" />
            <SegmentedControlItem value="en" label="EN" />
          </SegmentedControl>

          <VStack gap={3} align="stretch">
            {t.bullets.map((b) => (
              <CheckBullet key={b}>{b}</CheckBullet>
            ))}
          </VStack>

          <VStack gap={3} align="stretch">
            <TextInput
              label={t.emailLabel}
              type="email"
              value={email}
              onChange={(v) => { setEmail(v); setError(null); }}
              placeholder={t.emailPlaceholder}
              onEnter={submit}
            />
            <TextInput
              label={t.passwordLabel}
              type="password"
              value={password}
              onChange={(v) => { setPassword(v); setError(null); }}
              placeholder={t.passwordPlaceholder}
              onEnter={submit}
              status={error ? { type: "error", message: error } : undefined}
            />
            <Button
              label={t.signIn}
              variant="primary"
              size="lg"
              style={{ width: "100%" }}
              icon={<ArrowRightEndOnRectangleIcon style={{ width: 18, height: 18 }} />}
              isDisabled={!canSubmit}
              isLoading={busy}
              onClick={submit}
            />
          </VStack>

          <HStack gap={2} align="center" justify="center">
            <ShieldCheckIcon style={{ width: 14, height: 14, color: "var(--lx-text-muted)", flexShrink: 0 }} />
            <Text type="supporting" color="secondary">{t.privacy}</Text>
          </HStack>
        </VStack>
      </Card>
    </Center>
  );
}
