#!/usr/bin/env python3
"""Convert the builder's raw build.json into the unified filename-keyed manifest.

The numbered release gets this file uploaded as build.json, and the archive
releases (stable/beta) get a cumulative merge of it (see merge_archive_manifest.sh).
Schema matches .github/scripts/backfill_manifests.py output (schema version 1).

Env:
    NEXT_VER_CODE   release tag / build number (required)
    IS_PRERELEASE   true -> beta channel, else stable
Writes:
    temp/manifest/build.json
"""
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path


def normalize_key(s):
    return re.sub(r"[^a-z0-9]", "", (s or "").lower())


def normalize_arch(arch_raw):
    a = (arch_raw or "").lower().strip()
    if "arm64" in a or "aarch64" in a:
        return "arm64"
    if "arm" in a or "armeabi" in a:
        return "arm"
    if a in ["all", "universal"] or a.endswith("-all") or a.endswith("-universal"):
        return "all"
    if "x86_64" in a or "x64" in a:
        return "x86_64"
    if "x86" in a:
        return "x86"
    return a or "all"


def extract_arch(fname, version=""):
    match = re.search(
        r"-(arm64-v8a|armeabi-v7a|arm-v7a|aarch64|arm64|arm32|arm|x86_64|x64|x86|universal|all)(?:-(?:apk|module))?\.(?:apk|zip)$",
        fname,
        re.IGNORECASE,
    )
    if match:
        return match.group(1)
    if version:
        clean_ver = re.escape(version.lstrip("v"))
        m = re.search(rf"-v?{clean_ver}-([a-zA-Z0-9_-]+?)(?:-(?:apk|module))?\.(?:apk|zip)$", fname, re.IGNORECASE)
        if m:
            return m.group(1)
    name_no_ext = re.sub(r"\.(?:apk|zip)$", "", fname, flags=re.IGNORECASE)
    name_no_mode = re.sub(r"-(?:apk|module)$", "", name_no_ext, flags=re.IGNORECASE)
    parts = name_no_mode.split("-")
    if len(parts) > 1:
        return parts[-1]
    return "all"


def parse_patch_info(patches_source, patches_ref):
    primary = (patches_source or "").split()[0] if patches_source else ""
    if not primary and patches_ref:
        primary = patches_ref.split()[0].split("/")[0]
    primary_clean = primary.split("/")[-1].replace("-patches", "").replace("patches-", "")
    primary_clean = primary_clean.split("-")[0] if "-" in primary_clean else primary_clean
    primary_clean = primary_clean.capitalize() if primary_clean.islower() else primary_clean
    key = normalize_key(primary_clean) or "patched"
    return key, primary_clean or "Patched"


def main():
    next_ver_code = os.environ.get("NEXT_VER_CODE", "").strip()
    if not next_ver_code:
        print("Error: NEXT_VER_CODE not set.", file=sys.stderr)
        sys.exit(1)
    is_prerelease = os.environ.get("IS_PRERELEASE", "false").lower() == "true"
    channel = "beta" if is_prerelease else "stable"
    now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    build_json_file = Path("build.json")
    if not build_json_file.exists():
        print("No build.json found — writing empty manifest.")
        build_info = {}
    else:
        with open(build_json_file, encoding="utf-8") as f:
            build_info = json.load(f)

    build_dir = Path("build")
    built_files = [f for f in build_dir.iterdir() if f.is_file()] if build_dir.exists() else []

    files = {}
    for target_key, info in build_info.items():
        file_prefix = info.get("name") or target_key
        prefix_lower = file_prefix.lower()
        matching_files = [
            f for f in built_files
            if f.name.lower().startswith(prefix_lower + "-v") or f.name.lower().startswith(prefix_lower + "-module-")
        ]
        if not matching_files:
            continue

        app_name = (info.get("display_name") or target_key).strip()
        app_key = normalize_key(app_name) or normalize_key(target_key)

        brand_cfg = (info.get("brand") or "").strip()
        if brand_cfg:
            brand_key, brand_name = normalize_key(brand_cfg), brand_cfg
        else:
            brand_key, brand_name = parse_patch_info(info.get("patches_source"), info.get("patches"))

        variant_cfg = (info.get("variant") or "").strip()
        variant_val = variant_cfg if (variant_cfg and variant_cfg.lower() != "default") else None
        sub_variant_cfg = (info.get("sub_variant") or "").strip()
        sub_variant_val = sub_variant_cfg if sub_variant_cfg else None
        version = info.get("version", "")
        patches_ref = (info.get("patches") or "").strip()
        changelog_url = (info.get("changelog") or "").strip()

        for f in matching_files:
            fname = f.name
            lower = fname.lower()
            if not (lower.endswith(".apk") or lower.endswith(".zip")):
                continue
            files[fname] = {
                "name": file_prefix,
                "version": version,
                "appKey": app_key,
                "appName": app_name,
                "arch": normalize_arch(extract_arch(fname, version)),
                "fileType": "APK" if lower.endswith(".apk") else "Module",
                "brandKey": brand_key,
                "brandName": brand_name,
                "variant": variant_val,
                "subVariant": sub_variant_val,
                "packageName": (info.get("package_name") or "").strip() or None,
                "patchSources": patches_ref.split() if patches_ref else [],
                "changelogs": changelog_url.split() if changelog_url else [],
                "appliedPatches": info.get("applied_patches") or [],
                "originBuild": next_ver_code,
                "publishedAt": now_iso,
            }

    manifest = {
        "schema": 1,
        "kind": "build",
        "meta": {"build": next_ver_code, "channel": channel, "publishedAt": now_iso},
        "files": files,
    }

    out_dir = Path("temp/manifest")
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / "build.json"
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(manifest, f, separators=(",", ":"))
    print(f"Wrote {out_path} with {len(files)} file entries (build {next_ver_code}, channel {channel}).")


if __name__ == "__main__":
    main()
