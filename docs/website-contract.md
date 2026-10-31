# Website contract

Two repositories, one product: the builder publishes, the site renders. This file
documents only the **seam** — the formats and ordering rules that cross the
boundary. The site's internals (UI, `script.js` configuration, categories,
notices, search engine, Obtainium flow) are documented by its own guide:
[`nullcpy.github.io/CONFIG.md`](https://github.com/nullcpy/nullcpy.github.io/blob/main/CONFIG.md).

## What crosses the boundary

| Channel | Direction | Format | Stability |
|---|---|---|---|
| `website` branch of rvb | rvb → site | `manifests/<tag>.json`, `archive/{stable,beta}.json`, schema v1 | **the contract**; the site clones this branch shallowly |
| GitHub Releases API | site → GitHub | asset existence, size, `downloadCount`, browser download URLs | queried live, never cached in git |
| `catalog-updated` dispatch | rvb → site | `repository_dispatch` event type | name only; a lost dispatch is recovered by schedule |
| `update` branch pointers | phone → rvb | `module.prop` `updateJson` URL + JSON | baked into installed modules |
| Numbered/archive release URLs | site → rvb | `releases/download/<tag>/<file>` | filename grammar is the contract |
| `.github/scripts/naming.py` on `main` | site → rvb | Python module, imported by a sparse clone | one-way; a missing path fails the rebuild loudly |
| `data.json` (public URL) | site → `nullcpy/nullstore` | the schema-v2 catalogue, fetched read-only each night | the gateway derives its static page from it; it never writes back |

**rvb never writes into the site repository,** and the site never writes into rvb.
The only file either side edits in the other's name is `data.json`, which the site
regenerates from rvb's branch. The gateway repo (`nullcpy/nullstore`) sits one hop
further downstream: it reads the deployed `data.json` like any visitor, so the
store's schema v2 is its only dependency, and its own README owns the page's
internals.

## The pipeline across the seam

```
rvb: merge_build_info → build.json → build_make_manifest.py → temp/manifest/build.json
                                                            ↓ (after archive upload)
rvb:  website branch  manifests/<tag>.json  +  archive/<channel>.json
                                                            ↓ git clone --branch website
site: rebuild-catalog.yml → rebuild_catalog.py → data.json (schema v2) → deploy-pages.yml
                                                            ↑
site: also on cron "23 */6 * * *"  (convergence for lost dispatches)
```

The catalog is **derived from scratch** every run — fold numbered manifests, fold
archive manifests against live assets, then query the releases API for mutables. A
release or asset that no longer exists simply does not appear; nothing edits
`data.json` in place. That is why a corrupted branch entry is repairable by the
next build rather than permanent.

`deploy-pages.yml` deliberately ignores pushes that cannot change the deployed
site (`data.json`, `.github/**`, docs), which is why a catalog rebuild dispatches
the Pages deployment explicitly after a successful push.

Branch files are plain pretty-printed JSON documents: 2-space indent, raw UTF-8,
LF, trailing newline — the form [.github/scripts/jsonfmt.py](../.github/scripts/jsonfmt.py)
describes and `jq` emits by default, so rvb's shell and Python writers produce the
same bytes. Whitespace carries nothing: both ends parse the file, so reformatting
is never a contract change, and a consumer must not read a manifest line-wise.

## From schema v1 to schema v2

Schema v1 (rvb writes; keys listed in
[storage-and-branches.md](storage-and-branches.md)) is per-file and flat. Schema
v2 (the site publishes) is a normalised document: `apps[] → brands[] → variants[]
→ builds[] → assets[]`, with the three repeated lists — applied patches,
changelog URLs, patch-source slugs — collapsed into top-level tables
(`patchSets`, `changelogSets`, `patchSourceSets`) that builds reference by integer
index (`patchSetRef`, `changelogRef`, `patchSourceRef`). Dedup is keyed on the
ordered list, so only byte-identical repeats collapse; an empty list is omitted
entirely.

**Per-file values are authoritative, not per-app.** A numbered build publishes each
arch independently, so one build can carry `arm64` at the newest app version and
`arm` at an older fallback, and their applied-patch sets can differ. rvb therefore
stamps `version` and `appliedPatches` from each file's own name/arch and its own
file type — under `build-mode = "both"` the APK and the module of one arch are
stamped from separate patch lists, because module mode disables the microG/GmsCore
patches that the APK carries (never a collapsed per-app or per-arch scalar). The
numbered build **card** is keyed by the build tag, so
those mixed versions stay under one "Build <tag>" entry that lists every version it
published (`build.versions`) and shows the version on each asset row; only the
archive release keys its cards by version (it is a version history). When a build's
arches carry distinct patch sets, the applied-patches view exposes per-arch tabs
(like the Stable/Beta channel tabs) so each arch's list is shown.

| v1 (rvb) | v2 (site) | Notes |
|---|---|---|
| key = asset filename | `assets[].name` | the join key for everything mutable |
| `name`, `version`, `arch`, `fileType` | asset + build fields | arch ordering: `arm64`, `arm`, `all`, `universal`, `x86_64`, `x86`. A build publishes only the arches it actually produced, so an app may carry a subset (a single-ABI app has one arch entry) — the catalog derives from the manifests present, never assumes both channels exist ([decisions/0007](decisions/0007-requested-arch-is-a-hard-requirement.md)) |
| `appKey`, `appName` | `apps[]` identity | app grouping |
| `brandKey`, `brandName`, `variant`, `subVariant` | `brands[]`, `variants[]` | variant is `null` for `default` |
| `appliedPatches[]`, `changelogs[]`, `patchSources[]` | the ref tables above | |
| `originBuild` | build identity for archived files | an archive entry still names the numbered build it came from |
| `meta.channel`, `meta.kind` | `releaseType`, `isArchive` | `kind: "archive"` ⇒ `isArchive: true` |
| — (never in the manifest) | `size`, `downloadCount`, download URL | live from the Releases API |

Mutable numbers are never stored in git on either side: existence, size and
download counts belong to the releases, immutable build-time facts belong to the
manifests. Splitting them that way is what makes a stale catalogue impossible
rather than merely unlikely.

## Filename parsing is shared, not duplicated

`arch` extraction/normalisation, `file_prefix` and key normalisation have exactly one
implementation: [.github/scripts/naming.py](../.github/scripts/naming.py). The site's
`rebuild_catalog.py` **imports** it — `rebuild-catalog.yml` performs a blob-filtered,
sparse clone of `main` and points `RVB_NAMING_DIR` at `.github/scripts`, and a local
run resolves the same file from a `rvb` checkout beside the site repo. If the module
cannot be found the rebuild exits with `FATAL:` rather than falling back to anything.

That closes what used to be the weakest seam in the design: the site carried a
hand-copied mirror held together by "change both in the same series of commits",
and divergence would have been silent — an app grouping under the wrong architecture
or splitting into two variant cards. History and rejected alternatives:
[decisions/0006](decisions/0006-filename-parsing-is-imported-not-mirrored.md).

Practical consequence for editing: a behaviour change in `naming.py` reaches the site
on the next catalogue rebuild with no second edit, so run `rebuild-catalog.yml` with
`dry_run: true` and read the diff before merging one. Keep `naming.py` stdlib-only —
a third-party import there would break the site's dependency-free rebuild job.

## Degraded entries are visible by design

If a live asset has no manifest entry, the rebuild synthesises a minimal one from
its filename so **download buttons never disappear**. Such entries have no applied
patch list, and the site renders them as degraded nameless "patched" wrapper
cards. That is intentional: a missing record degrades visibly instead of hiding
files from users. The same rule governs rvb's repair tooling — check the
fallback count in a dry run before applying it.

## Circuit breakers

Both sides can lose an input, so both refuse to publish a collapse:

| Guard | Where | Fires when |
|---|---|---|
| `MIN_RATIO` (default `0.6`) | site `rebuild_catalog.py` | the new catalogue retains fewer than 60% of the previous apps/builds → abort (`FORCE=1` overrides) |
| fetch failure = job failure | rvb `merge_archive_branch.sh`, `fetch_data_branch.sh` | the previous branch state could not be read — no "start from empty" path exists |
| merge sanity gate | rvb `merge_archive_branch.sh` | the merged archive manifest kept fewer entries than `|union(old,new) ∩ live|` |
| push retry with rebase | both manifest/branch writers | a concurrent branch update; a genuine conflict defers to the next run rather than forcing |

The 2026-09-24 archive collapse is the reason the first two exist: a transient
download failure fell back to an empty base and the cumulative manifest restarted
from one build. Storage moved to a branch so that failure mode cannot be
expressed — the full account is
[decisions/0002](decisions/0002-manifests-live-on-a-branch.md).

## Changing a format without breaking the site

1. **Additive first.** A new manifest key is invisible to the site; a new *build*
   object shape is not, so the site's `rebuild_catalog.py` and its `CONFIG.md`
   schema section change in the same series. Filename-parsing rules do not have this
   problem — they live in one module both sides use.
2. **Never reinterpret an existing key.** Filenames, `updateJson` paths, JSON key
   names and the branch layout are wire formats already in users' hands. Introduce
   a new key and let the old one age out, or accept a forced re-flash.
3. **Bump `schema`** in the manifest envelope for a breaking change, and make the
   consumer reject an unknown major version loudly instead of half-reading it.
4. **Verify both ends before pushing.** Locally:
   `python3 .github/scripts/rebuild_catalog.py --repo nullcpy/rvb --manifest-dir <clone-of-website-branch> --out /tmp/data.json.new --existing data.json`
   then diff `/tmp/data.json.new` against `data.json` ignoring `updated_at` —
   exactly what the workflow's report step does. On GitHub: run
   `rebuild-catalog.yml` with `dry_run: true`.
5. **Remember the pruning coupling.** Archive assets disappear (2 newest versions
   per app + arch) and their manifest entries drop out at the next merge; module
   `updateJson` pointers resolve against the *archive* release, so a pruned file
   breaks a pending module update rather than only the catalogue.
