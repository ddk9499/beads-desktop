#!/bin/sh
# Builds the production app (Release, uz.dkamaloff.beads) into dist/BeadsDesktop.app.
# The Xcode scheme only does Debug; Release builds are refused unless started from here.
#
#   scripts/build-release.sh            build into dist/
#   scripts/build-release.sh --install  build and copy to /Applications (quits a running copy first)
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

"$ROOT/scripts/fetch-dolt.sh" >/dev/null
xcodegen generate --quiet

DERIVED="$ROOT/build/release"
xcodebuild -project BeadsDesktop.xcodeproj -scheme BeadsDesktop -configuration Release \
  -derivedDataPath "$DERIVED" BEADS_RELEASE_BUILD=YES build -quiet

APP="$DERIVED/Build/Products/Release/BeadsDesktop.app"
codesign --verify --deep --strict "$APP"
mkdir -p "$ROOT/dist"
rm -rf "$ROOT/dist/BeadsDesktop.app"
ditto "$APP" "$ROOT/dist/BeadsDesktop.app"
echo "Built $ROOT/dist/BeadsDesktop.app ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist"))"

if [ "${1:-}" = "--install" ]; then
  osascript -e 'tell application id "uz.dkamaloff.beads" to quit' >/dev/null 2>&1 || true
  rm -rf "/Applications/BeadsDesktop.app"
  ditto "$ROOT/dist/BeadsDesktop.app" "/Applications/BeadsDesktop.app"
  echo "Installed /Applications/BeadsDesktop.app"
fi
