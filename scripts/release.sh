#!/usr/bin/env bash
# Releases are AUTOMATIC: every push to main builds, signs, notarizes and
# publishes a release (see .github/workflows/release.yml). The version is
# "<VERSION file MAJOR.MINOR>.<commit count>" — there are no tags to push and
# no patch numbers to manage.
#
# This script only bumps the MAJOR.MINOR base in the VERSION file:
#
#   scripts/release.sh minor        # 0.3 -> 0.4
#   scripts/release.sh major        # 0.3 -> 1.0
#
# Commit + push the change and CI does the rest.
set -euo pipefail
cd "$(dirname "$0")/.."

BUMP_ARG="${1:-}"

CURRENT="$(cut -d. -f1,2 <<< "$(cat VERSION | tr -d '[:space:]')")"
MAJOR="$(cut -d. -f1 <<< "$CURRENT")"
MINOR="$(cut -d. -f2 <<< "$CURRENT")"

case "$BUMP_ARG" in
    minor) NEW="${MAJOR}.$((MINOR + 1))" ;;
    major) NEW="$((MAJOR + 1)).0" ;;
    *)
        echo "usage: scripts/release.sh minor|major" >&2
        echo "(patch releases happen automatically on every push to main)" >&2
        exit 2
        ;;
esac

echo "$NEW" > VERSION

# Keep pyproject.toml's package version in lockstep with the VERSION base.
sed -i '' "s/^version = \".*\"/version = \"${NEW}\"/" pyproject.toml

echo "-> VERSION base bumped: ${CURRENT} -> ${NEW} (VERSION + pyproject.toml)"
echo "   commit + push to main and CI will ship v${NEW}.<commit-count>:"
echo "     git add VERSION pyproject.toml && git commit -m 'Bump version base to ${NEW}' && git push"
