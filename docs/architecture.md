# Architecture

## The system at a glance

```
   patch sources (github/gitlab/codeberg)         app sources (stores & mirrors)
   MorpheApp, ReVanced, anddea, Piko, devanced…   APKMirror, Uptodown, APKPure,
        │                                         APKCombo, archive.org, GitHub,
        │ watcher lists releases, every 4 h       direct URL, shared APK cache
        ▼                                              │
 ┌──────────────────────────────────────┐              ▼
 │ nullcpy/rvb  (this repo)             │      ┌──────────────────┐
 │  main     code, workflows, docs      │      │  nullcpy/apks    │
 │  data     configs/ + state/          │      │  shared APK cache│
 │  website  manifests/ + archive/      │      │  + usage stats   │
 │  update   module update pointers     │      └──────────────────┘
 │  Releases numbered + stable + beta   │
 └──────────────────────────────────────┘
        │            ▲        │
        │            │        │ clone --branch website (manifest input)
        │            │        ▼
        │            │   ┌────────────────────────────────────────┐
        │            │   │ nullcpy/nullcpy.github.io              │
        │            │   │  rebuild-catalog.yml → data.json       │
        │            │   │  GitHub Pages: index.html + script.js  │
        │            │   └────────────────────────────────────────┘
        │            │                 ▲
        └────────────┼─────────────────┘
          catalog-updated repository_dispatch (from cleanup.yml)

   nullcpy/archive — permanent numbered mirror of every build
        │  rvb build.yml: mirror upload + manifest push + pages dispatch
        │  (opt-in via vars.ARCHIVE_REPO, cross-repo via ARCHIVE_REPO_TOKEN)
        ▼
      own pages.yml: renders README surface on main + Jekyll surface on site

   nullcpy/nullstore — static SEO gateway page for search engines
        ▲  nightly read-only fetch of the store's public data.json;
        │  deployed at nullcpy.github.io/nullstore, never written to from here
        └─ (details: its own README)
```

Five moving parts: **this repo** builds and publishes, the **`apks` repo** is a
shared download cache, the **`website` branch** is the build-metadata store,
**`nullcpy.github.io`** folds that store into the `data.json` the site renders,
and downstream of the site two read-mostly repos keep the history and the search
front door: **`nullcpy/archive`**, a permanent numbered mirror of every build
with pages generated from its own manifests, and **`nullcpy/nullstore`**, the
static SEO gateway page the catalog feeds.

## Repositories

| Repo | Role | Written by |
|---|---|---|
| `nullcpy/rvb` | The builder: engine, CI, patch configs, artifacts | CI + maintainer |
| `nullcpy/apks` | Cross-run cache of downloaded stock APKs/bundles plus a usage tracker | CI (`GH_TOKEN`/`APKS_REPO_TOKEN`, `vars.APKS_REPO`) |
| `nullcpy/nullcpy.github.io` | The download site: catalogue generator + static Pages UI | CI rebuild + maintainer |
| `nullcpy/archive` | Permanent numbered mirror of every build, with README and Pages surfaces generated from its own manifests | rvb CI (`ARCHIVE_REPO_TOKEN`, opt-in via `vars.ARCHIVE_REPO`) + the archive's own `pages.yml` (`GITHUB_TOKEN`) |
| `nullcpy/nullstore` | Static SEO gateway page for the catalog; one generated HTML front door that links to the store | its own nightly workflow |

The site is a separate repository with its own guide; this folder documents only
the seam between them → [website-contract.md](website-contract.md). The archive
repo's wire formats and history live in its own README; what rvb writes to it is
[storage-and-branches.md](storage-and-branches.md#nullcpyarchive-permanent-build-mirror),
and the CI steps are 11b–11d of [ci-pipelines.md](ci-pipelines.md). The gateway
repo reads only the store's public `data.json`; rvb never writes to either. The
store itself is served on several domains (this GitHub Pages origin plus Vercel,
Cloudflare Pages and a Cloudflare Worker mirror); rvb and the gateway always link
the canonical origin, and the mirror set and per-visitor rotation are owned by
the gateway's
[`nullcpy/nullstore/README.md`](https://github.com/nullcpy/nullstore/blob/main/README.md).

## Branches of this repo

`main` is **pure code**. Everything generated lives elsewhere, so a checkout of
`main` is always reviewable and never churns:

| Branch | Contains | Sole writer | Read by |
|---|---|---|---|
| `main` | Engine, workflows, scripts, `module/` template, `bin/`, docs | Maintainer (PRs) | every job, checked out first |
| `data` | `configs/` (human TOMLs + generated `stable_build.json`/`beta_build.json`), `state/` (watcher JSONs) | watcher (`commit_data_branch.sh`) for `*.json`; maintainer (`push_data_configs.sh`) for `*.toml` | watcher and build jobs, via `fetch_data_branch.sh` |
| `website` | `manifests/<tag>.json` per build + cumulative `archive/{stable,beta}.json` | `merge_archive_branch.sh` (build), `cleanup_website_branch.sh` (prune) | the site's `rebuild_catalog.py` |
| `update` | `changelogs/<code>.md` + `<channel>/<module-id>.json` pointers | `build_update_changelog.sh`, `cleanup_update_branch.sh` | KernelSU / Magisk module updaters, at phone-check time |

Details, recovery procedures and the wire formats: [storage-and-branches.md](storage-and-branches.md).

## Releases

Two classes, and the distinction is load-bearing:

- **Numbered** (`260141`, `260140`, …) — one per build, append-only, immutable.
  Title `Build No. <code>`, body generated from that build's APK list by
  `generate_release_notes.py`, `--prerelease` for beta-channel runs. Holds that
  run's files. The build number is `YY` + a 4-digit sequence derived from the
  highest existing tag/release (`build_resolve_version.sh`).
- **Archive** (`stable`, `beta`) — two rolling releases that accumulate every
  build's files. Assets are overwritten in place (`--clobber`) and pruned by
  `cleanup.yml`, which keeps the **two newest versions per app + architecture**
  (`cleanup-archive-assets.py`). Their title, notes and pre-release badge are
  **owner-written**: the archive upload step names no metadata at all, so CI
  touches files only → [decisions/0001-release-metadata-ownership.md](decisions/0001-release-metadata-ownership.md).

Per-build `build.json` is **no longer a release asset**; the `website` branch is
the only manifest store (completed 2026-09-25).

## Channels and pools

`stable` and `beta` are the only channel keywords. They are routing, not
versioning:

- `patches-version = "stable"` (the default) → the app is compiled into the
  **stable pool** only.
- `"beta"` → beta pool only; `"both"` → both, resolved per config file at build
  time (`build.sh` reads the file it was given: a beta-named config *is* the beta
  pool).
- A concrete value (`"v4.8.3"`) pins that release; it survives generation
  verbatim and nothing rewrites it.
- Keywords are resolved at build time against `state/patch_sources.json` — the
  watcher's record of each source's current release per channel — rather than
  being stamped into the config, so a build is consistent with the state snapshot
  it was generated from (`configs/` and `state/` always come from the same `data`
  commit).

Channel decides three downstream things: which generated config is built
(`configs/stable_build.json` / `beta_build.json`), which archive release receives
the files, and the `-beta` module-id suffix that gives Magisk modules an
independent update channel.

## One build, end to end

**Watcher** — `ci.yml`, 6 UTC crons on a 4 h window grid with randomized minutes
(GitHub's scheduler is best-effort and drops missed ticks — see
[CI pipelines](ci-pipelines.md)), concurrency group `ci`:

1. `fetch_data_branch.sh` materialises `configs/` + `state/` from `data`.
2. `compile_patch_configs.py` regenerates the two pool configs from the TOMLs.
3. `sync_patch_sources.py` lists every patch source's releases → writes
   `state/patch_sources.json` (per-channel tag + date + `blocked` flag) and
   reports whether stable/beta moved.
4. `ci_fetch_app_versions.sh` + `ci_compare_app_versions.sh` scrape the app
   stores for current versions and compare with `state/app_versions.json`.
5. `ci_trigger_flags.sh` is the single owner of "is there any work left";
   `ci_check_app_patches.py` checks whether new patches cover known app versions;
   `ci_generate_configs.sh` rewrites the pool configs for the apps that changed.
6. `commit_data_branch.sh` pushes **only** `*.json` under `configs/` + `state/`
   back to `data`. TOMLs are excluded by design — they publish through
   `push_data_configs.sh`.
7. Outputs `trigger_stable` / `trigger_beta` gate the two build calls: beta
   first, then stable (`needs: build_beta`, and only if the watcher succeeded).

**Build** — `build.yml`, once per pool, concurrency group `build`, with a
Cloudflare-bypass sidecar service on `:8000`:

1. Checkout `main` (full history, submodules) → `fetch_data_branch.sh` →
   `build_resolve_context.sh` maps the config file to `ARCHIVE_TAG`,
   `IS_PRERELEASE`, Telegram thread and title suffix.
2. Install Bouncy Castle only if a BKS-needing Xposed module is in the config;
   install the signing keystore from secrets.
3. `build_resolve_version.sh` computes `NEXT_VER_CODE`; the Actions APK cache is
   restored and the `nullcpy/apks` repo cache is available to the engine as the
   highest-priority download source.
4. `scripts/build.sh configs/<pool>_build.json` runs the engine →
   [build-engine.md](build-engine.md). Output: `build/` files, `build.json`,
   `build.md`.
5. `update_usage_tracker.py` records which app versions this run consumed;
   `build_cache_cleanup.sh` trims the local APK cache against an 8 GB watermark.
6. `build_make_manifest.py` converts `build.json` into the schema-v1 manifest;
   the numbered release is uploaded (`RELEASE_BODY_FILE=build.md`,
   `IS_PRERELEASE` from the channel).
7. `build_update_changelog.sh` + a scoped `git add` publish module pointers and
   this build's changelog to `update`.
8. `build_exclude_from_archive.sh` drops opted-out apps from `build/`, then the
   **archive** upload runs — assets only, no metadata named. When the mirror is
   enabled, the same files are also copied to `nullcpy/archive` under this
   build's tag, its manifest is published there, and the archive's page rebuild
   is dispatched (steps 11b–11d of [ci-pipelines.md](ci-pipelines.md); the whole
   chain is fail-soft).
9. `merge_archive_branch.sh` merges this build's manifest into `website`
   (`manifests/<tag>.json` + cumulative `archive/<channel>.json`), live-filtered
   against the archive release's actual files.
10. Telegram notification for the build.

**Cleanup** — `cleanup.yml`, called after a successful build:

1. `ophub/delete-releases-workflows` deletes old releases/tags, keeping the
   newest 98 and anything matching `stable`/`beta`.
2. `cleanup-archive-assets.py` prunes archive assets to 2 versions per app+arch.
3. `cleanup_update_branch.sh` and `cleanup_website_branch.sh` drop pointers and
   manifests whose releases are gone.
4. A `catalog-updated` `repository_dispatch` pings the website repo, which
   re-folds `data.json` and redeploys Pages. A missed dispatch is not lost: the
   site also rebuilds on its own `23 */6 * * *` schedule.

Failure of any `notify.yml` path is non-fatal to the pipeline; the notify workflow
only fires on `failure()`.

## Where truth lives

| Question | Authoritative source |
|---|---|
| Which apps exist, with which patches, on which channel | `data:configs/patches/*.toml` |
| Which pool an app lands in | that TOML's `patches-version`, resolved by `build.sh` |
| What version a patch source is on | `data:state/patch_sources.json` (watcher-written) |
| Which app versions are current in the stores | scraped live; `data:state/app_versions.json` only tracks what a CLI cannot report |
| What went into a build | `website:manifests/<tag>.json` |
| What is downloadable right now | the GitHub Releases API (existence, size, download counts) |
| What every build ever contained, permanently | `nullcpy/archive`'s numbered releases and the pages generated from its `website` branch |
| What the website shows | `nullcpy.github.io:data.json`, derived — never hand-edited except to fix a bad fold |
| What search engines rank | `nullcpy/nullstore`'s generated `index.html`, folded from the store's public `data.json` each night |
| What module id polls for updates | `updateJson` baked into `module.prop`, mirroring `update_json_path()` |

## Failure policy, and why it is asymmetric

- **Destructive or silent-wrong-data paths fail loudly.** A missing `data`
  branch, a failed `git fetch` of `website`, or an archive merge that keeps fewer
  entries than the sanity gate computes are hard failures. The 2026-09-24
  archive collapse happened because a download failure silently started from an
  empty base; the branch redesign made that path unrepresentable.
- **Per-app and notification paths fail soft.** One broken app must not lose the
  other 60: `build_rv` failures log and continue, `continue-on-error: true` covers
  the archive upload and Telegram, `update_usage_tracker.py` is `|| true`.
- **Re-runs must be idempotent.** Asset uploads use `--clobber` and a 3-attempt
  per-file retry; catalogue pushes rebase and retry; the repair tools are dry-run
  by default.

## Coupling hazards worth knowing before editing

- **The site imports rvb's filename rules.** `rebuild_catalog.py` resolves
  `.github/scripts/naming.py` from a sparse clone of this repo's `main`
  (`RVB_NAMING_DIR`) rather than mirroring it, so moving that path breaks the
  catalogue rebuild — loudly. The dependency is one-way and intentional;
  [decisions/0006](decisions/0006-filename-parsing-is-imported-not-mirrored.md).
- **The archive repo imports rvb's page generator the same way.** Its `pages.yml`
  sparse-clones `main` for `build_archive_pages.py` (and `naming.py` through it);
  moving either path breaks the archive's page rebuild — also loudly.
- **Wire formats that are already in the wild.** `updateJson` paths baked into
  installed modules, `module.prop` shape, `data.json` schema keys, and the
  `manifests/`+`archive/` layout. Renaming any of them orphans existing clients.
- **`configs/` and `state/` on `main` are ignored working copies.** They are
  materialised, not committed; `fetch_data_branch.sh` overwrites them.
- **Everything downstream of `merge_build_info`** assumes `build.json` keys match
  what the engine wrote for each table build — the manifest, the release notes
  and the site all read the same record.
