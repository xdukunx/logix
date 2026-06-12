#!/usr/bin/env bash
# Logix installer launcher for Linux & macOS.
# Usage:  sudo ./install/install.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="$(command -v python3 || command -v python || true)"
if [ -z "$PY" ]; then
  echo "Python 3 not found. Install Python 3 first." >&2
  exit 1
fi
exec "$PY" "$HERE/install.py" "$@"
