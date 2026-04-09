#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# shellcheck disable=SC1091
source .venv/bin/activate

# First-run: if no user config exists, run the hotkey picker.
USER_CFG="$HOME/.config/Witzper/config.toml"
if [[ ! -f "$USER_CFG" ]]; then
  echo "→ first run — let's pick your hotkey"
  python -m flow setup
fi

# Read hotkey from user config (fall back to right_option)
HOTKEY=$(python -c "
import tomli, os
p=os.path.expanduser('~/.config/Witzper/config.toml')
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

# Build the native launcher if needed. Gives Activity Monitor a binary
# literally named "Witzper" so the Process Name column shows "Witzper"
# instead of "Python". The launcher dlopens libpython and calls
# Py_BytesMain() in-process so p_comm stays as "Witzper".
if [[ ! -x ./Witzper || scripts/witzper_launcher.m -nt ./Witzper ]]; then
  if command -v clang >/dev/null 2>&1; then
    echo "→ building native Witzper launcher"
    clang -fobjc-arc -O2 -o Witzper scripts/witzper_launcher.m \
      -framework Foundation 2>/dev/null || true
  fi
fi

if [[ -x ./Witzper ]]; then
  exec ./Witzper --verbose
else
  exec -a Witzper-daemon python -m flow run --verbose
fi
