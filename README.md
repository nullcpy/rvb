# data branch — generated CI state (machine-owned)

`configs/*.json` files that the CI watcher regenerates constantly.
They live here instead of main so main's history contains only human
decisions. Consumers materialize them with `fetch_data_branch.sh` (workflows
`ci.yml` and `build.yml` run it right after checkout).

| File | Written by |
|---|---|
| patch_sources.json, patch_file_hashes.json | sync_patch_sources.py |
| app_versions.json | ci_fetch_app_versions.sh |
| config.stable.updated.json, config.beta.updated.json | ci_compile_base_configs.sh + ci_generate_configs.sh |

Rules:
- Single writer: the ci.yml watcher (via `commit_data_branch.sh`, ci
  concurrency group). Never edit files here by hand.
- Human-edited config (per-app TOMLs, config.manual.toml) lives on main —
  this branch deliberately carries none of it so fetches can't clobber it.
- Lost branch? Recover: `bash temp/seed_data_branch.sh` (or restore a state
  commit from this branch's own history).
