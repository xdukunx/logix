# Homebrew formula for the Logix cross-platform core + CLI (macOS/Linux).
#
# Install via a tap:
#   brew tap xdukunx/logix https://github.com/xdukunx/homebrew-logix
#   brew install logix
#   sudo logix configure
#
# This formula lives in the main repo for reference; to publish, copy it into a
# `homebrew-logix` tap repo under Formula/logix.rb and fill in `sha256` with the
# release tarball's checksum:
#   curl -fsSL https://github.com/xdukunx/logix/archive/refs/tags/v1.2.0.tar.gz | shasum -a 256
#
# It installs the pure-Python core (stdlib only) -- NOT the Windows sign-in
# agent. The at-keyboard sign-in prompt is Windows-only.
class Logix < Formula
  desc "Privacy-first sign-in logbook for shared lab computers (core + CLI)"
  homepage "https://github.com/xdukunx/logix"
  url "https://github.com/xdukunx/logix/archive/refs/tags/v1.2.0.tar.gz"
  sha256 "REPLACE_WITH_RELEASE_TARBALL_SHA256"
  license "MIT"

  depends_on "python@3.12"

  def install
    # Core lives in libexec/logix so install.py's own SRC resolution
    # (parent.parent/"logix") points back at this same directory -- the same
    # invariant the deb/rpm layout (/opt/software/logix) relies on.
    lib_dir = libexec/"logix"
    lib_dir.install "logix/paths.py",
                    "logix/log_physical.py",
                    "logix/logbook_report.py",
                    "logix/logbook_sql.py",
                    "logix/logbook_ssh_login.py",
                    "logix/gsheet_sync.py",
                    "install/install.py"
    lib_dir.install "VERSION"

    # Thin wrapper: point LOGIX_LIB at the formula's copy, then hand off to the
    # shared dispatcher shipped in the repo (packaging/bin/logix).
    libexec.install "packaging/bin/logix" => "logix-dispatch"
    (bin/"logix").write <<~SH
      #!/bin/sh
      export LOGIX_LIB="#{lib_dir}"
      exec "#{libexec}/logix-dispatch" "$@"
    SH
  end

  def caveats
    <<~EOS
      One-time setup (writes to /Library/Application Support/Logix):
        sudo logix configure

      Records who/how/when only -- never screen contents. See:
        https://github.com/xdukunx/logix/blob/main/docs/PRIVACY.md
    EOS
  end

  test do
    assert_match "logix", shell_output("#{bin}/logix version")
  end
end
