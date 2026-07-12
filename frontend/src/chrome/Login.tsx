// Login gate shown when there's no session token. Matches
// docs/design/LogiX App Shell & Login.dc.html §01: centered mascot + LOGIX
// wordmark, an ID/EN language toggle, two privacy-forward value props, an
// outline Google sign-in, and a privacy footer stating what we do (and don't)
// log. Navigating to /api/auth/google/login starts OAuth (or the
// LOGIX_DEV_MODE mock), which redirects back to /?token=... handled by App.
import { useState } from "react";
import { Button } from "@astryxdesign/core/Button";
import { Card } from "@astryxdesign/core/Card";
import { Center } from "@astryxdesign/core/Center";
import { SegmentedControl, SegmentedControlItem } from "@astryxdesign/core/SegmentedControl";
import { HStack, VStack } from "@astryxdesign/core/Stack";
import { Text } from "@astryxdesign/core/Text";
import { CheckIcon, ShieldCheckIcon } from "@heroicons/react/24/solid";

import mascot from "../assets/mascot.png";
import Wordmark from "../components/Wordmark";

type Lang = "id" | "en";

const COPY: Record<
  Lang,
  { subtitle: string; bullets: [string, string]; signIn: string; privacy: string }
> = {
  id: {
    subtitle: "Lab Access Logbook",
    bullets: [
      "Lihat siapa memakai tiap stasiun — fisik, SSH, atau AnyDesk.",
      "Laporan kehadiran & penggunaan otomatis, adil, transparan.",
    ],
    signIn: "Masuk dengan Google",
    privacy: "Kami mencatat siapa, cara, dan kapan — bukan keystroke atau isi layar.",
  },
  en: {
    subtitle: "Lab Access Logbook",
    bullets: [
      "See who is at each station — physical, SSH, or AnyDesk.",
      "Automatic attendance & usage reports — fair and transparent.",
    ],
    signIn: "Sign in with Google",
    privacy: "We log who, how, and when — never keystrokes or screen contents.",
  },
};

// Official multicolor Google "G" on a white tile so it reads on any button.
const GoogleMark = () => (
  <span
    style={{
      display: "inline-flex",
      alignItems: "center",
      justifyContent: "center",
      width: 20,
      height: 20,
    }}
  >
    <svg width="18" height="18" viewBox="0 0 48 48" aria-hidden="true">
      <path fill="#EA4335" d="M24 9.5c3.54 0 6.71 1.22 9.21 3.6l6.85-6.85C35.9 2.38 30.47 0 24 0 14.62 0 6.51 5.38 2.56 13.22l7.98 6.19C12.43 13.72 17.74 9.5 24 9.5z" />
      <path fill="#4285F4" d="M46.98 24.55c0-1.57-.15-3.09-.38-4.55H24v9.02h12.94c-.58 2.96-2.26 5.48-4.78 7.18l7.73 6c4.51-4.18 7.09-10.36 7.09-17.65z" />
      <path fill="#FBBC05" d="M10.53 28.59c-.48-1.45-.76-2.99-.76-4.59s.27-3.14.76-4.59l-7.98-6.19C.92 16.46 0 20.12 0 24c0 3.88.92 7.54 2.56 10.78l7.97-6.19z" />
      <path fill="#34A853" d="M24 48c6.48 0 11.93-2.13 15.89-5.81l-7.73-6c-2.15 1.45-4.92 2.3-8.16 2.3-6.26 0-11.57-4.22-13.47-9.91l-7.98 6.19C6.51 42.62 14.62 48 24 48z" />
    </svg>
  </span>
);

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

export default function Login() {
  const [lang, setLang] = useState<Lang>("id");
  const t = COPY[lang];

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

          <Button
            label={t.signIn}
            variant="secondary"
            size="lg"
            style={{ width: "100%" }}
            icon={<GoogleMark />}
            onClick={() => {
              window.location.href = "/api/auth/google/login";
            }}
          />

          <HStack gap={2} align="center" justify="center">
            <ShieldCheckIcon style={{ width: 14, height: 14, color: "var(--lx-text-muted)", flexShrink: 0 }} />
            <Text type="supporting" color="secondary">{t.privacy}</Text>
          </HStack>
        </VStack>
      </Card>
    </Center>
  );
}
