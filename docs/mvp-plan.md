# MVP: BeadsDesktop (macOS, read-only, SSH)

Based on: `docs/spike-dolt-data-ref.md`. Date: 2026-11-18.

## Goal

A native macOS app: I add a GitHub repo over SSH, and I see that repo's beads issues
(board, epics, details, dependency graph), updated in near real time. No local copy of the project, no writing.

**Not in the MVP:** writing (create/edit/drag-and-drop), HTTPS/OAuth, other people's servers/`bd serve`,
Mac App Store, Intel/universal build, auto-update.

## Identity and platforms

- **Name:** BeadsDesktop, **renameable**. The display name lives in one place (`APP_DISPLAY_NAME` in an xcconfig →
  `CFBundleDisplayName`/`PRODUCT_NAME`); no code or path depends on it.
- **Bundle ID:** `uz.dkamaloff.beads` (doesn't contain the name, so a rename doesn't touch it).
- **Data, settings, Keychain, sockets, logs** are keyed by bundle id, not the name:
  `Application Support/uz.dkamaloff.beads/`, standard `UserDefaults`, os.Logger subsystem `uz.dkamaloff.beads`.
- **macOS:** only the two latest major versions → deployment target = the previous major (**macOS 26** — supported range 26–27);
  bump it once a year after each new macOS release. arm64 only.
- **Toolchain:** needs full Xcode (this machine has only Command Line Tools) for the .app target, signing, notarization.

## Key decisions

| Question | Decision | Why |
|---|---|---|
| UI | SwiftUI; graph in WKWebView (React Flow) | user's decision; graph is the most expensive part in pure SwiftUI |
| Transport | `git` over SSH, key explicit per project, `BatchMode`, ControlMaster | spike: SSH+mux is faster than HTTPS, no tokens |
| Getting data | `git fetch --depth=1 <url> refs/dolt/data` into a bare repo → lay out the tree into `.dolt/noms/` | spike #4: 3 MB / 3 s, dolt git-transport and `bd` not needed |
| Reading | bundled `dolt` (arm64), `dolt sql -r json -q …` | 0.07 s per query; one binary of 118 MB instead of 262 MB |
| Change detection | `git ls-remote <url> refs/dolt/data` every 30 s + on window focus + ⌘R | ~0.9 s with mux; fetch only when SHA changed |
| Schema | read `schema_migrations.version`; supported range is in the code; outside it → "beads version not supported" banner, best-effort reading | SQL against the beads schema is coupling, we need to detect drift |
| Distribution | Developer ID + notarization, GitHub Releases | sandbox doesn't allow `~/.ssh` and the agent socket |

## Architecture

```
App (SwiftUI)
├─ ProjectsStore        — list of projects (JSON in Application Support): url, ssh key path, name, last SHA
├─ SyncService (actor)  — per project: ls-remote → fetch → materialize → notifies the UI
│   ├─ GitRunner        — Process(/usr/bin/git), env: GIT_SSH_COMMAND, GIT_CONFIG_NOSYSTEM=1, GIT_TERMINAL_PROMPT=0
│   └─ SSHMux           — ControlPath in a short dir (/tmp/beads-<uid>/, 0700), ControlPersist=300
├─ Snapshot             — read-only Dolt store for a specific SHA: snapshots/<sha>/.dolt/
├─ BeadsReader          — dolt sql -r json → Codable models; version check
└─ Views                — Sidebar(projects) · Board · Epics · Focus · Detail · Graph(WKWebView)
```

**On-disk layout:** `~/Library/Application Support/uz.dkamaloff.beads/projects/<uuid>/`
- `data.git/` — bare repo, the only remote ref is `refs/dolt/data`
- `snapshots/<sha>/.dolt/{noms/*, repo_state.json}` — written to `tmp-<sha>` and then `rename` (atomic);
  the current one is a `current` symlink; old ones are removed after switching.

**Sync cycle (one project):**
1. `ls-remote` → SHA. Same as `lastSHA` → done.
2. `fetch --depth=1 … refs/dolt/data:refs/dolt/data` into `data.git`.
3. `git ls-tree` + `git cat-file --batch` → files into `snapshots/tmp-<sha>/.dolt/noms/`, + minimal `repo_state.json`.
4. Check `schema_migrations` → swap `current` → reload the models → diff against the previous ones (for notifications).
Projects sync in parallel, but no more than 3 at a time; inside a project it's serial.

## Data model (beads tables → UI)

- `issues` (+ `custom_statuses(name, category)` for statuses outside the base set like `hooked`, `resolved`).
  `deleted_at IS NULL`, `ephemeral = 0`, `is_template = 0`.
- `ready_issues`, `blocked_issues` — ready-made beads views, used for the board columns.
- `dependencies(issue_id, depends_on_issue_id, type)` — graph; `type='parent-child'` → epic → children.
- `labels`, `comments`, `issue_counter` (prefix).

Board columns (like Scotty): Backlog (`deferred`) · Ready (`ready_issues`) · In Progress · Blocked (`blocked_issues`) · Done (`closed` + custom statuses with category done).
Need to check with Scotty (`lib/bd.ts`, `lib/schema.ts`) that the mapping matches `bd ready/blocked`.

## Screens

1. **Add project**: field `git@github.com:owner/repo.git` (we accept https URLs too and convert them to ssh),
   key picker (list of `~/.ssh/*` that have a `.pub`, default `IdentityFile` from config for github.com),
   a "Check" button → `ssh -T` (shows *which GitHub account* the key logs in as) + `ls-remote` for `refs/dolt/data`.
   Errors spelled out in human terms: no access / no beads data / key not in agent / host key.
2. **Board**: 5 columns, filters (type, priority, assignee, label), search, 👤/🤖 by allowlist.
3. **Epics**: list with progress (closed/total children).
4. **Focus**: In flight · Blocked · Next up, grouped by assignee.
5. **Detail** (inspector on the right): fields, markdown description, labels, dependencies (clickable), comments.
6. **Graph**: WKWebView + bundled React Flow bundle; data via `postMessage`, node click → Detail.
7. **Status bar of the window**: last sync time, SHA, error. Menu: ⌘R refresh.

Nice-to-have if there's time: menu bar extra with the Ready/Blocked counters; notifications "closed / unblocked".

## Milestones

| # | What | Done when |
|---|---|---|
| M0 | Xcode project, `dolt` in Resources (+ codesign of the nested binary), CLT git check | the app starts, `dolt version` from the bundle |
| M1 | SyncService + Snapshot + BeadsReader without UI (unit/integration tests on `gastownhall/beads` and `beads-spike-tmp`) | test: URL → list of issues; repeat without changes = only ls-remote |
| M2 | Add project + Sidebar + Board + Detail | I see `beads-spike-tmp` and `gastownhall/beads` on the board |
| M3 | Epics + Focus + filters/search | parity with Scotty for reading |
| M4 | Polling, focus refresh, error states, changes in the UI without flicker | the agent pushes → the card moves within ≤ 45 s |
| M5 | Graph in WKWebView | the dependency graph for an epic |
| M6 | Developer ID signing, notarization, DMG/zip in GitHub Releases | it installs on a clean Mac without warnings |

## Risks and open questions

- **Schema drift in beads** (64 migrations already) — the version check + reader tests on a fixture of the real store.
  Alternative: once `bd` opens the hand-laid snapshot (spike open question) → `bd … --json` instead of SQL, but +144 MB.
- **dolt in the bundle**: nested binary signing/notarization, hardened runtime; check that `dolt sql` doesn't try
  to write into the read-only snapshot (lock files) — maybe needs a writable snapshot copy.
- **Concurrent dolt invocations** on the same snapshot — serialize reads per project or keep one `dolt sql-server` (later).
- **Git without CLT**: `/usr/bin/git` is a shim that offers to install Xcode CLT. Need a check and a clear screen.
- **Data from GitHub = untrusted**: don't render description/comments as HTML; markdown → AttributedString without raw HTML;
  in the graph WebView — `textContent` only, CSP without network.
- **Comment loss after merge** (see spike) — in read-only it's visible as "the comment disappeared"; we don't fix it,
  but a minimal repro + issue upstream.

## Status (2026-11-18)

**M0 ✅, M1 ✅.** Code: `project.yml`, `Config/App.xcconfig`, `App/`, `Packages/BeadsKit/`.
- App builds clean (Xcode 26.6), bundle 114 MB, dolt embedded in `Contents/Helpers` with hardened runtime.
- Verified headless: two projects (private `ddk9499/beads-spike-tmp`, public `gastownhall/beads`) synced on launch.
- Tests: 20 (unit + integration over SSH). First sync of beads ~3 s, no-change sync ~0.86 s.

Found while building M1 (all fixed):
- **Schema drift is real now:** repos made by bd 1.3.4 are schema 66, which dropped `issues.deleted_at`; beads' own repo
  is schema 64. The reader discovers columns/tables first and builds its queries from what exists.
- **ssh offers keys from `~/.ssh/config` in addition to `-i`:** a key that GitHub rejects would silently fall back to the
  config's key = a different account. With an explicit key we pass `-F /dev/null` + `IdentitiesOnly=yes`
  (agent stays enabled for passphrase keys).
- **`%C` in ControlPath doesn't include the key:** two projects with different keys would share one master connection.
  ControlPath is now `<dir>/<key tag>-%C`.
- **`UserKnownHostsFile` splits on spaces** ("Application Support"): paths are double-quoted.
- **dolt phones home:** usage metrics and a GitHub version check. Both disabled via `DOLT_ROOT_PATH` config +
  `DOLT_DISABLE_VERSION_CHECKS`.
- dolt needs a writable `noms/` (LOCK file) even for reads; parallel reads of one snapshot are fine.

**M2 ✅** (2026-11-18):
- Board: Backlog · Ready · In Progress · Blocked · Done, same placement rules as Scotty (`lib/board-columns.ts`):
  blocked = status `blocked` or open with an unclosed `blocks`/`conditional-blocks`/`waits-for` target (missing target
  counts as open; `parent-child` is hierarchy, not a blocker); `hooked` → In Progress; custom statuses by beads
  category (active→Ready, wip→In Progress, done→Done, frozen→Backlog). Empty Blocked column hidden; Done limited to
  closed within 7/14/30 days or all. Sort: priority or recently updated.
- Cards: type icon, id, 👤/🤖 (allowlist in Settings), priority, title, parent epic, epic progress, "Blocked by …",
  labels, assignee.
- Detail inspector: fields, epic/children with progress, Blocked by / Blocks / Related (clickable), description/design/
  acceptance/notes and comments as safe inline markdown (http(s) links only).
- List view (sortable table) as an alternative to the board.
- Add Project: live address parsing, key picker, "Check access" (which account the key signs in as + whether
  `refs/dolt/data` exists).
- A failed refresh keeps the last snapshot on screen with a banner.
- Debug-only launch flags for UI checks: `-debugSelectProject owner/repo -debugSelectIssue <id> -debugPlainDetail YES
  -debugSnapshot <png>` (window snapshots can't render the Liquid Glass inspector, hence the plain-detail mode).

**M3 ✅** (2026-11-18):
- Views: Board ⌘1 · List ⌘2 · Epics ⌘3 · Focus ⌘4.
- Filters (Scotty's `lib/filters.ts` semantics): status, type, priority, origin, assignee (incl. Unassigned), label;
  OR within a facet, AND across; `archived` hidden by default. Search over id/title/assignee/labels. Active filters
  shown as removable chips. Applies to all views.
- Focus: In flight (in_progress/hooked) · Blocked · Next up (open P0/P1, not blocked) · optional Recently finished
  (last 7 closed); optional grouping by assignee (active people first).
- Epics: open before closed, then priority; progress = closed ÷ children; expandable children; hide closed.
- Note: window snapshots (`-debugSnapshot`) render the Epics view blank (cause unknown; the live view works).

Next: M4 (polling + notifications of changes), M5 (graph), M6 (signing/notarization/release).
Known gap: snapshot cleanup can race a detail read of the previous snapshot (rare; retry on failure in M4).
