#!/bin/sh
# Local release: builds the DMG on this Mac (signed with your identity from Config/Signing.xcconfig),
# creates the tag and a GitHub Release, and attaches the installer. Costs no GitHub Actions minutes.
#
#   scripts/release.sh v0.2.0                 build, confirm, publish
#   scripts/release.sh v0.2.0 --prerelease    mark the release as a pre-release
#   scripts/release.sh v0.2.0 --dry-run       run all checks and the build, publish nothing
#   scripts/release.sh v0.2.0 --yes           don't ask for confirmation
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

die() { echo "error: $*" >&2; exit 1; }

TAG="${1:-}"
[ -n "$TAG" ] || die "usage: scripts/release.sh <tag, e.g. v0.2.0> [--prerelease] [--dry-run] [--yes]"
shift
PRERELEASE=NO
DRY_RUN=NO
YES=NO
for arg in "$@"; do
  case "$arg" in
    --prerelease) PRERELEASE=YES ;;
    --dry-run) DRY_RUN=YES ;;
    --yes) YES=YES ;;
    *) die "unknown option: $arg" ;;
  esac
done

# --- Checks -------------------------------------------------------------------------------------
printf '%s' "$TAG" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$' \
  || die "tag must look like v1.2.3 or v1.2.3-beta.1 (got '$TAG')"
VERSION="${TAG#v}"

command -v gh >/dev/null || die "GitHub CLI (gh) is not installed"
gh auth status >/dev/null 2>&1 || die "gh is not logged in (run: gh auth login)"

[ -z "$(git status --porcelain)" ] || die "uncommitted changes; a release must be built from a committed state"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
COMMIT="$(git rev-parse HEAD)"
git fetch --quiet --tags origin
git merge-base --is-ancestor "$COMMIT" "origin/$BRANCH" 2>/dev/null \
  || die "commit ${COMMIT%"${COMMIT#???????}"} is not pushed to origin/$BRANCH (push it first)"

git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && die "tag $TAG already exists locally"
git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1 && die "tag $TAG already exists on origin"

REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"

# --- Build --------------------------------------------------------------------------------------
BUILD_NUMBER="$(git rev-list --count HEAD)"
echo "Building BeadsDesktop $VERSION ($BUILD_NUMBER) from $BRANCH @ $(git rev-parse --short HEAD)…"
BEADS_VERSION="$VERSION" BEADS_BUILD_NUMBER="$BUILD_NUMBER" "$ROOT/scripts/build-release.sh" --dmg

DMG="dist/BeadsDesktop-$VERSION.dmg"
SUM="$DMG.sha256"
[ -f "$DMG" ] && [ -f "$SUM" ] || die "build did not produce $DMG"
SIGNER="$(codesign -dv --verbose=2 dist/BeadsDesktop.app 2>&1 | sed -n 's/^Authority=//p' | head -1)"
[ -n "$SIGNER" ] || SIGNER="ad-hoc (no identity: notifications won't be allowed)"

# --- Publish ------------------------------------------------------------------------------------
cat <<EOF

Release summary
  repository : $REPO
  tag        : $TAG → $COMMIT ($BRANCH)
  title      : BeadsDesktop $VERSION$( [ "$PRERELEASE" = YES ] && echo " (pre-release)" )
  assets     : $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' ')), $SUM
  signed by  : $SIGNER
EOF

if [ "$DRY_RUN" = YES ]; then
  echo "Dry run: nothing was published."
  exit 0
fi

if [ "$YES" != YES ]; then
  printf 'Publish this release to GitHub? [y/N] '
  read -r answer
  case "$answer" in y|Y|yes|YES) ;; *) echo "Cancelled."; exit 1 ;; esac
fi

set -- "$TAG" "$DMG" "$SUM" --repo "$REPO" --target "$COMMIT" --title "BeadsDesktop $VERSION" --generate-notes
[ "$PRERELEASE" = YES ] && set -- "$@" --prerelease
gh release create "$@"
git fetch --quiet --tags origin
echo "Published: $(gh release view "$TAG" --repo "$REPO" --json url --jq .url)"
