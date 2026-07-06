// Login screen shown when there's no session token. Navigating to
// /api/auth/google/login starts the OAuth flow (or the LOGIX_DEV_MODE mock
// login), which redirects back to /?token=... handled by App.
import { Button } from "@astryxdesign/core/Button";
import { Card } from "@astryxdesign/core/Card";
import { Center } from "@astryxdesign/core/Center";
import { VStack } from "@astryxdesign/core/Stack";
import { Heading, Text } from "@astryxdesign/core/Text";

export default function Login() {
  return (
    <Center height="100vh">
      <Card padding={8} maxWidth={380}>
        <VStack gap={4} align="center">
          <Heading level={3}>Logix</Heading>
          <Text type="body" color="secondary">
            Lab access logbook — masuk dengan akun admin untuk membuka dashboard.
          </Text>
          <Button
            label="Masuk dengan Google"
            variant="primary"
            size="lg"
            onClick={() => {
              window.location.href = "/api/auth/google/login";
            }}
          />
        </VStack>
      </Card>
    </Center>
  );
}
