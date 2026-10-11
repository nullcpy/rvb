# Build engine

`scripts/build.sh` (entry) + `scripts/utils.sh` (library, ~4700 lines, 124
functions). This is the part that turns one TOML table into a signed APK and a
Magisk module zip.

## Entry point and invariants

```bash
bash scripts/build.sh configs/stable_build.json   # CWD must be the repo root
bash scripts/build.sh clean                       # remove temp/, build/, build.md
```

- `build.sh` sources its sibling `utils.sh` explicitly and exports `RVB_UTILS_SH`
  so pooled children can re-source it.
- Requires `jq`, `java`, `zip`; `python3` is optional (release notes and TOML
  fallbacks). Repo tools live in `bin/`: `aapt2`, `htmlq`, `toml/tq` (per-arch
  binaries), `apksigner.jar`, `dexlib2.jar`, `paccer.jar`.
- Everything transient goes under `temp/` (gitignored); everything shippable goes
  to `build/`. `build.json` is the machine record, `build.md` the human one.
- The engine never fails the whole run for one app: per-app failures log and
  continue; only "no output at all" aborts (`All builds failed.`). It stays
  notification-free — but every failure leaves a machine-readable record under
  `temp/failures/` for the CI report step to pick up (see below).

## Per-app failure records (`temp/failures/`)

Once `build_rv` has a resolved version it writes `temp/failures/<slug>.json`
(app, version, `vc`, arch, `patches_src`); the requested arch is already part of
the display label, so `<slug>` (= label lowercased, non-alphanumerics collapsed
to `-`) is identical in the pooled child, the serial parent and the CI step.
- **Build failure** — if the app then aborts, the parent copies that child's log
  to `temp/failures/<slug>.log` alongside the descriptor. A clean return deletes
  both. Serial mode `tee`s the build output to the same path so a single job also
  yields an uploadable log.
- **Download exhaustion** — writing `temp/failures/<slug>_dl.json` and returning 0
  (a skip, not a failure), so it never gets a `.log`; it only asks for a manual
  cache-repo upload. Both exhaustion points record: no source that can be read at
  all, and every version tried through every source with nothing accepted — the
  second one used to skip silently, because returning 0 makes the parent delete the
  app's `<slug>.json` as a clean return, and only the `_dl` name survives that sweep.

`temp/failures/` is wiped at the START of `build.sh` and deliberately survives the
end-of-run sweep, so the `build.yml` "Report build failures" step can read it.
The engine itself makes no network calls for this — see
[ci-pipelines.md](ci-pipelines.md#the-build-job-buildyml).

## Duplicate-build suppression (`temp/unchanged/`, `state/build_content_hashes.json`)

A patch source that bumps its `shared/` folder triggers every app of that
source, but most of those apps patch to logically identical bytes. Republishing
an identical APK under a new build number falsely notifies every updater
(issue #165), so `build_rv` asks `check_duplicate_build` the moment a mode's
`patch_apk` returns — before the copy to `build/` and before module packing:

- **Fingerprint:** md5 over the zip central directory (`name + CRC32 + size`,
  sorted, `META-INF/*` skipped) via `.github/scripts/content_hash.py`. Raw file
  bytes never match across rebuilds (rezipping, re-signing); v2/v3 signatures
  live outside the central directory, so they are invisible to the digest for
  free. md5 is deliberate: this answers "did our own pipeline repeat itself",
  the same non-adversarial question `ci_check_app_patches.py` hashes bundles
  with md5 for.
- **One verdict per app+arch**, taken from the first patched APK of the
  `for build_mode` loop (the apk-mode APK for `apk`/`both`, the module APK
  when module is the only mode): apk and module patching differ only in microG
  handling, so a match terminates the whole table build — the module stage is
  never patched or packed, nothing lands in `build/`, and no `write_build_info`
  fragment is written, so notes and manifest need no post-hoc filtering.
- **Reference:** `state/build_content_hashes.json` on `data`, keyed
  `channel → "<prefix>-v<version>-<arch>" → md5`. It is build bookkeeping,
  not metadata: `build.json`, the numbered manifest and the website contract
  gain no keys. The engine only ever updates the local copy (enforce mode, so
  the two arches of one run agree); CI publishes it after the upload chain
  succeeded, and the merge additionally refuses a recorded stem whose artifact
  never reached `build/` — the patch-time record must not outrun a later
  per-app failure (a run can fail an app after hashing it; the state has never
  actually held such an entry, but nothing prevented one until this filter).
  A hash becomes authoritative only when its own artifact is live.
  Lifecycle: `cleanup_artifact_hashes.sh` drops any entry whose file is gone
  from all releases, so a suppression guard never outlives the artifact it
  vouches for (see [ci-pipelines.md](ci-pipelines.md)).
- **Scopes:** CI-only (`GITHUB_REPOSITORY` set), revanced/morphe tools only
  (`PATCHER_HASH_DEDUP_ELIGIBLE` in the patchers registry — cross-run hash
  stability for the other tools is unmeasured), `python3` present, channel
  recognised. Anything missing publishes as today: the check fails toward
  redundancy, never toward a silent drop.
- **`RVB_DEDUP_MODE`** (`off|log|enforce`, also settable as the `dedup-mode`
  file-level config key; the pool default comes from the `build.yml` env, which
  runs **`enforce`** since the 1388-1391 log phase found one true duplicate,
  zero false matches and no stale state; a config naming nothing falls back to
  `log`, so local and hand-run builds still only measure). `log` computes and
  compares but skips nothing and mutates no reference.
- Records: `temp/unchanged/<slug>.json` per skipped app (same survive-the-sweep
  rule as `temp/failures/`), and `temp/hashes/append.<pid>.tsv` lines per fresh
  fingerprint — consumed by `build_check_no_change.sh` and
  `build_merge_hashes.sh`. An all-duplicate run exits 0 with
  `temp/unchanged/all.txt` instead of aborting `All builds failed.` — that
  marker is what stops the publish chain from creating an empty release.

## From config to a build request

`toml_prep` converts the config to JSON (native `tq` binary, `python3` fallback)
and the file splits into a **main table** (file-level defaults: `patches-version`,
`patches-source`, `cli-source`, `brand`, `variant`, `arch`, `author`, …) and one
table per app. For each enabled table `build.sh`:

1. Inherits every key from the file-level default when the app omits it.
2. Resolves `patches-version = "both"` from the file being built — a beta-named
   config *is* the beta pool (`configs/beta_build.json`, `*.beta.toml`).
3. Validates the enum keys hard (`arch`, `build-mode`, `include-stock`,
   `*-source-host`, boolean `inclusive-patches`) and rejects quote-less patch
   lists, because `list_args` splits on quoted tokens.
4. Refuses `inclusive-patches` together with `exclusive-patches` — they are
   opposites, and the ambiguity would be resolved by argument order.
5. Calls `get_prebuilts` to fetch the CLI jar and every patch bundle, then builds
   the `app_args` associative array, including the aggregated `patches_ref` and
   `changelog_url` derived from the **exact** bundle resolved for this build.
6. `arch = both` fans out into two builds, `arm64-v8a` and `arm-v7a`, each with
   its own module-id suffix (`-arm64` / `-arm`).
7. Beta builds get `-beta` appended to the module id automatically, so a phone's
   module updater never crosses channels.

`get_prebuilts` must be called directly rather than inside `$( )`: it writes the
`__PREBUILTS_CACHE__` global, and a subshell would discard it.

## Parallel pool (`PARALLEL_JOBS`)

The only knob is the env var set in [build.yml](../.github/workflows/build.yml)
(`PARALLEL_JOBS: "6"`); no config file can change it. `1` — the historical
default — runs the original sequential path untouched. Above that, each table
build becomes a fresh `bash -c` child that re-sources `utils.sh`:

- per-job globals (`PATCHER_*`, `PATCH_OUTPUT`, every in-process cache) are
  therefore isolated by construction, which is what makes concurrency safe;
- children write `temp/queue/<id>.log` plus an `rc` file; the parent replays
  finished logs inside their own `::group::` in completion order, so the Actions
  log stays as clean as the serial one;
- the wrapper runs `set +e` so it can record a failing child's rc, and a child
  killed externally without an rc file gets a synthesised `137` rather than
  hanging the drain;
- `INT` kills in-flight children before running the normal abort sweep.

The `=()` initialisers on the job arrays are required: bash 5.3 treats a bare
`declare -gA` as unset under `set -u`. Why the knob is a workflow env value and not
a config key: [decisions/0005](decisions/0005-tuning-knobs-live-in-the-workflow.md).
There is no second pool for downloads either — a prewarm pass was built and reverted
for adding surface without a measured gain
([decisions/0004](decisions/0004-no-download-prewarm-pass.md)).

## `build_rv`, stage by stage

1. **Identity** — resolve display name/slug, package name (a `pkg-name` of its
   own, or inferred from a GitHub/archive release-tag URL).
2. **Patch selection** — `inclusive-patches` is expanded *here* into explicit
   patch names via `_all_patch_names`, with excluded names removed from the
   expansion rather than passed as both include and exclude. Downstream code keeps
   reading one `included-patches` string and never learns the flag. Per-bundle
   `-e`/`-d` lists are joined by `join_args` (the single escaping point, which is
   what makes apostrophes in patch names survivable) and `|`-separated per
   bundle, so multi-source apps can address each bundle individually.
3. **Version resolution** — `_resolve_list_and_version` implements the
   precedence: explicit `version` from the config (a tag, or `exp`/`latest`/`beta`)
   → the version the patch bundle advertises under `auto` (a tested compatibility
   guarantee) → `state/app_versions.json` (only when the CLI advertises nothing) →
   live latest from the source. The target `versionCode` is derived from patch
   metadata only, and `has_compatible_patches` gates the build on the bundle
   actually covering the resolved version.
4. **Stock acquisition** — see the source order below. Bundles
   (`.xapk`/`.apkm`/`.apks`) are kept whole and handed to morphe untouched when
   `RVB_MORPHE_PASSTHROUGH=true` (morphe merges natively, and some APKs misbehave
   after `apkeditor`'s rewrite + re-sign); otherwise `merge_splits` flattens them.
   `verify_downloaded_apk` then checks the payload really is the requested
   package/version/arch before anything is patched. An **arch-honesty gate** follows:
   the artifact's real ABIs are read off its bytes (`_artifact_abis`) and, unless it
   carries the requested arch or is universal/arch-agnostic, the download is rejected
   and the run falls through to the next source — the arch goes unbuilt if no source
   supplies it, so no file is ever named for an ABI it does not contain
   ([decisions/0007](decisions/0007-requested-arch-is-a-hard-requirement.md)).
   APKPure/APKCombo/Uptodown links carry no ABI in the URL, so the first build to want
   one fetches it **once** and records its bytes in `temp/urlindex`; a later job that
   resolves the same link adopts the stored blob (right arch) or skips the source
   (wrong arch) with no network hit. Universal bundles are cached under the shared
   `-all` key and reused by both arch jobs from that single fetch.
5. **Arch trimming** — bundles go through `_trim_bundle_for_arch` (config members
   filtered by ABI); plain APKs get foreign `lib/<abi>/*` entries removed with
   `zip -d`. Result is cached as `<prefix>-<version>-<arch>.stripped.<ext>`, and
   `all`/`universal` ships the raw bundle.
6. **Patching** — `patch_apk` dispatches on the tool kind resolved by the patcher
   registry (see below) and records which patches the tool reports as applied.
7. **Naming and metadata** — `aapt2`/`aapt` re-reads the patched manifest, so a
   patcher that rewrote the package id is recorded honestly; output is
   `<file-prefix>-v<version>-<arch>.apk`; `write_build_info` appends the record
   that becomes the release manifest. One record is written **per arch**, each with
   its own resolved version and applied-patch set — a single build can publish
   arm64 at the newest version and fall back to an older one for an arch a source
   could not serve, so the per-arch values must not be lost downstream.
8. **Module mode** (`build-mode` `module`/`both`) — the `module/` template is
   copied to a scratch dir, `module_config` writes `config`
   (`PKG_NAME`/`PKG_VER`/`MODULE_ARCH`), `module_prop` writes `module.prop` and —
   only in CI, never for local builds — an `updateJson` URL built by
   `update_json_path()`. Output: `<file-prefix>-module-v<version>-<arch>.zip`.
9. **Finalisation** — `merge_build_info` folds per-job fragments into
   `build.json`, scratch state is swept, `generate_release_notes.py` writes
   `build.md` for the release body. A skipped duplicate (see
   [Duplicate-build suppression](#duplicate-build-suppression-tempunchanged-statebuild_content_hashesjson))
   never reaches this point: it writes no fragment. Because fragments share one key across arches,
   the fold keeps the first-wins scalars (`version`, `applied_patches`) for
   backward compatibility **and** records an additive `archVersion` / `archApplied`
   map keyed by the filename arch token, so a mixed-version build retains each
   arch's real version and patch set. `build_make_manifest.py` resolves each file's
   version from the filename first, then the `archVersion` map, then the scalar (and
   its patches from `archApplied` then the scalar). `generate_release_notes.py`
   derives each file's version straight from its filename and splits an app into one
   release-note bullet per distinct version, so a fallback arch is never reported
   under the other arch's version.

## Download sources, in priority order

`DL_SRCS` in [utils.sh](../scripts/utils.sh) is the order every app is attempted
in; the first source that yields a verified artifact **carrying the requested arch**
(see the arch-honesty gate above) wins:

| # | Source | Notes |
|---|---|---|
| 1 | `cache_repo` | `nullcpy/apks` — release per package name, download-only (never used to list versions) → [cache-repo.md](cache-repo.md) |
| 2 | `direct` | a straight file URL in the config |
| 3 | `github` | release assets, filtered by `github-release-regex` / `github-regex`, arch-mapped |
| 4 | `archive` | `archive.org` item, the long-term fallback for delisted versions |
| 5 | `apkmirror` | universal-bundle strategy; package/version read from the HTML |
| 6 | `uptodown` | |
| 7 | `apkpure` | one link per ABI read off `/downloading/<v>` → `/download/<v>` → `/download`, the page's featured `#download_link` being only one candidate, with the store's own `?versionCode=&nc=` link form as the last resort when a page yields nothing; XAPK handling in `_apkpure_install_xapk` |
| 8 | `apkcombo` | trusts the served filename over its object key |

Supporting machinery:

- **Anti-bot routing** — a Cloudflare-bypass sidecar (`CF_SOLVER_URL`, the
  `ghcr.io/sarperavci/cloudflarebypassforscraping` service in `build.yml`), asked
  about the **effective URL after redirects**, not the request URL; `curl_cffi`
  (`scripts/cf_get.py`) for TLS-fingerprint walls.
- **Which page a scrape actually saw** — the sidecar answers in two shapes, and they
  are not the same document: clearance cookies let `curl_cffi` fetch the **raw** page,
  while its `/html` endpoint returns a **JS-rendered DOM**, in which rendering has
  already deleted or rewritten server-rendered markup (measured on APKPure's
  `downloading/<v>` page: ~71k characters shorter, with its featured anchor gone). A
  page that yields nothing is therefore ambiguous without a record, so `cf_get.py`
  writes the producing path plus the sidecar's final URL to `temp/cf_source.txt`, and
  `_cf_get` exposes it as `__CF_GET_VIA__` for a scraper's failure message.
- **Stores answer 200 for things they do not have** — APKPure returns a generic
  "Free APK Downloader" page for a version it does not carry, so a missing link is
  named as *page not served* rather than as a parse failure; the two call for
  different retries (another version, or another source). For this host the rendered
  DOM is worse than ambiguous: measured across run 37964499217, every page the sidecar
  returned (~206k characters, three pages per build) contained **no** `d.apkpure.com`
  link at all, while the same URLs in a normal browser list one per ABI. Scraping
  APKPure from a datacenter address is therefore not a solvable problem — which is why
  `dl_apkpure` ends with the link the store writes into its own download markup
  (`/b/XAPK/<pkg>?versionCode=<vc>&nc=<abi>`, verified to select different bytes per
  `nc` and to serve nothing for an unknown `nc`). It is used only when the engine has
  already resolved a version code and the arch has a store spelling, it is logged as
  constructed, and the artifact is judged from its bytes like any other.
- **Transfer guards** — `_req` sets connect *and* absolute ceilings plus a low-
  speed stall guard, because a mirror that trickles would otherwise hold a build
  slot forever.
- **Locks** — per-package download locks under `temp/dllocks` stop parallel jobs
  fetching the same APK twice; rejected downloads sweep their sibling bundle
  files so the post-loop scan cannot adopt a partial artifact.
- **Response caches** — `__DL_RESP_CACHE__` and friends keep a run from
  re-scraping the same page per architecture.

## Cache layers

| Layer | Location | Keyed by | Written by |
|---|---|---|---|
| Actions cache | `temp/apks` on the runner | `apks-<hash of size+name manifest>` | `build.yml` restore/save |
| Shared APK cache | `nullcpy/apks` releases | tag = package name | the engine, after a successful fresh download (`UPLOAD_APKS_REPO`, `GH_TOKEN=APKS_REPO_TOKEN`) |
| Prebuilt tools | `temp/<host>__<owner>__<repo>-rv` | patch source / CLI release | `get_prebuilts` |
| In-process | `__PREBUILTS_CACHE__`, `__PATCH_VER_CACHE__`, `__PKG_VERS_CACHE__`, `__DL_RESP_CACHE__` | per job | memoised lookups |

`build_cache_cleanup.sh` keeps `temp/apks` under an 8 GB watermark with tiered
retention (30/14/7/3 days) so the Actions cache stays below GitHub's 10 GB
per-repo limit. `update_usage_tracker.py` posts the versions actually consumed
(`temp/used_versions.txt`) back to the cache repo, whose own monthly retention pass
keeps the 10 newest versions per package and everything used in the last 30 days —
see [cache-repo.md](cache-repo.md).

## Patcher registry

`.github/scripts/patchers.sh` (sourced by the engine, overridable with
`RVB_PATCHERS_SH` for tests) owns `resolve_patcher` and the `PATCHER_*` flags:
which tool kind this is, whether it lists patches, whether it needs a mount arg,
how its output is recovered. `.github/scripts/patchers.py` answers the CI-side
question `needs-bks` (does this config contain an app whose patcher needs the
**JVM** to provide a BKS keystore?). Only NPatch does: it calls the single-argument
`KeyStore.getInstance("BKS")`, which is a global provider lookup, and ships its
built-in stores as BKS files — so a stock Temurin answers `KeyStoreException: BKS
not found` and the run must install the provider first. ReVanced CLI and Morphe use
BKS too, but call `KeyStore.getInstance("BKS", "BC")` against a provider bundled in
their own jar, and LSPatch reads a bundled JKS through `KeyStore.getDefaultType()`;
none of those three needs anything installed, which is why the flag is set for the
npatch flavour of the xposed flow alone.

The same split decides `PATCHER_KEYSTORE_FORMAT`: the xposed tools sign their own
output, so the identity reaches them as `-k <store> <pass> <alias> <pass>` (same
argument order in both) and the flag names which of the two stores that tool can
read. Adding a tool means editing the registry, not `build_rv`.

## Signing and identity

| Env var | Default | Purpose |
|---|---|---|
| `RVB_KEYSTORE` / `RVB_KEYSTORE_P12` | none | the BKS store (ReVanced CLI, Morphe, NPatch) and the PKCS12 store (apksigner, LSPatch); `install_keystore.sh` writes both from `KEYSTORE_B64` / `KEYSTORE_P12_B64` and exports the two paths |
| `RVB_KEYSTORE_PASS` / `RVB_KEY_ALIAS` | none | one password, passed as both store and key password, and one alias present in both stores. Alphanumeric only: both are interpolated into `eval`'d CLI arguments, and `require_signing_identity` rejects anything else |
| `RVB_MORPHE_PASSTHROUGH` | `true` | keep bundles whole for morphe instead of merging at download time |
| `RVB_INSTAFEL_FALLBACK_COMMIT`, `RVB_INSTAFEL_DEFAULT_PATCHES` | see source | used when the InstaFel CLI manifest has no commit hash or a config omits `included-patches` |

Signature identity is not cosmetic: patched apps that lose the expected signer
cannot update in place, which is why `check_sig` exists. It therefore has no
default in `utils.sh` and no keystore ships in this repository — the two files
inherited from the template this was forked from came with a public private key, so
a missing secret meant every build here was signable by anyone holding the same
template. `build.sh` calls `require_signing_identity` before the first download,
and `install_keystore.sh` fails the run when any of the four secrets is absent
instead of falling back; it also checks the BKS magic and that the alias really is
readable in the PKCS12 store, so a wrong secret stops the job in seconds rather
than at the first patch of every app. A local build must export all four itself,
pointing at one key pair held in both BKS and PKCS12 form (same alias, same
password). The price of adopting a fresh identity is paid once: every previously
installed patched app has to be uninstalled, because its signer changed.

### Why the BKS copy cannot be dropped

One key pair, two store formats, because the consumers are not equally tolerant:

| Consumer | How it reads `--keystore` / `-k` | BKS required? |
|---|---|---|
| ReVanced CLI | `KeyStore.getInstance("BKS", "BC")` on its bundled provider, no format sniffing | **yes** — a PKCS12 file will not load |
| Morphe desktop | sniffs `KeystoreInputFormat` (BKS/JKS/PKCS12) and converts via `KeystoreImporter` | no |
| NPatch | `KeyStore.getInstance("BKS")` against the JVM | **yes**, and it is the only one that also needs the provider installed on the runner |
| LSPatch | `KeyStore.getInstance(KeyStore.getDefaultType())` | no — it wants the PKCS12 copy |
| apksigner | `--ks`, auto-detects | no — it wants the PKCS12 copy |

So `RVB_KEYSTORE` stays BKS as long as any `ReVanced/revanced-cli` app is
configured; collapsing to a single PKCS12 store would mean dropping one secret and
breaking those builds, and was checked rather than assumed (verified against the
`revanced-cli-6.0.0-all.jar` and `morphe-desktop.jar` bytecode, not documentation).

## Guardrails

The tool-decision branches of `utils.sh` are covered by the offline trace
harness — fixtures, stubbed `curl`/`java`, golden argv files, verified on every
push to `build.sh`/`utils.sh`. See
[.github/traces/README.md](../.github/traces/README.md). Helper-level tests for
cache and bundle functions sit beside it; behavioural tests for individual shell
fixes live in `temp/` (gitignored) by convention, and the ones worth keeping are
listed in [contributing.md](contributing.md).
