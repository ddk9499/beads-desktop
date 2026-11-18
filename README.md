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

Data from the remote is untrusted: tree entries are validated, SQL never interpolates unvalidated strings,
text is rendered as plain text. dolt metrics and version checks are disabled.
