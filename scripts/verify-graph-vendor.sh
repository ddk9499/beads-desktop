#!/bin/sh
# Verifies the vendored graph libraries against Resources/Graph/vendor/SHA256SUMS.
# With --upstream, also downloads the pinned npm packages and checks the files are byte-identical.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT/Resources/Graph/vendor"
CYTOSCAPE="3.34.4"
CYTOSCAPE_DAGRE="4.0.1"

(cd "$VENDOR" && shasum -a 256 -c SHA256SUMS)

if [ "${1:-}" = "--upstream" ]; then
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  (cd "$TMP" && npm pack --silent "cytoscape@$CYTOSCAPE" "cytoscape-dagre@$CYTOSCAPE_DAGRE" >/dev/null)
  mkdir -p "$TMP/a" "$TMP/b"
  tar -xzf "$TMP/cytoscape-$CYTOSCAPE.tgz" -C "$TMP/a"
  tar -xzf "$TMP/cytoscape-dagre-$CYTOSCAPE_DAGRE.tgz" -C "$TMP/b"
  cmp "$TMP/a/package/dist/cytoscape.min.js" "$VENDOR/cytoscape.min.js"
  cmp "$TMP/b/package/dist/cytoscape-dagre.min.js" "$VENDOR/cytoscape-dagre.min.js"
  echo "upstream npm packages match"
fi
