# Release manifest scripts (`build.json`)

Every release in this repo carries a `build.json` asset — a schema-v1,
filename-keyed manifest describing the APKs/ZIPs in that release (app name,
version, arch, applied patches, `originBuild`, ...). The numbered releases get
a manifest for exactly their own files; the two rolling archive releases
(`stable`, `beta`) additionally get a **cumulative** manifest covering every
file still archived on them. These scripts implement and repair that pipeline.

```
builder (utils.sh)                build.yml
      │                                │
      ▼                                ▼
 build.json ──► build_make_manifest.py ──► temp/manifest/build.json
                        │                          │
                        │            ┌─────────────┴──────────────┐
                        ▼            ▼ (numbered release)         ▼ (archive upload)
            temp/manifest/*.json   build_upload_release.sh   merge_archive_manifest.sh
                                   (UPLOAD_FILES includes      │ unions old cumulative
                                    temp/manifest/build.json)  │ manifest + new entries,
                                                               │ drops files no longer
                                                               │ on the release
                                                               ▼
                                                <stable|beta>/build.json
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

### `merge_archive_manifest.sh`
Merges the current build's manifest into the archive release's cumulative
`build.json`. Run **after** the archive file upload so the live-asset filter
sees the new files. Env: `ARCHIVE_TAG` (`stable`|`beta`), `GITHUB_REPOSITORY`.

Hardened against the 2026-09-24 incident where one transient
`gh release download` failure silently restarted the cumulative manifest from
the current build only (stable dropped from 408 → 2 entries):

- the old-manifest download retries 3× (like the upload) and **aborts the job**
  if the release has a `build.json` asset that cannot be fetched — only a
  genuinely absent asset is treated as "first merge";
- before uploading, a sanity gate recomputes the expected minimum
  (`|union(old, new) ∩ live assets|`) and refuses to publish a merge that kept
  fewer entries.

Regression tests: `temp/test_merge_archive_manifest.sh` (stubbed `gh`, run from
Git Bash; `temp/` is gitignored, keep a copy alongside the other local tests).

## Archive maintenance

### `cleanup-archive-assets.py`
Prunes old assets from the archive releases (size caps). The merge script's
live-asset filter automatically drops manifest entries whose files were
pruned, so the cumulative manifest tracks what is actually downloadable.

## One-time repair tools (manual, dry-run by default)

Both tools are idempotent recovery utilities: run without `--apply` first,
inspect the summary, then re-run with `--apply`.

### `repair_archive_manifest.py`
Rebuilds an **archive** release's cumulative `build.json` from the numbered
releases' own `build.json` assets — used after the merge hardening gap wiped
`stable`. Merges entries whose filenames still live on the archive (newest
`originBuild` wins); files whose originating numbered release has already been
deleted get filename-derived fallback entries (empty `appliedPatches`).

```bash
python3 .github/scripts/repair_archive_manifest.py --archive stable          # dry run
python3 .github/scripts/repair_archive_manifest.py --archive stable --apply  # upload
```

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
