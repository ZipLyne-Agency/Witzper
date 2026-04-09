#!/usr/bin/env bash
# Post-commit hook: rebuild Witzper.app and reinstall to /Applications so
# the installed copy always matches the latest committed source.
#
# Why post-commit (not pre-commit):
#   - Commits never block on a Swift build.
#   - If the build breaks, the commit still lands so you can fix + recommit.
#
# Disable for a single commit:  FLOW_SKIP_REBUILD=1 git commit …
# Disable permanently:          chmod -x .git/hooks/post-commit
set -euo pipefail

if [[ "${FLOW_SKIP_REBUILD:-0}" == "1" ]]; then
    exit 0
fi

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# Only rebuild when Swift sources, the build script, or the icon changed.
# This keeps doc-only commits from triggering a 30-second rebuild every time.
if ! git diff --name-only HEAD~1 HEAD 2>/dev/null | grep -qE '^(swift-helper/|scripts/build_app\.sh|assets/AppIcon\.icns|scripts/build_icon\.py)'; then
    echo "post-commit: no Swift/build changes — skipping Witzper.app rebuild"
    exit 0
fi

echo "post-commit: rebuilding Witzper.app…"

# Run the build in the background so `git commit` returns immediately — the
# Swift release build takes 5–10 s and we don't want to make the user wait.
(
    /bin/bash scripts/build_app.sh > /tmp/flow-post-commit.log 2>&1 || {
        echo "post-commit: build FAILED — see /tmp/flow-post-commit.log" >&2
        exit 1
    }

    if [[ -d build/Witzper.app ]]; then
        # Only reinstall if /Applications/Witzper.app already exists —
        # don't force an install on machines that never had one.
        if [[ -d /Applications/Witzper.app ]]; then
            pkill -9 -f '/Applications/Witzper.app/Contents/MacOS/Witzper' 2>/dev/null || true
            sleep 0.5
            rm -rf /Applications/Witzper.app
            cp -R build/Witzper.app /Applications/
            echo "post-commit: reinstalled /Applications/Witzper.app" >> /tmp/flow-post-commit.log
            open /Applications/Witzper.app
        fi
    fi
) &

disown
exit 0
