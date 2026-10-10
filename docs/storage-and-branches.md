# Storage and branches

Where every artifact lives, who is allowed to write it, and how to get it back.
The governing rule: **`main` is pure code.** Anything machine-regenerated and
single-writer lives on another branch, so `main`'s history stays human.

## Branch map

| Branch | Contents | Sole writer(s) | Readers |
|---|---|---|---|
| `main` | engine, workflows, scripts, `module/`, `bin/`, `docs/`, `CONFIG.md` | maintainer, via PRs | every CI job (checked out first) |
| `data` | `configs/` (human TOMLs + generated pool JSON), `state/` (watcher JSONs) | `commit_data_branch.sh` (CI, `*.json` — run by the watcher, and by the build job for `build_content_hashes.json` after a successful upload), `push_data_configs.sh` (maintainer, `*.toml`) | watcher + build jobs through `fetch_data_branch.sh` |
| `website` | `manifests/<tag>.json`, `archive/{stable,beta}.json` | `merge_archive_branch.sh`; pruned by `cleanup_website_branch.sh` | the site's `rebuild_catalog.py` |
| `update` | `changelogs/<code>.md`, `<channel>/<module-id>.json` | `build_update_changelog.sh`; pruned by `cleanup_update_branch.sh` | KernelSU / Magisk module updaters on phones |
| `notify-queue` | `queue.jsonl` (pending debounced issue/PR alerts) | `notify_enqueue.sh` (append) + `notify_drain.sh` (prune), both via `notify_queue.sh` | the drain job only |

GitHub Releases are storage too, and they are **not** mirrors of branches:
releases hold files, branches hold the metadata that describes the files.

Each non-code branch carries its own `README.md` at its tip, written for whoever
lands on it (`git show origin/data:README.md`, `origin/website:README.md`,
`origin/update:README.md`). Those files are the per-branch contracts and the
sections below link back to them; keep the two in step when a path changes, and
treat the branch copy as the one a contributor reading the branch will see first.

## `data`

```
configs/
  config.manual.toml          hand-built config for Manual CI
  patches/<author>.toml       one file per patch source family (the real config)
  stable_build.json           generated: the stable pool for the next build
  beta_build.json             generated: the beta pool
state/
  patch_sources.json          per source: host, repo, stable tag+date, beta tag+date, blocked
  app_versions.json           app: {keys: […], version}; "_check_only_listed": true
  patch_file_hashes.json      source → channel → package → bundle content hash
  build_content_hashes.json   channel → built-artifact key → content md5 (duplicate-build
                              check; written by the build job after a successful upload)
```

- Both directories are ignored on `main` ([.gitignore](../.gitignore)) and exist
  locally only as materialisations. Never `git add` them.
- **`fetch_data_branch.sh` overwrites local `configs/` and `state/`.** Publish
  hand-edited TOMLs *before* fetching, or lose them:
  `bash .github/scripts/push_data_configs.sh "<message>"` — plumbing temp-index
  commit of `configs/**/*.toml` only, using your git identity.
- Writer boundaries are enforced by glob, not convention: the CI committer commits
  only `*.json` directly under those two directories, so it can never sweep a
  half-edited TOML into history — and equally, it cannot delete one. A *renamed*
  TOML must therefore be removed on `data` explicitly, or the old name lingers.
- `state/` is regenerable: the watcher rebuilds it from the forges. `configs/`
  TOMLs are the sole copy of human intent — they are the thing worth backing up.
- Recovery: `temp/seed_data_branch.sh` reseeds the branch from a maintainer clone's
  working copies. All jobs hard-fail when `data` is missing rather than falling
  back to empty state.
- `git switch data` for an occasional hand-edit is legitimate, but the ignored
  local copies get clobbered on switch — re-run `fetch_data_branch.sh` afterwards.

## `website`

Per-build manifests plus two cumulative archives. This branch replaced release
assets as the manifest store on **2026-09-25**: numbered releases no longer carry
a `build.json`, so branch history is the only metadata history. The move and the
failure it eliminated are recorded in
[decisions/0002](decisions/0002-manifests-live-on-a-branch.md).

Schema v1 envelope (produced by `build_make_manifest.py`):

```json
{
  "schema": 1,
  "kind": "build" | "archive",
  "meta": { "build": "<tag>", "channel": "stable" | "beta", "publishedAt": "<iso>" },
  "files": { "<exact asset filename>": { … per-file entry … } }
}
```

Per-file entry keys: `name` (file prefix), `version`, `appKey`, `appName`, `arch`
(normalised: `arm64`, `arm`, `all`, `universal`, `x86_64`, `x86`), `fileType`
(`APK` | `Module`), `brandKey`, `brandName`, `variant`, `subVariant`,
`packageName`, `patchSources[]`, `changelogs[]`, `appliedPatches[]`,
`originBuild` (the numbered tag the file came from — carried along when an entry
is merged into an archive, which is how the site still links an archived file to
its build), `publishedAt`.

The `<arch>` token in an asset filename is frozen grammar (parse it only through
`.github/scripts/naming.py`). A manifest records exactly the arches a build
produced, so an app may legitimately list one arch rather than both — the requested
arch is a hard requirement and an absent channel is unbuilt, never a mislabeled
file ([decisions/0007](decisions/0007-requested-arch-is-a-hard-requirement.md)).

An archive envelope restamps `meta` as `{build: <channel>, channel: <channel>,
publishedAt: <merge time>}` while keeping the surviving file entries.

Merge semantics for `archive/<channel>.json` (`merge_archive_branch.sh`):

1. Fetch and check out `website`; copy the current cumulative file. A fetch
   failure **fails the job** — there is deliberately no "start from empty" path,
   which is what eliminated the 2026-09-24 collapse where a failed asset download
   silently restarted the cumulative manifest.
2. Union old + new — **new entries win on a filename collision** — then drop every
   entry whose file no longer exists on the archive release (live filter, read from
   the Releases API). Existence is the releases' business; history is the branch's.
3. Sanity gate: recompute `|union(old,new) ∩ live|` and refuse to push if the
   result kept fewer entries than that.
4. Push with retries, rebasing over concurrent updates (the `build` concurrency
   group is what makes "concurrent" rare).

Recovery order for a damaged `archive/*.json`: **branch history first**
(`git log -p archive/stable.json`, `git show <rev>:archive/stable.json`, force-push
to undo), then `repair_archive_manifest.py` (dry-run by default), and only while
legacy release assets still exist does `seed_website_branch.py` make sense.

## `update`

Wire format baked into shipped software. A module zip's `module.prop` carries
`updateJson=https://raw.githubusercontent.com/<owner>/<repo>/update/<channel>/<module-id>.json`
— the branch must mirror that path exactly, and `update_json_path()` in
[scripts/utils.sh](../scripts/utils.sh) is the single derivation:

```
module id  <table>-<author>[-beta][-arm64|-arm]     (build.sh composes it)
pointer    <channel>/<id-without-author-or-channel>.json   → stable/youtube.json
                                                      → beta/youtube-arm64.json
changelog  changelogs/<build-code>.md
```

Pointer content: `{ "version", "versionCode", "zipUrl", "changelog" }` — `zipUrl`
points at the **archive** release (`releases/download/<channel>/<file>`), so a
pruned archive asset means a pointer that no longer resolves; that coupling is why
the archive upload precedes the merge step.

Consumers are the KernelSU and Magisk app updaters only. LSPatch is a patching
backend, not an updater — its APKs come from releases/Obtainium and never poll
this branch. **Never "tidy" this layout:** every installed module carries the old
URL and would 404, which is a forced re-flash for the user.

## `notify-queue`

A transient working branch, not product data: one append-only `queue.jsonl` holding
issue/PR alerts that have not been delivered yet, so a burst of events coalesces
into one debounced Telegram message (see
[ci-pipelines.md](ci-pipelines.md#notify-notifyyml)). The branch is created by the
first `notify_enqueue.sh` append (a root commit off the empty tree), grows via
push-retry under concurrent runs, and is emptied by `notify_drain.sh` once the
batch posts — pruning exactly the prefix it sent, so an event that landed mid-send
waits for the next drain rather than being dropped. Every write pins
`core.autocrlf=false`/`core.eol=lf`: the file is byte-exact JSONL and the drain's
prune matches whole lines, so a runner's git config must not be able to inject
CRLF. Nothing reads it except the drain.

## GitHub Releases

| | Numbered | Archive |
|---|---|---|
| Tags | `260141`, `260140`, … (`YY` + sequence) | `stable`, `beta` |
| Lifetime | append-only; newest 98 survive cleanup | permanent (`releases_keep_keyword`) |
| Contents | this build's APKs + module zips | cumulative, pruned to 2 versions per app+arch |
| Title/body | generated per build | **owner-written**; CI names no metadata |
| Pre-release flag | `--prerelease` on beta runs | set once by hand (`beta` only) |
| `build.json` | no (moved to the `website` branch) | no |

Asset filename grammar — the contract every consumer parses:

```
<file-prefix>-v<version>-<arch>.apk                  youtube-morphe-v19.16.39-arm64-v8a.apk
<file-prefix>-module-v<version>-<arch>.zip           youtube-morphe-module-v19.16.39-arm64-v8a.zip
```

`file-prefix` is everything before the first `-v<digit>` or `-module-`
(`naming.py:file_prefix`). Arch spelling is normalised for matching
(`armeabi-v7a` ≡ `arm-v7a`, `all` ≡ `universal`) because the engines of different
patchers write different tokens. Filename-derived arch is a *fallback*: the
manifest's recorded arch is authoritative, and the derivation itself lives in
`naming.py` alone — the website imports that module rather than copying it
([website-contract.md](website-contract.md)).

### Withdrawing a bad build

Numbered releases are append-only for consumers, not for the maintainer: a build
whose artifacts are broken can be pulled, but the order matters, because the site
resolves download links from the Releases API and reads existence from the
manifests. What happened to build 260210 (patched with no BouncyCastle provider, so
NPatch died after it had embedded the stock APK: two signature-less stubs, reported
as a green build) is the reference case:

1. Delete the offending assets from the **archive** release first
   (`gh api -X DELETE repos/<owner>/<repo>/releases/assets/<id>`). Releases are the
   existence truth for `merge_archive_branch.sh`, so a later merge prunes the
   archive manifest on its own.
2. Delete the numbered release with its tag: `gh release delete <tag> --cleanup-tag`.
3. Fix the `website` metadata that named them: remove `manifests/<tag>.json`, and
   re-run the merge's own existence filter over `archive/<channel>.json` instead of
   hand-deleting keys, so the result is what CI would have written. Leave
   `meta.publishedAt` alone — restamping is the merge's job, not a hand fix's.
4. Confirm nothing on `update` still points at a withdrawn file. Only module builds
   write pointers, but an archived `zipUrl` that no longer resolves is a silent
   failure for every phone holding that module version.

Deleting the **highest** tag also frees that version code: `build_resolve_version.sh`
counts above the highest existing tag, so the next build reuses the number (260210
was withdrawn and recreated the same afternoon). A version code is therefore not a
stable unique identifier across a withdrawal — the site keys on filenames and
manifests, so those are what must be cleaned, not the tag alone.

## `nullcpy/apks` (shared download cache)

A **separate repository**, not a branch: one release per Android package name,
holding the stock APKs and bundles the engine has already fetched, named
`<pkg>-<version>[-<versionCode>]-<arch>.<ext>`. It is download source #1 and is
never consulted for version listing, so it cannot become a rival source of truth
about upstream releases. The engine writes back anything it fetched freshly (never
a copy that came from the cache itself or from `archive`), and
`update_usage_tracker.py` stamps the versions a run consumed into the repo's
`usage.json`, which is what its monthly retention pass keys on.

This repo's Actions cache (`temp/apks`) is a fast local copy of the same
population; both are caches, neither is authoritative. Layout, read/write rules,
retention policy and debugging: [cache-repo.md](cache-repo.md).

## `temp/` (gitignored, but load-bearing locally)

Scratch space for downloads, prebuilts, per-job logs and manifests — plus the
project's habit of keeping **prototype regression harnesses** here
(`test_*.sh`, `_mp/`, `_ver/`, `_metastop/`, …). They are not tracked, so the
references to them in docs and in `.github/scripts/README.md` are pointers to a
maintainer's disk, not to CI. Anything the pipeline must run forever belongs in
`.github/traces/` instead.

## Line endings

[.gitattributes](../.gitattributes) forces LF for `*.sh`, `*.py`, `*.yml`,
`*.json`, `*.toml` and `*.trace` — Windows checkouts with `core.autocrlf=true`
would otherwise inject CRLF, breaking Linux execution and byte-comparing trace
goldens. The engine also normalises `utils.sh` defensively (`dos2unix`) before
sourcing it in CI.
