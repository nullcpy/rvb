import os, json, zipfile, hashlib, re, subprocess, glob
import urllib.request

def load_channel_config(channel):
    filename = f"config.{channel}.json"
    if not os.path.exists(filename):
        subprocess.run(["bash", ".github/scripts/ci_compile_base_configs.sh"], check=False)
    if os.path.exists(filename):
        try:
            with open(filename, 'r', encoding='utf-8') as f:
                return json.load(f)
        except Exception as e:
            print(f"Warning: Failed to read {filename}: {e}")
    return {}

def get_app_mappings():
    apps_stable = {}
    apps_beta = {}
    cli_sources = {}

    for channel, target_dict in [('stable', apps_stable), ('beta', apps_beta)]:
        data = load_channel_config(channel)
        for key, val in data.items():
            if not isinstance(val, dict):
                continue

            enabled = val.get('enabled', True)
            if isinstance(enabled, str):
                enabled = enabled.lower() == 'true'
            if not enabled:
                continue

            src = (val.get('patches-source') or 'morpheapp/morphe-patches').strip().lower()
            cli_src = (val.get('cli-source') or 'morpheapp/morphe-desktop').strip().lower()
            if cli_src:
                cli_sources.setdefault(src, set()).add(cli_src)

            pkg_name = val.get('pkg-name') or ''
            app_name = (val.get('app-name') or '').lower()
            patch_folder = (val.get('patch-folder') or '').lower()

            if not pkg_name:
                m_git = val.get('github-dlurl') or ''
                m_arch = val.get('archive-dlurl') or ''
                if 'releases/tag/' in m_git:
                    pkg_name = m_git.rstrip('/').split('/')[-1]
                elif 'apks/' in m_arch:
                    pkg_name = m_arch.rstrip('/').split('/')[-1]

            if pkg_name:
                target_dict.setdefault(src, {})[key] = {
                    'pkg': pkg_name,
                    'app_name': app_name,
                    'patch_folder': patch_folder
                }

    return apps_stable, apps_beta, cli_sources

def process_zip(path, pkg_info):
    pkgs = list(pkg_info.keys())
    pkg_bytes = {p: p.encode() for p in pkgs}
    buckets = {p: hashlib.md5() for p in pkgs + ['shared']}
    comp_map = {}
    all_comps = set()
    
    with zipfile.ZipFile(path) as z:
        # Pass 1: Build all_comps
        for info in z.infolist():
            m = re.search(r'(?:^|/)(?:patches|patched_up)/([^/]+)/', info.filename)
            if m:
                comp = m.group(1)
                if comp not in ['shared', 'all']:
                    all_comps.add(comp)
                    
        # Inject explicitly defined patch-folders from config so they are evaluated even if the regex above missed them
        for meta in pkg_info.values():
            pf_str = meta.get('patch_folder', '')
            if pf_str:
                for pf in pf_str.split():
                    if pf != '*':
                        all_comps.add(pf)
                        
        # Pass 2: Heuristics
        for comp in all_comps:
            for pkg, meta in pkg_info.items():
                pf_str = meta.get('patch_folder', '')
                an = meta.get('app_name', '')
                an_clean = an.replace('-', '')
                
                if pf_str:
                    pfs = pf_str.split()
                    if '*' in pfs:
                        pass # Handled by global catch-all
                    elif comp in pfs:
                        comp_map.setdefault(comp, set()).add(pkg)
                    continue
                    
                if an and (comp == an or comp == an_clean):
                    comp_map.setdefault(comp, set()).add(pkg)
                elif pkg and comp in pkg.split('.'):
                    # Prevent youtube from mapping to youtube-music
                    if comp == 'youtube' and 'music' in an.lower(): continue
                    comp_map.setdefault(comp, set()).add(pkg)
            
        # Pass 3: Bytecode Fallback
        for info in z.infolist():
            if info.filename.endswith('.class'):
                content = z.read(info)
                for pkg, b_pkg in pkg_bytes.items():
                    pf = pkg_info[pkg].get('patch_folder', '')
                    if pf: continue # Explicitly defined patch-folders shouldn't use bytecode fallback
                    
                    if b_pkg in content:
                        m = re.search(r'(?:^|/)(?:patches|patched_up)/([^/]+)/', info.filename)
                        if m:
                            comp = m.group(1)
                            if comp not in ['shared', 'all']:
                                comp_map.setdefault(comp, set()).add(pkg)

        sorted_comps = sorted(list(all_comps), key=len, reverse=True)
        comp_regexes = {comp: re.compile(r'(^|/|-|_)' + re.escape(comp) + r'(/|\.|-|_)') for comp in sorted_comps}
                    
        for info in sorted(z.infolist(), key=lambda x: x.filename):
            if info.is_dir(): continue
            if info.filename.startswith('META-INF/') or info.filename == 'classes.dex':
                continue
                
            content = z.read(info)
            
            # Wildcard catch-all: if an app uses '*', hash EVERYTHING for it
            for pkg in pkgs:
                pf_str = pkg_info[pkg].get('patch_folder', '')
                if pf_str and '*' in pf_str.split():
                    buckets[pkg].update(content)
                    
            assigned = False
            # 1. Directory Structure matching (Primary source of truth)
            for comp, reg in comp_regexes.items():
                if reg.search(info.filename):
                    if comp in comp_map:
                        for p in comp_map[comp]:
                            buckets[p].update(content)
                    assigned = True # Mark as handled to avoid shared bucket poisoning
                    break
                    
            # 2. Bytecode Fallback (For isolated patches or shared/ folders)
            if not assigned:
                for pkg, b_pkg in pkg_bytes.items():
                    if b_pkg in content:
                        buckets[pkg].update(content)
                        assigned = True
                        
            if not assigned:
                buckets['shared'].update(content)
    return {k: v.hexdigest() for k, v in buckets.items()}

def evaluate_repo_channel(repo_lower, repo, tag, channel, new_info, hashes, active_list, apps_stable, apps_beta, is_revanced_or_morphe):
    repo_apps = apps_stable.get(repo_lower, {}) if channel == 'stable' else apps_beta.get(repo_lower, {})
    print(f"::group::{repo} [{channel}] @ {tag}")
    if not repo_apps:
        print(f"  No enabled apps found. Skipping patch inspection.")
        print("::endgroup::")
        return
        
    pkg_info = {}
    for meta in repo_apps.values():
        pkg = meta['pkg']
        if pkg not in pkg_info:
            pkg_info[pkg] = meta
    
    if not is_revanced_or_morphe:
        print(f"  Not a revanced/morphe patcher — triggering all {len(repo_apps)} app(s).")
        active_list.extend(repo_apps.keys())
        print("::endgroup::")
        return
    
    # Cleanup stale files before download
    for old_f in glob.glob('*.mpp') + glob.glob('*.rvp') + glob.glob('*.jar'):
        os.remove(old_f)
    
    try:
        host = new_info.get('host', 'github')
        if host == 'gitlab':
            encoded_repo = repo.replace('/', '%2F')
            api_url = f"https://gitlab.com/api/v4/projects/{encoded_repo}/releases/{tag}"
            req = urllib.request.Request(api_url)
            with urllib.request.urlopen(req) as response:
                release_data = json.loads(response.read().decode('utf-8'))
                
            download_url = None
            file_name = None
            for link in release_data.get('assets', {}).get('links', []):
                name = link.get('name', '')
                if name.endswith('.mpp') or name.endswith('.rvp') or name.endswith('.jar'):
                    download_url = link.get('direct_asset_url') or link.get('url')
                    file_name = name
                    break
                    
            if not download_url:
                raise Exception(f"No .mpp, .rvp, or .jar asset found in GitLab release for {repo}@{tag}")
                
            dl_req = urllib.request.Request(download_url, headers={'Accept': 'application/octet-stream'})
            with urllib.request.urlopen(dl_req) as dl_resp, open(file_name, 'wb') as out_file:
                out_file.write(dl_resp.read())
        else:
            # Download asset using gh cli
            subprocess.run(['gh', 'release', 'download', tag, '-R', repo, '-p', '*.mpp', '-p', '*.rvp', '-p', '*.jar', '--clobber'], check=True, capture_output=True)
        
        # Find downloaded files
        files = glob.glob('*.mpp') + glob.glob('*.rvp') + glob.glob('*.jar')
        files = [f for f in files if 'cli' not in f.lower()] # Exclude cli jar if any
        
        if len(files) > 1:
            no_dev_files = [f for f in files if '-dev' not in f.lower()]
            if len(no_dev_files) == 1:
                files = no_dev_files
        
        if len(files) > 1:
            no_debug_files = [f for f in files if 'debug' not in f.lower()]
            if len(no_debug_files) >= 1:
                files = no_debug_files
                
        if len(files) > 1:
            version = tag[1:] if tag.startswith('v') else tag
            version_files = [f for f in files if version in f]
            if len(version_files) >= 1:
                files = version_files
        
        if not files:
            print(f"  ::warning::No patch file found. Defaulting to trigger all {len(repo_apps)} app(s).")
            active_list.extend(repo_apps.keys())
            print("::endgroup::")
            return
        
        new_hashes = process_zip(files[0], pkg_info)
        
        # Cleanup downloaded files
        for f in glob.glob('*.mpp') + glob.glob('*.rvp') + glob.glob('*.jar'):
            os.remove(f)
        
        old_hashes = hashes[repo_lower].get(channel, {})
        
        # Check if shared changed
        if old_hashes.get('shared') != new_hashes.get('shared'):
            print(f"  Shared patches changed — triggering all {len(repo_apps)} app(s).")
            active_list.extend(repo_apps.keys())
        else:
            # Check individual packages
            changed = []
            for toml_key, meta in repo_apps.items():
                pkg_name = meta['pkg']
                if old_hashes.get(pkg_name) != new_hashes.get(pkg_name):
                    changed.append((toml_key, pkg_name))
                    active_list.append(toml_key)
            if changed:
                print(f"  {len(changed)} app(s) changed:")
                for toml_key, pkg_name in changed:
                    print(f"    ✎ {toml_key} ({pkg_name})")
            else:
                print(f"  No patch changes detected for {len(repo_apps)} app(s).")
        
        # Save new hashes
        hashes[repo_lower][channel] = new_hashes
        print("::endgroup::")
        
    except Exception as e:
        print(f"  ::warning::Failed to process patches @ {tag}: {e}. Defaulting to trigger all.")
        active_list.extend(repo_apps.keys())
        # Also clean up on failure
        for f in glob.glob('*.mpp') + glob.glob('*.rvp') + glob.glob('*.jar'):
            try:
                os.remove(f)
            except:
                pass
        print("::endgroup::")


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

    apps_stable, apps_beta, cli_sources = get_app_mappings()
    
    active_stable = []
    active_beta = []

    for repo_key, new_info in tags_new.items():
        old_info = tags_old.get(repo_key, {})
        repo = new_info.get('repo', '')
        repo_lower = repo.lower()
        
        # Determine if we need to check stable/beta
        check_stable = new_info.get('stable') != "" and new_info.get('stable') != old_info.get('stable')
        new_beta = new_info.get('beta', '')
        old_beta = old_info.get('beta', '')
        check_beta = new_beta != "" and new_beta != old_beta
        
        if new_info.get('enabled') is False or new_info.get('blocked') is True:
            check_stable = False
            check_beta = False
        
        if not check_stable and not check_beta:
            continue
            
        repo_clis = cli_sources.get(repo_lower, set())
        
        is_revanced_or_morphe = any('revanced' in c or 'morphe' in c for c in repo_clis)
        if not repo_clis:
            is_revanced_or_morphe = True
        
        if repo_lower not in hashes:
            hashes[repo_lower] = {}
        hashes[repo_lower].setdefault('stable', {})
        hashes[repo_lower].setdefault('beta', {})
            
        if check_stable:
            evaluate_repo_channel(repo_lower, repo, new_info.get('stable'), 'stable', new_info, hashes, active_stable, apps_stable, apps_beta, is_revanced_or_morphe)
            
        if check_beta:
            evaluate_repo_channel(repo_lower, repo, new_beta, 'beta', new_info, hashes, active_beta, apps_stable, apps_beta, is_revanced_or_morphe)

    with open(hash_file, 'w') as f:
        json.dump(hashes, f, indent=2, sort_keys=True)
        
    with open('active_patch_apps.stable.json', 'w') as f:
        json.dump(list(set(active_stable)), f)
        
    with open('active_patch_apps.beta.json', 'w') as f:
        json.dump(list(set(active_beta)), f)

if __name__ == '__main__':
    run()
