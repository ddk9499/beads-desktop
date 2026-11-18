#!/bin/sh
# Xcode build phase: copy the pinned dolt binary into Contents/Helpers and sign it
# with the app's identity + hardened runtime (required for notarization).
set -eu
SRC="${SRCROOT}/Vendor/dolt/dolt"
if [ ! -x "$SRC" ]; then
  echo "error: $SRC missing. Run scripts/fetch-dolt.sh" >&2; exit 1
fi
DEST_DIR="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers"
mkdir -p "$DEST_DIR"
install -m 0755 "$SRC" "$DEST_DIR/dolt"
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:--}"
[ -z "$IDENTITY" ] && IDENTITY="-"
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$DEST_DIR/dolt"
