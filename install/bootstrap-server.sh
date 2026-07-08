#!/usr/bin/env bash
# One-line installer for the Logix central admin server (Linux/macOS).
#
#   curl -fsSL https://raw.githubusercontent.com/xdukunx/logix/main/install/bootstrap-server.sh | bash
#
# To pass flags through to setup_server.py (admin emails, --service, etc.),
# use `bash -s --`:
#   curl -fsSL .../bootstrap-server.sh | bash -s -- --admin-emails you@example.org --service
#
# What it does: makes sure git + python3 are present (best-effort install via
# apt/dnf/pacman/brew, else prints manual instructions), clones or updates the
# repo into $LOGIX_INSTALL_DIR, builds the React dashboard if npm is available
# (optional -- the server falls back to the legacy static UI otherwise), then
# hands off to the existing, fully-featured install/setup_server.py, forwarding
# every argument you passed. Safe to re-run: git pull + upgrade in place.
#
# Like any curl-pipe-bash installer, read it before you run it:
#   curl -fsSL <url> -o bootstrap-server.sh && less bootstrap-server.sh
#
# Config via env vars (all optional):
#   LOGIX_INSTALL_DIR  where to clone (default: /opt/logix if root, else ~/logix)
#   LOGIX_REPO_URL     git remote (default: the official repo)
#   LOGIX_BRANCH       branch to check out (default: main)
set -euo pipefail

REPO_URL="${LOGIX_REPO_URL:-https://github.com/xdukunx/logix.git}"
BRANCH="${LOGIX_BRANCH:-main}"
if [ -z "${LOGIX_INSTALL_DIR:-}" ]; then
    if [ "$(id -u)" = "0" ]; then INSTALL_DIR="/opt/logix"; else INSTALL_DIR="$HOME/logix"; fi
else
    INSTALL_DIR="$LOGIX_INSTALL_DIR"
fi

say()  { printf '\n==> %s\n' "$1"; }
warn() { printf 'WARNING: %s\n' "$1" >&2; }
die()  { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

# --- 1. Prerequisites: python3, then git (best-effort auto-install) ---------
have() { command -v "$1" >/dev/null 2>&1; }

pkg_install() {
    # Try the common package managers in turn; silently skip ones not present.
    if have apt-get; then sudo apt-get update -qq && sudo apt-get install -y "$@"; return; fi
    if have dnf;     then sudo dnf install -y "$@"; return; fi
    if have yum;     then sudo yum install -y "$@"; return; fi
    if have pacman;  then sudo pacman -Sy --noconfirm "$@"; return; fi
    if have brew;    then brew install "$@"; return; fi
    return 1
}

say "Checking prerequisites"
if ! have python3; then
    warn "python3 not found; attempting to install it"
    pkg_install python3 || die "Could not auto-install python3. Install Python 3.9+ yourself, then re-run."
fi
have python3 || die "python3 still not found after install attempt."

if ! have git; then
    warn "git not found; attempting to install it"
    pkg_install git || warn "Could not auto-install git; will fall back to downloading a tarball."
fi

# --- 2. Get the code onto this machine ---------------------------------------
say "Fetching Logix into $INSTALL_DIR"
if have git; then
    if [ -d "$INSTALL_DIR/.git" ]; then
        git -C "$INSTALL_DIR" fetch --depth 1 origin "$BRANCH"
        git -C "$INSTALL_DIR" checkout "$BRANCH"
        git -C "$INSTALL_DIR" reset --hard "origin/$BRANCH"
        say "Updated existing checkout"
    else
        mkdir -p "$(dirname "$INSTALL_DIR")"
        git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$INSTALL_DIR"
    fi
else
    # No git: fetch the branch tarball from GitHub directly (curl+tar only).
    have curl || die "Neither git nor curl is available -- install one and re-run."
    TARBALL_URL="${REPO_URL%.git}/archive/refs/heads/${BRANCH}.tar.gz"
    mkdir -p "$INSTALL_DIR"
    curl -fsSL "$TARBALL_URL" | tar -xz --strip-components=1 -C "$INSTALL_DIR"
fi

cd "$INSTALL_DIR"

# --- 3. Build the dashboard (optional -- falls back to the legacy static UI) -
if have npm; then
    say "Building the React dashboard"
    (cd frontend && npm ci --no-audit --no-fund 2>/dev/null || npm install --no-audit --no-fund) \
        && (cd frontend && npm run build) \
        || warn "Dashboard build failed; the server will serve the legacy static UI instead."
else
    warn "npm not found; skipping the React dashboard build (legacy static UI will be served). Install Node.js and run 'cd frontend && npm install && npm run build' later to upgrade it."
fi

# --- 4. Hand off to the real installer, forwarding all arguments ------------
say "Running install/setup_server.py"
exec python3 install/setup_server.py "$@"
