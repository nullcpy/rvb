# Trace harness (P0)

Offline regression gate for the patcher-tool branches of `utils.sh`.
Runs the engine's tool-decision functions against stubbed `curl`/`java` and
local release fixtures — no network, no real patching — and records the exact
`java` argv the engine builds per tool kind. The result is the contract P1+
must preserve.

## Usage

```bash
bash .github/traces/trace_runner.sh capture   # (re)write goldens after intentional changes
bash .github/traces/trace_runner.sh verify   # gate: compare against goldens (exit 1 on drift)
```

Runs on Git Bash and plain Linux. Requires: bash, jq, sed (GNU), python3 with
`tomllib`/`toml` fallback (only for TOML parsing via `utils.sh`'s own chain).
`bin/toml/tq-<arch>` is used automatically if present.

## What is exercised

Per fixture in `fixtures/configs/` (one per patcher kind + edge cases):

- `_get_prebuilts` — release listing, prerelease/stable pick, asset filtering
  (`.jar/.zip` for CLI; per-tool bundle globs `.rvp|.mpp|.jar` vs `.apk`),
  download, `tag_name.txt`, more-than-one-asset fallback order
- `_patches_list_versions`, `patches_list` — per-tool subcommand + flags
- `has_compatible_patches` — version-match hit/miss rc
- `patch_apk` — the full argv: keystore flags, `-p`/`--patches` placement,
  per-bundle `-e/-d` (via engine `join_args`), `-b` on revanced-cli, long/short
  fallback behavior, output recovery for npatch/lspatch/instafel
- instafel — jar-shadowing cp side effects (files exist but are not asserted),
  init/run/build sequence, clone APK selection

`goldens/<name>.trace` = human-readable results section, then every stubbed
`java` argv (via the `utils.sh` `java()` wrapper, so `--enable-native-access`
shows too). Paths under the run dir normalize to `<RUN>`; ANSI colors stripped.

## Deliberately NOT exercised (diff by eye during P1)

- `build_rv` internals that need a real patched APK: exp-version guards
  (`utils.sh:2581/2848`), `--mount` module decision (`3250-3255`), microg
  `-e/-d` juggling (`3223-3246`), arch `zip -d` stripping, module packaging.
- `_get_patch_last_supported_ver` / versionCode cache paths (need real bundle
  metadata).

## Adding a fixture

1. `fixtures/configs/<name>.toml` — any cli-source/patches-source combo.
2. Add matching release JSONs in `fixtures/releases/<owner>__<repo>.json`
   (array of GitHub release objects; asset `url`s must be `https://fake.asset/*`).
3. `trace_runner.sh capture`, review diff, commit.
