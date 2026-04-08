#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
source .venv/bin/activate

# First-run: if no user config exists, run the hotkey picker.
USER_CFG="$HOME/.config/flow-local/config.toml"
if [[ ! -f "$USER_CFG" ]]; then
  echo "→ first run — let's pick your hotkey"
  python -m flow setup
fi

# Read hotkey from user config (fall back to right_option)
HOTKEY=$(python -c "
import tomli, os
p=os.path.expanduser('~/.config/flow-local/config.toml')
try:
    with open(p,'rb') as f: print(tomli.load(f).get('hotkey',{}).get('key','right_option'))
except Exception:
    print('right_option')
")

HELPER=swift-helper/.build/release/flow-helper
if [[ -x "$HELPER" ]]; then
  echo "→ launching Swift helper (hotkey=$HOTKEY)"
  "$HELPER" --hotkey "$HOTKEY" &
  HELPER_PID=$!
  trap 'kill $HELPER_PID 2>/dev/null || true' EXIT
  sleep 0.4
else
  echo "⚠ Swift helper not built — using pynput fallback"
fi

exec python -m flow run --verbose
