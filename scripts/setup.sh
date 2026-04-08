#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

echo "→ creating venv"
python3 -m venv .venv
# shellcheck disable=SC1091
source .venv/bin/activate
pip install --upgrade pip
pip install -e ".[dev,personalize]"

echo "→ building Swift helper"
if command -v swift >/dev/null 2>&1; then
  (cd swift-helper && swift build -c release)
  echo "  built: swift-helper/.build/release/flow-helper"
else
  echo "  swift not found — install Xcode command-line tools: xcode-select --install"
fi

echo
echo "✔ setup complete"
echo "  next: ./scripts/download_models.sh"
echo "  then: ./scripts/run.sh"
