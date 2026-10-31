#!/usr/bin/env python3
"""
sync_patch_sources.py
Automated patch sources state manager for CI:
1. Dynamically discovers all unique (patches-source, patches-source-host) from all .toml patch configs.
2. Queries GitHub, GitLab and Codeberg APIs for active releases.
3. Tracks latest stable and beta releases in state/patch_sources.json (state cache).
4. Automatically prunes sources no longer used in any TOML config.
5. Detects changes and emits TRIGGER_STABLE, TRIGGER_BETA, and TRIGGER_BLOCKED.
6. Writes changed_sources.json: the one canonical "what moved since last run"
    record set that every later step consumes (see derive_source_changes.py).
"""

import os
import sys
import glob
import json
import re
import time
import urllib.request
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
# Sibling modules, importable only because of the insert above - keep them after
# it. isort:skip stops the formatter lifting them back over the path setup.
import jsonfmt  # isort:skip  # noqa: E402
import derive_source_changes  # isort:skip  # noqa: E402
import channels  # isort:skip  # noqa: E402

try:
    import tomllib
except ImportError:
    try:
        import tomli as tomllib
    except ImportError:
        print("Error: neither tomllib nor tomli is available.", file=sys.stderr)
        sys.exit(1)


PATCHES_DIR = "configs/patches"
STATE_FILE = "state/patch_sources.json"


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

        file_defaults = {k: v for k,
                         v in data.items() if not isinstance(v, dict)}
        def_src = file_defaults.get(
            "patches-source", "MorpheApp/morphe-patches")
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
                host = host_list[i] if i < len(host_list) else (
                    host_list[0] if host_list else "github")
                host = host.lower()
                if src:
                    active_sources[src] = host

    return active_sources


def _fetch_releases_with_retry(req, repo, forge_name, blocked_codes, timeout=25, max_retries=3):
    last_err = None
    for attempt in range(1, max_retries + 1):
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return json.loads(resp.read().decode("utf-8")), False
        except urllib.error.HTTPError as e:
            if e.code in blocked_codes:
                if forge_name == "GitHub" and e.code == 403:
                    if e.headers.get("X-RateLimit-Remaining") == "0":
                        print(
                            f"Warning: GitHub API rate limit exceeded for {repo}", file=sys.stderr)
                        return None, False
                return None, True
            if e.code in (429, 500, 502, 503, 504) and attempt < max_retries:
                time.sleep(2 * attempt)
                continue
            print(
                f"Warning: {forge_name} API error {e.code} for {repo}", file=sys.stderr)
            return None, False
        except Exception as e:
            last_err = e
            if attempt < max_retries:
                time.sleep(2 * attempt)
                continue
    print(
        f"Warning: Failed to fetch {forge_name} releases for {repo}: {last_err}", file=sys.stderr)
    return None, False


def fetch_github_releases(repo, token=None):
    url = f"https://api.github.com/repos/{repo}/releases?per_page=100"
    headers = {
        "User-Agent": "Mozilla/5.0 (rvb-patch-sync)",
        "Accept": "application/vnd.github+json"
    }
    if token:
        headers["Authorization"] = f"token {token}"

    req = urllib.request.Request(url, headers=headers)
    return _fetch_releases_with_retry(
        req, repo, "GitHub", blocked_codes=(403, 404, 451), timeout=25, max_retries=3
    )


def fetch_gitlab_releases(repo):
    encoded = urllib.parse.quote(repo, safe="")
    url = f"https://gitlab.com/api/v4/projects/{encoded}/releases?per_page=100"
    headers = {
        "User-Agent": "Mozilla/5.0 (rvb-patch-sync)",
        "Accept": "application/json"
    }
    req = urllib.request.Request(url, headers=headers)
    return _fetch_releases_with_retry(
        req, repo, "GitLab", blocked_codes=(403, 404), timeout=25, max_retries=3
    )


def fetch_codeberg_releases(repo, token=None):
    """Release list from codeberg.org, which runs Forgejo (Gitea API).

    The response shape matches GitHub's (tag_name / prerelease / published_at), so
    parse_releases reads it on that branch. Two differences that matter: the page
    size parameter is `limit` (`per_page` is ignored, and the default page is only
    30 items), and `limit=50` is that API's maximum.
    Codeberg's community instance can be slow on cold queries, so use a higher
    timeout and retry on transient failures.
    """
    url = f"https://codeberg.org/api/v1/repos/{repo}/releases?limit=50"
    headers = {
        "User-Agent": "Mozilla/5.0 (rvb-patch-sync)",
        "Accept": "application/json"
    }
    if token:
        headers["Authorization"] = f"token {token}"

    req = urllib.request.Request(url, headers=headers)
    return _fetch_releases_with_retry(
        req, repo, "Codeberg", blocked_codes=(403, 404, 451), timeout=45, max_retries=3
    )


def parse_releases(releases, host):
    if not isinstance(releases, list):
        return "", "", "", ""

    stable_tag = ""
    stable_date = ""
    beta_tag = ""
    beta_date = ""

    # channels.py owns the marker words, the engine's GitLab arm mirrors them and
    # test_channel_markers.sh keeps the two honest. GitLab releases carry no
    # pre-release flag, so there the tag is the whole signal; GitHub and Forgejo
    # have the flag, and the tag only names a pre-release the flag forgot.
    if host == "gitlab":
        for rel in releases:
            tag = rel.get("tag_name") or ""
            date = rel.get("released_at") or rel.get("created_at") or ""
            if not tag:
                continue
            if channels.is_pre_release_tag(tag):
                if not beta_tag or date > beta_date:
                    beta_tag = tag
                    beta_date = date
            else:
                if not stable_tag or date > stable_date:
                    stable_tag = tag
                    stable_date = date
    else:  # github and codeberg: same release shape, prerelease flag + published_at
        for rel in releases:
            tag = rel.get("tag_name") or ""
            date = rel.get("published_at") or rel.get("created_at") or ""
            # GitHub's API never lists drafts; Forgejo's does, and an unpublished
            # release is no one's channel release.
            if rel.get("draft"):
                continue
            is_pre = (bool(rel.get("prerelease"))
                      or channels.is_pre_release_tag(tag))
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
    codeberg_token = os.environ.get("CODEBERG_TOKEN")
    active_sources = discover_active_sources()
    print(
        f"Discovered {len(active_sources)} active patch source(s) across TOML configs.")

    # Load previous state
    old_state = {}
    if os.path.exists(STATE_FILE):
        try:
            with open(STATE_FILE, "r", encoding="utf-8") as f:
                old_state = json.load(f)
        except Exception as e:
            print(
                f"Warning: Failed to read {STATE_FILE}: {e}", file=sys.stderr)

    new_state = {}
    trigger_stable = 0
    trigger_beta = 0
    trigger_blocked = 0

    for repo, host in sorted(active_sources.items()):
        print(f"::group::{repo} ({host})")
        old_info = old_state.get(repo, {})

        if host == "gitlab":
            releases, blocked = fetch_gitlab_releases(repo)
        elif host == "codeberg":
            releases, blocked = fetch_codeberg_releases(repo, codeberg_token)
        else:
            releases, blocked = fetch_github_releases(repo, token)

        if blocked:
            print(f"  ::warning::Repository access blocked!")
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
            print("::endgroup::")
            continue

        if releases is None:
            # API failure or rate limit: retain old info safely
            print(f"  ::warning::Could not fetch releases. Retaining previous state.")
            entry = dict(old_info)
            entry["repo"] = repo
            entry["host"] = host
            entry.setdefault("stable", "")
            entry.setdefault("stable_date", "")
            entry.setdefault("beta", "")
            entry.setdefault("beta_date", "")
            entry.setdefault("blocked", False)
            new_state[repo] = entry
            print("::endgroup::")
            continue

        stable_tag, stable_date, beta_tag, beta_date = parse_releases(
            releases, host)

        old_stable = old_info.get("stable", "")
        old_beta = old_info.get("beta", "")

        if stable_tag and stable_tag != old_stable:
            print(f"  ↑ Stable: {old_stable or 'none'} → {stable_tag}")
            print(
                f"::notice title=New Stable Release::{repo} — {old_stable or 'none'} → {stable_tag}")
        elif stable_tag:
            print(f"    Stable: {stable_tag} (no change)")
        else:
            print(f"    Stable: (none)")

        if beta_tag and beta_tag != old_beta:
            print(f"  ↑ Beta:   {old_beta or 'none'} → {beta_tag}")
            # Beta triggers if it is newer than stable
            if beta_date > stable_date:
                print(
                    f"::notice title=New Beta Release::{repo} — {old_beta or 'none'} → {beta_tag}")
        elif beta_tag:
            print(f"    Beta:   {beta_tag} (no change)")
        else:
            print(f"    Beta:   (none)")

        new_state[repo] = {
            "repo": repo,
            "host": host,
            "stable": stable_tag,
            "stable_date": stable_date,
            "beta": beta_tag,
            "beta_date": beta_date,
            "blocked": False
        }
        print("::endgroup::")

    # Save state files
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    jsonfmt.write(STATE_FILE, new_state, sort_keys=True)

    jsonfmt.write("tags_old.json", old_state)

    jsonfmt.write("tags_new.json", new_state)

    # One derivation of "what changed", shared by every later step instead of
    # each re-diffing tags_old/tags_new with its own rules. The trigger flags
    # below are read out of these records, so a trigger can never disagree with
    # what ci_check_app_patches.py and ci_generate_configs.sh will act on.
    changed_records = derive_source_changes.derive(old_state, new_state)
    jsonfmt.write("changed_sources.json", changed_records, sort_keys=True)
    if any(r["channel"] == "stable" for r in changed_records):
        trigger_stable = 1
    if any(r["channel"] == "beta" and r["newer_than_base"] for r in changed_records):
        trigger_beta = 1

    # Export CI trigger variables
    github_output = os.environ.get("GITHUB_OUTPUT")
    if github_output:
        with open(github_output, "a", encoding="utf-8") as f:
            f.write(f"TRIGGER_STABLE={trigger_stable}\n")
            f.write(f"TRIGGER_BETA={trigger_beta}\n")
            f.write(f"TRIGGER_BLOCKED={trigger_blocked}\n")

    print(
        f"Patch sources synchronized: {len(new_state)} active sources tracked.")
    print(
        f"Triggers: STABLE={trigger_stable}, BETA={trigger_beta}, BLOCKED={trigger_blocked}")
    if not trigger_stable and not trigger_beta and not trigger_blocked:
        print("::notice title=Patch Sync Summary::No new patch releases detected")
    else:
        parts = []
        if trigger_stable:
            parts.append("STABLE")
        if trigger_beta:
            parts.append("BETA")
        if trigger_blocked:
            parts.append("BLOCKED")
        print(
            f"::notice title=Patch Sync Summary::Build triggered — {', '.join(parts)}")


if __name__ == "__main__":
    main()
