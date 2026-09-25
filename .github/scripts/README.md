# Release manifest scripts (`build.json`)

Every release in this repo carries a `build.json` asset — a schema-v1,
filename-keyed manifest describing the APKs/ZIPs in that release (app name,
version, arch, applied patches, `originBuild`, ...). The numbered releases get
a manifest for exactly their own files; the cumulative archive manifests and
the per-build copies live on the **`website` branch** of this repo, which the
website catalog rebuild consumes directly. These scripts implement and repair
that pipeline.

```
builder (utils.sh)                build.yml
      │                                │
      ▼                                ▼
 build.json ──► build_make_manifest.py ──► temp/manifest/build.json
                        │                          │
                        │            ┌─────────────┴──────────────┐
                        ▼            ▼ (numbered release)         ▼ (archive upload)
            temp/manifest/*.json   build_upload_release.sh   merge_archive_branch.sh
                                   (UPLOAD_FILES includes      │ commits manifests/<tag>.json
                                    temp/manifest/build.json)  │ + merges archive/<channel>.json
                                                               ▼   (union, live-filter, push)
                                              website branch: archive/{stable,beta}.json
```

## Per-build pipeline (runs in CI)

### `build_make_manifest.py`
Converts the builder's raw `build.json` into the unified filename-keyed
manifest (`temp/manifest/build.json`) that everything downstream consumes.
Env: `NEXT_VER_CODE` (release tag), `IS_PRERELEASE` (→ channel `beta`/`stable`).

### `build_upload_release.sh`
Unified uploader (native `gh`, per-file retry, `--clobber`). Used for both the
numbered release (build outputs + `temp/manifest/build.json`) and the archive
releases. Note: `gh` names an uploaded asset after the **local file's
basename** — always stage files under their intended asset name.

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
Downloads every live release's `build.json` asset and lays out the full
`website` branch content (`manifests/*.json` + `archive/*.json`). Used to seed
the branch initially; also the recovery path to rebuild the branch from
scratch after a manifest repair (`--out` then replace the branch content).

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
        --data-json /tmp/data_prewipe.json --apply                           # upload
```

After `--apply`, re-sync the `website` branch with
`seed_website_branch.py --out temp/website-branch` and replace the branch's
`archive/<channel>.json` with the repaired file, then trigger the website's
`rebuild-catalog.yml` (workflow_dispatch) so `data.json` re-folds from it.
Since the branch keeps full history, the first recovery step for a degraded
`archive/*.json` is now `git log -p` / `git show <rev>:archive/stable.json`
on the branch itself.

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
arch extraction/normalization) shared by `build_make_manifest.py` and
`backfill_manifests.py`. The website repo's `rebuild_catalog.py` carries a
copy — change both in the same series of commits; divergence is the silent
bug class the manifest architecture exists to prevent.
