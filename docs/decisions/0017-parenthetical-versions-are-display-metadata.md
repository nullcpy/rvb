# 0017 — A parenthetical version annotation is display metadata

**Status:** accepted (2026-11-18)
**Affects:** `scripts/utils.sh` (`_ver_key`, `build_rv`'s `version_f` label,
`_rekey_to_bytes`, `_cached_identity_disagrees`), `docs/build-engine.md`,
`.github/traces/test_artifact_identity.sh`

## Context

Upstream commit `hyzor/hyzor-morphe-patches@5be3bb31` moved Nova Launcher to 8.9.7 and
changed its patch target to `AppTarget(version = "89700 (8.9.7)", versionCode = 89700)`.
That is not the patch author being verbose: Nova's own `versionName` really is
`89700 (8.9.7)`, and Morphe compares `versionName` as-is, so the build number is part of
the target string.

The engine already reduced such a listing to the bare key `89700` when resolving a
version (the greedy ` (.* patch.*` strip in `get_patch_last_supported_ver`), and the
pre-download compatibility gate passed on `89700`. But the post-download identity gate
reads the artifact's `versionName` and canonicalises it with `_ver_key`, which only
removed whitespace and a leading `v`. The bytes therefore folded to `89700(8.9.7)`, a
string no patch covers, so `_rekey_to_bytes` discarded every fetch that *had* succeeded:
APKMirror and Uptodown were dropped as "no compatible patches", APKPure returned 403,
APKCombo had no link, and both `NovaLauncher-hyzor` arches went unbuilt in CI run
44138265442. The same fold drives `_cached_identity_disagrees`, so once a `89700` cache
entry existed it would have been invalidated on every run.

## Decision

`_ver_key` — the engine's one canonical version form — strips whitespace, then a
**trailing digit-leading parenthetical**, then one leading `v`/`V`. `build_rv` derives
`version_f` through it too, so filenames, cache keys, gates and reports all speak the
same key and a configured full version string cannot leak parentheses into the frozen
filename grammar.

The digit-leading restriction is part of the rule: `89700 (8.9.7)` folds to `89700`, but
a textual flavour suffix like `1.0 (beta)` stays `1.0(beta)` and still reads as a
different build. A parenthetical is not automatically ignorable.

## Rejected alternatives

- **Strip every trailing `(...)`.** Simpler, but it would silently merge flavours whose
  distinguishing token is textual, reintroducing the "two flavours, one number" failure
  that [0012](0012-direct-source-identity-comes-from-its-artifact.md) fixed.
- **Pin `89700` in the app's TOML.** The pre-download label was already `89700`; the
  failure is in the bytes-side fold, so a config change cannot reach it.
- **Narrow `get_patch_last_supported_ver`'s strip so the full string is resolved.** That
  would make the advertised version and the bytes-side label agree only by accident,
  and would put parentheses into `version` (and any report quoting it), while the patch
  bundle's key is the bare number. One fold, applied on both sides, is the invariant.
- **Special-case Nova by package name.** The vendor format is not Nova-specific; a
  per-app exception leaves the next vendor with the same breakage.
- **Ask the patch author to stop printing the parenthetical.** The patch target must
  match the APK's real `versionName`, which is the vendor's choice. Our canonical form
  is ours to fix.

## Consequences

- A vendor's numeric annotation no longer changes the build key, so the honest bytes
  label and the patch bundle's key stay identical through download, cache and release.
- A parenthetical whose content does not start with a digit still denotes a distinct
  version and is refused by the compatibility gate if the bundle does not cover it —
  deliberately loud, not a guess.
- Version keys never contain parentheses, so the frozen filename grammar and the
  website's shared `naming.py` parsing are unaffected.

## Verification

`.github/traces/test_artifact_identity.sh` asserts the fold on both sides: a bytes
`versionName` of `89700 (8.9.7)` against label `89700` neither re-keys nor re-runs the
gate, a cached file with that `versionName` is not treated as a false name, and a textual
`1.0 (beta)` still re-keys and re-runs the gate (negative control). The helper assertions
cover spaced and joined numeric parentheticals, a plain version, and the textual case.
`bash .github/traces/trace_runner.sh verify` stays green with unchanged goldens.
