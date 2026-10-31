# Decision records

Short, append-only notes answering a question the code cannot answer: *why is it
this way, and what did we try instead?*

Write one when a future reader (human or agent) could plausibly "fix" the thing
back. The code comment that guards the rule should link here, and the file should
name the verification that keeps the rule true.

## Format

```markdown
# NNNN — <title in present tense>

**Status:** accepted (YYYY-MM-DD) | superseded by NNNN | deprecated
**Affects:** <paths, branches, wire formats, external state>

## Context        what the situation was, and what broke or nearly broke
## Decision       the rule, stated so it can be checked
## Rejected alternatives   each one, with the reason — this is the section that
                          stops the same idea being re-implemented in six months
## Consequences    what is now someone else's problem, and how to recover it
## Verification    the test or command that keeps the decision true
```

Number files monotonically, never renumber or delete one; supersede instead. Keep
each under ~100 lines — if it needs more, it is two decisions or an architecture
document.

## Index

| # | Decision | Affects |
|---|---|---|
| [0001](0001-release-metadata-ownership.md) | Release metadata is owned by whoever names it | release uploads, archive releases |
| [0002](0002-manifests-live-on-a-branch.md) | Build manifests live on a branch, not on releases | `website` branch, archive merge, catalogue rebuild |
| [0003](0003-blocked-patch-sources-are-skipped.md) | A blocked patch source is skipped, never re-queried | watcher state, `get_prebuilts` |
| [0004](0004-no-download-prewarm-pass.md) | No download prewarm pass; fetching stays inside each build | build pool, download flock, `RVB_DL_MAX_TIME` |
| [0005](0005-tuning-knobs-live-in-the-workflow.md) | Build tuning knobs live in the workflow's env block | `PARALLEL_JOBS`, `UPLOAD_CONCURRENCY`, no config keys |
| [0006](0006-filename-parsing-is-imported-not-mirrored.md) | Filename parsing is imported across the repo boundary, never mirrored | `naming.py`, the site's catalogue rebuild |
| [0007](0007-requested-arch-is-a-hard-requirement.md) | A requested build arch is a hard requirement; no mislabeled artifacts | `build_rv` download gate, download-link index, published arch names |
| [0008](0008-signing-identity-is-secret-only.md) | The signing identity is a secret, never a repository file | `install_keystore.sh`, `RVB_KEYSTORE*`, keystore secrets, every published artifact's signer |
| [0009](0009-effective-patch-set-decides-compatibility.md) | The patch set that will be applied decides compatibility | `has_compatible_patches`, version resolution, candidate arch filter, `temp/failures/*_np.json` |
| [0010](0010-config-change-pending-builds.md) | Config changes and build failures drive a pending-build list | `ci_detect_config_changes.sh`, `build_update_retry_list.sh`, `state/built_shape.json`, `state/pending_builds.json`, `TRIGGER_CONFIG_CHANGE` |
| [0011](0011-version-code-fallback-to-arch.md) | A pinned version code is a preference; the arch wins when the bundle is wrong | `dl_apkmirror`, `build_rv` re-key, `temp/failures/*` `vc_fallback`, retry parking |
| [0012](0012-direct-source-identity-comes-from-its-artifact.md) | A direct source's identity comes from its artifact, not its URL | `direct-dlurl`, `get_direct_resp`, `dl_direct`, `build_rv` re-key and compatibility re-check |
| [0013](0013-an-fdroid-source-asks-the-repo-what-it-publishes.md) | An F-Droid source asks the repo what it publishes | `fdroid-dlurl`, `get_fdroid_resp`, `dl_fdroid`, `DL_SRCS` order, F-Droid fixtures |
| [0014](0014-config-changes-that-earn-a-rebuild.md) | Only a config change that earns an artifact may force a rebuild | `retry_tracked_keys`, `state/built_shape.json` `{arches, cfg}`, `reason: "config"`, `changed_apps.json`, `state/build_content_hashes.json` `{hash, kinds}`, `check_duplicate_build` |
| [0015](0015-builds-are-mirrored-to-a-permanent-archive-repo.md) | Builds are mirrored to a permanent archive repo | `build.yml` mirror + manifest steps, `ARCHIVE_REPO`/`ARCHIVE_REPO_TOKEN`, `nullcpy/archive` + its `website` branch, `build.archive.md`, notify link targets |
| [0016](0016-archive-pages-are-generated-markdown-on-main.md) | The archive is generated markdown on its own branches | `build_archive_pages.py`, `nullcpy/archive` `main` README + `site` Pages sources, its `pages.yml`, `Notify archive pages` step, `PUBLISHED` output |

Candidates still unwritten, because the reasoning currently lives only in commit
messages: pinning a patch source's `patches-version` to a tag vs resolving the
keyword from the state snapshot (2fced014), the APKMirror variant picker — split
bundle before plain APK, lowest `Minimum Version` first, a pinned versionCode as a
filter rather than an answer (20eb4e5a) — and why the archive release is the download
target for module update pointers rather than the numbered release.
