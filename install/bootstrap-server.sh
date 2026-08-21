#!/usr/bin/env bash
# One-line installer for the Logix central admin server (Linux/macOS).
#
#   curl -fsSL https://raw.githubusercontent.com/xdukunx/logix/main/install/bootstrap-server.sh | bash
#
# To pass flags through to setup_server.py (admin emails, --service, etc.),
# use `bash -s --`:
#   curl -fsSL .../bootstrap-server.sh | bash -s -- --admin-emails you@example.org --service
#
# What it does: installs every prerequisite it can (python3 + the venv module,
# Node.js 18+, git -- best-effort via apt/dnf/pacman/brew, else it prints
# manual instructions), clones or updates the repo into $LOGIX_INSTALL_DIR,
# builds the React dashboard, then hands off to the existing, fully-featured
# install/setup_server.py, forwarding every argument you passed. That step
# installs the server's Python dependencies into server/.venv.
# Safe to re-run: git pull + upgrade in place.
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

# Root already has the privileges sudo would grant, and minimal cloud/container
# images of Ubuntu and Debian frequently ship without sudo at all -- calling it
# unconditionally turned "already root" into "sudo: command not found".
if [ "$(id -u)" = "0" ]; then
    SUDO=""
elif have sudo; then
    SUDO="sudo"
else
    SUDO=""
fi

pkg_install() {
    # Try the common package managers in turn; silently skip ones not present.
    if have apt-get; then $SUDO apt-get update -qq && DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y "$@"; return; fi
    if have dnf;     then $SUDO dnf install -y "$@"; return; fi
    if have yum;     then $SUDO yum install -y "$@"; return; fi
    if have pacman;  then $SUDO pacman -Sy --noconfirm "$@"; return; fi
    if have brew;    then brew install "$@"; return; fi
    return 1
}

say "Checking prerequisites"
if ! have python3; then
    warn "python3 not found; attempting to install it"
    pkg_install python3 || die "Could not auto-install python3. Install Python 3.9+ yourself, then re-run."
fi
have python3 || die "python3 still not found after install attempt."

# Debian and Ubuntu package the venv module separately from python3, and the
# setup step below installs the server's dependencies into a venv (their system
# python is marked externally managed, so pip cannot write to it). Without this,
# `python3 -m venv` fails with "ensurepip is not available" on an otherwise
# perfectly good Ubuntu server.
if ! python3 -c "import ensurepip" >/dev/null 2>&1; then
    if have apt-get; then
        warn "the python3 venv module is missing; installing python3-venv"
        pkg_install python3-venv || warn "Could not install python3-venv automatically -- if setup fails, run: $SUDO apt-get install -y python3-venv"
    else
        warn "the python3 venv module is missing; install your distribution's python3 venv package if setup fails."
    fi
fi

# Node.js is a real dependency of the dashboard, not a nice-to-have. It used
# to be treated as one: if npm happened to exist the React UI was built, and
# otherwise the script printed a warning and quietly served the legacy
# vanilla-JS UI instead -- so which dashboard an install ended up with came
# down to what the machine already had. Install it like everything else.
#
# Vite 7 / React 19 need Node 18+; CI builds on 20 LTS. Distro packages are
# often older than that, so the major version is checked, not just presence.
NODE_MIN=18
node_major() {
    have node || { echo 0; return; }
    local raw major
    raw="$(node --version 2>/dev/null)" || { echo 0; return; }
    major="${raw#v}"; major="${major%%.*}"
    case "$major" in ''|*[!0-9]*) echo 0 ;; *) echo "$major" ;; esac
}

if [ "$(node_major)" -lt "$NODE_MIN" ]; then
    if have node; then warn "Node $(node --version) is older than the required v$NODE_MIN."; fi
    warn "Node.js $NODE_MIN+ not found; attempting to install it"
    # nodejs and npm are separate packages on Debian/Ubuntu and on Arch; brew
    # ships one formula. pkg_install skips managers that are not present.
    if have apt-get || have pacman; then
        pkg_install nodejs npm || warn "Could not auto-install Node.js."
    elif have brew; then
        pkg_install node || warn "Could not auto-install Node.js."
    else
        pkg_install nodejs || warn "Could not auto-install Node.js."
    fi
fi

if [ "$(node_major)" -ge "$NODE_MIN" ]; then
    say "Using Node $(node --version)"
else
    warn "Node.js $NODE_MIN+ is still unavailable (distro packages are often older)."
    warn "Install a current LTS from https://nodejs.org or via nodesource/nvm, then re-run"
    warn "this script to get the full dashboard. The legacy static UI works meanwhile."
fi

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

# --- 3. Build the dashboard --------------------------------------------------
if [ "$(node_major)" -ge "$NODE_MIN" ] && have npm; then
    say "Building the React dashboard"
    # `set -e` is on, so each step is guarded explicitly: a build failure must
    # degrade to the legacy UI with a message that names the retry commands,
    # not abort the whole install and not vanish into /dev/null the way the
    # previous `2>/dev/null ||` chain did.
    if (cd frontend && { npm ci --no-audit --no-fund || npm install --no-audit --no-fund; } && npm run build); then
        say "Dashboard built into frontend/dist"
    else
        warn "Dashboard build failed; the server will serve the legacy static UI instead."
        warn "To retry:  cd $INSTALL_DIR/frontend && npm install && npm run build"
    fi
else
    warn "Skipping the dashboard build (no usable Node.js). The legacy static UI will be served."
fi

# --- 4. Hand off to the real installer, forwarding all arguments ------------
say "Running install/setup_server.py"
exec python3 install/setup_server.py "$@"
