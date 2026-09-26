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
concrete patches-version (a tag instead of a channel) is copied verbatim.
"""

import os
import sys
import glob
import json
import re

try:
    import tomllib
except ImportError:
    try:
        import tomli as tomllib
    except ImportError:
        print("Error: neither tomllib nor tomli is available.", file=sys.stderr)
        sys.exit(1)


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
        return stable_pool, beta_pool

    seen_stable = {}
    seen_beta = {}

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
                is_beta_pin = bool(re.search(
                    r"[-._](beta|dev|alpha|rc|pre)", channel, re.IGNORECASE)) or (file_pv == "beta")

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

    return stable_pool, beta_pool


def main():
    patches_dir = sys.argv[1] if len(sys.argv) > 1 else "configs/patches"
    stable_pool, beta_pool = compile_configs(patches_dir)

    stable_out = {"patches-version": "stable"}
    stable_out.update(stable_pool)

    beta_out = {"patches-version": "beta"}
    beta_out.update(beta_pool)

    with open("config.stable.json", "w", encoding="utf-8") as f:
        json.dump(stable_out, f, indent=2)

    with open("config.beta.json", "w", encoding="utf-8") as f:
        json.dump(beta_out, f, indent=2)

    print("Base patch configurations compiled successfully.")
    print(f"Stable pool apps: {len(stable_pool)}")
    print(f"Beta pool apps:   {len(beta_pool)}")


if __name__ == "__main__":
    main()
