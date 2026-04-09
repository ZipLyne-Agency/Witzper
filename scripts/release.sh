#!/usr/bin/env bash
# One-command release: bump VERSION, commit, tag, push.
#
#   scripts/release.sh 0.2.0
#
# The push of the tag triggers .github/workflows/release.yml, which builds
# Witzper.app on macos-14, zips it, and creates a GitHub Release with the
# zip + latest.json manifest attached. The in-app Updater reads latest.json.
#
# Safety checks:
#   - Must be on main.
#   - Working tree must be clean (no staged or unstaged changes).
#   - Version must be strict semver (X.Y.Z).
#   - Tag must not already exist.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ $# -ne 1 ]]; then
    echo "usage: scripts/release.sh <version>   e.g. scripts/release.sh 0.2.0" >&2
    exit 2
fi

VERSION="$1"

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: version must be X.Y.Z (got: $VERSION)" >&2
    exit 2
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$BRANCH" != "main" ]]; then
    echo "ERROR: must release from main (currently on: $BRANCH)" >&2
    exit 2
fi

if ! git diff-index --quiet HEAD --; then
    echo "ERROR: working tree is dirty. Commit or stash before releasing." >&2
    git status --short >&2
    exit 2
fi

TAG="v${VERSION}"
if git rev-parse --verify --quiet "refs/tags/${TAG}" >/dev/null; then
    echo "ERROR: tag ${TAG} already exists" >&2
    exit 2
fi

echo "→ bumping VERSION to ${VERSION}"
echo "${VERSION}" > VERSION

echo "→ committing"
git add VERSION
# Use FLOW_SKIP_REBUILD so the post-commit hook doesn't fire — the release
# workflow on GitHub will produce the official artifact.
FLOW_SKIP_REBUILD=1 git commit -m "release: v${VERSION}"

echo "→ tagging ${TAG}"
git tag -a "${TAG}" -m "v${VERSION}"

echo "→ pushing main + tag"
git push origin main
git push origin "${TAG}"

echo ""
echo "✔ released ${TAG}"
echo "  GitHub Actions will build Witzper.app and publish the release at:"
echo "  https://github.com/ZipLyne-Agency/Witzper/releases/tag/${TAG}"
echo ""
echo "  Users with Witzper already installed will see the update via"
echo "  menu bar → Check for Updates… within 24 hours (or manually on click)."
