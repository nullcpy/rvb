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
    
    print("--- Cleaning up Website Catalog Data ---")
    
    # 1. Fetch active release tags from GitHub
    print("Fetching active release tags from GitHub...")
    releases_raw = run_cmd('gh api "repos/nullcpy/rvb/releases?per_page=100"', check=False)
    active_tags = set()
    if releases_raw:
        try:
            releases_data = json.loads(releases_raw)
            active_tags = {r["tag_name"] for r in releases_data if "tag_name" in r and not r.get("draft")}
        except Exception as e:
            print(f"Warning: Failed to parse releases: {e}")
    print(f"Found {len(active_tags)} active release tags.")

    # 2. Fetch live assets for stable and beta
    print("Fetching active assets for stable and beta releases...")
    stable_assets = set()
    stable_raw = run_cmd('gh release view stable --json assets', check=False)
    if stable_raw:
        try:
            stable_data = json.loads(stable_raw)
            stable_assets = {a["name"] for a in stable_data.get("assets", [])}
        except Exception as e:
            print(f"Warning: Failed to parse stable assets: {e}")

    beta_assets = set()
    beta_raw = run_cmd('gh release view beta --json assets', check=False)
    if beta_raw:
        try:
            beta_data = json.loads(beta_raw)
            beta_assets = {a["name"] for a in beta_data.get("assets", [])}
        except Exception as e:
            print(f"Warning: Failed to parse beta assets: {e}")

    print(f"Active assets: {len(stable_assets)} in stable, {len(beta_assets)} in beta.")

    clone_dir = None
    if is_local_dry_run:
        data_path = Path("../nullcpy.github.io/data.json").resolve()
        if not data_path.exists():
            data_path = Path("temp/data.json")
    else:
        website_repo_url = f"https://oauth2:{token}@github.com/nullcpy/nullcpy.github.io.git"
        clone_dir = Path("temp/website_repo_cleanup")
        if clone_dir.exists():
            shutil.rmtree(clone_dir)
        print("Cloning website repository (nullcpy.github.io)...")
        run_cmd(f"git clone --depth 1 {website_repo_url} {clone_dir}")
        data_path = clone_dir / "data.json"

    if not data_path.exists():
        print(f"data.json not found at {data_path}. Skipping.")
        return

    catalog_data = load_json(data_path)
    apps = catalog_data.get("apps", [])

    total_pruned_builds = 0
    total_pruned_assets = 0

    for app in apps:
        for patch in app.get("patches", []):
            surviving_builds = []
            for b in patch.get("builds", []):
                if b.get("isArchive"):
                    rel_type = b.get("releaseType", "stable")
                    active_set = beta_assets if rel_type == "beta" else stable_assets
                    matching_assets = [a for a in b.get("assets", []) if a["name"] in active_set]
                    if len(matching_assets) < len(b.get("assets", [])):
                        total_pruned_assets += (len(b.get("assets", [])) - len(matching_assets))
                    if matching_assets:
                        b["assets"] = matching_assets
                        surviving_builds.append(b)
                    else:
                        total_pruned_builds += 1
                else:
                    tag = str(b.get("build") or "")
                    if tag in active_tags or not active_tags:
                        surviving_builds.append(b)
                    else:
                        total_pruned_builds += 1

            # Cap builds to latest 10
            patch["builds"] = surviving_builds[:10]

    print(f"Sanitization complete: removed {total_pruned_builds} obsolete builds and {total_pruned_assets} pruned archive assets.")

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
        run_cmd("git commit -m 'chore: prune deleted releases and archive assets from data.json'", cwd=clone_dir)
        run_cmd("git push origin main", cwd=clone_dir)
        print("Pushed sanitized data.json to nullcpy.github.io!")

if __name__ == "__main__":
    main()
