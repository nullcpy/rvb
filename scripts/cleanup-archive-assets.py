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
    repo = os.environ.get("GITHUB_REPOSITORY")
    
    # Get the release ID first
    output = run_cmd(f"gh api repos/{repo}/releases/tags/{tag} --jq .id")
    if not output:
        return
    release_id = output.strip()
    
    # Fetch all assets with pagination to ensure we get all 600+ files
    output = run_cmd(f"gh api --paginate repos/{repo}/releases/{release_id}/assets")
    if not output:
        return
        
    try:
        assets = json.loads(output)
    except Exception as e:
        print(f"Failed to parse JSON: {e}")
        return
    
    # regex to match app_name, version, architecture/type, and extension
    # e.g. google-photos-morphe-v7.84.0.949657053-arm-v7a.apk
    # e.g. youtube-revanced-v19.16.39-all.apk
    # e.g. youtube-revanced-v19.16.39-module.zip
    # e.g. hola-vpn-morphe-vAARCH64_1.248.400-arm64-v8a.apk
    # e.g. discord-xposed-v338.13-Stable-arm64-v8a.apk
    pattern = re.compile(r'^(.*?)-((?:[vV]?[0-9]|[vV][A-Z]).*?)-(arm64-v8a|arm-v7a|universal|all|module|x86|x86_64)\.(apk|zip)$')
    
    groups = {}
    
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
        # Sort by created_at descending (newest first)
        group_assets.sort(key=lambda x: x['created_at'], reverse=True)
        
        keep_count = 2
        to_keep = group_assets[:keep_count]
        to_delete = group_assets[keep_count:]
        
        if to_delete:
            print(f"\nGroup: {key}")
            for a in to_keep:
                print(f"  Keeping: {a['name']} ({a['created_at']})")
                
            for a in to_delete:
                print(f"  Deleting: {a['name']} ({a['created_at']})")
                cmd = f'gh api -X DELETE repos/{repo}/releases/assets/{a["id"]}'
                run_cmd(cmd)

if __name__ == "__main__":
    if not os.environ.get("GITHUB_REPOSITORY"):
        print("GITHUB_REPOSITORY environment variable not set.")
        sys.exit(1)
    cleanup_release("stable")
    cleanup_release("beta")
