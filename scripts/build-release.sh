#!/bin/sh
# Builds the production app (Release, uz.dkamaloff.beads) into dist/BeadsDesktop.app.
# The Xcode scheme only does Debug; Release builds are refused unless started from here.
#
#   scripts/build-release.sh            build into dist/
#   scripts/build-release.sh --dmg      … and make the installer dist/BeadsDesktop-<version>.dmg (+ .sha256)
#   scripts/build-release.sh --install  … and copy to /Applications (quits a running copy first)
#
# Optional environment:
#   BEADS_VERSION       marketing version (CFBundleShortVersionString), e.g. 0.2.0
#   BEADS_BUILD_NUMBER  build number (CFBundleVersion), e.g. the CI run number
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DMG=NO
INSTALL=NO
for arg in "$@"; do
  case "$arg" in
    --dmg) DMG=YES ;;
    --install) INSTALL=YES ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

# Versions go into Info.plist: allow only plain version strings.
check() { printf '%s' "$2" | grep -Eq "$3" || { echo "invalid $1: $2" >&2; exit 2; }; }
SETTINGS="BEADS_RELEASE_BUILD=YES"
if [ -n "${BEADS_VERSION:-}" ]; then
  check BEADS_VERSION "$BEADS_VERSION" '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$'
  SETTINGS="$SETTINGS MARKETING_VERSION=$BEADS_VERSION"
fi
if [ -n "${BEADS_BUILD_NUMBER:-}" ]; then
  check BEADS_BUILD_NUMBER "$BEADS_BUILD_NUMBER" '^[0-9]+$'
  SETTINGS="$SETTINGS CURRENT_PROJECT_VERSION=$BEADS_BUILD_NUMBER"
fi

"$ROOT/scripts/fetch-dolt.sh" >/dev/null
xcodegen generate --quiet

DERIVED="$ROOT/build/release"
# shellcheck disable=SC2086 # SETTINGS is a list of validated KEY=VALUE words
xcodebuild -project BeadsDesktop.xcodeproj -scheme BeadsDesktop -configuration Release -destination "platform=macOS,arch=arm64" \
  -derivedDataPath "$DERIVED" $SETTINGS build -quiet

APP="$DERIVED/Build/Products/Release/BeadsDesktop.app"
codesign --verify --deep --strict "$APP"
mkdir -p "$ROOT/dist"
rm -rf "$ROOT/dist/BeadsDesktop.app"
ditto "$APP" "$ROOT/dist/BeadsDesktop.app"
PLIST="$ROOT/dist/BeadsDesktop.app/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
echo "Built dist/BeadsDesktop.app ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST") $VERSION ($BUILD))"

if [ "$DMG" = YES ]; then
  # Drag-to-install disk image: the app, a shortcut to /Applications, and the app icon as the volume icon.
  IMAGE="BeadsDesktop-$VERSION.dmg"
  STAGE="$(mktemp -d)"
  trap 'rm -rf "$STAGE"' EXIT
  ditto "$ROOT/dist/BeadsDesktop.app" "$STAGE/BeadsDesktop.app"
  ln -s /Applications "$STAGE/Applications"
  if [ -f "$STAGE/BeadsDesktop.app/Contents/Resources/AppIcon.icns" ]; then
    cp "$STAGE/BeadsDesktop.app/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"
  fi
  rm -f "$ROOT/dist/$IMAGE" "$ROOT/dist/$IMAGE.sha256"
  RW="$STAGE.rw.dmg"
  hdiutil create -quiet -volname "BeadsDesktop $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW"
  if [ -f "$STAGE/.VolumeIcon.icns" ]; then
    # Flag the volume as having a custom icon (needs the image mounted read-write).
    MOUNT="$(mktemp -d)"
    hdiutil attach -quiet -nobrowse -noautoopen -mountpoint "$MOUNT" "$RW"
    xcrun SetFile -a C "$MOUNT" || true
    hdiutil detach -quiet "$MOUNT"
    rmdir "$MOUNT" 2>/dev/null || true
  fi
  hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$ROOT/dist/$IMAGE"
  rm -f "$RW"
  hdiutil verify -quiet "$ROOT/dist/$IMAGE"
  (cd "$ROOT/dist" && shasum -a 256 "$IMAGE" > "$IMAGE.sha256")
  echo "Created dist/$IMAGE"
fi

if [ "$INSTALL" = YES ]; then
  osascript -e 'tell application id "uz.dkamaloff.beads" to quit' >/dev/null 2>&1 || true
  rm -rf "/Applications/BeadsDesktop.app"
  ditto "$ROOT/dist/BeadsDesktop.app" "/Applications/BeadsDesktop.app"
  echo "Installed /Applications/BeadsDesktop.app"
fi
