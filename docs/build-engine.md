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
The retry writer (`build_update_retry_list.sh`) re-queues **only** the download-
exhaustion record below; a build abort, a patcher abort, a patch-set rejection and a
bundle-unreadable abort are settled, not retried, because a retry reproduces the same
abort — see [ci-pipelines.md](ci-pipelines.md#the-build-job-buildyml).
- **Build failure** — if the app then aborts, the parent copies that child's log
  to `temp/failures/<slug>.log` alongside the descriptor. A clean return deletes
  both. Serial mode `tee`s the build output to the same path so a single job also
  yields an uploadable log.
- **Download exhaustion** — writing `temp/failures/<slug>_dl.json` and returning 0
  (a skip, not a failure), so it never gets a `.log`; it only asks for a manual
  cache-repo upload. Both exhaustion points record: no source that can be read at
  all, and every version tried through every source with nothing accepted — the
  second one used to skip silently, because returning 0 makes the parent delete the
  app's `<slug>.json` as a clean return, and only the `_dl` name survives that sweep
  (the same trap the `_pf` name below escapes).
- **Patch-set rejection** — writing `temp/failures/<slug>_np.json` (`tried` lists the
  versions the bundle refused) and returning 0. Kept separate from `_dl` because it
  means the opposite: no source failed and no APK is missing, the patch set has
  nothing to apply for this version set or this arch, so the report names the bundle
  instead of asking for an upload ([decisions/0009](decisions/0009-effective-patch-set-decides-compatibility.md)).
  Its optional `bytesVersion` column says a file *was* fetched and its own `versionName` is
  what the set refuses (the `_rekey_to_bytes` discard): the remedy is still the bundle or the
  source, never a manual upload, so it stays out of `_dl`.
- **Bundle unreadable** — the patch CLI could not **list** the bundle at all: `list-patches`
  itself aborted (run 39786888211: `MorpheApp/morphe-patches v1.48.0`, compiled against
  `morphe-patcher 2.0.0`, loaded by the `morphe-desktop v1.18.1` CLI that still ships
  `morphe-patcher 1.15.1` — every patch class static-init throws `NoSuchMethodError` on
  `Fingerprint.<init>`). Unlike the `_np` case the bundle never answers, so no version is
  resolved and `build_rv` aborts with rc 1 inside `_resolve_list_and_version`, **before**
  the plain `<slug>.json` descriptor is written — which left the app invisible to the report
  entirely. It now writes `temp/failures/<slug>_lb.json` (`app`, `arch`, `patches_src`,
  `cli_source`, `pkg`) and the parent relocates the captured log to `<slug>_lb.log`, so the
  stack trace is linkable; the report renders a **Patch Bundle Unreadable** section naming
  both the bundle and the CLI (the mismatch is between the two). Like the others it is
  settled, not retried: only a matching CLI release or a bundle pin fixes it.
- **Patcher abort** — the patch set loaded, the APK was fetched, and the patcher
  itself aborted (`Patching aborted`): `build_rv` also skips with rc 0, which used to
  wipe the app's `<slug>.json` as a clean return and report nothing (run 39199799796:
  TikTok-hushfeed failed on both arches, no notification). It now leaves
  `temp/failures/<slug>_pf.json` (same fields as the build descriptor) and the parent
  moves the captured log to `<slug>_pf.log` before its sweep; the report renders the
  pair in the Build Failed section. When the artifact shipped anyway (a dedup skip
  after an earlier mode aborted in the same build), the child deletes the pair — a
  published app must not be reported as failed. Like a build abort, a patcher abort is
  settled (not retried) by `build_update_retry_list.sh`: only a patch-bundle release
  or a config edit can fix it, and both re-trigger the app on their own.
- **Version-code fallback** — a build-failure descriptor also carries
  `vc_fallback: true` when the arch was already fetched through the code→arch fallback
  (stage 4) and still failed. That is a genuine incompatibility, not a transient miss, so
  the report says so ([decisions/0011](decisions/0011-version-code-fallback-to-arch.md)).
  It no longer drives a retry decision: build failures are settled, not re-queued, so the
  stamp only colours the notification wording now.

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
  A match is only half the verdict: it must also cover **every kind this build
  was asked to publish** (`build_mode_arr` is passed in). Without that, flipping
  `build-mode = "both"` on an app whose APK bytes are unchanged would re-produce
  a matching APK forever, suppress the module the maintainer actually asked for,
  and let the build job record the missing kind as built — the suppression would
  be permanent and silent. The verdict stays all-or-nothing per app+arch: one
  artifact kind is never published without the other, so no partial release.
- **Reference:** `state/build_content_hashes.json` on `data`, keyed
  `channel → "<prefix>-v<version>-<arch>" → {hash, kinds}` — the fingerprint, and
  the artifact kinds proven live for that stem. A bare md5 value (written before
  kinds were tracked) reads as *kinds unknown* and therefore **cannot justify a
  skip**: the polarity is the opposite of `built_shape`'s missing-baseline rule on
  purpose, because a duplicate skip is destructive and terminal while one extra
  publish is only noise. It is build bookkeeping, not metadata: `build.json`, the
  numbered manifest and the website contract gain no keys. The engine only ever
  updates the local copy (enforce mode, so the two arches of one run agree), and
  its kinds are this build's *request*, provisional within the run; CI publishes
  after the upload chain succeeded, and `build_merge_hashes.sh` — not the engine —
  decides which kinds are credited, per filename spelling that actually reached
  `build/`. The merge additionally refuses a recorded stem whose artifact never
  reached `build/` — the patch-time record must not outrun a later per-app failure
  (a run can fail an app after hashing it; the state has never actually held such
  an entry, but nothing prevented one until this filter). A hash becomes
  authoritative only when its own artifact is live.
  Lifecycle: `cleanup_artifact_hashes.sh` is the only reader of real liveness, so
  it is the only place a kind may be removed — and the only place one may be
  re-proved. An entry keeps exactly the kinds whose spelling still has a live
  asset and is dropped whole when none survives, so a suppression guard never
  outlives the artifact it vouches for (see
  [ci-pipelines.md](ci-pipelines.md)). Because trimming a kind leaves the *key
  count* unchanged, that step compares parsed documents, not counts, to decide
  whether its rewrite is worth keeping.
- **Scopes:** CI-only (`GITHUB_REPOSITORY` set), revanced/morphe tools only
  (`PATCHER_HASH_DEDUP_ELIGIBLE` in the patchers registry — cross-run hash
  stability for the other tools is unmeasured), `python3` present, channel
  recognised. Anything missing publishes as today: the check fails toward
  redundancy, never toward a silent drop.
- **`RVB_DEDUP_MODE`** (`off|log|enforce`). Tuning knob by
  [decisions/0005](decisions/0005-tuning-knobs-live-in-the-workflow.md): named
  **only** by the `build.yml` job env — never by a config key — and that env is
  `enforce` since the 1388-1391 log phase found one true duplicate, zero false
  matches and no stale state, except on a Manual CI run whose `disable_dedup`
  checkbox demotes it to `log` — the match is reported, the artifact is not
  withheld. Unset, as in any local run, it defaults to `log`: measure, never
  skip. The value is read into the exported variable itself and printed at build
  start; assigning it after a config-style read is how the workflow's choice got
  clobbered once. `log` computes and compares but skips nothing and mutates no
  reference.
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
   live latest from the source. What the bundle "advertises" is the version set of
   the patches that will actually be applied: `_effective_patch_versions` reads
   `list-patches` restricted to the `included-patches` names when they are set (they
   reach the CLI as `-e` and apply even when the bundle ships them `Enabled: false`)
   and `list-versions` — which counts only the default-enabled set — when they are
   not. The same table supplies the target `versionCode` and answers
   `has_compatible_patches`, so a version can never be advertised by one function and
   rejected by the other ([decisions/0009](decisions/0009-effective-patch-set-decides-compatibility.md)).
   A candidate whose version-code annotation lists other ABIs only is redirected, not
   dropped: if another supported version is viable for the arch it takes its place
   (that is what lets one app publish arm64 at one version and arm-v7a at another),
   and when none of them mentions the arch the download proceeds and the artifact-bytes
   gate above decides — the annotation records what the patch author tested, not what
   the store ships. `arch=all`/`auto` never filters.
4. **Stock acquisition** — see the source order below. Bundles
   (`.xapk`/`.apkm`/`.apks`) are kept whole and handed to morphe untouched when
   `RVB_MORPHE_PASSTHROUGH=true` (morphe merges natively, and some APKs misbehave
   after `apkeditor`'s rewrite + re-sign); otherwise `merge_splits` flattens them.
   `verify_downloaded_apk` then checks the payload really is the requested
   package/version/arch before anything is patched. `_rekey_to_bytes` runs at that point
   for every source: the name the artifact will carry is taken from its own `versionName`
   and the patch gate re-checks that version, so a store that served a different flavour of
   the requested number cannot leave a build labelled for a version it is not
   ([decisions/0012](decisions/0012-direct-source-identity-comes-from-its-artifact.md),
   widened to all sources). An **arch-honesty gate** follows:
   the artifact's real ABIs are read off its bytes (`_artifact_abis`) and, unless it
   carries the requested arch or is universal/arch-agnostic, the download is rejected
   and the run falls through to the next source — the arch goes unbuilt if no source
   supplies it, so no file is ever named for an ABI it does not contain
   ([decisions/0007](decisions/0007-requested-arch-is-a-hard-requirement.md)).
   A pinned `versionCode` is a preference, not a veto: when no APKMirror variant carries
   both the pinned code and the requested arch (a bundle can stamp the arm64 code on
   every ABI), `dl_apkmirror` re-selects by arch+version alone and `build_rv` re-keys the
   artifact to the code read off its bytes, so a wrong per-ABI code cannot drop a
   buildable arch and patch application decides compatibility
   ([decisions/0011](decisions/0011-version-code-fallback-to-arch.md)).
   APKPure/APKCombo/Uptodown links carry no ABI in the URL, so the first build to want
   one fetches it **once** and records its bytes in `temp/urlindex`; a later job that
   resolves the same link adopts the stored blob (right arch) or skips the source
   (wrong arch) with no network hit. What a build finally stores is keyed the same way:
   `_publish_stock_artifact` reads the arch token off the artifact — bundle or plain APK
   alike — so a universal file takes the shared `-all` key that both arch jobs then reuse
   from that single fetch, and an arch-specific file can never be adopted by somebody
   else's build.
5. **Arch trimming** — one keep-list (`_striplibs_keep_of_arch`) and **one decision about
   who applies it** (`_patcher_strips_libs`). Bundles go through `_trim_bundle_for_arch`,
   which drops whole foreign-ABI `config.*` members — a bundle member is never rewritten,
   only removed, so the split APKs keep the signatures they were published with.
   A plain APK is where the two halves differ: for a morphe build the flag
   `--striplibs <keep-list>` filters the ABIs at output assembly and the input is staged
   **unchanged** (a `cp` onto the same `<prefix>-<version>-<arch>.stripped.apk` path); for
   every other patcher — and for `RVB_MORPHE_STRIPLIBS=false` — the engine rewrites it with
   `_strip_apk_abis`, which reads the archive's own entry list and deletes foreign
   `lib/<abi>/…` entries by exact name — never by a wildcard, because `lib/x86/*` silently
   misses a `./`-rooted archive (rc 12, a warning the old `|| :` threw away) while the
   `*lib/x86/*` that catches it also deletes an app's `assets/engine/lib/x86/…` payload.
   Only Android's own ABI directory names are candidates, so an app's `lib/<dir>` that names
   no ABI is left alone. The rewrite lands through a temp file and one rename, and a failure
   ends that app's build rather than publishing an unstripped artifact. Either way the
   `<prefix>-<version>-<arch>.stripped.<ext>` path is also the reuse guard: a table build
   that already staged that input for another mode does not stage it again.

   **Why a morphe input must not be rewritten:** the APK Signing Block is not an entry — it
   sits between the local file data and the central directory — so anything that rebuilds
   the archive from the central directory drops it with the entries it deletes (`zip -d`
   returning 0 was measured doing exactly that, leaving v2/v3 absent and v1 referencing
   files that are gone). The patcher then holds an unsigned APK and every patch that reads
   the **stock** certificate — the spoof-signature family, the universal microG metadata
   patch — aborts with `NoCertificateException` after the archive has already been decoded
   (the failure [j-hc/revanced-magisk-module#848](https://github.com/j-hc/revanced-magisk-module/issues/848)
   reports for merged bundles). Nothing catches it earlier: `check_sig` only answers for a
   package pinned in `sig.txt`. So the strip runs once, in the component that can do it
   without destroying the archive; `all` means **arm universal**: `arm64-v8a` and
   `armeabi-v7a`, no x86 ABI, whichever artifact format the vendor shipped (an `all`
   bundle is otherwise copied whole, so the flag is what makes the two paths agree).
   Publishing x86/x86_64 would be its own decision, not a side effect of the download
   source. `RVB_MORPHE_STRIPLIBS=false` drops the flag and hands the engine's rewritten
   input back — the bisect switch, at the price of the certificate-reading patches above.
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
   backward compatibility **and** records additive `archVersion` / `archApplied`
   maps: `archVersion` keyed by the filename arch token, `archApplied` keyed by
   `token/kind` (`apk` vs the module `zip`), so a mixed-version build retains each
   arch's real version and each artifact's real patch set — under `build-mode`
   `both` one arch yields both an APK and a module whose applied sets differ
   (module mode disables the microG/GmsCore patches), which a token-only key
   would collapse to whichever fragment sorts last. `build_make_manifest.py`
   resolves each file's version from the filename first, then the `archVersion`
   map, then the scalar (and its patches from `archApplied` at the file's own
   `arch/kind`, then the scalar). `generate_release_notes.py`
   derives each file's version straight from its filename and splits an app into one
   release-note bullet per distinct version, so a fallback arch is never reported
   under the other arch's version.

## Download sources, in priority order

`DL_SRCS` in [utils.sh](../scripts/utils.sh) is the order every app is attempted
in; the first source that yields a verified artifact **carrying the requested arch**
(see the arch-honesty gate above) wins. It is also the order the watcher's version
scrape asks in ([ci-pipelines.md](ci-pipelines.md)), minus `cache_repo`, `direct` and
`archive` — reordering this array therefore changes which store gets to decide what a
tracked app's "latest version" is, so it must stay the order the build prefers.

| # | Source | Notes |
|---|---|---|
| 1 | `cache_repo` | `nullcpy/apks` — release per package name, download-only (never used to list versions) → [cache-repo.md](cache-repo.md). No release for the package means it has never been uploaded (every app's first build), which is logged as a cache miss, not as a failed request |
| 2 | `direct` | a straight file URL in the config. Its text is never parsed: the link is fetched once at source selection and the package name, version and versionCode are read off the artifact, so a nameless endpoint serving whatever the vendor ships today works as well as a versioned filename. The fetched blob goes into the download-link index, so each arch adopts it instead of re-fetching, and a single-ABI link is refused for another arch |
| 3 | `github` | release assets, filtered by `github-release-regex` / `github-regex`, arch-mapped |
| 4 | `fdroid` | an F-Droid repo: a package page (versions from the site's `api/v1/packages/<pkg>` JSON, file named `<pkg>_<code>.apk`) or a bare repo root (versions, exact file names and declared ABIs read from `index-v1.jar`, falling back to `index.jar`). One APK per version code, so no variant picker; `pkg-name` is required for the repo-root form |
| 5 | `archive` | `archive.org` item, the long-term fallback for delisted versions |
| 6 | `apkmirror` | variant picker ranks the release's rows (see below); package/version read from the HTML |
| 7 | `uptodown` | versions and package name come from [uptodown.py](../scripts/uptodown.py) alone (its `/apps/<id>/versions/<page>` JSON); there is no shell fallback, because the one that used to follow the call parsed `__UPTODOWN_RESP__`, a variable nothing has set since the scrape moved into python. When the call answers nothing, `get_uptodown_vers` still returns 0 with empty output on purpose: `build_rv` calls it as `$(get_…_vers)` under `set -e`, where a non-zero would abort the app instead of letting the next source try |
| 8 | `apkpure` | one link per ABI read off `/downloading/<v>` → `/download/<v>` → `/download`, the page's featured `#download_link` being only one candidate, with the store's own `?versionCode=&nc=` link form as the last resort when a page yields nothing; XAPK handling in `_apkpure_install_xapk` |
| 9 | `apkcombo` | trusts the served filename over its object key |

Supporting machinery:

- **A repo index is only fetched when it is small** — an F-Droid package page asks the
  site's per-package JSON (a few hundred bytes) and builds the file name from the
  `<pkg>_<versionCode>.apk` grammar, because `f-droid.org/repo/index-v1.jar` is 15.8 MB
  compressed and ~190 MB as JSON. A bare repo root has no such endpoint, so it is read
  through its own index jar, which also carries the exact published file name and the
  `nativecode` list — measured over a 1400-app repo: 2964 released entries, no ABI-suffixed
  file names, and only two names deviating from the grammar (author quirks), which is why
  the index form never reconstructs a name ([decisions/0013](decisions/0013-an-fdroid-source-asks-the-repo-what-it-publishes.md)).
- **An artifact's version belongs to its bytes** — the staged file is re-keyed by
  `_rekey_to_bytes` to the `versionName` read off its manifest *before* the version-code,
  signature and arch gates finish judging it, and the patch-compatibility gate is then
  re-run on that version (the one that ran before the download judged a version the source
  never served). A build the patch bundle does not support therefore drops that source,
  discards the fetch, records the version in the `_np` record's `bytesVersion`, and leaves
  the remaining sources to serve the version the label asked for. This began as the direct
  source's rule ([decisions/0012](decisions/0012-direct-source-identity-comes-from-its-artifact.md))
  and now applies to every source, because the mismatch is a property of the file: a patch
  bundle pins version *names*, and a store shipping two flavours of one number under one
  versionCode cannot answer a suffixed request. Run 41314721427 is the case — Proton Lumo
  was asked as `2.1.5-nogms`, APKMirror ships only `2.1.5-gms` (same code 79), and the
  patcher applied zero patches to an artifact still named `-nogms`. Only `direct` re-keys
  the versionCode as well, since a bare link claims no code while a store row has already
  been checked against the target; a versionCode written by hand in `version-code` survives
  as an order and still rejects the artifact.
- **A cache hit is judged by the same name test** — `_cached_identity_disagrees` reads the
  cached file's `versionName` before the loop adopts it (a cache hit skips every fetch
  gate). A label the bytes deny is a false name, so the entry and its sidecars are deleted
  and the source loop re-fetches; an unreadable `versionName` is *not* treated as a denial,
  because aapt fails on some vendor bundles and reading that as a lie would re-download
  every artifact on every run. A wrong `versionCode` alone stays the softer "not what this
  target wants" case: the arch copy is dropped, the shared blob is left for a sibling.
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
- **Which release page a version resolves to** — before any row can be picked, `dl_apkmirror`
  has to land on the page for that version, and an *old* version is not where the obvious
  lookups expect it. Slug guessing uses the listing's current `<h1>` and the config's category
  slug, so a release published under a **former app name** (`truecaller-trusted-caller-id-26-10-6`)
  is missed; the app's own page lists ten recent releases and `/page/N/` re-renders them, so
  anything older is invisible there. What remains is a search, and a search must be treated
  as a *field of candidates*, never as a winner: `?s=<version>` is answered site-wide (APKMirror
  ignores the app path once a query is present), so links are ordered by the app's own listing
  path and then **each candidate page is fetched and read for its package until one belongs to
  the app being built** — a wrong app or a dead link is named in the log and skipped, and a
  rejected page is remembered so the ten-page walk cannot ask for it again. Taking the first
  substring hit instead is what handed Truecaller-bufferk's 26.10.6 to `ru.vkusvill` (a grocer
  that also sits on 26.10.6) and then abandoned APKMirror for the version, though the right link
  was further down the same page (run 40175646917). The site-wide fallback is queried with the
  app's **title**, not its listing slug: APKMirror matches display names and answers "No results
  found matching your query" for `truecaller-caller-id-block 26.10.6`, while
  `truecaller-spam-call-blocker 26.10.6` returns the release. A candidate budget
  (`_APKMIRROR_CANDIDATE_LIMIT`) bounds the requests per field, because a store that throttles
  datacenter IPs should not be walked six ways at once. A version carrying a **flavour**
  (`2.1.5-nogms`, `1.7.0-lite`, `4.50.1_tv`) is ordered by that spelling first: the exact-slug
  tier runs before the tier that accepts any suffix on the same number, so where the store ships
  both flavours the requested one wins, and where it ships only the other one the loose tier
  still answers (that is what keeps `1.7.0-lite` building when the slug is plain `1.7.0`) and
  `_apkmirror_flavor_of` names the gap in the log before the transfer instead of after the
  patcher has applied nothing. The flavour is never a veto, because the slug is the store's
  spelling while the artifact's `versionName` is the fact, and `_rekey_to_bytes` judges that.
  Pinned in by `.github/traces/test_apkmirror_release_lookup.sh` and
  `.github/traces/test_apkmirror_flavor_ranking.sh`.
- **APKMirror variant picking** — one release page lists several uploads of the *same*
  versionCode that differ only in their Architecture / Minimum Version / Screen DPI
  columns, so the row matcher (`scripts/apkmirror_search.py`, mirrored in `utils.sh` for
  a runner without python) treats each column as a predicate and then ranks what is left:
  the **lowest Minimum Version** first, so the published artifact installs on the oldest
  device the app still supports instead of on whichever row sits at the table's bottom;
  wider ABI coverage next (one fetch then serves both arm builds); an exact DPI match
  next; table position last. A pinned versionCode narrows the rows and does not end the
  search — answering the first numeric match is what handed the arm-v7a build the
  arm64-only bundle in run 38589077939. A multi-ABI column is read by membership, so
  `arm64-v8a + armeabi-v7a + x86 + x86_64` counts as carrying arm-v7a, while a catch-all
  `all` request takes only `universal`/`noarch`. Split uploads are looked for **before**
  single-file APKs (`_apkmirror_type_order`), falling through to the plain APK when no
  bundle row satisfies arch, versionCode and DPI. A version no row satisfies is not
  guessed at: the source is skipped and the next one tried, and the bytes are still
  judged by the arch-honesty gate above.
- **Format preference (`preferred-format`)** — the config key is an ordered chain of
  `apk`/`apkm`/`xapk`/`apks` fed to every source that has a variant choice to make, as a
  **prefix of that source's own order, never a filter**: the named shape is tried first
  among the rows/links that satisfy the hard predicates, and anything the chain does not
  name keeps the source's built-in tail (`_pref_class_order`/`_pref_ext_order` in
  `utils.sh`). Sources differ in what they can distinguish — APKMirror's badge is only
  split-vs-single-file, APKPure's kind is a URL path, APKCombo's is which version page it
  probes, Archive's is the filename extension, Uptodown's is a row flag whose final file
  kind the store still decides — so a chain finer than a source's granularity collapses
  to it silently. F-Droid, GitHub, `direct` and `cache_repo` serve one artifact per
  release: the key is warned-about and ignored there. Unset everywhere, each source keeps
  its historical order byte-for-byte (APKMirror badge-first, Archive/APKCombo plain-first),
  which is what every existing golden was produced under. Universal-over-per-ABI coverage
  is deliberately **not** part of this axis: it is a download-quota policy (one fetch
  serving the whole matrix is what keeps an egress IP off a store's block list) and stays
  hard-wired at APKPure/APKCombo regardless of the chain.
- **Transfer guards** — `_req` sets connect *and* absolute ceilings plus a low-
  speed stall guard, because a mirror that trickles would otherwise hold a build
  slot forever. `req_artifact` wraps it for a vendor's own download endpoint: a CDN
  that closes the socket mid-file fails with curl (18), which `--retry` does not treat
  as transient and which `-C -` cannot resume through a per-request signed redirect, so
  the URL is re-requested (up to three attempts) rather than dropped as a source miss.
- **Locks** — two of them, and neither may assert a fact the bytes have not proved yet.
  `temp/dllocks` serialises a single destination path, so parallel jobs never fetch the
  same file twice. `temp/apkslocks` serialises the whole cache-check → download → upload
  sequence per **pkg + version**: deliberately not per version code, because the code is
  read off the artifact after the lock is taken (an arch no supported version declares
  starts without one, and `direct` re-keys afterwards), so codes-in-the-lock-name let two
  sibling arch builds run unserialized and store one universal APK twice. Rejected
  downloads sweep their sibling bundle files so the post-loop scan cannot adopt a
  partial artifact.
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
