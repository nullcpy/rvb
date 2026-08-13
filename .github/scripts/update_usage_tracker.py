import os
import sys
import json
import time
import subprocess

def run_cmd(cmd, check=True):
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    if check and result.returncode != 0:
        print(f"Error running command: {cmd}\n{result.stderr}")
        sys.exit(1)
    return result.stdout.strip()

def main():
    token = os.environ.get("APKS_REPO_TOKEN")
    if not token:
        print("APKS_REPO_TOKEN is not set. Skipping usage tracker update.")
        return

    used_versions_file = "temp/used_versions.txt"
    if not os.path.exists(used_versions_file):
        print("No used_versions.txt found. Skipping update.")
        return

    with open(used_versions_file, "r") as f:
        used_versions = set([line.strip() for line in f if line.strip()])

    if not used_versions:
        print("No versions recorded. Skipping update.")
        return

    repo_url = f"https://oauth2:{token}@github.com/nullcpy/apks.git"
    clone_dir = "temp/apks_repo"
    
    if os.path.exists(clone_dir):
        run_cmd(f"rm -rf {clone_dir}")

    print("Cloning apks repository...")
    run_cmd(f"git clone --depth 1 {repo_url} {clone_dir}")

    usage_file = os.path.join(clone_dir, "usage.json")
    
    usage_data = {}
    if os.path.exists(usage_file):
        try:
            with open(usage_file, "r") as f:
                usage_data = json.load(f)
        except Exception as e:
            print(f"Failed to load existing usage.json: {e}")

    current_time = int(time.time())
    
    for version in used_versions:
        usage_data[version] = current_time

    with open(usage_file, "w") as f:
        json.dump(usage_data, f, indent=2)

    os.chdir(clone_dir)
    
    status = run_cmd("git status --porcelain")
    if not status:
        print("No changes to usage.json.")
        return

    print("Committing and pushing usage.json...")
    run_cmd("git config user.name 'github-actions[bot]'")
    run_cmd("git config user.email 'github-actions[bot]@users.noreply.github.com'")
    run_cmd("git add usage.json")
    run_cmd("git commit -m 'chore: update cache usage tracker'")
    run_cmd("git push origin main")
    print("Successfully updated usage tracker in apks repository.")

if __name__ == "__main__":
    main()
