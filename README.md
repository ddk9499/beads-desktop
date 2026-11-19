# BeadsDesktop

Native macOS viewer for [beads](https://github.com/gastownhall/beads) issue trackers, working only from a git
remote URL over SSH — no local checkout of the project. Read-only for now (MVP).

- Bundle ID `uz.dkamaloff.beads`; display name set in `Config/App.xcconfig` (`APP_DISPLAY_NAME`).
- macOS 26+ (supported: 26 and 27 — the two latest majors), Apple Silicon.
- Design notes: `docs/spike-dolt-data-ref.md`, `docs/mvp-plan.md`.

## Build

Requires Xcode 26+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
./scripts/fetch-dolt.sh          # pinned dolt 2.7.5 → Vendor/dolt/dolt (checksum-verified, gitignored)
xcodegen generate                # BeadsDesktop.xcodeproj (generated, gitignored)
open BeadsDesktop.xcodeproj      # or: xcodebuild -scheme BeadsDesktop -derivedDataPath build/DerivedData build
```

## Signing (needed for notifications)

Builds are ad-hoc signed by default. macOS doesn't list ad-hoc apps in System Settings → Notifications and denies them,
so for notifications sign with an Apple Development certificate (free Apple ID is enough):

1. Xcode → Settings → Accounts → add your Apple ID → Manage Certificates → **+ Apple Development**.
2. `cp Config/Signing.example.xcconfig Config/Signing.xcconfig` and put your Team ID there.
3. `xcodegen generate` and rebuild.

## Tests

```sh
cd Packages/BeadsKit
swift test                                            # unit tests

# integration tests against real GitHub repos over SSH
BEADS_IT_DOLT=$PWD/../../Vendor/dolt/dolt \
BEADS_IT_SSH_KEY=~/.ssh/<key GitHub accepts> \
BEADS_IT_PRIVATE=git@github.com:<owner>/<private repo with beads data>.git \
BEADS_IT_OTHER_KEY=~/.ssh/<key GitHub does NOT accept> \
swift test
```

## How it works

1. `git ls-remote <repo> refs/dolt/data` (SSH, multiplexed) — cheap change check.
2. On change: `git fetch --depth=1` of that single ref into `Application Support/uz.dkamaloff.beads/projects/<id>/data.git`.
3. The ref's tree *is* a Dolt store: its files are laid out into `snapshots/<commit>/.dolt/noms/`.
4. The bundled `dolt sql -r json` reads beads tables (schema-adaptive; tested on schema 60–66).

Data from the remote is untrusted:
- tree entries are validated (plain files only, strict names, size/count limits, known manifest format);
- only base tables are read — if a beads table is replaced by a SQL VIEW (code dolt would run) the snapshot is refused;
- dolt runs under `sandbox-exec`: no network, writes only to the snapshot and its config root, no reads under `~`
  besides those; collected output is capped and runaway processes are killed (SIGTERM → SIGKILL);
- SQL never interpolates unvalidated strings;
- bead text is shown as inline markdown with http(s) links only (no HTML, images or other URL schemes);
- github.com host keys are pinned (the user's known_hosts is not consulted for it; the 2023 RSA key is revoked);
- dolt metrics and version checks are disabled.

`scripts/verify-graph-vendor.sh [--upstream]` checks the vendored graph libraries against their recorded sha256
(and against the npm packages).

## Debugging the UI from a script (Debug builds only)

```sh
build/DerivedData/Build/Products/Debug/BeadsDesktop.app/Contents/MacOS/BeadsDesktop \
  -debugSelectProject gastownhall/beads -debugSelectIssue bd-7vb13 -debugPlainDetail YES \
  -debugSnapshot /tmp/shot.png -debugSnapshotDelay 8
```
Writes a PNG of the main window and quits; no screen-recording permission needed. Launch via
`open <app> --args …` (a directly started binary may get no window). In Graph mode (`-debugMode graph`)
`-debugGraphSnapshot <png>` also captures the web view.
