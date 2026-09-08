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
    if a in ["all", "universal"] or a.endswith("-all") or a.endswith("-universal"):
        return "all"
    if "x86_64" in a or "x64" in a:
        return "x86_64"
    if "x86" in a:
        return "x86"
    return a or "all"

def extract_arch(fname, version=""):
    # First match against known architecture tokens at the end of the filename
    match = re.search(
        r"-(arm64-v8a|armeabi-v7a|arm-v7a|aarch64|arm64|arm32|arm|x86_64|x64|x86|universal|all)(?:-(?:apk|module))?\.(?:apk|zip)$",
        fname,
        re.IGNORECASE
    )
    if match:
        return match.group(1)

    # If version is provided, match what follows -v<version>-
    if version:
        clean_ver = re.escape(version.lstrip("v"))
        m = re.search(rf"-v?{clean_ver}-([a-zA-Z0-9_-]+?)(?:-(?:apk|module))?\.(?:apk|zip)$", fname, re.IGNORECASE)
        if m:
            return m.group(1)

    # Fallback to the last hyphen-delimited segment before extension
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
    name = primary_clean or "Patched"
    return key, name

def update_catalog_data(catalog_data, build_info, built_files, next_ver_code, is_prerelease, github_server, github_repo):
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
            brand_name = brand_cfg
            brand_key = normalize_key(brand_cfg)
        else:
            brand_key, brand_name = parse_patch_info(info.get("patches_source"), info.get("patches"))

        variant_cfg = (info.get("variant") or "").strip()
        variant_val = variant_cfg if (variant_cfg and variant_cfg.lower() != "default") else None

        sub_variant_cfg = (info.get("sub_variant") or "").strip()
        sub_variant_val = sub_variant_cfg if sub_variant_cfg else None

        version = info.get("version", "")
        pkg_name = (info.get("package_name") or "").strip()
        changelog_url = (info.get("changelog") or "").strip()
        patches_ref = info.get("patches", "").strip()

        # Find or create app entry
        if app_key not in app_map:
            app_entry = {
                "appKey": app_key,
                "appName": app_name,
                "totalDownloads": 0,
                "latestPublishedAt": now_iso,
                "brands": []
            }
            app_map[app_key] = app_entry
            apps.append(app_entry)
        else:
            app_entry = app_map[app_key]
            app_entry["appName"] = app_name
            app_entry["latestPublishedAt"] = now_iso
            if "brands" not in app_entry:
                app_entry["brands"] = []

        # Find or create brand entry
        brand_entry = next((b for b in app_entry["brands"] if b["brandKey"] == brand_key), None)
        if not brand_entry:
            brand_entry = {
                "brandKey": brand_key,
                "brandName": brand_name,
                "latestVersion": version,
                "latestPublishedAt": now_iso,
                "totalDownloads": 0,
                "variants": [],
                "builds": []
            }
            app_entry["brands"].append(brand_entry)
        else:
            brand_entry["brandName"] = brand_name
            brand_entry["latestVersion"] = version
            brand_entry["latestPublishedAt"] = now_iso

        # Find or create variant entry
        variant_entry = next(
            (v for v in brand_entry["variants"]
             if v.get("variant") == variant_val and v.get("subVariant") == sub_variant_val),
            None
        )
        if not variant_entry:
            variant_entry = {
                "variant": variant_val,
                "subVariant": sub_variant_val,
                "packageName": pkg_name,
                "apkFilter": f"^{file_prefix}-v.*\\.apk$",
                "latestStable": None,
                "latestBeta": None
            }
            brand_entry["variants"].append(variant_entry)
        else:
            variant_entry["packageName"] = pkg_name or variant_entry.get("packageName", "")
            variant_entry["apkFilter"] = f"^{file_prefix}-v.*\\.apk$"

        # Update latest channel pointers
        channel_meta = {
            "version": version,
            "build": next_ver_code,
            "publishedAt": now_iso,
            "releaseId": next_ver_code,
            "releaseUrl": f"{github_server}/{github_repo}/releases/tag/{next_ver_code}",
            "isArchiveFallback": False
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
            raw_arch = extract_arch(fname, version)
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

        # Separate existing numbered builds and archive builds
        existing_numbered = [
            b for b in brand_entry["builds"]
            if not b.get("isArchive") and not (
                str(b.get("build")) == str(next_ver_code) and
                b.get("variant") == variant_val and
                b.get("subVariant") == sub_variant_val
            )
        ]

        build_entry = {
            "build": next_ver_code,
            "releaseId": next_ver_code,
            "releaseType": release_type,
            "isArchive": False,
            "version": version,
            "variant": variant_val,
            "subVariant": sub_variant_val,
            "publishedAt": now_iso,
            "releaseUrl": f"{github_server}/{github_repo}/releases/tag/{next_ver_code}",
            "patchSources": patches_ref.split() if isinstance(patches_ref, str) else (patches_ref or []),
            "changelogs": changelog_url.split() if isinstance(changelog_url, str) else (changelog_url or []),
            "appliedPatches": info.get("applied_patches") or [],
            "assets": assets
        }

        # Rolling archive build entry
        archive_tag = "beta" if is_prerelease else "stable"
        archive_assets = [
            {
                "name": a["name"],
                "browser_download_url": f"{github_server}/{github_repo}/releases/download/{archive_tag}/{a['name']}",
                "size": a["size"],
                "download_count": a.get("download_count", 0),
                "arch": a["arch"],
                "fileType": a["fileType"]
            }
            for a in assets
        ]
        archive_entry = {
            "build": version,
            "releaseId": archive_tag,
            "releaseType": release_type,
            "isArchive": True,
            "version": version,
            "variant": variant_val,
            "subVariant": sub_variant_val,
            "publishedAt": now_iso,
            "releaseUrl": f"{github_server}/{github_repo}/releases/tag/{archive_tag}",
            "patchSources": patches_ref.split() if isinstance(patches_ref, str) else (patches_ref or []),
            "changelogs": changelog_url.split() if isinstance(changelog_url, str) else (changelog_url or []),
            "appliedPatches": info.get("applied_patches") or [],
            "assets": archive_assets
        }

        # Existing archive builds matching same variant, subVariant and same releaseType (excluding same version)
        matching_archive = [
            b for b in brand_entry["builds"]
            if b.get("isArchive") and b.get("variant") == variant_val and b.get("subVariant") == sub_variant_val and b.get("releaseType") == release_type and b.get("version") != version
        ]
        other_archive = [
            b for b in brand_entry["builds"]
            if b.get("isArchive") and not (b.get("variant") == variant_val and b.get("subVariant") == sub_variant_val and b.get("releaseType") == release_type)
        ]
        # Keep up to 1 older archive build for same variant and channel
        surviving_archive = [archive_entry] + matching_archive[:1] + other_archive

        brand_entry["builds"] = [build_entry] + existing_numbered + surviving_archive

    # Sort apps alphabetically
    apps.sort(key=lambda a: a["appName"].lower())
    catalog_data["version"] = 2
    catalog_data["apps"] = apps
    catalog_data["updated_at"] = now_iso
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
    build_dir = Path("build")
    built_files = [f for f in build_dir.iterdir() if f.is_file()] if build_dir.exists() else []

    website_repo_url = f"https://oauth2:{token}@github.com/nullcpy/nullcpy.github.io.git"
    clone_dir = Path("temp/website_repo")

    if clone_dir.exists():
        shutil.rmtree(clone_dir)

    print("Cloning website repository (nullcpy.github.io)...")
    run_cmd(f"git clone --depth 1 {website_repo_url} {clone_dir}")

    data_path = clone_dir / "data.json"
    catalog_data = load_json(data_path, default={"version": 2, "updated_at": "", "apps": []})

    print("Updating website data with new build entries...")
    updated_catalog = update_catalog_data(
        catalog_data,
        build_info,
        built_files,
        next_ver_code,
        is_prerelease,
        github_server,
        github_repo
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
    
    pushed = False
    for attempt in range(1, 4):
        result = subprocess.run("git push origin main", shell=True, capture_output=True, text=True, cwd=clone_dir)
        if result.returncode == 0:
            pushed = True
            print("Successfully published updated data.json to nullcpy.github.io!")
            break
        print(f"Warning: Git push attempt {attempt} failed: {result.stderr.strip()}. Retrying with rebase...", file=sys.stderr)
        subprocess.run("git pull --rebase origin main", shell=True, cwd=clone_dir)
    if not pushed:
        print("Error: Failed to push updated data.json after 3 attempts.", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
