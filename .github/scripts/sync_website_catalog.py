#!/usr/bin/env python3
import os
import sys
import json
import shutil
import subprocess
from pathlib import Path

def run_cmd(cmd, check=True, cwd=None):
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True, cwd=cwd)
    if check and result.returncode != 0:
        print(f"Error running command: {cmd}\n{result.stderr}", file=sys.stderr)
        sys.exit(1)
    return result.stdout.strip()

def load_json(path, default=None):
    if os.path.exists(path):
        try:
            with open(path, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception as e:
            print(f"Warning: Could not read {path}: {e}", file=sys.stderr)
    return default if default is not None else {}

def main():
    token = os.environ.get("WEBSITE_REPO_TOKEN") or os.environ.get("APKS_REPO_TOKEN") or os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    is_local_dry_run = not bool(token)
    
    print("=== Synchronizing Website Catalog Data & Live Metrics ===")
    
    # 1. Fetch active releases from GitHub (single bulk request)
    print("Fetching active releases and live metrics from GitHub...")
    releases_raw = run_cmd('gh api "repos/nullcpy/rvb/releases?per_page=100"', check=False)
    if not releases_raw:
        print("Error: Could not retrieve releases from GitHub API. Aborting to protect catalog integrity.", file=sys.stderr)
        sys.exit(1)

    try:
        releases_data = json.loads(releases_raw)
    except Exception as e:
        print(f"Error: Failed to parse GitHub releases API response: {e}", file=sys.stderr)
        sys.exit(1)

    # Circuit-breaker: abort if response is unexpectedly empty or invalid (unless ALLOW_EMPTY_CATALOG is explicitly set)
    allow_empty = os.environ.get("ALLOW_EMPTY_CATALOG", "false").lower() == "true"
    min_threshold = int(os.environ.get("MIN_RELEASES_THRESHOLD", "1"))
    if not allow_empty:
        if not isinstance(releases_data, list):
            print("Error: GitHub API did not return a list of releases. Aborting to prevent catalog corruption.", file=sys.stderr)
            sys.exit(1)
        if len(releases_data) < min_threshold:
            print(f"Error: GitHub API returned {len(releases_data)} releases (< {min_threshold} threshold). Aborting to prevent catalog corruption.", file=sys.stderr)
            sys.exit(1)

    active_tags = set()
    live_numbered_assets = {}   # (tag, asset_name) -> { download_count, size }
    live_stable_assets = {}     # asset_name -> { download_count, size }
    live_beta_assets = {}       # asset_name -> { download_count, size }

    for r in releases_data:
        tag = r.get("tag_name")
        if not tag or r.get("draft"):
            continue
        active_tags.add(tag)

        assets = r.get("assets", [])
        if tag == "stable":
            for a in assets:
                live_stable_assets[a["name"]] = {
                    "download_count": a.get("download_count", 0),
                    "size": a.get("size", 0)
                }
        elif tag == "beta":
            for a in assets:
                live_beta_assets[a["name"]] = {
                    "download_count": a.get("download_count", 0),
                    "size": a.get("size", 0)
                }
        else:
            for a in assets:
                live_numbered_assets[(tag, a["name"])] = {
                    "download_count": a.get("download_count", 0),
                    "size": a.get("size", 0)
                }

    print(f"Discovered {len(active_tags)} active release tags.")

    # Targeted fallback for stable and beta if not present in first 100 releases
    if "stable" not in active_tags:
        print("Fetching stable release directly via targeted tag API...")
        stable_raw = run_cmd('gh api "repos/nullcpy/rvb/releases/tags/stable"', check=False)
        if stable_raw:
            try:
                stable_data = json.loads(stable_raw)
                for a in stable_data.get("assets", []):
                    live_stable_assets[a["name"]] = {
                        "download_count": a.get("download_count", 0),
                        "size": a.get("size", 0)
                    }
                active_tags.add("stable")
            except Exception as e:
                print(f"Warning: Could not parse stable release fallback: {e}", file=sys.stderr)

    if "beta" not in active_tags:
        print("Fetching beta release directly via targeted tag API...")
        beta_raw = run_cmd('gh api "repos/nullcpy/rvb/releases/tags/beta"', check=False)
        if beta_raw:
            try:
                beta_data = json.loads(beta_raw)
                for a in beta_data.get("assets", []):
                    live_beta_assets[a["name"]] = {
                        "download_count": a.get("download_count", 0),
                        "size": a.get("size", 0)
                    }
                active_tags.add("beta")
            except Exception as e:
                print(f"Warning: Could not parse beta release fallback: {e}", file=sys.stderr)

    print(f"Active archive assets: {len(live_stable_assets)} in stable, {len(live_beta_assets)} in beta.")

    # 2. Clone or locate data.json
    clone_dir = None
    if is_local_dry_run:
        data_path = Path("../nullcpy.github.io/data.json").resolve()
        if not data_path.exists():
            data_path = Path("temp/data.json")
    else:
        website_repo_url = f"https://oauth2:{token}@github.com/nullcpy/nullcpy.github.io.git"
        clone_dir = Path("temp/website_repo_sync")
        if clone_dir.exists():
            shutil.rmtree(clone_dir)
        print("Cloning website repository (nullcpy.github.io)...")
        run_cmd(f"git clone --depth 1 {website_repo_url} {clone_dir}")
        data_path = clone_dir / "data.json"

    if not data_path.exists():
        print(f"Error: data.json not found at {data_path}. Skipping sync.", file=sys.stderr)
        sys.exit(1)

    catalog_data = load_json(data_path)
    apps = catalog_data.get("apps", [])

    total_pruned_builds = 0
    total_pruned_assets = 0
    total_pruned_apps = 0
    total_refreshed_assets = 0

    surviving_apps = []
    for app in apps:
        surviving_brands = []
        brands_list = app.get("brands", [])
        for brand in brands_list:
            surviving_builds = []
            for b in brand.get("builds", []):
                if b.get("isArchive"):
                    rel_type = b.get("releaseType", "stable")
                    active_dict = live_beta_assets if rel_type == "beta" else live_stable_assets
                    surviving_assets = []
                    for a in b.get("assets", []):
                        fname = a["name"]
                        if fname in active_dict:
                            live_info = active_dict[fname]
                            a["download_count"] = live_info.get("download_count", a.get("download_count", 0))
                            if live_info.get("size"):
                                a["size"] = live_info["size"]
                            surviving_assets.append(a)
                            total_refreshed_assets += 1
                        else:
                            total_pruned_assets += 1

                    if surviving_assets:
                        b["assets"] = surviving_assets
                        surviving_builds.append(b)
                    else:
                        total_pruned_builds += 1
                else:
                    tag = str(b.get("build") or "")
                    if tag in active_tags:
                        surviving_assets = []
                        for a in b.get("assets", []):
                            fname = a["name"]
                            live_info = live_numbered_assets.get((tag, fname))
                            if live_info:
                                a["download_count"] = live_info.get("download_count", a.get("download_count", 0))
                                if live_info.get("size"):
                                    a["size"] = live_info["size"]
                                surviving_assets.append(a)
                                total_refreshed_assets += 1
                            else:
                                total_pruned_assets += 1

                        if surviving_assets:
                            b["assets"] = surviving_assets
                            surviving_builds.append(b)
                        else:
                            total_pruned_builds += 1
                    else:
                        total_pruned_builds += 1

            brand["builds"] = surviving_builds

            # Reconcile variant pointers with surviving builds and prune dead variants
            surviving_variants = []
            for v in brand.get("variants", []):
                v_var = v.get("variant")
                v_sub = v.get("subVariant")
                has_builds = any(
                    b for b in surviving_builds
                    if b.get("variant") == v_var and b.get("subVariant") == v_sub
                )
                if not has_builds:
                    continue

                for ch in ["latestStable", "latestBeta"]:
                    rel_filter = "stable" if ch == "latestStable" else "beta"
                    # Find newest matching surviving build
                    new_b = next((
                        b for b in surviving_builds
                        if b.get("variant") == v_var and b.get("subVariant") == v_sub and b.get("releaseType") == rel_filter
                    ), None)
                    if new_b:
                        v[ch] = {
                            "version": new_b.get("version", ""),
                            "build": new_b.get("build", ""),
                            "publishedAt": new_b.get("publishedAt", ""),
                            "releaseId": new_b.get("releaseId", ""),
                            "releaseUrl": new_b.get("releaseUrl", ""),
                            "isArchiveFallback": new_b.get("isArchive", False)
                        }
                    else:
                        v[ch] = None
                surviving_variants.append(v)
            brand["variants"] = surviving_variants

            # Keep brand if it has surviving builds
            if surviving_builds:
                brand["latestVersion"] = surviving_builds[0].get("version", "")
                brand["latestPublishedAt"] = surviving_builds[0].get("publishedAt", "")
                brand["totalDownloads"] = sum(
                    sum(a.get("download_count", 0) for a in b.get("assets", []))
                    for b in surviving_builds
                )
                surviving_brands.append(brand)

        # Keep app if it has surviving brands
        if surviving_brands:
            app["brands"] = surviving_brands
            app["totalDownloads"] = sum(b.get("totalDownloads", 0) for b in surviving_brands)
            surviving_apps.append(app)
        else:
            total_pruned_apps += 1

    catalog_data["version"] = 2
    catalog_data["apps"] = surviving_apps
    print(f"Sync complete: refreshed {total_refreshed_assets} assets with live metrics, removed {total_pruned_builds} obsolete builds, {total_pruned_assets} pruned assets, and {total_pruned_apps} empty apps.")

    with open(data_path, "w", encoding="utf-8") as f:
        json.dump(catalog_data, f, separators=(",", ":"))

    if clone_dir and clone_dir.exists():
        run_cmd("git config user.name 'github-actions[bot]'", cwd=clone_dir)
        run_cmd("git config user.email 'github-actions[bot]@users.noreply.github.com'", cwd=clone_dir)
        run_cmd("git add data.json", cwd=clone_dir)
        status = run_cmd("git status --porcelain", cwd=clone_dir)
        if not status:
            print("No catalog changes to commit.")
            return
        run_cmd("git commit -m 'chore: sync live download metrics and prune deleted releases'", cwd=clone_dir)
        run_cmd("git push origin main", cwd=clone_dir)
        print("Pushed synchronized data.json to nullcpy.github.io!")

if __name__ == "__main__":
    main()
