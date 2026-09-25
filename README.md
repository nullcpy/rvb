# data branch — configs & state, never code

Everything here is consumed by jobs that run
`.github/scripts/fetch_data_branch.sh` right after checkout. Paths are contracts:
generators, watcher, and builds all reference them verbatim.

## Layout

- `configs/` — build inputs
  - `config.manual.toml`, `patches/*.toml` — **human-authored** app/patch
    configs. They live here only; main's tree is pure code. Edit them in a
    normal main checkout (the paths are gitignored there), then publish with
    `bash .github/scripts/push_data_configs.sh "<commit message>"`.
  - `stable-build.json`, `beta-build.json` — generated pool configs, written
    by the ci.yml watcher, consumed via the `config_file` workflow input.
- `state/` — watcher-owned machine state (never hand-edit except recovery):
  - `patch_sources.json` — latest known release of every patch-source repo
  - `app_versions.json` — last-known app version per package (+ `_check_only_listed`)
  - `patch_file_hashes.json` — patch-file content hashes for change detection

## Writers

| Path | Writer | Trigger |
| --- | --- | --- |
| `configs/*.toml`, `configs/patches/*.toml` | human via `push_data_configs.sh` | on config change |
| `configs/*-build.json` | `commit_data_branch.sh` (ci.yml watcher) | scheduled run, when changed |
| `state/*.json` | `commit_data_branch.sh` (ci.yml watcher) | scheduled run, when changed |

The watcher only ever commits `*.json`; the human tool only ever commits
`*.toml`. Neither can clobber the other's files. Single watcher (concurrency
group `ci`); both writers use plumbing (temp index + commit-tree) and a
fetch-retry loop — on a race, the later push's changed files win per-file.

## Recovery

- `state/*` is regenerable: the watcher rebuilds patch sources and version
  baselines over successive runs (a lost baseline causes one full check pass).
- `configs/*` is the **sole authoritative copy** of the app knowledge — if it
  is lost, restore from any maintainer clone's ignored working copies, or from
  this branch's git history (`git log --diff-filter=D`).
