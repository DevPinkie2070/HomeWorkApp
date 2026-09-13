#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
API_DIR="$ROOT_DIR/Vendor/Schulmanager-API"
VENV_DIR="$ROOT_DIR/.venv"

if [[ ! -f "$API_DIR/main/schedules.py" ]]; then
  git clone --depth 1 https://github.com/SchmueI/Schulmanager-API.git "$API_DIR"
fi

if ! command -v python3 >/dev/null; then
  echo "Python 3 wird für die Schulmanager-API benötigt." >&2
  exit 1
fi

if [[ ! -x "$VENV_DIR/bin/python" ]]; then
  python3 -m venv "$VENV_DIR"
fi

"$VENV_DIR/bin/python" -m pip install --upgrade pip
"$VENV_DIR/bin/python" -m pip install selenium

if [[ ! -d "/Applications/Google Chrome.app" ]] && ! command -v chromium >/dev/null && ! command -v chromium-browser >/dev/null; then
  echo "Installiere Google Chrome oder Chromium, damit Selenium den Stundenplan laden kann." >&2
  exit 1
fi

echo "Schulmanager-API ist bereit: $VENV_DIR/bin/python"
