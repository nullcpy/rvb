#!/usr/bin/env python3
"""
sync_patch_sources.py
Automated patch sources state manager for CI:
1. Dynamically discovers all unique (patches-source, patches-source-host) from all .toml patch configs.
2. Queries GitHub and GitLab APIs for active releases.
3. Tracks latest stable and beta releases in .github/configs/patch_sources.json (state cache).
4. Automatically prunes sources no longer used in any TOML config.
5. Detects changes and emits TRIGGER_STABLE, TRIGGER_BETA, and TRIGGER_BLOCKED.
"""

import os
import sys
import glob
import json
import re
import urllib.request
import urllib.parse

try:
    import tomllib
except ImportError:
    try:
        import tomli as tomllib
    except ImportError:
        print("Error: neither tomllib nor tomli is available.", file=sys.stderr)
        sys.exit(1)


PATCHES_DIR = ".github/configs/patches"
STATE_FILE = ".github/configs/patch_sources.json"


def split_quoted_list(text):
    """Parses whitespace/quoted lists like "'repo1' 'repo2'" or "repo1"."""
    if not text:
        return []
    items = []
    # Match single-quoted, double-quoted, or unquoted tokens
    matches = re.findall(r"'([^']*)'|\"([^\"]*)\"|(\S+)", text.strip())
    for m in matches:
        val = m[0] or m[1] or m[2]
        if val.strip():
            items.append(val.strip())
    return items


def discover_active_sources(patches_dir=PATCHES_DIR):
    """Scans all TOML files and returns a dict: repo -> host for all enabled apps."""
    active_sources = {}
    toml_files = sorted(glob.glob(os.path.join(patches_dir, "*.toml")))

    for filepath in toml_files:
        try:
            with open(filepath, "rb") as f:
                data = tomllib.load(f)
        except Exception as e:
            print(f"Warning: Could not parse {filepath}: {e}", file=sys.stderr)
            continue

        file_defaults = {k: v for k, v in data.items() if not isinstance(v, dict)}
        def_src = file_defaults.get("patches-source", "MorpheApp/morphe-patches")
        def_host = file_defaults.get("patches-source-host", "github")

        for app_key, app_table in data.items():
            if not isinstance(app_table, dict):
                continue
            merged = dict(file_defaults)
            merged.update(app_table)

            enabled = merged.get("enabled", True)
            if isinstance(enabled, str):
                enabled = enabled.lower() == "true"
            if not enabled:
                continue

            src_str = str(merged.get("patches-source", def_src))
            host_str = str(merged.get("patches-source-host", def_host))

            src_list = split_quoted_list(src_str)
            host_list = split_quoted_list(host_str)

            for i, src in enumerate(src_list):
                host = host_list[i] if i < len(host_list) else (host_list[0] if host_list else "github")
                host = host.lower()
                if src:
                    active_sources[src] = host

    return active_sources


def fetch_github_releases(repo, token=None):
    url = f"https://api.github.com/repos/{repo}/releases?per_page=100"
    headers = {
        "User-Agent": "Mozilla/5.0 (rvb-patch-sync)",
        "Accept": "application/vnd.github+json"
    }
    if token:
        headers["Authorization"] = f"token {token}"

    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return json.loads(resp.read().decode("utf-8")), False
    except urllib.error.HTTPError as e:
        if e.code in (403, 404, 451):
            return None, True
        print(f"Warning: GitHub API error {e.code} for {repo}", file=sys.stderr)
        return None, False
    except Exception as e:
        print(f"Warning: Failed to fetch releases for {repo}: {e}", file=sys.stderr)
        return None, False


def fetch_gitlab_releases(repo):
    encoded = urllib.parse.quote(repo, safe="")
    url = f"https://gitlab.com/api/v4/projects/{encoded}/releases?per_page=100"
    headers = {"User-Agent": "Mozilla/5.0 (rvb-patch-sync)"}
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return json.loads(resp.read().decode("utf-8")), False
    except urllib.error.HTTPError as e:
        if e.code in (403, 404):
            return None, True
        print(f"Warning: GitLab API error {e.code} for {repo}", file=sys.stderr)
        return None, False
    except Exception as e:
        print(f"Warning: Failed to fetch GitLab releases for {repo}: {e}", file=sys.stderr)
        return None, False


def parse_releases(releases, host):
    if not isinstance(releases, list):
        return "", "", "", ""

    stable_tag = ""
    stable_date = ""
    beta_tag = ""
    beta_date = ""

    beta_pattern = re.compile(r"(dev|alpha|beta|rc)", re.IGNORECASE)

    if host == "gitlab":
        for rel in releases:
            tag = rel.get("tag_name") or ""
            date = rel.get("released_at") or rel.get("created_at") or ""
            if not tag:
                continue
            if beta_pattern.search(tag):
                if not beta_tag or date > beta_date:
                    beta_tag = tag
                    beta_date = date
            else:
                if not stable_tag or date > stable_date:
                    stable_tag = tag
                    stable_date = date
    else:  # github
        for rel in releases:
            tag = rel.get("tag_name") or ""
            date = rel.get("published_at") or rel.get("created_at") or ""
            is_pre = rel.get("prerelease", False) or bool(beta_pattern.search(tag))
            if not tag:
                continue
            if is_pre:
                if not beta_tag or date > beta_date:
                    beta_tag = tag
                    beta_date = date
            else:
                if not stable_tag or date > stable_date:
                    stable_tag = tag
                    stable_date = date

    return stable_tag, stable_date, beta_tag, beta_date


def main():
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    active_sources = discover_active_sources()
    print(f"Discovered {len(active_sources)} active patch source(s) across TOML configs.")

    # Load previous state
    old_state = {}
    if os.path.exists(STATE_FILE):
        try:
            with open(STATE_FILE, "r", encoding="utf-8") as f:
                old_state = json.load(f)
        except Exception as e:
            print(f"Warning: Failed to read {STATE_FILE}: {e}", file=sys.stderr)

    new_state = {}
    trigger_stable = 0
    trigger_beta = 0
    trigger_blocked = 0

    for repo, host in sorted(active_sources.items()):
        print(f"Checking {repo} ({host})...")
        old_info = old_state.get(repo, {})

        if host == "gitlab":
            releases, blocked = fetch_gitlab_releases(repo)
        else:
            releases, blocked = fetch_github_releases(repo, token)

        if blocked:
            print(f"::warning::Repository access blocked for {repo}!")
            if not old_info.get("blocked", False):
                trigger_blocked = 1
            new_state[repo] = {
                "repo": repo,
                "host": host,
                "stable": old_info.get("stable", ""),
                "stable_date": old_info.get("stable_date", ""),
                "beta": old_info.get("beta", ""),
                "beta_date": old_info.get("beta_date", ""),
                "blocked": True
            }
            continue

        if releases is None:
            # API failure or rate limit: retain old info safely
            print(f"::warning::Could not fetch releases for {repo}. Retaining previous state.")
            entry = dict(old_info)
            entry["repo"] = repo
            entry["host"] = host
            entry.setdefault("stable", "")
            entry.setdefault("stable_date", "")
            entry.setdefault("beta", "")
            entry.setdefault("beta_date", "")
            entry.setdefault("blocked", False)
            new_state[repo] = entry
            continue

        stable_tag, stable_date, beta_tag, beta_date = parse_releases(releases, host)

        old_stable = old_info.get("stable", "")
        old_beta = old_info.get("beta", "")

        if stable_tag and stable_tag != old_stable:
            print(f"::notice::Stable update detected for {repo}: {old_stable or 'none'} -> {stable_tag}")
            trigger_stable = 1

        if beta_tag and beta_tag != old_beta:
            print(f"::notice::Beta update detected for {repo}: {old_beta or 'none'} -> {beta_tag}")
            # Beta triggers if it is newer than stable
            if beta_date > stable_date:
                trigger_beta = 1

        new_state[repo] = {
            "repo": repo,
            "host": host,
            "stable": stable_tag,
            "stable_date": stable_date,
            "beta": beta_tag,
            "beta_date": beta_date,
            "blocked": False
        }

    # Save state files
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    with open(STATE_FILE, "w", encoding="utf-8") as f:
        json.dump(new_state, f, indent=2, sort_keys=True)

    with open("tags_old.json", "w", encoding="utf-8") as f:
        json.dump(old_state, f, indent=2)

    with open("tags_new.json", "w", encoding="utf-8") as f:
        json.dump(new_state, f, indent=2)

    # Export CI trigger variables
    github_output = os.environ.get("GITHUB_OUTPUT")
    if github_output:
        with open(github_output, "a", encoding="utf-8") as f:
            f.write(f"TRIGGER_STABLE={trigger_stable}\n")
            f.write(f"TRIGGER_BETA={trigger_beta}\n")
            f.write(f"TRIGGER_BLOCKED={trigger_blocked}\n")

    print(f"Patch sources synchronized: {len(new_state)} active sources tracked.")
    print(f"Triggers: STABLE={trigger_stable}, BETA={trigger_beta}, BLOCKED={trigger_blocked}")


if __name__ == "__main__":
    main()
