# Contributing

Two very different contributions live here. Pick yours first — most of the value
in this project comes from the first one, and it needs no code.

| I want to… | Touch | How |
|---|---|---|
| add an app, enable/disable a patch, change a variant or channel | a TOML on the `data` branch | [below](#changing-app-configurations-the-common-case) |
| fix a build failure, scraper, uploader, workflow | `main` | [below](#changing-code) |
| report something | nothing | [issue templates](../.github/ISSUE_TEMPLATE) (yes, website issues are filed here too), or the Telegram group |
| patch a patch problem | nothing here | the patch author's repository — this builder only assembles what they publish |

## Changing app configurations (the common case)

Config lives on the **`data`** branch under `configs/patches/*.toml`, one file per
patch-source family, with file-level defaults above the first `[table]`.
Every key is documented in [CONFIG.md](../CONFIG.md); read that rather than
copying a neighbour's guess. The rules that people get wrong:

- **Channel is routing, not versioning.** `patches-version` is `stable`, `beta` or
  `both` (or a concrete tag to pin). Omitted means "inherit the file default", and
  the file default is `stable` unless the filename carries `.beta.`. `both` opts an
  app into both pools — an app with no explicit setting does **not** get both.
- **A mistyped channel is treated as a tag**, so `patchs-version = "stble"` fails
  loudly on the release lookup instead of quietly landing in the wrong pool.
- **Patch names in include/exclude lists must be quoted** — the parser splits on
  quoted tokens, and `build.sh` rejects an unquoted list.
- **`inclusive-patches` and `exclusive-patches` are opposites**; setting both is a
  hard error.
- `enabled = false` disables an app in every pool. Deleting a config block instead
  leaves the generated pool entry until the watcher regenerates, and a *renamed*
  file must be removed from `data` explicitly — the TOML publisher cannot delete.

### Publish it

```bash
bash .github/scripts/fetch_data_branch.sh            # materialise configs/ + state/
# edit configs/patches/<family>.toml in the working tree (these paths are ignored on main)
bash .github/scripts/push_data_configs.sh "feat(config): add Pinterest builds"
```

`fetch_data_branch.sh` **overwrites** local `configs/`, so publish before you
fetch, not after. For a one-off hand edit you may also `git switch data`, commit,
push, `git switch main` — then re-run the fetch, because switching clobbers the
ignored local copies.

Your change takes effect on the next watcher run (every 4 hours): the pool configs
are regenerated from your TOML and the affected app gets built. To verify
immediately instead of waiting, run **Manual CI** (`workflow_dispatch`) against
`configs/config.manual.toml` — a hand-built config that never touches the pools.

## Changing code

### Local setup

```bash
git clone <this repo> && cd rvb
bash .github/scripts/fetch_data_branch.sh    # you cannot build or test without this
```

Requirements: bash 4+ (the project's tests are written against bash 5.x under Git
Bash on Windows), GNU `sed`, `jq`, `python3` (3.11+ for `tomllib`), `zip`,
Java 21 for real builds, and `dos2unix` where CI normalises `utils.sh`.
Line endings are enforced by [.gitattributes](../.gitattributes): scripts, JSON,
YAML and TOML are LF everywhere. If your editor writes CRLF into a `.sh`, the
trace goldens will fail on byte comparison.

[.editorconfig](../.editorconfig) keeps the working copy in that shape rather than
letting a save undo it: LF, UTF-8, a final newline, tabs for shell (every script here
is tab-indented), two spaces for YAML, JSON, HTML and CSS, four for Python. Its
`.github/traces/**` section turns the newline and trailing-space rules off on purpose:
21 captured fixtures end without a final newline because that is how the upstream
response arrived, and several `.trace` goldens carry trailing spaces the runner
emitted, so "tidying" one rewrites a byte-compared file. The part editorconfig cannot
express is in [.vscode/settings.json](../.vscode/settings.json): the formatter is off
for markdown, YAML, shell and JSON, where a rewrite changes behaviour rather than
appearance (JSON state and fixtures are defined to be byte-identical to what `jq`
writes). Python keeps its formatter.

Run a build locally to see the engine work end to end. It will refuse to start
without a signing identity, on purpose: every artifact this project produces is
signed, and the repository ships no keystore (the template's had a public private
key - see [decisions/0008](decisions/0008-signing-identity-is-secret-only.md)). In
CI the identity arrives from the four `KEYSTORE_*` secrets, so a local run has to
supply the same four variables itself:

```bash
export RVB_KEYSTORE=~/keys/ks.keystore           # BKS:    Morphe / ReVanced CLI, NPatch
export RVB_KEYSTORE_P12=~/keys/ks-p12.keystore   # PKCS12: apksigner, LSPatch
export RVB_KEYSTORE_PASS=<alnum-only>            # one password: store AND key
export RVB_KEY_ALIAS=<alias>                      # one alias, present in both stores
bash scripts/build.sh configs/config.manual.toml
```

`build.sh` checks all of this before the first download and names whatever is
missing. The password has to be alphanumeric because it is interpolated into
`eval`'d CLI arguments.

To get a throwaway pair for engine experiments (never the release key), one key
stored in both formats:

```bash
keytool -genkeypair -alias test -keyalg RSA -keysize 2048 -validity 10950 \
  -storetype PKCS12 -keystore ks-p12.keystore -storepass "$PASS" -keypass "$PASS" \
  -dname "CN=test"
keytool -importkeystore -providerpath bcprov-jdk18on-<ver>.jar \
  -providerclass org.bouncycastle.jce.provider.BouncyCastleProvider -providername BC \
  -srckeystore ks-p12.keystore -srcstoretype PKCS12 -srcstorepass "$PASS" -srcalias test \
  -destkeystore ks.keystore -deststoretype BKS -deststorepass "$PASS" -destalias test
```

The second command needs a BouncyCastle provider jar because a stock JDK has no BKS
type (`keytool error: java.security.KeyStoreException: BKS not found` is that gap
talking). And never put a keystore path with its password into `configs/**`: the
`data` branch is public.

Expect it to need real network access to the stores. Module auto-update is
disabled locally by design (there is no published `update` branch for a local run
to point at), and output lands in `build/` with `build.json` + `build.md`
describing it. `bash scripts/build.sh clean` resets.

### Test what you changed

| Layer | Command | Notes |
|---|---|---|
| Patcher/tool decisions in the engine | `bash .github/traces/trace_runner.sh verify` | offline; stubbed `curl`/`java` + fixtures; runs on push to `build.sh`/`utils.sh`. After an *intentional* argv change: `… capture`, read the diff, commit the goldens |
| Cache / bundle / arch-strip / patch-version / store-picker / store-release-lookup / download-source helpers | `bash .github/traces/test_cache_helpers.sh`, `bash .github/traces/test_bundle_helpers.sh`, `bash .github/traces/test_arch_strip.sh`, `bash .github/traces/test_patch_versions.sh`, `bash .github/traces/test_apkmirror_variants.sh`, `bash .github/traces/test_apkmirror_release_lookup.sh`, `bash .github/traces/test_direct_source.sh`, `bash .github/traces/test_fdroid_source.sh` | same job |
| Watcher retry / re-arm state machine | `bash .github/traces/test_config_rearm.sh` | drives `ci_detect_config_changes.sh` + `build_update_retry_list.sh` in sandbox trees; no network, no repo state touched |
| A CI shell script | a stubbed-binary harness under `temp/` | convention below |
| Website-facing formats | `rebuild-catalog.yml` with `dry_run: true` | see [website-contract.md](website-contract.md) |

The `temp/` harness convention, because it is how most bugs in this repo got
pinned down: `temp/` is gitignored, so a harness there is a *maintainer's* test,
not a CI gate. The pattern that works is a stub directory first on `PATH`
(`stub/gh`, `stub/curl`) that appends every invocation to a log, then assertions
about which flags actually reached the tool. Two lessons baked into the habit:

- **Guard against escaping the sandbox.** Resolve the repo root with `cygpath` and
  refuse to run if it is not the expected checkout, before any `rm`/`git` in the
  script touches disk. MSYS2 also rewrites arguments that look like paths unless
  `MSYS2_ARG_CONV_EXCL` is set.
- **An absence check needs a negative control.** Asserting "the flag was not
  passed" proves nothing if the same harness cannot also show the flag *being*
  passed. Keep the `true`/`false` cases next to the "unset" case.

### Shell rules this codebase follows

- `set -euo pipefail` at the top of every script.
- The engine assembles patcher argv as strings that are later evaluated, which is
  why quoting must happen in exactly one place — `join_args` in `utils.sh` for
  `-e`/`-d` patch lists. Never add a second quoting site or a hand-built `eval`:
  patch names contain apostrophes and that is a known failure class, not a
  hypothetical.
- A `[ … ] && var=value` short-circuit list is fine as a statement, but a chain
  whose *final* command may not run will abort the step under `set -e` before
  outputs are written. Write `if` blocks when the thing after it is `$GITHUB_OUTPUT`.
- Reset `local` variables in functions that are called repeatedly with
  `local var=${1:-}`-style initialisers rather than relying on the previous value
  being gone.
- Command substitution swallows side effects: anything that mutates a shared cache
  or global must be called directly.

### Commits

- [Conventional Commits](https://www.conventionalcommits.org/): `fix(ci): …`,
  `refactor(build): …`, `feat(config): …`, `perf(build): …`, `docs: …`,
  `test: …`, `chore: …`. Scope is the subsystem, not the file.
- **One logical step per commit.** A fix and the test that pins it belong
  together; adjacent cleanups do not.
- Multi-line messages go through a file (`git commit -F temp/_commit_msg.txt`) so
  the shell cannot mangle quoting; the body explains *why*, since the diff already
  shows *what*.
- Never `git add -A`. `configs/`, `state/`, `temp/`, `build/`, `build.json`,
  `build.md` and the watcher's working files are ignored on `main` for a reason,
  and a stray `git add` of them either fails silently or commits materialised data
  into code history.
- Do not merge or push on someone's behalf without being asked; a push to `main`
  changes the next scheduled run, and nothing runs on push except Trace Verify.

### Pull request checklist

1. `bash .github/traces/trace_runner.sh verify` passes (if you touched the engine).
2. Any new/changed wire format is reflected in
   [storage-and-branches.md](storage-and-branches.md) and, if it crosses the seam,
   in [website-contract.md](website-contract.md). Filename-parsing rules belong in
   `.github/scripts/naming.py` only — the site imports it, so never add a copy.
3. Behaviour docs updated where the behaviour is documented
   ([ci-pipelines.md](ci-pipelines.md) for steps/ordering,
   [build-engine.md](build-engine.md) for engine stages).
4. A load-bearing decision that someone might undo got a numbered file in
   [decisions/](decisions/) and a pointer to it from the code.
5. No `configs/`, `state/`, `temp/` or generated artifacts in the diff.

## Reading the running system

```bash
gh run list --repo nullcpy/rvb                     # recent CI / Build / Cleanup runs
gh run view <id> --log-failed                      # the failing step, filtered
gh api repos/nullcpy/rvb/releases/tags/stable -q '.assets[].name'   # what is downloadable now
git fetch origin website && git show FETCH_HEAD:archive/stable.json | jq '.files | length'
```

`state/`, the pool configs and the `website`/`update` branches are all readable
without any privileged access, which is what makes a bug report actionable.
