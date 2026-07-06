// Login gate shown when there's no session token. Comnyang-style: mascot +
// language toggle up top, bold wordmark, feature bullets, and a prominent
// Google sign-in. Navigating to /api/auth/google/login starts the OAuth flow
// (or the LOGIX_DEV_MODE mock login), which redirects back to /?token=...
// handled by App.
import { useState } from "react";
import { Button } from "@astryxdesign/core/Button";
import { Card } from "@astryxdesign/core/Card";
import { Center } from "@astryxdesign/core/Center";
import { SegmentedControl, SegmentedControlItem } from "@astryxdesign/core/SegmentedControl";
import { HStack, VStack } from "@astryxdesign/core/Stack";
import { Heading, Text } from "@astryxdesign/core/Text";
import { CheckCircleIcon } from "@heroicons/react/24/solid";

import mascot from "../assets/mascot.png";

type Lang = "id" | "en";

const COPY: Record<Lang, {
  subtitle: string;
  bullets: [string, string];
  signIn: string;
  help: string;
  contact: string;
}> = {
  id: {
    subtitle: "Masuk dengan akun Google admin untuk membuka dashboard Logix di semua komputer.",
    bullets: [
      "Kelola sesi & perangkat lab dari satu dashboard",
      "Monitoring real-time, peringatan, dan laporan Excel",
    ],
    signIn: "Masuk dengan Google",
    help: "Butuh bantuan?",
    contact: "Hubungi admin lab",
  },
  en: {
    subtitle: "Sign in with your admin Google account to open the Logix dashboard on any computer.",
    bullets: [
      "Manage lab sessions & devices from one dashboard",
      "Real-time monitoring, alerts, and Excel reports",
    ],
    signIn: "Sign in with Google",
    help: "Need help?",
    contact: "Contact the lab admin",
  },
};

// Official multicolor Google "G", wrapped in a white tile so it stays legible
// on the coloured sign-in button.
const GoogleMark = () => (
  <span
    style={{
      display: "inline-flex",
      alignItems: "center",
      justifyContent: "center",
      width: 24,
      height: 24,
      borderRadius: 6,
      background: "#fff",
    }}
  >
    <svg width="16" height="16" viewBox="0 0 48 48" aria-hidden="true">
      <path fill="#EA4335" d="M24 9.5c3.54 0 6.71 1.22 9.21 3.6l6.85-6.85C35.9 2.38 30.47 0 24 0 14.62 0 6.51 5.38 2.56 13.22l7.98 6.19C12.43 13.72 17.74 9.5 24 9.5z" />
      <path fill="#4285F4" d="M46.98 24.55c0-1.57-.15-3.09-.38-4.55H24v9.02h12.94c-.58 2.96-2.26 5.48-4.78 7.18l7.73 6c4.51-4.18 7.09-10.36 7.09-17.65z" />
      <path fill="#FBBC05" d="M10.53 28.59c-.48-1.45-.76-2.99-.76-4.59s.27-3.14.76-4.59l-7.98-6.19C.92 16.46 0 20.12 0 24c0 3.88.92 7.54 2.56 10.78l7.97-6.19z" />
      <path fill="#34A853" d="M24 48c6.48 0 11.93-2.13 15.89-5.81l-7.73-6c-2.15 1.45-4.92 2.3-8.16 2.3-6.26 0-11.57-4.22-13.47-9.91l-7.98 6.19C6.51 42.62 14.62 48 24 48z" />
    </svg>
  </span>
);

export default function Login() {
  const [lang, setLang] = useState<Lang>("id");
  const t = COPY[lang];

  return (
    <Center height="100vh">
      <Card padding={8} width={420}>
        <VStack gap={5} align="stretch">
          <HStack gap={3} align="center" justify="between">
            <img src={mascot} alt="Logix" style={{ height: 52, width: "auto" }} />
            <SegmentedControl value={lang} onChange={(v) => setLang(v as Lang)} label="Bahasa" size="sm">
              <SegmentedControlItem value="id" label="ID" />
              <SegmentedControlItem value="en" label="EN" />
            </SegmentedControl>
          </HStack>

          <VStack gap={1} align="start">
            <Heading level={2} style={{ letterSpacing: "0.06em" }}>LOGIX</Heading>
            <Text type="supporting" color="secondary">Lab Access Logbook</Text>
          </VStack>

          <Text type="body" color="secondary">{t.subtitle}</Text>

          <VStack gap={2} align="start">
            {t.bullets.map((b) => (
              <HStack key={b} gap={2} align="center">
                <CheckCircleIcon style={{ width: 18, height: 18, color: "var(--color-accent)", flexShrink: 0 }} />
                <Text type="body">{b}</Text>
              </HStack>
            ))}
          </VStack>

          <Button
            label={t.signIn}
            variant="primary"
            size="lg"
            icon={<GoogleMark />}
            onClick={() => {
              window.location.href = "/api/auth/google/login";
            }}
          />

          <Text type="supporting" color="secondary">
            {t.help} {t.contact}.
          </Text>
        </VStack>
      </Card>
    </Center>
  );
}
