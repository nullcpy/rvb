#!/usr/bin/env python3
"""
compile_patch_configs.py
Parses all TOML patch configurations in configs/patches/
and generates config.stable.json and config.beta.json with dynamic pool routing:
- apps with patches-version = "stable" go to stable pool only
- apps with patches-version = "beta" go to beta pool only
- apps with patches-version = "both" go to both pools
- apps with no patches-version inherit the file-level default, which is itself
  "stable" unless the filename carries .beta. — so such an app lands in
  one pool, not both. "both" is what opts an app into both.
- apps with enabled = false are omitted

Which release a channel keyword means is not resolved here: the generated config
keeps the keyword and the build looks the tag up in state/patch_sources.json. A
concrete patches-version (a tag instead of a channel) is copied verbatim, and the
pool it joins is decided by the pre-release markers in that tag (channels.py), the
same list the watcher and the release picker read.
"""

import os
import sys
import glob
import json

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import jsonfmt  # isort:skip  # noqa: E402
import channels  # isort:skip  # noqa: E402

try:
    import tomllib
except ImportError:
    try:
        import tomli as tomllib
    except ImportError:
        print("Error: neither tomllib nor tomli is available.", file=sys.stderr)
        sys.exit(1)

# Every config key the builder and the watcher understand. The list was taken from
# what the code actually reads (`toml_get "$t"` / `toml_get "$main_config_t"` in
# scripts/build.sh, plus `patch-folder` in ci_check_app_patches.py), not from what
# upstream ReVanced Manager documents — that distinction matters: mount-*,
# compress-module-files, override-version-code, use-prebuilt-apks and fdroid-index are
# all real upstream names or real temp-file names here, and none of them is a key this
# builder reads, so accepting them would have let a typo pass as valid.
#
# An unrecognised key is a hard error rather than something silently carried into the
# published pool, because a misspelled key is otherwise invisible forever:
# `folder-name = "terabox"` sat in a live config for months while the real bypass is
# named `patch-folder`, and nothing — not the build, not the failure report, not the
# notification — had any way to say so.
#
# The authoritative list of the keys that DECIDE a rebuild lives in
# `.github/scripts/retry_lib.sh` (`retry_tracked_keys` / `retry_ignored_keys`). This
# mirrors it so the shell stays stdlib-only and the compiler needs no subprocess, and
# `.github/traces/test_config_rearm.sh` fails if the two ever disagree.
TRACKED_KEYS = frozenset({
    "patches-source", "patches-source-host", "patches-version",
    "cli-source", "cli-source-host", "cli-version",
    "brand", "variant", "sub-variant", "app-name", "pkg-name", "patched-pkg-name",
    "included-patches", "excluded-patches", "exclusive-patches", "inclusive-patches",
    "patcher-args", "arch", "build-mode", "version", "version-code", "dpi",
    "include-stock", "compression-level", "remove-rv-integrations-checks",
    "github-release-regex", "github-regex", "module-prop-name",
    "enable-module-update",
})
# Read by the builder or the watcher, but never a reason to rebuild (see
# retry_ignored_keys). `patch-folder` is the interesting one: ci_check_app_patches.py
# uses it to attribute bundle files to an app, the engine never reads it, so a rebuild
# over a change there reproduces identical bytes and the content hash suppresses them.
# `preferred-format` joins it because the same suppression wins before the pickers even
# run: a cached stock APK skips the download stage the key steers entirely.
UNTRACKED_KEYS = frozenset(
    {"enabled", "author", "author-page", "patch-folder", "preferred-format"})


def unknown_key(key):
    """Return None when `key` is recognised, else why it is not.

    Download URLs are accepted by suffix rather than by name, so a newly added store
    cannot arrive as an unclassified key. The suggestion is a prefix match, never a
    guess at what the author meant: a misspelled value must still fail, and the
    near-miss exists only to save a lookup of the docs.
    """
    if key in TRACKED_KEYS or key in UNTRACKED_KEYS:
        return None
    if key.endswith("-dlurl"):
        return None
    near = sorted({k for group in (TRACKED_KEYS, UNTRACKED_KEYS) for k in group
                   if k[:3] == key[:3]})
    return ("not a config key the builder reads"
            + ("; did you mean one of: " + ", ".join(near[:4]) if near else ""))


def normalize_channel(val):
    """Canonicalize a patches-version value to "stable"/"beta"/"both", or return a
    concrete tag unchanged. Those three words are the whole vocabulary: stable and
    beta name a release channel, both is pool routing that build.sh resolves before
    a build runs. Anything else is read as a release tag to pin to - including a
    mistyped channel, which then fails loudly instead of quietly landing in a pool.
    utils.sh mirrors the same two keywords in _release_channel_of."""
    if not val or not isinstance(val, str):
        return None
    v = val.strip().lower()
    if v == "stable":
        return "stable"
    if v == "beta":
        return "beta"
    if v == "both":
        return "both"
    return val.strip()  # Pinned version string like "v1.41.0"


def compile_configs(patches_dir="configs/patches"):
    stable_pool = {}
    beta_pool = {}

    toml_files = sorted(glob.glob(os.path.join(patches_dir, "*.toml")))
    if not toml_files:
        print(
            f"Warning: No TOML files found in {patches_dir}", file=sys.stderr)
        return stable_pool, beta_pool, []

    seen_stable = {}
    seen_beta = {}
    # Collected, not raised on the spot: one run should report every bad key in every
    # file, not make the maintainer fix one, re-run, and find the next.
    problems = []

    for filepath in toml_files:
        filename = os.path.basename(filepath)
        try:
            with open(filepath, "rb") as f:
                data = tomllib.load(f)
        except Exception as e:
            print(f"Error parsing {filepath}: {e}", file=sys.stderr)
            sys.exit(1)

        # File-level defaults are keys defined before tables
        file_defaults = {k: v for k,
                         v in data.items() if not isinstance(v, dict)}

        for key in file_defaults:
            why = unknown_key(key)
            if why:
                problems.append(
                    f"{filename}: file-level key '{key}' is {why}")

        # Resolve file-level channel default (default is "stable" if omitted)
        file_pv = normalize_channel(file_defaults.get("patches-version"))
        if not file_pv:
            # A .beta. filename is the only file-name signal; "dev" is not a channel
            # spelling any more, and matching on a bare substring would pull in a
            # source named like devanced.toml.
            file_pv = "beta" if ".beta." in filename else "stable"

        for app_key, app_table in data.items():
            if not isinstance(app_table, dict):
                continue

            for key in app_table:
                why = unknown_key(key)
                if why:
                    problems.append(
                        f"{filename}: [{app_key}] key '{key}' is {why}")

            merged = dict(file_defaults)
            merged.update(app_table)

            enabled = merged.get("enabled", True)
            if isinstance(enabled, str):
                enabled = enabled.lower() == "true"
            if not enabled:
                continue

            app_pv_raw = app_table.get("patches-version")
            if app_pv_raw:
                channel = normalize_channel(app_pv_raw)
            else:
                channel = file_pv

            is_pinned = channel not in ("stable", "beta", "both")
            is_beta_pin = False
            if is_pinned:
                # Same marker list the watcher and the release picker read the tag
                # with, so a pin routes to the pool its tag would resolve from.
                is_beta_pin = channels.is_pre_release_tag(
                    channel) or (file_pv == "beta")

            # Route to stable pool
            if channel in ("stable", "both") or (is_pinned and not is_beta_pin):
                if app_key in stable_pool:
                    print(
                        f"Error: Duplicate app key '[{app_key}]' in {filename} (already defined in {seen_stable[app_key]})", file=sys.stderr)
                    sys.exit(1)
                seen_stable[app_key] = filename
                entry = dict(merged)
                if is_pinned:
                    # Carried exactly as written. Generation used to overwrite a
                    # non-channel patches-version with the watcher's current tag;
                    # the build now resolves channel keywords from that snapshot
                    # itself (see _patch_source_state_tag in utils.sh), so a pin is
                    # the only thing left in the config and it is always the
                    # author's, in both pools.
                    entry["patches-version"] = channel
                else:
                    # Omit redundant key when matching pool default
                    entry.pop("patches-version", None)
                stable_pool[app_key] = entry

            # Route to beta pool
            if channel in ("beta", "both") or (is_pinned and is_beta_pin):
                if app_key in beta_pool:
                    print(
                        f"Error: Duplicate app key '[{app_key}]' in {filename} (already defined in {seen_beta[app_key]})", file=sys.stderr)
                    sys.exit(1)
                seen_beta[app_key] = filename
                entry = dict(merged)
                if is_pinned:
                    # See stable pool: a written pin is carried unchanged.
                    entry["patches-version"] = channel
                else:
                    # Omit redundant key when matching pool default
                    entry.pop("patches-version", None)
                beta_pool[app_key] = entry

    return stable_pool, beta_pool, problems


def main():
    patches_dir = sys.argv[1] if len(sys.argv) > 1 else "configs/patches"
    stable_pool, beta_pool, problems = compile_configs(patches_dir)

    # Before anything is written: an invalid config must leave the previous pools
    # standing rather than publishing a pool built from keys nobody reads.
    if problems:
        print(f"Error: {len(problems)} unrecognised config key(s):",
              file=sys.stderr)
        for p in problems:
            print(f"  {p}", file=sys.stderr)
        print("Fix the key or remove it; a config key that no code reads is silently "
              "ignored today and would be a silent no-op forever.", file=sys.stderr)
        sys.exit(1)

    stable_out = {"patches-version": "stable"}
    stable_out.update(stable_pool)

    beta_out = {"patches-version": "beta"}
    beta_out.update(beta_pool)

    jsonfmt.write("config.stable.json", stable_out)

    jsonfmt.write("config.beta.json", beta_out)

    print("Base patch configurations compiled successfully.")
    print(f"Stable pool apps: {len(stable_pool)}")
    print(f"Beta pool apps:   {len(beta_pool)}")


if __name__ == "__main__":
    main()
