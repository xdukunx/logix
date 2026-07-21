#!/bin/sh
# Post-install notice for the Logix core packages (deb/rpm). Deliberately does
# NOT run the interactive wizard itself -- package installs must be
# non-interactive and idempotent. It just points the operator at the one-time
# setup command.
set -eu
echo ""
echo "Logix core installed. One-time setup:"
echo "    sudo logix configure"
echo ""
echo "  Non-interactive (imaging/automation), e.g.:"
echo "    sudo logix configure --non-interactive \\"
echo "        --device-name \"Lab PC 3\" --server-url https://logix.example.org \\"
echo "        --enroll-code ABCD-1234-EFGH-5678 --privacy-mode local_only"
echo ""
echo "  Then enable SSH-login capture (Linux):"
echo "    sudo ln -sf /opt/software/logix/logix-ssh-hook.sh /etc/profile.d/zz_logbook_ssh.sh"
echo ""
echo "  Privacy: records who/how/when only -- never screen contents. See"
echo "  /usr/share/doc/logix/PRIVACY.md"
echo ""
exit 0
