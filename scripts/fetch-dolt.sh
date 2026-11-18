#!/bin/sh
# Downloads the pinned dolt release into Vendor/dolt/dolt and verifies its checksum.
set -eu
DOLT_VERSION="2.7.5"
DOLT_SHA256="b9d2bcd08f84b710c32ccfb3d87e5f91cddffccdc7c0f3b475ddbeacbb781416"  # dolt-darwin-arm64.tar.gz
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/Vendor/dolt"
if [ -x "$OUT/dolt" ] && "$OUT/dolt" version 2>/dev/null | grep -q "dolt version $DOLT_VERSION"; then
  echo "dolt $DOLT_VERSION already present"; exit 0
fi
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/dolt.tar.gz" "https://github.com/dolthub/dolt/releases/download/v${DOLT_VERSION}/dolt-darwin-arm64.tar.gz"
echo "$DOLT_SHA256  $TMP/dolt.tar.gz" | shasum -a 256 -c -
tar -xzf "$TMP/dolt.tar.gz" -C "$TMP"
mkdir -p "$OUT"
install -m 0755 "$TMP/dolt-darwin-arm64/bin/dolt" "$OUT/dolt"
cp "$TMP/dolt-darwin-arm64/LICENSES" "$OUT/LICENSES"
"$OUT/dolt" version
