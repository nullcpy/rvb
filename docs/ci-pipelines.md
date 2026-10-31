# CI pipelines

Six workflows in [.github/workflows](../.github/workflows). One watcher decides
*whether* to build; the reusable build job does the building; cleanup keeps
GitHub's limits; notify reports failures.

| File | Name | Triggered by | Concurrency group |
|---|---|---|---|
| [ci.yml](../.github/workflows/ci.yml) | CI | `schedule` (6 UTC crons: ~4 h windows with randomized minutes), `workflow_dispatch` | `ci` |
| [build.yml](../.github/workflows/build.yml) | Build | `workflow_call` only — from `ci.yml` (per pool) or `manual-ci.yml` | `build` |
| [cleanup.yml](../.github/workflows/cleanup.yml) | Cleanup | `workflow_call`, `workflow_dispatch` | `clean` |
| [manual-ci.yml](../.github/workflows/manual-ci.yml) | Manual CI | `workflow_dispatch` (config choice, optional `remove_apks`, `disable_dedup` checkbox) | `ci` |
| [notify.yml](../.github/workflows/notify.yml) | Notify | `issues`/`pull_request` (debounced batch), `workflow_call` (immediate, when a needed job of the caller ended in `failure`) | drain: `notify-debounce` |
| [trace-verify.yml](../.github/workflows/trace-verify.yml) | Trace Verify | `push` touching `scripts/build.sh`, `scripts/utils.sh`, `scripts/apkmirror_search.py`, `scripts/uptodown.py`, the two version-watcher scripts or `.github/traces/**` | `trace-verify` |

Nothing here runs on `push` to `main` except Trace Verify: a push changes
behaviour for the *next* scheduled run, it does not start a build.

The watcher's schedule is a set of 6 UTC crons, one per 4 h window (`0,4,8,12,16,20`),
each with its own randomized minute. GitHub's `schedule` trigger is best-effort —
under load a due run is enqueued late, and a tick that was missed is dropped rather
than back-filled (measured here at 3-4 runs a day against a 4 h cron, each 40 min to
3.5 h late) — so widening the window to 4 h trades redundancy away: a dropped tick
can now leave a gap of up to ~4 h instead of the ~2 h the earlier grid tolerated. The
watcher is idempotent, so an extra tick costs only the check steps unless something
actually moved. Spreading the minutes across each window takes ticks off the
contended :00 and keeps every run off the website's `23 */6` rebuild (no window
shares minute 23). Cadence is still not a guarantee — when a check must happen now,
`manual-ci.yml` is the path.

## The watcher (`ci.yml`)

One job, `check_patch`, decides everything downstream. Order matters because each
step's output is the next step's input:

| Step | Script | What it decides |
|---|---|---|
| Fetch configs & state | `fetch_data_branch.sh` | hard-fails if `data` is missing — no silent fallback to stale state |
| Compile Base Configs | `compile_patch_configs.py` | every app's pool membership from `configs/patches/*.toml` |
| Sync Patch Sources | `sync_patch_sources.py` | discovers all `(patches-source, host)` pairs, lists releases on GitHub/GitLab/Codeberg, rewrites `state/patch_sources.json`, prunes sources no config uses, emits `TRIGGER_STABLE`/`TRIGGER_BETA`/`TRIGGER_BLOCKED` and writes `changed_sources.json` |
| Fetch App Versions | `ci_fetch_app_versions.sh` | scrapes current store versions (honours `"_check_only_listed"` in `state/app_versions.json`). Sources are asked in `DL_SRCS` order — the engine's own download order, read from `scripts/utils.sh` — so the version recorded is the one the build would be handed first; `cache_repo`, `direct` and `archive` are never asked for a listing (the cache and the mirror answer "do you have X?", not "what is the latest X?", and a direct URL's version only exists in its bytes). Every answer names the source it came from, and a source that loads but lists nothing is warned about by name before the search continues: a silent fall-through is what let one flaky Uptodown scrape hand a group to APKMirror, a release ahead, and record that as an update. Stays **soft** — no source answering at all writes `::error::` and moves on with the previous baseline, because one store rate-limiting the runner must not stall every other app's build |
| Compare App Versions | `ci_compare` step | `TRIGGER_APP_UPDATE` when a tracked app moved **up**. Both sides are first reduced to their release key — everything before the first space, because stores print one release two ways (`349.9`, `349.9 - Stable`) — and the new key must beat the old under `get_highest_ver`, the engine's own comparator. A reformat of the same release and a lower version are each refused with a `::warning::` naming both values and leave `state/app_versions.json` byte-identical: re-recording either would re-key the build's cache name and re-patch an APK that never moved |
| Detect config changes | `ci_detect_config_changes.sh` | always runs: diffs the compiled config against `state/built_shape.json` — its arch set **and** each app's tracked config map — enqueues new apps/arches (`reason: new`), apps whose tracked config moved (`reason: config`, with the field diff written to `changed_apps.json`) and carried-over retries into `state/pending_builds.json`, prunes queue entries whose app/arch left the config (the `built_shape` memory is kept, so re-enabling an app is not a new build request), **re-arms** an entry whose app config changed since it was written (`cfg` fingerprint: attempts reset, park lifted), and emits `TRIGGER_CONFIG_CHANGE` — which means "the watcher's state moved", not "build this": it is the only signal that gets `state/*.json` committed to `data`, and whether a run starts is decided downstream by the enabled-app count in the pool (why: [decisions/0010](decisions/0010-config-change-pending-builds.md), [0014](decisions/0014-config-changes-that-earn-a-rebuild.md)) |
| Classify triggers | `ci_trigger_flags.sh` | the two questions everyone else asks: `SOURCES_CHANGED`, `ANYTHING_CHANGED` (config change counts toward the latter, never the former) |
| Check Patch App Updates | `ci_check_app_patches.py` | only when `SOURCES_CHANGED`: downloads the changed bundles and hashes them (`state/patch_file_hashes.json`) to find which apps the new patches actually cover |
| Generate configs (JSON) | `ci_generate_configs.sh` | only when `ANYTHING_CHANGED`: writes the pool config each channel will build |
| Resolve effective triggers | `ci_resolve_triggers.sh` | per-channel `TRIGGER_*` **after** generation, and downgrades a trigger to 0 when the resulting pool has no enabled apps |
| Notify telegram | `ci_notify_telegram.sh` | raw vs effective triggers, so a suppressed trigger is visible; sent as Telegram **HTML** so the bundle heading can be bold *and* linked (legacy Markdown renders `*text [a](url)*` literally), the grammar the release notes already use; mirrored to `DISCORD_WEBHOOK_PATCH_ALERT` ([§Discord mirror](#discord-mirror-notify_discordsh)) |
| Notify build queue | `ci_notify_queue.sh` | ONE message on the log topic (`TG_THREAD_NOTIFY`) naming every app this run will actually build: the enabled keys of the regenerated pools, as `📱 *Name* (brand • variant)` blocks grouped under `🧩 *owner/repo* ([tag](release page)) · N apps` headers — the same bold-heading grammar the release notes use (the tag is a version, not another path segment, and the parentheses sit outside the link because a `)` ends a `[label](url)` run in both dialects). It reads the **effective** triggers, not the raw ones, so a channel `ci_resolve_triggers.sh` downgraded for want of enabled apps contributes nothing (the watcher is also the last place both pools are visible together — each build job sees only its own config). The tag is the one the build would resolve: the app's own `patches-version`, else the pool's channel, answered from `state/patch_sources.json` the same way `_patch_source_state_tag` answers it. An app with nothing to build from is **not queued and not listed** — a source the snapshot marks `blocked` is skipped by the engine before it resolves any version, and a channel with no tag recorded for that source has no bundle to patch (a stable-only repository therefore contributes no beta line) — each skip is written to the step log so a missing app is explainable. A pool whose every app is filtered out sends nothing. Mirrored to `DISCORD_WEBHOOK_GITHUB_LOG` |
| Notify announcements | `ci_notify_announcements.sh` | ONE message on the NullStore announcement topic (`TG_THREAD_ANNOUNCE`) covering both things the watcher can cause: apps added to the config (`new_apps.json`) and apps it woke because their tracked config moved (`changed_apps.json`, printed as the field diff, e.g. `build-mode: apk → both`). No-op when neither has anything; one send per run, not two notices chasing each other. Mirrored to `DISCORD_WEBHOOK_GITHUB_LOG` |
| Commit updated state | `commit_data_branch.sh` | pushes **only** `*.json` under `configs/` + `state/` to `data` |

Some design rules worth preserving:

- **`changed_sources.json` is written once**, by the sync step
  (`derive_source_changes.py`). Config generation, the patch-relevance scan and
  the trigger flags all project from that one record, so three steps can never
  disagree about what moved.
- **A version is an update only when it goes up, and the watcher asks its stores in
  the order the engine downloads in.** Both halves are one rule: the version recorded
  in `state/app_versions.json` must be the answer the build would have got anyway, or a
  scraping hiccup becomes a release. That record is not just bookkeeping — when a patch
  bundle advertises no version, `build_rv` patches exactly what the watcher wrote, so a
  bounce between two stores re-patched and re-released the same APKs on alternate ticks
  (Discord: `349.9 - Stable` ↔ `350.8 - Stable`, twice in two days). `DL_SRCS` is the
  order and `get_highest_ver` is the ordering; neither is reimplemented here.
- **Generation is membership-only.** `ci_generate_configs.sh` sets
  `enabled = false` for apps outside this run's change set and never rewrites a
  version: an app whose `patches-version` is a channel keyword keeps the keyword,
  resolved at build time against `state/patch_sources.json`. Stamping a concrete
  tag into the pool config used to create a second artifact that had to agree
  with the state snapshot about what "stable" meant.
- The beta pool keeps one extra gate: an app-version bump alone pulls an app into
  beta only when one of its sources genuinely has `beta_date > stable_date`,
  otherwise the stable pool already covers it.

### What causes a build

| Event | Flags | Effect |
|---|---|---|
| A patch source publishes a release on the stable channel | `TRIGGER_STABLE` | stable pool regenerates and builds |
| …on the beta channel | `TRIGGER_BETA` | beta pool only |
| An app's own version moved **up** in a tracked store | `TRIGGER_APP_UPDATE` | both pools reconsider membership (beta gated as above) |
| A source is blocked or unblocked (`404`/`451`/`403` from the forge) | `TRIGGER_BLOCKED` | regenerates membership, so frozen sources drop out and recovered ones return |
| The config gained a new app or a new architecture, **or** a previously-failed build is still owed a retry, **or** an app's own config changed under a parked entry (re-arm) | `TRIGGER_CONFIG_CHANGE` (non-parked pending list) | pool regenerates with the pending apps force-enabled, and the build runs even though no source or version moved (why: [decisions/0010](decisions/0010-config-change-pending-builds.md)) |
| Nothing moved | all `0` | no config write, no notification, no build |

A blocked source is **skipped**, not retried: neither a retry nor a live listing
recovers a repository that is gone, and the app reappears by itself once the
forge answers again. The deliberate fail-open inside that check is recorded in
[decisions/0003](decisions/0003-blocked-patch-sources-are-skipped.md).

### Ordering and safety rails

- `build_beta` runs first; `build_stable` `needs` it and additionally requires the
  watcher to have succeeded and beta not to have been cancelled. The single
  `build` concurrency group therefore serialises every manifest merge against the
  `website` branch — two builders never merge at once.
- `trigger_cleanup` runs on `always()` if either build succeeded.
- `trigger_notify_failure` runs on `always()` plus an explicit `== 'failure'` test on
  each of `check_patch`, `build_beta` and `build_stable`. Two separate traps shaped
  that line:
  - `always()` is load-bearing, not stylistic. GitHub skips a job whose needed job was
    **skipped** unless the condition begins with `always()`, and a `check_patch` failure
    leaves both build jobs skipped. Under a bare `failure()` the one failure that gates
    every build was the one that announced nothing (run 39261459573, killed by a typo'd
    config key in "Compile Base Configs").
  - The results are named one by one because `contains(needs.*.result, 'failure')` at
    JOB level is unreliable — a runner bug open since 2021
    ([actions/runner#1540](https://github.com/actions/runner/issues/1540)): a job-level
    condition does not evaluate the wildcard from the same values the identical
    expression shows at step level. Run 39263204435 carried that form and still skipped
    the job while `check_patch` was in `failure`. `trigger_cleanup` two entries above
    is the working precedent for the named form.

  Comparing to `'failure'` rather than `!= 'success'` keeps the ordinary quiet night
  silent: with nothing to build, `build_beta` ends `skipped`, which is not a failure —
  and a `cancelled` run is not news either.
- `ci_trigger_flags.sh` writes outputs with explicit `if` blocks rather than
  `[ … ] || [ … ] && var=` lists on purpose: under `set -e` a short-circuit list
  whose final command never runs exits non-zero and would kill the step *before*
  it wrote its outputs, silently turning every dependent step into a no-op.

## The build job (`build.yml`)

Called once per pool with `config_file` (and optional `remove_apks`, plus
`disable_dedup` from Manual CI). Everything it needs to be reproducible lives in
that one file, including the tuning knobs —
`PARALLEL_JOBS: "6"` and `UPLOAD_CONCURRENCY: "12"` are workflow env values, not
repo variables, so they are visible in PRs, survive forks, and carry git history
(why: [decisions/0005](decisions/0005-tuning-knobs-live-in-the-workflow.md)).

Step order, with the reason each is where it is:

1. Java 21 (Temurin) → checkout `main` with `fetch-depth: 0` and submodules (full
   history is needed to enumerate existing tags and to commit to other branches) →
   `fetch_data_branch.sh`.
2. `build_resolve_context.sh` maps the config file to `ARCHIVE_TAG`,
   `IS_PRERELEASE`, `TITLE_SUFFIX` and the Telegram thread — the single owner of
   "which channel is this run".
3. Install Bouncy Castle **only if** `patchers.py needs-bks` says an app in this
   config is patched with NPatch — the only tool that asks the **JVM** for a BKS
   keystore type (single-argument `KeyStore.getInstance("BKS")`). ReVanced CLI and
   Morphe also work in BKS but carry their own provider inside their jar, and
   LSPatch uses `getDefaultType()`, so none of them trigger this step. A stock
   Temurin has no BKS type, so getting the gate wrong either way is visible: skip
   it for an NPatch config and patching dies on `KeyStoreException: BKS not found`.
4. `install_keystore.sh` writes the signing identity from the four `KEYSTORE_*`
   secrets and **fails the run** if any of them is absent: there is no keystore in
   the repository to fall back on (the template's shipped a public private key), and
   silently signing with it would make every build here updatable by anyone holding
   the same template. It also checks the BKS magic and that `KEY_ALIAS` is readable
   with `KEYSTORE_PASSWORD`, so a wrong secret stops the job here rather than at the
   first patch. `build.sh` then re-checks the identity before any download.
5. `build_resolve_version.sh` computes `NEXT_VER_CODE` (`YY` + the next 4-digit
   sequence above the highest existing tag/release, e.g. `260141`).
6. Restore the Actions APK cache (`temp/apks`), optionally drop named APKs, then
   `pip install curl_cffi` for the store scrapers. The Cloudflare-bypass sidecar
   runs as a job `service` on `:8000`.
7. `scripts/build.sh <config>` — the engine ([build-engine.md](build-engine.md)).
   `UPLOAD_APKS_REPO` + `APKS_REPO_TOKEN` turn on the shared cache repo;
   `RVB_MORPHE_PASSTHROUGH`, `RVB_DEDUP_MODE` and the `RELEASE_NOTES_*_LINK`
   vars are passed here. On any per-app failure the engine writes a record to
   `temp/failures/` (kept across the run's end, wiped at start), which the next
   step consumes. An app whose freshly patched APK matches its published
   fingerprint (`state/build_content_hashes.json`, `RVB_DEDUP_MODE=enforce`) is
   skipped before module packaging and recorded under `temp/unchanged/` — a
   skip, not a failure; it never reaches the failure report. The job env derives
   that knob from `inputs.disable_dedup`: ticked, a Manual CI run demotes to
   `log`, so a match is still reported but nothing is withheld and the app
   publishes anyway; every other caller gets `enforce`. The match only
   suppresses when every artifact kind the build was asked to publish is already
   live on the record, and a bare-md5 entry (kinds unknown) never suppresses at
   all — see [build-engine.md](build-engine.md).
7b. **Report build failures** (`build_report_failures.sh`, `if: always()`,
   `continue-on-error`): reads `temp/failures/`, uploads each build log to
   `xi.pe`, and posts ONE batched Markdown message to the failure topic
   (`TG_THREAD_NOTIFY`, mirrored to `DISCORD_WEBHOOK_GITHUB_LOG`) in up to four
   sections — apps that failed to **build**
   (`<slug>.json`, with the log link and patch source), apps where **the patcher
   itself aborted** (`<slug>_pf.json` + `<slug>_pf.log`: the engine skips with rc 0,
   so the plain descriptor is wiped as a clean return and only this survivor pair
   reaches the report; rendered in the same Build Failed section), apps whose **patch
   bundle the CLI could not even list** (`<slug>_lb.json` + `<slug>_lb.log`: `list-patches`
   itself aborted — usually a CLI↔bundle patcher-version mismatch — so no version is ever
   resolved and the build aborts before the plain descriptor exists; rendered in a Patch
   Bundle Unreadable section naming both the bundle and the CLI), apps the patch set
   **refused for every supported version** (`<slug>_np.json`: the tried versions and
   the bundle link, and deliberately no APK search links, since nothing was ever
   fetched), and apps whose **download sources were all exhausted**
   (`<slug>_dl.json`, a request to upload the APK to the cache repo manually), plus a
   link to the run. A slug that has a build record has its `_dl`/`_np`/`_pf`/`_lb` twins
   dropped, so an app is reported once. When it sends, it sets the job output
   `reported_failures=true`, which
   `trigger_notify_failure` forwards as `already_reported` so
   `notify_send_telegram.sh` skips the generic "🔴 CI #N failed" alert for that
   run (Route B) — non-build failures still notify normally.
7b2. **Reconcile pending-build state** (`build_update_retry_list.sh`,
   `if: !cancelled()`): reads the same `temp/failures/` records and updates
   `state/built_shape.json` + `state/pending_builds.json` for this channel. **Only
   download exhaustion (`_dl`) is retried**: a `_dl` arch still requested is re-queued
   as a retry and parked once it hits `RVB_RETRY_MAX`. Every other failure class — a
   build abort (`<slug>.json`), a patcher abort (`_pf`), a patch-set rejection (`_np`)
   and a bundle-unreadable abort (`_lb`) — is **settled, not retried**: re-running the
   same engine over the same
   inputs reproduces the same abort, so it spends a build slot to learn nothing. The
   fix for those is a patch-bundle release or a config edit, and both already
   re-trigger the app independently (`TRIGGER_STABLE` / the watcher's re-arm), so the
   retry queue has nothing to add. A settled arch is merged into `built_shape` (its
   tracked config map stamped from the pool it just built) so neither the retry queue
   nor the watcher's "arch never built → reason new" path re-nags it every run; the
   baseline is held back only for an arch that still owes a download retry, or the
   pending retry would forgive the very edit it is re-queuing (decisions/0014). The
   entry is merged, not
   replaced, so the watcher's `cfg` fingerprint survives the attempt — dropping it
   would make every run look like a config change and re-arm the app forever. A
   dedicated commit step
   pushes the two files to `data`. The watcher reads them next run to force-enable
   the queue (step 7c of `check_patch`, [above](#the-watcher-ciyml)).
7c. **Check whether anything needs publishing** (`build_check_no_change.sh`):
   `build/` empty plus `temp/unchanged/all.txt` (every artifact this pool built
   was an unchanged duplicate) → `HAS_NEW_FILES=false`, and steps 9–16 are all
   skipped — no numbered release, no manifest, no pointers, no archive upload,
   no website merge, no notification. The build number reserved in step 5 is
   simply unused: the counter reads existing releases/tags, so a no-change run
   leaves no gap. Anything else (including a failed build, which aborts before
   this step) keeps the chain enabled — the guard fails toward publishing,
   never toward silence. A no-change run also publishes no fingerprints: the
   already-live files match the state entries that suppressed them.
8. `update_usage_tracker.py` (`|| true`), `build_cache_cleanup.sh`, then the cache
   manifest (`size name` pairs) is hashed into the save key so a run that changed
   nothing does not re-upload 8 GB.
9. `build_get_output.sh` lifts `build.md` into a step output (and `build.tmp`,
   which the changelog step prefers as the source so the next build's `build.md`
   append does not corrupt it).
10. `build_make_manifest.py` → `temp/manifest/build.json`.
11. **Upload to release** (numbered): title `Build No. <code>`, body from
    `build.md`, `--prerelease` for beta.
11b. **Upload to archive repo (per-build mirror)** (`build_upload_release.sh`
    unchanged, `if: HAS_NEW_FILES && vars.ARCHIVE_REPO != ''`, `continue-on-error`,
    `id: archive_mirror`): mirrors the whole `./build/*` into `nullcpy/archive` under
    the same build-number tag while it is still complete (before the exclude trim in
    step 13), with the repository overridden via env and the archive-linked
    `build.archive.md` as the body, so files and their links agree. Opt-in: an unset
    `ARCHIVE_REPO` skips the step and changes nothing else
    ([decisions/0015](decisions/0015-builds-are-mirrored-to-a-permanent-archive-repo.md)).
11c. **Publish archive manifest** (`push_archive_manifest.sh`, gated on
    `steps.archive_mirror.outcome == 'success'`, `continue-on-error`): commits this
    build's `manifests/<tag>.json` to `nullcpy/archive`'s `website` branch (the branch
    is created from the default head when absent, and the blob updated in place by sha
    on a rerun; the base64 travels as a request body, never an argument, see
    [decisions/0015](decisions/0015-builds-are-mirrored-to-a-permanent-archive-repo.md)).
    Numbered-only — no cumulative `archive/<channel>.json` and no live-existence
    filter; a metadata-push miss fails soft, never reddening a run whose files shipped.
    It appends `PUBLISHED=true` to its step output only after the PUT returns.
11d. **Notify archive pages** (`gh api .../actions/workflows/pages.yml/dispatches`,
    gated on that `PUBLISHED` output, `continue-on-error`): asks `nullcpy/archive` to
    re-render its browsable site (the README surface on `main`, the Pages sources on
    `site`) from the manifests. The rendering workflow lives in the archive
    repo rather than here, and also runs on a schedule, so a lost dispatch delays the
    view instead of breaking it
    ([decisions/0016](decisions/0016-archive-pages-are-generated-markdown-on-main.md)).
12. **Update changelog and module update files**: `build_update_changelog.sh`
    checks out `update`, writes `changelogs/<code>.md` plus one JSON pointer per
    module zip, and lists the exact paths it created in `.updated_pointers`. The
    next step stages *those* paths explicitly — a `git add -A` on that branch
    would sweep in unrelated dirt. Runs only when modules were built.
13. `git checkout -f main` (dropping the `update` checkout) →
    `build_exclude_from_archive.sh` removes opted-out apps from `build/`.
14. **Upload to release (Archive)**: `continue-on-error: true`, assets only. It
    names no metadata at all, which is deliberate —
    [decisions/0001-release-metadata-ownership.md](decisions/0001-release-metadata-ownership.md).
15. `merge_archive_branch.sh` merges this build's manifest into the `website`
    branch. Must run **after** the archive upload so its live-asset filter sees the
    new files. Why manifests live on a branch at all:
    [decisions/0002](decisions/0002-manifests-live-on-a-branch.md).
16. **Merge published content hashes into state** (`build_merge_hashes.sh`):
    folds the fingerprints the engine recorded in `temp/hashes/append.*.tsv`
    into `state/build_content_hashes.json` — but only when the upload chain
    got through (the step also requires the archive upload not to have failed),
    and **per line**: a stem is adopted only when the artifact it stands for
    actually shipped (`build/` holds its `.apk` or module-`.zip` spelling) or it
    already has a state entry. The engine hashes at patch time, and a per-app
    stage after it (module packing, stock merge) can still fail while the run
    overall succeeds — without this filter a failed build would seed a
    fingerprint for a file nobody published. A hash becomes authoritative
    exactly when its artifact is live, per app, not per run. Kinds are credited
    the same way and **per spelling**: the entry keeps the kinds it already
    recorded plus `apk`/`module` for whichever of the two filenames reached
    `build/` this run, so a run whose module zip failed to pack cannot mint the
    evidence that would suppress a module later.
    `commit_data_branch.sh` then pushes the state file to `data` (only when the
    merge changed it; a failed data push is a warning, not a failure — the next
    run's fetch converges and the worst case is one redundant republish).
17. `build_notify_telegram.sh` posts the release to the channel's thread and to the
    broadcast channel, and mirrors the release text once to
    `DISCORD_WEBHOOK_BUILDER_LOG` (stable and beta share that one channel). Both services
    split it through `pack_message`, so a message never opens with an app's arch links
    separated from the app itself ([Where a message ends](#where-a-message-ends-notify_packsh)).
    `continue-on-error`: the chat, the channel and the topic come
    from variables only (no built-in handle), so an unset one fails this step — but
    the step runs last, after publishing, and a notification-config error must not
    turn a run whose files are already live into a failed build.
    It reads `NOTES_FILE`, which the workflow names `build.archive.md` only when the
    archive mirror (11b) landed and `build.md` otherwise, so a successful mirror makes
    Telegram and Discord link the permanent copy while a failed one — or a fork with no
    archive repo — keeps linking rvb and never advertises a file that is not there.

## Cleanup (`cleanup.yml`)

1. `ophub/delete-releases-workflows` deletes releases and tags, keeping the newest
   **98** and anything matching the keyword `stable`/`beta` — that keyword list is
   the only thing protecting the archive releases from deletion.
2. `cleanup-archive-assets.py` prunes each archive to the **2 newest versions per
   app + architecture** (grouping by `<app>-<arch>.<ext>`, newest by `created_at`).
3. `cleanup_update_branch.sh` drops update pointers and changelogs whose release is
   gone; `cleanup_website_branch.sh` drops `manifests/<tag>.json` for deleted
   releases.
3b. `cleanup_artifact_hashes.sh` prunes `state/build_content_hashes.json` against
   what actually lives on the releases (matching the `<stem>.apk` and
   `<…>-module-v<…>.zip` spellings, case-insensitively) — per spelling, so each one
   proves its own kind: an entry keeps exactly the kinds still downloadable and is
   dropped entirely when none survives. Being the only reader of real liveness, it
   is also the only place a lost kind can be re-proved, and it upgrades a bare-md5
   entry to `{hash, kinds}` from the asset names rather than leaving it unknown.
   This is a guard on the duplicate-build check, not tidying: an entry is the
   evidence that lets a rebuild be suppressed, so evidence for a deleted file must
   go with the file —
   otherwise a pinned rebuild would be "skipped" as identical to something
   nobody can download. It runs **after** the asset deleters so entries pruned
   in the same pass lose their guard in that pass; a failed releases listing
   aborts it loudly rather than pruning against an empty set. When it changed
   the file, `commit_data_branch.sh` pushes the pruned state to `data`.
4. A `catalog-updated` `repository_dispatch` to `vars.WEBSITE_REPO`
   (default `nullcpy/nullcpy.github.io`), authenticated with
   `WEBSITE_DISPATCH_TOKEN` falling back to `APKS_REPO_TOKEN`. `continue-on-error`,
   because the site also rebuilds on its own schedule — a lost dispatch delays the
   catalogue, it does not break it.

## Notify (`notify.yml`)

Two delivery models sharing one renderer (`notify_render.sh`), one target guard
(`notify_targets.sh`) and one message packer (`notify_pack.sh`):

The renderer writes **Telegram HTML** for every event, in the same shape the release
notes and the build queue use: one bold clickable headline (`<a href="…"><b>🔴 CI #336
failed</b></a> in <b>rvb</b>`) with its `  ╰ ` detail lines immediately beneath it — no
blank line inside an event, no per-line emoji, the status dot in the headline being the
only one in the message — and a blank line only between two events of a batch. Legacy
Markdown was abandoned here for two reasons — it cannot nest a link inside a bold run, so
a headline had to be either bold or clickable; and it has no escaping, so the old `md()`
helper *deleted* `* _ [ ] \`` from every title, mangling a PR named "Fix [rename] (v2)".
HTML needs only `& < >` escaped, so titles and branch names arrive whole. The event title
is additionally wrapped in `<code>`: it is the one string nobody controls, and `*`, `_`,
`[` and a backtick each mean something to one renderer or the other, so a PR called
"Fix *this* [that]" would otherwise arrive italicised with its brackets eaten. On the
Discord side a title holding a backtick is fenced with `` \`\` `` rather than a single
backtick, which is what lets it be shown literally. `queue.jsonl` needs no schema change:
its `text` field has always meant "whatever `notify_render.sh` emitted", and the queue is
empty between a burst and its drain (seconds), so no Markdown-rendered record can outlive
the switch.

- **`workflow_call` — immediate.** A caller (`ci.yml`/`manual-ci.yml`) invokes it on
  `failure()`; the `notify` job renders the generic "🔴 CI #N failed" alert via
  `notify_send_telegram.sh` and posts it at once. When the caller passes
  `already_reported=true` (Route B — the build's own Report-build-failures step
  already sent a per-app report) the script exits without posting, so a build
  failure is never double-messaged. Non-build failures (checkout, `check_patch`)
  never set the flag and still alert.
- **`issues` / `pull_request` — debounced batch.** GitHub fires one run per event and
  runs cannot share memory, so a burst (several issues closing at once) would
  otherwise post one message each. The `enqueue` job instead renders the event and
  appends it to `queue.jsonl` on the orphan `notify-queue` branch (self-created on
  the first append; the push-retry loop merges concurrent appends and never
  force-pushes), and the `drain` job — under concurrency `notify-debounce`,
  `cancel-in-progress: false` — sleeps `NOTIFY_DEBOUNCE_SECONDS` (60) then posts
  ONE batched message and prunes exactly the drained prefix. Later queued drains
  find the queue empty and no-op.

The log topic (`TG_THREAD_NOTIFY`) carries two independent messages, not one combined
report: the build job's per-app failure report and the watcher's build-queue notice are
sent by different steps, in different runs of the pipeline, and folding them together
would make a clean build that is about to happen announce nothing.

**No notification script names a chat.** Every `TG_*` target arrives from a
repository variable, and `tg_require_targets` refuses to send when one is unset:
the step fails with an `::error::` listing the missing names and no message goes
out. It used to be `${TG_CHAT_ID:-@handle}` / `${TG_THREAD_*:-<number>}` defaults at
each send site, which meant a renamed group or a misspelled variable kept posting to
the stale chat instead of saying so. A missing topic ID is an error too, not "no
thread" — in a forum group Telegram routes a threadless message to General, which
looks like a delivered notification. The guard runs after the `TG_TOKEN` skip (a
fork with no token still exits 0 quietly) and after each script's own "nothing to
send" early exit, so a clean run never fails over config nobody needed; a failed
drain leaves its queue lines on the branch for the next attempt.

### Discord mirror (`notify_discord.sh`)

Telegram is the author of every notification body and stays the result the run reports
on. Discord is a **mirror**: each send site calls `discord_send` once with the same text,
**as the script's last statement**, so a mirror problem can never hide the Telegram
result above it. Sinks are per Discord channel and addressed by webhook URL —
`DISCORD_WEBHOOK_PATCH_ALERT` for the watcher's patch/version notice,
`DISCORD_WEBHOOK_GITHUB_LOG` for the log topic's four message kinds plus the
announcements, `DISCORD_WEBHOOK_BUILDER_LOG` for the release text (one copy, whatever
Telegram topic and broadcast channel it also went to).

Two rules that are easy to get wrong and are enforced in the library, not at the sites:

- **Message size is counted in UTF-16 code units, not characters.** Discord charges 2000
  units and `bash` counts a leading emoji as one character while the API charges it as
  two, so a char-counted budget can be twice too generous and the post is rejected. The
  library passes its own measure (`_pack_len_units`, one `jq` pass per block) to
  `pack_message`, which is where the splitting itself happens — see
  [Where a message ends](#where-a-message-ends-notify_packsh) for why the mirror and the
  Telegram send break at the same places. The dialect shift (`*x*` → `**x**`,
  `<b>` → `**`, `&amp;` → `&`) runs under `LC_ALL=C` for the same byte-vs-character
  reason: under a UTF-8 locale `sed` mis-matches the emoji that leads every header. The
  HTML unwrapping also has to run **inside-out** — a bundle heading is `<b>` around an
  `<a href>`, so the link must become `[v1.57.0](url)` before the `<b>` rule (which
  cannot cross a `<`) will match the heading at all.
- **A copy must not break a resend contract.** `notify_drain.sh` is the one site that
  treats a mirror failure as best-effort (`|| true`): a non-zero there would skip the
  prune, the queue would keep its lines, and the next drain would re-post the whole batch
  to Telegram to repair a Discord hiccup. Every other site has no such contract, so it
  propagates the failure and the step shows red.

An unset webhook is a **skip**, not a configuration error — unlike `TG_CHAT_ID`, whose
absence is an error precisely because a *default* chat exists to be wrong about. Here the
URL is both the destination and the credential, so there is nothing to guess: no channel
means that sink is not mirrored, and a fork holding neither credential stays silent. The
URL therefore lives in repository **secrets** (it carries its token), never in a variable
and never in a file in this repo, and it is deliberately absent from every log line the
library writes. `allowed_mentions: {parse: []}` is sent on every message, because a PR or
issue title containing `@everyone` would otherwise ping the whole server, and
`flags: 4` (SUPPRESS_EMBEDS) with it — that is the webhook form of the
`disable_web_page_preview=true` every Telegram send already passes. It is not a
formality: `[label](url)` unfurls into a preview card on Discord while showing nothing but
the label in a Telegram topic, so a release note carrying six arch links arrives as six
stacked images unless the flag is set (measured: the same text yields `embeds: 2` without
it and `embeds: 0` with it, read back from the created message via `?wait=true`). Two
things the flag does not cover, and neither has a sender-side switch: a `discord.gg`
invite is rendered as a server-invitation **component** rather than a link embed, and
`[label](<url>)` — the documented text form that stops ordinary unfurls — does not stop
that either (measured: the card survived both). So the mirror **repoints an invite link**
to the broadcast channel instead: `[Channel](https://t.me/s/<handle>)`, the URL derived
from `TG_CHAT_ID_BROADCAST` rather than written out a second time, with the footer's own
💬 replaced by the 📣 the channel uses everywhere else. A join link is worth nothing to a
reader already in the server; on Telegram and in the GitHub release body the footer keeps
the invite. No notifier body writes a bare URL, so that one pass covers every sink.

### Where a message ends (`notify_pack.sh`)

Every body too long for one message is split by `pack_message`, which packs **blocks**,
not lines. A block is a paragraph — consecutive lines with no blank line between them —
and that is the grammar these notices are written in: an app entry is its `• App vX` line
plus the `  ╰ APK:` / `  ╰ Module:` lines under it, and those lines mean nothing apart.
The chunkers this replaced filled messages line by line, so a long release produced
messages that opened with an orphan `╰ APK:` under no app name at all, and section
headings that ended one message while their content went in the next.

A caller names what a heading looks like in its own dialect (`^<b>.*</b>$` for the release
notes, `^\*.*\*$` for the Markdown reports, `^\*\*.*\*\*$` for converted Discord text) and
the packer glues each heading to the block under it, so a boundary can never fall between
them. The one thing it cannot honour: a single block larger than the limit is still split
(on a line boundary, then a space, then hard), which is the only remaining case
where a continuation appears without its heading — unreachable for these bodies, since the
largest block is one app with two arch links.

`ci_notify_queue.sh` keeps its own assembly loop: it decides group boundaries while it
builds the notice (a group too big for one message repeats its header), which is a
stronger guarantee than packing finished text, so it is left alone and only its output is
mirrored.

The queue is append-only and every plumbing call pins `core.autocrlf=false` /
`core.eol=lf`, so the JSONL bytes (and the drain's prefix prune) do not depend on
the runner's git config.

## Required secrets and variables

| Kind | Name | Used by | Notes |
|---|---|---|---|
| secret | `GITHUB_TOKEN` (auto) | all | `contents: write` on the jobs that push branches |
| secret | `KEYSTORE_B64`, `KEYSTORE_P12_B64`, `KEYSTORE_PASSWORD`, `KEY_ALIAS` | build | signing identity; **all four required** — `install_keystore.sh` fails the run when any is missing and no keystore ships in the repo ([decisions/0008](decisions/0008-signing-identity-is-secret-only.md)) |
| secret | `APKS_REPO_TOKEN` | build, cleanup | cross-repo write to `nullcpy/apks`, doubles as dispatch token |
| secret | `ARCHIVE_REPO_TOKEN` | build | cross-repo write to `nullcpy/archive` (per-build mirror + manifest push) and the `workflow_dispatch` that rebuilds its pages, which needs Actions write; with `ARCHIVE_REPO` unset the whole feature is off |
| secret | `CODEBERG_TOKEN` | watcher | raises Codeberg/Forgejo rate limits |
| secret | `TG_TOKEN`, `WEBSITE_DISPATCH_TOKEN` (optional) | notify steps | |
| secret | `DISCORD_WEBHOOK_PATCH_ALERT`, `DISCORD_WEBHOOK_GITHUB_LOG`, `DISCORD_WEBHOOK_BUILDER_LOG` (optional) | notify steps | per-channel Discord mirrors; unset means that sink is not mirrored ([§Discord mirror](#discord-mirror-notify_discordsh)) |
| var | `APKS_REPO`, `WEBSITE_REPO` | build, cleanup | alternate cache/site repos for forks |
| var | `ARCHIVE_REPO` | build | the permanent mirror repo (`nullcpy/archive`); **unset disables the whole archive feature** — no mirror, no manifest push, no page rebuild, notes stay rvb-linked ([decisions/0015](decisions/0015-builds-are-mirrored-to-a-permanent-archive-repo.md)) |
| var | `TG_CHAT_ID`, `TG_CHAT_ID_BROADCAST`, `TG_THREAD_CI`, `TG_THREAD_STABLE`, `TG_THREAD_BETA`, `TG_THREAD_NOTIFY`, `TG_THREAD_ANNOUNCE` | notifications | the chat handle and every topic ID come from here only, and an unset one fails its notify step (see the target guard above) instead of falling back to a written-in chat; `TG_THREAD_NOTIFY` is the log topic and receives two separate kinds of message — the per-app build/download failure report, and the watcher's build-queue notice listing what the run resolved to build; `TG_THREAD_ANNOUNCE` is the announcement topic — config additions and config-change rebuild notices together (that step is `continue-on-error`, so an unset one only skips the notice). It replaced `TG_THREAD_NEWAPPS`, which pointed at the same topic under the narrower name |
| var | `RELEASE_NOTES_DISCORD_LINK`, `RELEASE_NOTES_DONATE_LINK`, `RELEASE_NOTES_WEBSITE_LINK` | build, watcher | the footer links of the generated release body; `RELEASE_NOTES_WEBSITE_LINK` doubles as the announcement's download link (`WEBSITE_LINK`). No URL is written into the workflows or the scripts, so an unset var drops its entry — the announcement loses the whole download line — instead of inventing a target |
| var | `RVB_MORPHE_PASSTHROUGH` | build | bundle handling escape hatch |
| var | `RVB_MORPHE_STRIPLIBS` | build | bisect switch for morphe's own `--striplibs`, which is then the **only** native-lib strip a plain-APK input gets — the engine stops rewriting that input, because deleting entries from it would delete its signing block ([build-engine.md](build-engine.md)); `false` restores the engine `zip -d` rewrite and drops the flag (bundle trims are unaffected) |

## Log conventions

The Actions log is a product surface here: 60+ apps × several arches in parallel,
and a maintainer reads it on failure.

- `::group::` / `::endgroup::` wrap each build (in pooled mode the parent emits
  them while replaying a child's log, in completion order).
- Engine messages go through `pr` / `wpr` / `epr` (green `+`, `!`, red `-`) and
  `abort` for fatal ones.
- The asset uploader marks each file's progress with `⬆️` (start) and `✅`
  (uploaded), and reports a failed attempt as `::warning::Attempt n/3 failed for
  <file>` before the final `::error::` — so a scan of the log locates the failing
  file.
- `::warning::` and `::error::` are reserved for annotatable problems, and a
  validation rejection that must stop the job writes `::error::` **and** exits
  non-zero (see `IS_PRERELEASE` handling in the uploader).

## Testing a pipeline change

| Change | Cheapest honest verification |
|---|---|
| Engine functions (`utils.sh`) | `bash .github/traces/trace_runner.sh verify` — offline, no network |
| A shell script CI calls | a stubbed-binary harness in `temp/` (see [contributing.md](contributing.md)) |
| Release/upload behaviour | the metadata matrix harness + a `workflow_dispatch` of Manual CI against `configs/config.manual.toml` |
| Watcher gating | Manual CI with a chosen config, or read the previous run's flags in the Actions UI |
| Website-facing formats | rebuild the site catalogue with `dry_run: true` on `rebuild-catalog.yml` |
