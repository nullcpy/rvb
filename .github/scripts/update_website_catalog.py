#!/usr/bin/env python3
import os
import sys
import re
import json
import shutil
import subprocess
from datetime import datetime, timezone
from pathlib import Path

def run_cmd(cmd, check=True, cwd=None):
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True, cwd=cwd)
    if check and result.returncode != 0:
        print(f"Error running command: {cmd}\n{result.stderr}", file=sys.stderr)
        sys.exit(1)
    return result.stdout.strip()

def normalize_key(s):
    return re.sub(r"[^a-z0-9]", "", (s or "").lower())

def load_json(path, default=None):
    if os.path.exists(path):
        try:
            with open(path, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception as e:
            print(f"Warning: Could not read {path}: {e}", file=sys.stderr)
    return default if default is not None else {}

def normalize_arch(arch_raw):
    a = (arch_raw or "").lower().strip()
    if "arm64" in a or "aarch64" in a:
        return "arm64"
    if "arm" in a or "armeabi" in a:
        return "arm"
    if a in ["all", "universal"]:
        return "all"
    if "x86_64" in a or "x64" in a:
        return "x86_64"
    if "x86" in a:
        return "x86"
    return a or "all"

def parse_patch_info(patches_source, patches_ref):
    primary = (patches_source or "").split()[0] if patches_source else ""
    if not primary and patches_ref:
        primary = patches_ref.split()[0].split("/")[0]

    primary_clean = primary.split("/")[-1].replace("-patches", "").replace("patches-", "")
    primary_clean = primary_clean.split("-")[0] if "-" in primary_clean else primary_clean
    primary_clean = primary_clean.capitalize() if primary_clean.islower() else primary_clean

    key = normalize_key(primary_clean) or "patched"
    name = primary_clean or "Patched"
    return key, name

def update_catalog_data(catalog_data, build_info, built_files, next_ver_code, is_prerelease, github_server, github_repo, config=None):
    apps = catalog_data.get("apps", [])
    app_map = {app["appKey"]: app for app in apps}
    now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    release_type = "beta" if is_prerelease else "stable"

    for target_key, info in build_info.items():
        file_prefix = info.get("name") or target_key
        prefix_lower = file_prefix.lower()
        matching_files = [f for f in built_files if (f.name.lower().startswith(prefix_lower + "-v") or f.name.lower().startswith(prefix_lower + "-module-"))]
        if not matching_files:
            continue

        raw_display = (info.get("display_name") or target_key).strip()
        app_name = raw_display
        app_key = normalize_key(app_name) or normalize_key(target_key)

        brand_cfg = (info.get("brand") or "").strip()
        if brand_cfg:
            patch_name = brand_cfg
            patch_key = normalize_key(brand_cfg)
        else:
            patch_key, patch_name = parse_patch_info(info.get("patches_source"), info.get("patches"))

        variant_cfg = (info.get("variant") or "").strip()
        sub_variant_cfg = (info.get("sub_variant") or "").strip()

        parts_key = []
        parts_name = []
        if variant_cfg and variant_cfg.lower() != "default":
            parts_key.append(normalize_key(variant_cfg))
            parts_name.append(variant_cfg)
        if sub_variant_cfg:
            parts_key.append(normalize_key(sub_variant_cfg))
            if parts_name:
                parts_name.append(f"({sub_variant_cfg})")
            else:
                parts_name.append(sub_variant_cfg)

        variant_key = "-".join(parts_key) if parts_key else "default"
        variant_name = " ".join(parts_name) if parts_name else "Standard"

        version = info.get("version", "")
        pkg_name = info.get("package_name", "")
        changelog_url = (info.get("changlog") or info.get("changelog") or "").strip()
        patches_ref = info.get("patches", "").strip()

        # Find or create app entry
        if app_key not in app_map:
            app_entry = {
                "appKey": app_key,
                "appName": app_name,
                "totalDownloads": 0,
                "latestPublishedAt": now_iso,
                "patches": []
            }
            app_map[app_key] = app_entry
            apps.append(app_entry)
        else:
            app_entry = app_map[app_key]
            app_entry["latestPublishedAt"] = now_iso

        # Find or create patch entry
        patch_entry = next((p for p in app_entry["patches"] if p["patchKey"] == patch_key), None)
        if not patch_entry:
            patch_entry = {
                "patchKey": patch_key,
                "patchName": patch_name,
                "latestVersion": version,
                "latestPublishedAt": now_iso,
                "totalDownloads": 0,
                "variants": [],
                "builds": []
            }
            app_entry["patches"].append(patch_entry)
        else:
            patch_entry["latestVersion"] = version
            patch_entry["latestPublishedAt"] = now_iso

        # Find or create variant entry
        variant_entry = next((v for v in patch_entry["variants"] if v["variantKey"] == variant_key), None)
        if not variant_entry:
            variant_entry = {
                "variantKey": variant_key,
                "variantName": variant_name,
                "package_name": pkg_name,
                "apkFilter": f"^{file_prefix}-v.*\\.apk$",
                "latestStable": None,
                "latestBeta": None,
                "latestArchiveStable": None,
                "latestArchiveBeta": None
            }
            patch_entry["variants"].append(variant_entry)
        else:
            variant_entry["package_name"] = pkg_name or variant_entry.get("package_name", "")
            variant_entry["apkFilter"] = f"^{file_prefix}-v.*\\.apk$"

        # Update latest channel pointers
        channel_meta = {
            "version": version,
            "build": next_ver_code,
            "publishedAt": now_iso,
            "releaseId": next_ver_code,
            "releaseUrl": f"{github_server}/{github_repo}/releases/tag/{next_ver_code}"
        }
        if release_type == "beta":
            variant_entry["latestBeta"] = channel_meta
        else:
            variant_entry["latestStable"] = channel_meta

        # Prepare assets for this build
        assets = []
        for f in matching_files:
            fname = f.name
            lower = fname.lower()
            if not (lower.endswith(".apk") or lower.endswith(".zip")):
                continue

            file_type = "APK" if lower.endswith(".apk") else "Module"
            arch_match = re.search(r"-v[^-]+-([a-zA-Z0-9_-]+)\.(apk|zip)$", fname, re.IGNORECASE)
            raw_arch = arch_match.group(1) if arch_match else "all"
            arch = normalize_arch(raw_arch)
            dl_url = f"{github_server}/{github_repo}/releases/download/{next_ver_code}/{fname}"
            size = f.stat().st_size if f.exists() else 0

            assets.append({
                "name": fname,
                "browser_download_url": dl_url,
                "size": size,
                "download_count": 0,
                "arch": arch,
                "fileType": file_type
            })

        # Sort assets consistently: arm64, arm, all
        arch_order = {"arm64": 0, "arm": 1, "all": 2, "universal": 3, "x86_64": 4, "x86": 5}
        assets.sort(key=lambda a: arch_order.get(a["arch"], 99))

        build_key = f"{next_ver_code}-{variant_key}"
        # Remove existing build with same build_key if rerunning
        patch_entry["builds"] = [b for b in patch_entry["builds"] if b.get("buildKey") != build_key]

        build_entry = {
            "buildKey": build_key,
            "releaseId": next_ver_code,
            "build": next_ver_code,
            "releaseType": release_type,
            "isArchive": False,
            "variantKey": variant_key,
            "publishedAt": now_iso,
            "releaseUrl": f"{github_server}/{github_repo}/releases/tag/{next_ver_code}",
            "version": version,
            "package_name": pkg_name,
            "patchMeta": {
                "cli": "",
                "patches": [patches_ref] if patches_ref else [],
                "changelogs": [changelog_url] if changelog_url else []
            },
            "appliedPatches": info.get("applied_patches") or [],
            "assets": assets
        }
        patch_entry["builds"].insert(0, build_entry)
        patch_entry["builds"] = patch_entry["builds"][:10]

    # Sort apps alphabetically
    apps.sort(key=lambda a: a["appName"].lower())
    catalog_data["apps"] = apps
    catalog_data["updated_at"] = now_iso
    if config:
        catalog_data["config"] = config
    return catalog_data

def main():
    token = os.environ.get("WEBSITE_REPO_TOKEN") or os.environ.get("APKS_REPO_TOKEN") or os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if not token:
        print("Warning: No token found for website repo. Skipping catalog push.")
        return

    next_ver_code = os.environ.get("NEXT_VER_CODE", "").strip()
    if not next_ver_code:
        print("Warning: NEXT_VER_CODE not set. Skipping website catalog update.")
        return

    github_server = os.environ.get("GITHUB_SERVER_URL", "https://github.com").rstrip("/")
    github_repo = os.environ.get("GITHUB_REPOSITORY", "nullcpy/rvb").strip()
    is_prerelease = os.environ.get("IS_PRERELEASE", "false").lower() == "true"

    build_json_file = Path("build.json")
    if not build_json_file.exists():
        print("No build.json found. Skipping catalog update.")
        return

    build_info = load_json(build_json_file)
    config = load_json("config.json")
    build_dir = Path("build")
    built_files = [f for f in build_dir.iterdir() if f.is_file()] if build_dir.exists() else []

    website_repo_url = f"https://oauth2:{token}@github.com/nullcpy/nullcpy.github.io.git"
    clone_dir = Path("temp/website_repo")

    if clone_dir.exists():
        shutil.rmtree(clone_dir)

    print("Cloning website repository (nullcpy.github.io)...")
    run_cmd(f"git clone --depth 1 {website_repo_url} {clone_dir}")

    data_path = clone_dir / "data.json"
    catalog_data = load_json(data_path, default={"version": 1, "updated_at": "", "apps": []})

    print("Updating website data with new build entries...")
    updated_catalog = update_catalog_data(
        catalog_data,
        build_info,
        built_files,
        next_ver_code,
        is_prerelease,
        github_server,
        github_repo,
        config
    )

    with open(data_path, "w", encoding="utf-8") as f:
        json.dump(updated_catalog, f, separators=(",", ":"))


    print("Committing and pushing updated data.json...")
    run_cmd("git config user.name 'github-actions[bot]'", cwd=clone_dir)
    run_cmd("git config user.email 'github-actions[bot]@users.noreply.github.com'", cwd=clone_dir)
    run_cmd("git add data.json", cwd=clone_dir)

    status = run_cmd("git status --porcelain", cwd=clone_dir)
    if not status:
        print("No data changes to commit.")
        return

    run_cmd(f"git commit -m 'chore: update data for build {next_ver_code}'", cwd=clone_dir)
    run_cmd("git push origin main", cwd=clone_dir)
    print("Successfully published updated data.json to nullcpy.github.io!")

if __name__ == "__main__":
    main()
