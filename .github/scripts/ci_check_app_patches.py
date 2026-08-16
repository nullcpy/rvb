import os, json, zipfile, hashlib, re, subprocess, glob, sys

def get_app_mappings():
    apps_stable = {}
    apps_dev = {}
    cli_sources = {}
    import glob
    for toml_file in glob.glob('.github/configs/patches/*.toml'):
        with open(toml_file, 'r', encoding='utf-8') as f:
            content = f.read()
            # Split by [app_key]
            sections = re.split(r'^\[(.*?)\]\s*$', content, flags=re.MULTILINE)[1:]
            for i in range(0, len(sections), 2):
                key = sections[i].strip()
                body = sections[i+1]
                
                m_enabled = re.search(r'^enabled\s*=\s*(true|false)', body, flags=re.MULTILINE | re.IGNORECASE)
                m_stable = re.search(r'^enabledStable\s*=\s*(true|false)', body, flags=re.MULTILINE | re.IGNORECASE)
                m_dev = re.search(r'^enabledDev\s*=\s*(true|false)', body, flags=re.MULTILINE | re.IGNORECASE)
                
                enabled = m_enabled.group(1).lower() == 'true' if m_enabled else True
                enabledStable = m_stable.group(1).lower() == 'true' if m_stable else True
                enabledDev = m_dev.group(1).lower() == 'true' if m_dev else True
                
                if not enabled:
                    continue
                
                # Extract patches-source
                m_src = re.search(r'patches-source\s*=\s*"([^"]+)"', body)
                src = m_src.group(1).lower() if m_src else "revanced/revanced-patches"
                
                # Extract cli-source
                m_cli = re.search(r'cli-source\s*=\s*"([^"]+)"', body)
                cli_src = m_cli.group(1).lower() if m_cli else ""
                if cli_src:
                    cli_sources.setdefault(src, set()).add(cli_src)
                
                m_pkg = re.search(r'pkg-name\s*=\s*"([^"]+)"', body)
                pkg_name = m_pkg.group(1) if m_pkg else ''
                
                if not pkg_name:
                    m_git = re.search(r'github-dlurl\s*=\s*"([^"]+)"', body)
                    m_arch = re.search(r'archive-dlurl\s*=\s*"([^"]+)"', body)
                    if m_git and 'releases/tag/' in m_git.group(1):
                        pkg_name = m_git.group(1).rstrip('/').split('/')[-1]
                    elif m_arch and 'apks/' in m_arch.group(1):
                        pkg_name = m_arch.group(1).rstrip('/').split('/')[-1]
                
                if pkg_name:
                    if enabledStable:
                        apps_stable.setdefault(src, {})[key] = pkg_name
                    if enabledDev:
                        apps_dev.setdefault(src, {})[key] = pkg_name

    return apps_stable, apps_dev, cli_sources

def process_zip(path, pkgs):
    pkg_bytes = {p: p.encode() for p in pkgs}
    buckets = {p: hashlib.md5() for p in pkgs + ['shared']}
    comp_map = {}
    all_comps = set()
    file_contents = {}
    
    with zipfile.ZipFile(path) as z:
        for info in z.infolist():
            m = re.search(r'patches/([^/]+)/', info.filename)
            if m:
                comp = m.group(1)
                if comp not in ['shared', 'all']:
                    all_comps.add(comp)
            
            if info.filename.endswith('.class'):
                content = z.read(info)
                file_contents[info.filename] = content
                for pkg, b_pkg in pkg_bytes.items():
                    if b_pkg in content:
                        if m:
                            comp = m.group(1)
                            if comp not in ['shared', 'all']:
                                comp_map[comp] = pkg

        comp_regexes = {comp: re.compile(r'(^|/)' + re.escape(comp) + r'(/|\.|-)') for comp in all_comps}
                    
        for info in sorted(z.infolist(), key=lambda x: x.filename):
            if info.is_dir(): continue
            if info.filename.startswith('META-INF/') or info.filename == 'classes.dex':
                continue
                
            content = file_contents.get(info.filename) or z.read(info)
            assigned = False
            for pkg, b_pkg in pkg_bytes.items():
                if b_pkg in content:
                    buckets[pkg].update(content)
                    assigned = True
                    break
                    
            if not assigned:
                for comp, reg in comp_regexes.items():
                    if reg.search(info.filename):
                        if comp in comp_map:
                            buckets[comp_map[comp]].update(content)
                        assigned = True
                        break
                        
            if not assigned:
                buckets['shared'].update(content)
    return {k: v.hexdigest() for k, v in buckets.items()}

def run():
    try:
        with open('tags_old.json', 'r') as f:
            tags_old = json.load(f)
    except FileNotFoundError:
        tags_old = {}
        
    try:
        with open('tags_new.json', 'r') as f:
            tags_new = json.load(f)
    except FileNotFoundError:
        tags_new = {}
    
    hash_file = '.github/configs/patch_file_hashes.json'
    if os.path.exists(hash_file):
        with open(hash_file, 'r') as f:
            hashes = json.load(f)
    else:
        hashes = {}

    apps_stable, apps_dev, cli_sources = get_app_mappings()
    
    active_stable = []
    active_dev = []

    for repo_key, new_info in tags_new.items():
        old_info = tags_old.get(repo_key, {})
        repo = new_info.get('repo', '')
        repo_lower = repo.lower()
        
        # Determine if we need to check stable/dev
        check_stable = new_info.get('stable') != "" and new_info.get('stable') != old_info.get('stable')
        check_dev = new_info.get('prerelease') != "" and new_info.get('prerelease') != old_info.get('prerelease')
        
        if not check_stable and not check_dev:
            continue
            
        repo_clis = cli_sources.get(repo_lower, set())
        
        is_revanced_or_morphe = any('revanced' in c or 'morphe' in c for c in repo_clis)
        if not repo_clis:
            is_revanced_or_morphe = True
        
        if repo_lower not in hashes:
            hashes[repo_lower] = {'stable': {}, 'dev': {}}
            
        def evaluate(tag, channel, active_list):
            repo_apps = apps_stable.get(repo_lower, {}) if channel == 'stable' else apps_dev.get(repo_lower, {})
            if not repo_apps:
                print(f"::notice::No enabled apps found for {repo} ({channel}). Skipping patch inspection.")
                return
                
            repo_pkgs = list(set(repo_apps.values()))
            
            if not is_revanced_or_morphe:
                print(f"::notice::Skipping patch inspection for {repo} (not revanced/morphe). Triggering all.")
                active_list.extend(repo_apps.keys())
                return
            
            try:
                host = new_info.get('host', 'github')
                if host == 'gitlab':
                    import urllib.request
                    encoded_repo = repo.replace('/', '%2F')
                    api_url = f"https://gitlab.com/api/v4/projects/{encoded_repo}/releases/{tag}"
                    req = urllib.request.Request(api_url)
                    with urllib.request.urlopen(req) as response:
                        release_data = json.loads(response.read().decode('utf-8'))
                        
                    download_url = None
                    file_name = None
                    for link in release_data.get('assets', {}).get('links', []):
                        name = link.get('name', '')
                        if name.endswith('.mpp') or name.endswith('.rvp') or name.endswith('.rvb'):
                            download_url = link.get('direct_asset_url') or link.get('url')
                            file_name = name
                            break
                            
                    if not download_url:
                        raise Exception(f"No .mpp, .rvp, or .rvb asset found in GitLab release for {repo}@{tag}")
                        
                    dl_req = urllib.request.Request(download_url, headers={'Accept': 'application/octet-stream'})
                    with urllib.request.urlopen(dl_req) as dl_resp, open(file_name, 'wb') as out_file:
                        out_file.write(dl_resp.read())
                else:
                    # Download asset using gh cli
                    subprocess.run(['gh', 'release', 'download', tag, '-R', repo, '-p', '*.mpp', '-p', '*.rvp', '-p', '*.rvb', '--clobber'], check=True, capture_output=True)
                
                # Find downloaded file
                files = glob.glob('*.mpp') + glob.glob('*.rvp') + glob.glob('*.rvb')
                files = [f for f in files if 'cli' not in f.lower()] # Exclude cli jar if any
                
                if not files:
                    print(f"::warning::No patch file found for {repo}@{tag}. Defaulting to trigger all.")
                    active_list.extend(repo_apps.keys())
                    return
                
                patch_file = files[0]
                new_hashes = process_zip(patch_file, repo_pkgs)
                os.remove(patch_file)
                
                old_hashes = hashes[repo_lower].get(channel, {})
                
                # Check if shared changed
                if old_hashes.get('shared') != new_hashes.get('shared'):
                    print(f"Shared patches changed for {repo} ({channel}). Triggering all apps.")
                    active_list.extend(repo_apps.keys())
                else:
                    # Check individual packages
                    for toml_key, pkg in repo_apps.items():
                        if old_hashes.get(pkg) != new_hashes.get(pkg):
                            print(f"Patch changed for {toml_key} ({pkg}) in {repo} ({channel}).")
                            active_list.append(toml_key)
                
                # Save new hashes
                hashes[repo_lower][channel] = new_hashes
                
            except Exception as e:
                print(f"::warning::Failed to process patches for {repo}@{tag}: {e}. Defaulting to trigger all.")
                active_list.extend(repo_apps.keys())
                
        if check_stable:
            evaluate(new_info.get('stable'), 'stable', active_stable)
            
        if check_dev:
            evaluate(new_info.get('prerelease'), 'dev', active_dev)

    with open(hash_file, 'w') as f:
        json.dump(hashes, f, indent=2)
        
    with open('active_patch_apps.stable.json', 'w') as f:
        json.dump(list(set(active_stable)), f)
        
    with open('active_patch_apps.dev.json', 'w') as f:
        json.dump(list(set(active_dev)), f)

if __name__ == '__main__':
    run()
