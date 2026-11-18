# Spike: reading beads data from a GitHub URL (refs/dolt/data)

Date: 2026-11-18. Versions: beads (bd) v1.3.4, dolt v2.7.5, darwin arm64. All runs used an isolated `HOME`.
Test repos: public `gastownhall/beads`, private `ddk9499/beads-spike-tmp` (temporary).

## TL;DR

"GitHub URL only, no local checkout" works with stock tools. Read path can be even lighter than bd's own:
fetch one git ref (~3 MB, ~3 s), lay its files out as a Dolt store, query it. Writes work via `bd init --remote`,
but push is slow (13–18 s) and one auto-merge quirk can temporarily drop a comment.

## How the data is stored

- beads data lives in the separate ref `refs/dolt/data` on the project's git remote; source code is not needed.
  (`gastownhall/beads` has it; `brendan-appstart/bead-me-up-scotty` doesn't use beads itself.)
- One commit of that ref = a **self-contained Dolt (noms) store**: `manifest` + table files (`*.darc` and plain).
  The manifest (`5:__DOLT__:<lock>:<root>:<gcgen>:<table>:<chunks>:…`) lists exactly the files in the tree,
  so `git fetch --depth=1` is enough. 3.2 MB / 3.2 s for beads' own ~2.4k issues.
- dolt also creates `refs/heads/__dolt_remote_info__` (just a DOLT_REMOTE.md marker; visible in GitHub UI).
- `git ls-remote <url> refs/dolt/data` is a cheap "does this repo have beads data" check for the Add Project flow.

## Live results

| # | Check | Result |
|---|-------|--------|
| 1 | `bd init --remote git+https://github.com/gastownhall/beads.git` in empty dir | ✅ 6 s, 7.6 MB on disk, 2365 issues; `bd list --all --json` 0.5 s |
| 2 | Same against private repo, token supplied **only** via `GIT_ASKPASS` | ✅ 6 s; no token found in any written file |
| 3 | `bd dolt pull` with no remote changes | public 2.1–2.4 s, private ~3 s; with changes ~6.5 s. `git ls-remote` ~1.2 s |
| 4 | Copy `refs/dolt/data` tree into `<dir>/.dolt/noms/` + minimal `repo_state.json`, run `dolt sql` | ✅ works, query 0.07 s. Needs only a git fetch, no dolt git transport |
| 5 | Writes app → remote → agent and back, concurrent edits on both sides | ✅ converges. `bd dolt push` 13–18 s. Same-field conflict → last-write-wins with a Notice |

Minimal `repo_state.json` for #4: `{"head":"refs/heads/main","remotes":{},"backups":{},"branches":{}}`.

## How bd/dolt reach the remote (from source)

- Remote URL format: `git+https://github.com/OWNER/REPO.git` (or `git+ssh://`). `bd init --remote <url>` clones and
  stores it as `sync.remote`; `bd bootstrap` does the same when origin has `refs/dolt/data`.
- bd's `internal/remotecache` shells out to the **`dolt` CLI** (`dolt clone`, `dolt pull origin main`) → ship both binaries.
- dolt's git transport (`go/store/blobstore/internal/git/runner.go`) shells out to **system `git`** with the process env,
  so normal git auth applies. Keeps an incremental cache at `.dolt/git-remote-cache/<hash>/repo.git`.

## Gotchas found

- **Bundle size**: bd 144 MB + dolt 118 MB (arm64 only). Universal ≈ 2×. Read-only MVP could ship dolt only.
- **Credential helpers**: Apple CLT git has `credential.helper=osxkeychain` in system config; after getting the token
  from askpass it tries to *store* it in Keychain (hung in our run). Always run with
  `GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0= GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=<helper>`.
  Never put the token in the URL (it lands in dolt remote config).
- **Empty repo**: dolt refuses to push to a repo with no branches ("initialize the repository with an initial branch").
- **`bd init --remote` runs `git init` and commits** `.gitignore`/`.beads/*` in the target dir. Fine for a hidden app dir.
- **Push is slow (13–18 s)** → optimistic UI, background push from a single serial queue, visible sync state.
- ⚠️ **Comment temporarily lost after auto-merge.** Agent had local edits, pulled → auto-merge
  ("labels/comments/events (union)") left the incoming comment in the **working set, not in the merge commit**.
  Agent pushed the merge commit → the app pulled and **its own comment disappeared**. It reappeared only after the
  agent's next write (which committed the working set). Likely a beads bug; worth a minimal repro + upstream issue.
  App mitigation: serialize write → push → pull; after pull, verify own recently pushed changes are still present.

## SSH transport (follow-up run)

URL: `git+ssh://git@github.com/OWNER/REPO.git`. Key passed via
`GIT_SSH_COMMAND="ssh -o BatchMode=yes -o IdentitiesOnly=yes -i <key>"` — dolt's git runner inherits it. ✅ init/pull/push all work.

| Operation | HTTPS | SSH, no mux | SSH + ControlMaster |
|-----------|-------|-------------|---------------------|
| `git ls-remote refs/dolt/data` | ~1.2 s | ~2.4 s | **~0.86 s** (first 2.4 s) |
| `bd init --remote` | 6 s | 8.2 s | — |
| `bd dolt pull` (no changes) | ~3 s | ~5.6 s | **~2.4 s** |
| `bd dolt push` | 13–18 s | 23 s | **~11.8 s** |

Mux options: `-o ControlMaster=auto -o ControlPath=<short dir>/%C -o ControlPersist=120`.

SSH gotchas:
- **Multiple GitHub accounts per machine.** Default `github.com` host here authenticates as a *different* account
  than the repo owner → "Repository not found". The app must let the user pick an SSH key per project
  (or per GitHub account) and pass it explicitly with `IdentitiesOnly=yes`; don't rely on `~/.ssh/config` defaults.
- **ControlPath length limit (104 bytes for Unix sockets).** `<long app support path>/%C` fails with
  "unix_listener: path … too long". Use a short dir (e.g. `/tmp/<app>-<uid>/` with 0700, or `~/.ssh/cm/`).
- `BatchMode=yes` is mandatory: a passphrase-protected key not in the agent must fail fast, not hang. Surface as
  "key not loaded — run `ssh-add --apple-use-keychain <key>`".
- No GitHub REST API without a token → change detection is `git ls-remote` over the mux'd connection (~0.9 s/repo).
- App Sandbox can't read `~/.ssh` / the agent socket → distribute via Developer ID + notarization, not the Mac App Store.

## Recommended architecture

- **Read (MVP — tracking)**: poll GitHub API `GET /repos/{o}/{r}/git/ref/dolt/data` with ETag (304s don't count
  against the rate limit) → on SHA change: `git fetch --depth=1` that ref into a per-project bare repo
  (or download blobs via the API) → lay files into `.dolt/noms/` → query via `dolt sql -r json`
  (or run `bd … --json` on top — not yet verified on a hand-laid store). Token stays in our Keychain item only.
- **Write (later)**: separate per-project workspace via `bd init --remote`, writes through `bd`, background push
  from a single queue.

## Open questions

- Does `bd` (not just `dolt`) open the hand-laid store from #4 without `bd init`? Would let the read path reuse bd's JSON shapes.
- Read-only path: raw SQL against beads' schema couples us to schema versions (`schema_migrations` table) — pin & check.
- GitHub fine-grained token scopes needed: read = Contents:read; write = Contents:write.
