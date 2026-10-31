# Release manifest scripts (`build.json`)

Every build produces a `build.json` manifest — a schema-v1, filename-keyed
description of the APKs/ZIPs in that build (app name, version, arch, applied
patches, `originBuild`, ...). Manifests live in exactly one shared place:
the **`website` branch** of this repo — a per-build copy plus the cumulative
archive manifests that the website catalog rebuild consumes. Release pages
carry only the files themselves. These scripts implement and repair that
pipeline.

```
builder (utils.sh)                build.yml
      │                                │
      ▼                                ▼
 build.json ──► build_make_manifest.py ──► temp/manifest/build.json
                        │                          │
                        ▼                          ▼ (after archive upload)
            temp/manifest/*.json        merge_archive_branch.sh
            (not uploaded anymore)       │ commits manifests/<tag>.json
                                         │ + merges archive/<channel>.json
                                         ▼   (union, live-filter, push)
                        website branch: archive/{stable,beta}.json
```

## Per-build pipeline (runs in CI)

### `build_make_manifest.py`
Converts the builder's raw `build.json` into the unified filename-keyed
manifest (`temp/manifest/build.json`) that everything downstream consumes.
Env: `NEXT_VER_CODE` (release tag), `IS_PRERELEASE` (→ channel `beta`/`stable`).

### `build_upload_release.sh`
Unified uploader (native `gh`, per-file retry, `--clobber`). Used for the
numbered release (build outputs) and the archive releases. Note: `gh` names
an uploaded asset after the **local file's basename** — always stage files
under their intended asset name.

Metadata obeys one rule: **a field the caller did not name is not written.**
`RELEASE_TITLE`, `RELEASE_BODY_FILE`, `RELEASE_NOTES` and the tri-state
`IS_PRERELEASE` all mean "leave it be" when unset; whatever is named goes out in a
single `gh release edit`, and when nothing is named there is no call at all. CI's
archive step names none, which makes it a pure asset uploader, while the numbered
step names title, body and channel. `--clobber` stays unconditional on assets.
Per-variable semantics are in the script header; the rationale, the zero-byte
`build.md` case and the rejected alternatives are in
[docs/decisions/0001](../../docs/decisions/0001-release-metadata-ownership.md).

Regression test: `temp/_metastop/test_metadata_write.sh` (stubbed `gh`; walks
exists/create x title x notes-source x prerelease-state, asserts which flags
reach `release edit`/`create`, that CI's archive shape makes no metadata call at
all even with `RELEASE_TARGET` set, that an empty body file counts as unnamed,
and that a bogus `IS_PRERELEASE` is rejected without touching `gh`; Git Bash).

### `merge_archive_branch.sh`
Merges the current build's manifest into the `website` branch: writes
`manifests/<tag>.json` and updates the cumulative `archive/<channel>.json`
(union, live-filter against the release's APK/ZIP assets, sanity gate) and
pushes. Run **after** the archive file upload so the live-asset filter sees the
new files. Env: `ARCHIVE_TAG` (`stable`|`beta`), `BUILD_TAG` (this release's
tag), `GITHUB_REPOSITORY`.

The branch design removes the 2026-09-24 incident class by construction: the
previous cumulative manifest is a checked-out file, not a `gh release
download` that can fail into an empty base — a broken `git fetch` fails the
job loudly instead. Remaining guards: the sanity gate recomputes the expected
minimum (`|union(old, new) ∩ live assets|`) and refuses to push a merge that
kept fewer entries; push retries rebase against concurrent branch updates.

Regression tests: `temp/test_merge_archive_branch.sh` (stubbed `gh`, local
bare `origin`; run from Git Bash — `temp/` is gitignored, keep a copy
alongside the other local tests).

### `push_archive_manifest.sh`
Cross-repo companion to `merge_archive_branch.sh`: publishes THIS build's
`temp/manifest/build.json` to the **permanent mirror repo** (`nullcpy/archive`) at
`manifests/<tag>.json` on its `website` branch, via the Contents API with
`ARCHIVE_REPO_TOKEN` (`gh api`). Numbered-only — the mirror has no rolling
stable/beta, so there is no cumulative `archive/<channel>.json` and no live-existence
filter here; `build_archive_pages.py` below folds the per-build manifests into the
browsable pages. It creates the
`website` branch from the repo default when absent and updates the blob in place by
sha on a rerun, so a retried build is idempotent. The base64 payload goes as a
request body via `--input`, never `-f content=<b64>`: Linux caps one argument at
128 KiB and a full-pool manifest exceeds that once encoded. Gated on the archive
mirror upload landing and **fail-soft**: a rejected push warns and exits 0, never
reddening a run whose files shipped. rvb's own `website` branch is untouched. Env:
`ARCHIVE_REPO`, `BUILD_TAG`, `GH_TOKEN`. Output: `PUBLISHED=true` on
`$GITHUB_OUTPUT`, written only after the PUT returns, which is what gates the page
rebuild. Regression test: `.github/traces/test_archive_mirror.sh`
block (c) (stubbed `gh api`; absent / present / oversized / fail modes).
Why the mirror exists: [decisions/0015](../../docs/decisions/0015-builds-are-mirrored-to-a-permanent-archive-repo.md).

### `build_archive_pages.py`
Renders the archive repo's browsable site from its `manifests/*.json`: an index
README (an apps table with each app's last build date, plus a line pointing anyone
after the newest versions or Obtainium adds at NullStore) and one
`apps/<appKey>/README.md` per app, grouped brand then variant, with each distinct
applied-patch list folded once above the build table it covers. Stdlib only, no
network, and every collection sorted with a tie-break, because unstable order would
rewrite files whose data did not change. `NULLSTORE_URL` is required with no
default, so a hub move cannot leave a stale link advertising itself, and
`ARCHIVE_SITE_BASE` sets the page links, which are always absolute because a
relative link 404s for a logged-out reader. When `ARCHIVE_PAGES_BASE` is set it also
writes the `index.md` mirror that Pages (Jekyll) renders, front matter included,
linking at that base, with continuation pages named `page-2.md` rather than `2.md` so
the two surfaces cannot overwrite each other. The archive workflow commits the README
surface to `main`, the index surface plus a synced copy of the chrome to `site`, and
builds Jekyll from `site`. Run by the archive repo's own `pages.yml`, which imports it
from a sparse clone of `main` exactly like
`naming.py` ([0006](../../docs/decisions/0006-filename-parsing-is-imported-not-mirrored.md),
[0016](../../docs/decisions/0016-archive-pages-are-generated-markdown-on-main.md)).
Regression test: `.github/traces/test_archive_pages.sh` (goldens, two-run
determinism, and a perturbed sort key that must break the comparison).

### `generate_release_notes.py` — the second note
Renders `build.md` exactly as before, and when `ARCHIVE_REPO` is set also renders
`build.archive.md` — identical byte-for-byte **except** the per-file asset download
base, which points at the mirror repo so the archive release body and the Telegram /
Discord notices link the permanent copy. The footer's GitHub/Discord/Donate/Website
links stay on the canonical home. Unset writes no second file (the feature is opt-in).
`build_upload_release.sh` is reused unchanged for the mirror upload — the same script
with `RELEASE_REPO` set to `ARCHIVE_REPO` (a step `env:` cannot shadow the runner's
built-in `GITHUB_REPOSITORY`, so the target is named through a non-reserved variable)
and `RELEASE_BODY_FILE: build.archive.md`.

## Duplicate-build suppression (state branch, not the manifest)

The engine's `check_duplicate_build` (`scripts/utils.sh`) decides whether a
rebuilt app is identical to the published one. These scripts implement the
fingerprint and the CI side of the contract; behaviour belongs to
[build-engine.md](../../docs/build-engine.md#duplicate-build-suppression-tempunchanged-statebuild_content_hashesjson)
and nothing here touches `build.json` or the website manifest.

### `content_hash.py`
md5 over an APK's zip central directory (`name+CRC32+size`, sorted, `META-INF/*`
ignored — v2/v3 signatures live outside it). Stdlib-only. Raw file bytes are
never compared: every rebuild rezips and re-signs. CLI prints the digest; a
non-zip input exits non-zero without printing, which the engine reads as
"no verdict → publish".

### `build_check_no_change.sh`
Post-build guard. `build/` empty + `temp/unchanged/all.txt` →
`HAS_NEW_FILES=false` and `build.yml` skips the whole publish chain (no empty
numbered release — the flaw that closed PR #171). Any other state, including
unknown, keeps the chain enabled: the guard fails toward publishing.

### `build_merge_hashes.sh`
Folds `temp/hashes/append.*.tsv` (`channel<TAB>key<TAB>md5` lines written by
the engine for every eligible build) into
`state/build_content_hashes.json`, dropping malformed lines and foreign
channels. Runs **only after the upload chain succeeded** — and filters **per
line**: a stem is adopted only when `build/` holds the artifact it stands for
(`.apk` or the module-`.zip` spelling) or the key already has a state entry.
The engine records at patch time; a later per-app failure (module pack, stock
merge) must not leave a fingerprint for a file that was never published.
Outputs `STATE_UPDATED=true|false`; the following `commit_data_branch.sh` step
pushes the file to `data` when, and only when, it changed.

### `cleanup_artifact_hashes.sh`
Cleanup-side counterpart: prunes entries whose published file (`<stem>.apk` or
`<…>-module-v<…>.zip`, case-insensitive) no longer exists on any release — a
state entry may only suppress a rebuild while its artifact is actually
downloadable. Runs after the asset deleters; a failed `gh api` releases
listing aborts it instead of pruning against a partial list. Writes
`STATE_PRUNED` to `temp/gh_outputs/cleanup_hashes.env` for the commit step.

Regression test: `temp/_deduptest/run.sh` (fixture APKs with differing
timestamps/signature entries, all three scripts + the engine gate across
`off`/`log`/`enforce`; Git Bash) and `temp/_deduptest/run2.sh` (stubbed `gh`
asset list: survivor/prune/idempotence/fail-loud cases; Git Bash).

## Archive maintenance

### `cleanup-archive-assets.py`
Prunes old assets from the archive releases (size caps). The merge script's
live-asset filter automatically drops manifest entries whose files were
pruned, so the cumulative manifest tracks what is actually downloadable.

### `cleanup_website_branch.sh`
Runs in `cleanup.yml` after release deletion: removes `manifests/<tag>.json`
from the `website` branch when the numbered release no longer exists (same
pattern as `cleanup_update_branch.sh` does for changelogs). `archive/*.json`
entries for pruned files drop out at the next build merge (live filter).

### `seed_website_branch.py`
Downloads every live release's `build.json` **asset** and lays out the full
`website` branch content (`manifests/*.json` + `archive/*.json`). Historical
role: seeded the branch at migration time (2026-09-25). Since per-build
manifests stopped being uploaded as release assets, the branch is the sole
store — recovery order is now: ① branch git history
(`git log -p archive/stable.json`, `git show <rev>:archive/stable.json`,
force-push to undo), ② the repair tools below rebuilding from the surviving
window of legacy release assets + a healthy website `data.json`, ③ this
script (only while legacy assets still exist).

## One-time repair tools (manual, dry-run by default)

Both tools are idempotent recovery utilities: run without `--apply` first,
inspect the summary, then re-run with `--apply`.

### `repair_archive_manifest.py`
Rebuilds an **archive** release's cumulative `build.json` from the numbered
releases' own `build.json` assets — used after the merge hardening gap wiped
`stable`. Merges entries whose filenames still live on the archive (newest
`originBuild` wins); files whose originating numbered release has already been
deleted are recovered from the website catalog (`--data-json`, pass a
pre-incident `data.json` revision from git history — its
`patchSetRef`/`changelogRef`/`patchSourceRef` tables are resolved back into
full entries). Only what neither source covers gets filename-derived fallback
entries — those render as degraded "patched" wrapper cards on the site, so
check the dry-run's fallback count is acceptable before `--apply`.

```bash
python3 .github/scripts/repair_archive_manifest.py --archive stable          # dry run
git -C ../nullcpy.github.io show <pre-incident-rev>:data.json > /tmp/data_prewipe.json
python3 .github/scripts/repair_archive_manifest.py --archive stable \
        --data-json /tmp/data_prewipe.json                                   # writes output file
```

The repaired file is then committed to the `website` branch as
`archive/<channel>.json` (the `--apply` flag still uploads a release asset,
which the pipeline no longer reads), then trigger the website's
`rebuild-catalog.yml` (workflow_dispatch) so `data.json` re-folds from it.
Since the branch keeps full history, the first recovery step for a degraded
`archive/*.json` is `git log -p` / `git show <rev>:archive/stable.json` on
the branch itself.

### `backfill_manifests.py`
Backfills **per-release** `build.json` assets into the numbered releases from
the website catalog (`../nullcpy.github.io/data.json`, override with
`DATA_JSON`), adding fallback entries for live assets the catalog doesn't
cover.

```bash
python3 .github/scripts/backfill_manifests.py          # dry run
python3 .github/scripts/backfill_manifests.py --apply  # upload
```

## Shared conventions

### `naming.py`
Single source of truth for filename/catalog-name derivation (`file_prefix`,
arch extraction/normalization). Imported — never copied — by
`build_make_manifest.py`, `backfill_manifests.py`, **and by the website's
`rebuild_catalog.py`** (whose rebuild job sparse-clones `main` and points
`RVB_NAMING_DIR` at this directory). Keep it stdlib-only so it stays importable
across the repo boundary; a change here is live on the site at the next catalogue
rebuild, so run `rebuild-catalog.yml` with `dry_run: true` before merging one.
See [docs/decisions/0006](../../docs/decisions/0006-filename-parsing-is-imported-not-mirrored.md).

### `jsonfmt.py`
The one serialization for every JSON **document** this pipeline persists: the
`website` branch's `manifests/<tag>.json` and `archive/<channel>.json`, the
`build.json` release asset, the generated `configs/*_build.json` pools and
`state/*.json`. Shape: 2-space indent, raw UTF-8 (no `\uXXXX` escapes), LF, one
trailing newline — deliberately `jq`'s own default output, so the steps that
already merge through `jq` (`merge_archive_branch.sh`, `build_merge_hashes.sh`,
`ci_generate_configs.sh`, the retry-state writers) match the Python steps
byte-for-byte without an extra hop, and a branch diff names the entries that
changed instead of showing one opaque 400 KB line. Key order stays the object's
own unless a writer passes `sort_keys=True` (the state files whose consumers
diff them between runs). Stdlib-only, like `naming.py`. Also a fixer:
`python3 .github/scripts/jsonfmt.py <file>...` rewrites the ones that drift.

Formatting carries no meaning anywhere on either side of the seam — every
consumer parses — and nothing fingerprints JSON bytes (`content_hash.py` reads
APK zip directories, `retry_fingerprint` re-serializes the parsed value), so a
reformat cannot move the duplicate-build gate or an ADR 0010 re-arm baseline.

Deliberate exceptions: the notify queue is newline-delimited JSON (one compact
record per line, `notify_enqueue.sh`) and job-scratch projections that only jq
reads back through `--slurpfile` stay as their writer emits them;
`update_usage_tracker.py` keeps its own `json.dump` because the same `usage.json`
is rewritten by `cleanup-apks.py` in the apks repo — those two have to match each
other, not this repo.

Guard: `temp/test_json_canonical.sh` (Git Bash) drives the real writers in a
throwaway tree and asks whether the serializer would have to rewrite their
output. Its negative control is the old compact dump: mutating a writer back to
`separators=(",", ":")` turns exactly one assertion red — checked by mutation,
so the green run means something.
