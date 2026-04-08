#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

HELPER=swift-helper/.build/release/flow-helper
if [[ -x "$HELPER" ]]; then
  echo "→ launching Swift helper in background"
  "$HELPER" &
  HELPER_PID=$!
  trap 'kill $HELPER_PID 2>/dev/null || true' EXIT
  sleep 0.3
else
  echo "⚠ Swift helper not built — running with pynput fallback (right-option key)"
fi

# shellcheck disable=SC1091
source .venv/bin/activate
exec python -m flow run --verbose
