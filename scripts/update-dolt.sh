#!/bin/sh
# Pins a new dolt release: downloads dolt-darwin-arm64.tar.gz of the given version from GitHub, records its
# sha256 in scripts/fetch-dolt.sh and fetches it into Vendor/dolt/. Run the tests afterwards.
#
#   scripts/update-dolt.sh 2.8.0        (or v2.8.0)
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-}"
VERSION="${VERSION#v}"
printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "usage: scripts/update-dolt.sh <version, e.g. 2.8.0>" >&2; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/dolt.tar.gz" "https://github.com/dolthub/dolt/releases/download/v${VERSION}/dolt-darwin-arm64.tar.gz"
SHA="$(shasum -a 256 "$TMP/dolt.tar.gz" | cut -d' ' -f1)"

FILE="$ROOT/scripts/fetch-dolt.sh"
sed -i.bak -e "s/^DOLT_VERSION=\".*\"/DOLT_VERSION=\"$VERSION\"/" \
           -e "s/^DOLT_SHA256=\"[0-9a-f]*\"/DOLT_SHA256=\"$SHA\"/" "$FILE"
rm -f "$FILE.bak"
grep -q "^DOLT_VERSION=\"$VERSION\"" "$FILE" && grep -q "^DOLT_SHA256=\"$SHA\"" "$FILE" \
  || { echo "failed to update $FILE" >&2; exit 1; }

"$ROOT/scripts/fetch-dolt.sh"
echo "dolt pinned to $VERSION (sha256 $SHA)"
