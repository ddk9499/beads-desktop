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
open BeadsDesktop.xcodeproj      # Run → "BeadsDesktop Debug" (the scheme uses Debug for every action)
```

**Production (Release) builds only by command:**

```sh
./scripts/build-release.sh            # → dist/BeadsDesktop.app
./scripts/build-release.sh --dmg      # … and the installer dist/BeadsDesktop-<version>.dmg (+ .sha256)
./scripts/build-release.sh --install  # … and copy to /Applications
BEADS_VERSION=0.2.0 BEADS_BUILD_NUMBER=12 ./scripts/build-release.sh --dmg   # set version/build number
```

A Release build started any other way (Xcode UI, plain `xcodebuild -configuration Release`) fails on purpose in the
"Guard Release builds" phase, so the production app is never launched by accident from Xcode.

## Releases

**GitHub Actions (main way, free for this public repo):** Actions → **Release** → Run workflow with a new tag such
as `v0.2.0` (or `gh workflow run release.yml -f tag=v0.2.0`). The workflow (`.github/workflows/release.yml`,
`macos-26` runner) checks the tag, imports your signing certificate into a temporary keychain, builds the DMG with
`scripts/build-release.sh --dmg` (version = tag without `v`, build number = run number, Team ID verified), creates
the tag on the built commit and a GitHub Release with `BeadsDesktop-<version>.dmg` and its `.sha256`, then deletes the
keychain. Repository secrets it needs:

| Secret | Value |
|---|---|
| `APPLE_CERT_P12_BASE64` | `base64 -i cert.p12` of the exported "Apple Development" certificate **with its private key** |
| `APPLE_CERT_PASSWORD` | the password chosen when exporting the `.p12` |
| `APPLE_TEAM_ID` | the certificate's Team ID |

Builds must be signed by the same team as the installed app, otherwise the in-app updater refuses them.

**Locally (fallback):**

```sh
scripts/release.sh v0.2.0 --dry-run     # checks + build, publishes nothing
scripts/release.sh v0.2.0               # build, show a summary, ask, then publish
```

It refuses to run with uncommitted changes, an unpushed commit, or an existing tag, and signs with
`Config/Signing.xcconfig`.

Without notarization (needs a paid Developer ID), macOS on another Mac asks to allow the app on first launch:
System Settings → Privacy & Security → "Open Anyway".

## In-app updates

The release app checks GitHub Releases of `ddk9499/beads-desktop` at launch (Settings → Updates; also
BeadsDesktop → Check for Updates…). If a release with a higher version (SemVer; pre-releases only when enabled) has
`BeadsDesktop-<version>.dmg`, it offers Install & Relaunch / Later / Skip This Version. Installing:

1. downloads the DMG in the background with progress (token: Keychain from Settings, else `gh auth token`; the token is
   sent only to api.github.com, never to the storage redirect);
2. verifies the SHA-256 from the release's `.sha256`, then the app inside: same bundle id, the release's version, valid
   code signature, and the same Team ID as the running app;
3. quits; a small script swaps the `.app` in place (restoring the old one if anything fails) and relaunches it.

The Debug app can check but never installs. End-to-end test without publishing anything: build an older release
(`BEADS_VERSION=0.0.9 scripts/build-release.sh`), copy `dist/BeadsDesktop.app` somewhere writable and run
`open --env BEADS_UPDATE_TEST_AUTOINSTALL=1 --stderr /tmp/upd.log <copy>` — it installs the newest release and logs each step.

## Keeping dolt up to date

The bundled dolt is pinned (version + sha256) in `scripts/fetch-dolt.sh`.

- **Automatically:** `.github/workflows/update-dolt.yml` runs every Monday (and via Actions → Update dolt → Run
  workflow). If the newest stable dolt release that is at least 7 days old is newer than the pinned one, it pins it,
  runs the tests and a Debug build on macOS, and opens a pull request `deps/dolt-<version>`. Merge it, then release.
- **By hand:** `scripts/update-dolt.sh 2.8.0` (downloads, records the sha256, fetches), then `swift test`.

## Debug and Release are separate apps

| Configuration | App | Bundle ID | Icon |
|---|---|---|---|
| Release | `BeadsDesktop.app` | `uz.dkamaloff.beads` | `Resources/Icon/AppIcon.icon` |
| Debug | `BeadsDesktop Debug.app` | `uz.dkamaloff.beads.debug` | `Resources/Icon/AppIcon-Debug.icon` (orange) |

Both can be installed and run at the same time on one Mac. Everything keyed by the bundle id is separate:
Application Support data (projects, snapshots), preferences, notification permission, saved windows, and the ssh
control-socket folder (`/tmp/beads-<tag>-<uid>`). Identity lives in `Config/Debug.xcconfig` / `Config/Release.xcconfig`
on top of the shared `Config/App.xcconfig`.

## Signing (needed for notifications)

Builds are ad-hoc signed by default. macOS doesn't list ad-hoc apps in System Settings → Notifications and denies them,
so for notifications sign with an Apple Development certificate (free Apple ID is enough):

1. Xcode → Settings → Accounts → add your Apple ID → Manage Certificates → **+ Apple Development**.
2. `cp Config/Signing.example.xcconfig Config/Signing.xcconfig` and put your Team ID there.
3. `xcodegen generate` and rebuild.

## CI

`.github/workflows/ci.yml` runs the BeadsKit tests and a Debug build on every pull request to `main` and every push to
`main`. "Tests and build" is a required status check for merging into `main`. Dolt-update PRs (opened by a bot, which
doesn't trigger workflows) start it themselves.

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
open "build/DerivedData/Build/Products/Debug/BeadsDesktop Debug.app" --args \
  -debugSelectProject gastownhall/beads -debugSelectIssue bd-7vb13 -debugPlainDetail YES \
  -debugSnapshot /tmp/shot.png -debugSnapshotDelay 8
```
Writes a PNG of the main window and quits; no screen-recording permission needed. Launch via
`open <app> --args …` (a directly started binary may get no window). In Graph mode (`-debugMode graph`)
`-debugGraphSnapshot <png>` also captures the web view.
