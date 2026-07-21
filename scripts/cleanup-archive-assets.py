import os
import json
import re
import subprocess
import sys

def run_cmd(cmd):
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"Error running command: {cmd}\n{result.stderr}")
        return None
    return result.stdout.strip()

def cleanup_release(tag):
    print(f"\n--- Fetching assets for release: {tag} ---")
    output = run_cmd(f"gh release view {tag} --json assets")
    if not output:
        return
    
    data = json.loads(output)
    assets = data.get("assets", [])
    
    # regex to match app_name, version, architecture/type, and extension
    # e.g. google-photos-morphe-v7.84.0.949657053-arm-v7a.apk
    # e.g. youtube-revanced-v19.16.39-all.apk
    # e.g. youtube-revanced-v19.16.39-module.zip
    pattern = re.compile(r'^(.*?)-(v?\d.*?)-(arm64-v8a|arm-v7a|universal|all|module|x86|x86_64)\.(apk|zip)$')
    
    groups = {}
    repo = os.environ.get("GITHUB_REPOSITORY")
    
    for asset in assets:
        name = asset['name']
        match = pattern.match(name)
        if match:
            app_name = match.group(1)
            suffix = match.group(3)
            ext = match.group(4)
            group_key = f"{app_name}-{suffix}.{ext}"
            
            if group_key not in groups:
                groups[group_key] = []
            groups[group_key].append(asset)
        else:
            print(f"Warning: Asset {name} does not match expected pattern, skipping.")
            
    for key, group_assets in groups.items():
        # Sort by createdAt descending (newest first)
        group_assets.sort(key=lambda x: x['createdAt'], reverse=True)
        
        keep_count = 2
        to_keep = group_assets[:keep_count]
        to_delete = group_assets[keep_count:]
        
        if to_delete:
            print(f"\nGroup: {key}")
            for a in to_keep:
                print(f"  Keeping: {a['name']} ({a['createdAt']})")
                
            for a in to_delete:
                print(f"  Deleting: {a['name']} ({a['createdAt']})")
                cmd = f'gh api -X DELETE repos/{repo}/releases/assets/{a["id"]}'
                run_cmd(cmd)

if __name__ == "__main__":
    if not os.environ.get("GITHUB_REPOSITORY"):
        print("GITHUB_REPOSITORY environment variable not set.")
        sys.exit(1)
    cleanup_release("stable")
    cleanup_release("beta")
