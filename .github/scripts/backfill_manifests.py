#!/usr/bin/env python3
"""Backfill per-release build.json manifests into rvb releases from the website data.json.

Reads data.json (schema v2 catalog), reverse-maps every build entry into the
unified filename-keyed manifest format, adds fallback entries for any live
release asset that data.json doesn't cover, and uploads build.json to each
release. Idempotent (gh release upload --clobber).

Usage:
    python3 .github/scripts/backfill_manifests.py            # dry run (default)
    python3 .github/scripts/backfill_manifests.py --apply    # actually upload

Env:
    DATA_JSON   path to website data.json (default: ../nullcpy.github.io/data.json)
    RVB_REPO    owner/repo (default: nullcpy/rvb)
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

SCHEMA_VERSION = 1


def run_cmd(cmd, check=True):
    result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    if check and result.returncode != 0:
        print(f"Error running command: {cmd}\n{result.stderr}", file=sys.stderr)
        sys.exit(1)
    return result.stdout.strip()


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
    match = re.search(
        r"-(arm64-v8a|armeabi-v7a|arm-v7a|aarch64|arm64|arm32|arm|x86_64|x64|x86|universal|all)(?:-(?:apk|module))?\.(?:apk|zip)$",
        fname,
        re.IGNORECASE,
    )
    if match:
        return match.group(1)
    if version:
        clean_ver = re.escape(version.lstrip("v"))
        m = re.search(rf"-v?{clean_ver}-([a-zA-Z0-9_-]+?)(?:-(?:apk|module))?\.(?:apk|zip)$", fname, re.IGNORECASE)
        if m:
            return m.group(1)
    name_no_ext = re.sub(r"\.(?:apk|zip)$", "", fname, flags=re.IGNORECASE)
    name_no_mode = re.sub(r"-(?:apk|module)$", "", name_no_ext, flags=re.IGNORECASE)
    parts = name_no_mode.split("-")
    if len(parts) > 1:
        return parts[-1]
    return "all"


def file_prefix_of(fname):
    m = re.match(r"^(.*?)-(?:v[0-9]|module-)", fname, re.IGNORECASE)
    return m.group(1) if m else fname.rsplit(".", 1)[0]


def fallback_entry(fname, origin_build, published_at):
    lower = fname.lower()
    return {
        "name": file_prefix_of(fname),
        "version": None,
        "appKey": None,
        "appName": None,
        "arch": normalize_arch(extract_arch(fname)),
        "fileType": "APK" if lower.endswith(".apk") else "Module",
        "brandKey": None,
        "brandName": None,
        "variant": None,
        "subVariant": None,
        "packageName": None,
        "patchSources": [],
        "changelogs": [],
        "appliedPatches": [],
        "originBuild": origin_build,
        "publishedAt": published_at,
    }


def manifest_entry_from_app(file_obj, app, brand, variant_meta, build, published_at):
    lower = file_obj["name"].lower()
    return {
        "name": variant_meta.get("prefix"),
        "version": build.get("version"),
        "appKey": app.get("appKey"),
        "appName": app.get("appName"),
        "arch": file_obj.get("arch") or normalize_arch(extract_arch(file_obj["name"], build.get("version") or "")),
        "fileType": file_obj.get("fileType") or ("APK" if lower.endswith(".apk") else "Module"),
        "brandKey": brand.get("brandKey"),
        "brandName": brand.get("brandName"),
        "variant": build.get("variant"),
        "subVariant": build.get("subVariant"),
        "packageName": variant_meta.get("packageName"),
        "patchSources": build.get("patchSources") or [],
        "changelogs": build.get("changelogs") or [],
        "appliedPatches": build.get("appliedPatches") or [],
        "originBuild": str(build.get("build")) if not build.get("isArchive") else None,
        "publishedAt": build.get("publishedAt") or published_at,
    }


def load_live_releases(repo):
    raw = run_cmd(f'gh api --paginate "repos/{repo}/releases?per_page=100"')
    releases = json.loads(raw)
    return {r["tag_name"]: r for r in releases if not r.get("draft")}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true", help="actually upload manifests (default: dry run)")
    ap.add_argument("--repo", default=os.environ.get("RVB_REPO", "nullcpy/rvb"))
    args = ap.parse_args()

    data_json_path = Path(os.environ.get("DATA_JSON", "../nullcpy.github.io/data.json")).resolve()
    if not data_json_path.exists():
        print(f"Error: data.json not found at {data_json_path}", file=sys.stderr)
        sys.exit(1)
    catalog = json.load(open(data_json_path, encoding="utf-8"))
    print(f"Loaded catalog: {len(catalog.get('apps', []))} apps, updated_at={catalog.get('updated_at')}")

    live = load_live_releases(args.repo)
    print(f"Live releases: {len(live)}")

    numbered = {}   # tag -> manifest
    archives = {}   # stable/beta -> manifest
    used_assets = set()  # (tag, fname) accounted for via data.json

    def new_manifest(kind, tag, channel, published_at):
        return {
            "schema": SCHEMA_VERSION,
            "kind": kind,
            "meta": {"build": tag, "channel": channel, "publishedAt": published_at},
            "files": {},
        }

    for app in catalog.get("apps", []):
        for brand in app.get("brands", []):
            # variant meta map keyed by (variant, subVariant): prefix + packageName
            vmeta = {}
            for v in brand.get("variants", []):
                pf = v.get("apkFilter")
                # strip ^ ... -v.*\.apk$ — but prefix may contain regex metachars;
                # escape was never applied by update_website_catalog.py, so a plain
                # cut at "-v.*\\.apk$" is right for all current data.
                prefix = None
                if pf:
                    m = re.match(r"^\^(.*)-v\.\*\\\.apk\$$", pf)
                    if m:
                        prefix = m.group(1)
                vmeta[(v.get("variant"), v.get("subVariant"))] = {
                    "prefix": prefix,
                    "packageName": v.get("packageName"),
                }
            for b in brand.get("builds", []):
                tag = str(b.get("releaseId") or b.get("build") or "")
                is_archive = bool(b.get("isArchive"))
                channel = b.get("releaseType") or "stable"
                bucket = archives if is_archive else numbered
                if tag not in bucket:
                    rel = live.get(tag, {})
                    kind = "archive" if is_archive else "build"
                    if is_archive:
                        ch = channel
                    else:
                        ch = "beta" if rel.get("prerelease") else "stable"
                    bucket[tag] = new_manifest(kind, tag, ch, b.get("publishedAt") or rel.get("published_at") or "")
                manifest = bucket[tag]
                vm = vmeta.get((b.get("variant"), b.get("subVariant")), {})
                for f in b.get("assets", []):
                    fname = f["name"]
                    manifest["files"][fname] = manifest_entry_from_app(f, app, brand, vm, b, b.get("publishedAt"))
                    used_assets.add((tag, fname))

    # Fix channel on numbered manifests that were created lazily by data.json
    # entries (release's prerelease flag is authoritative).
    for tag, m in numbered.items():
        rel = live.get(tag)
        m["meta"]["channel"] = "beta" if (rel and rel.get("prerelease")) else "stable"

    # Fallback entries: live assets data.json doesn't cover → synthesize from filename.
    fallback_count = 0
    for tag, rel in live.items():
        target = archives.get(tag) if tag in ("stable", "beta") else numbered.get(tag)
        channel = "beta" if rel.get("prerelease") else "stable"
        pub = (rel.get("published_at") or "").replace("+00:00", "Z")
        if target is None:
            target = new_manifest("archive" if tag in ("stable", "beta") else "build", tag, channel, pub)
            (archives if tag in ("stable", "beta") else numbered)[tag] = target
        for a in rel.get("assets", []):
            fname = a["name"]
            low = fname.lower()
            if not (low.endswith(".apk") or low.endswith(".zip")):
                continue
            if (tag, fname) in used_assets:
                continue
            target["files"][fname] = fallback_entry(fname, None if tag in ("stable", "beta") else tag, pub)
            fallback_count += 1

    total_files = sum(len(m["files"]) for m in numbered.values()) + sum(len(m["files"]) for m in archives.values())
    print(f"Manifests: {len(numbered)} numbered, {len(archives)} archive; {total_files} file entries "
          f"({fallback_count} synthesized from filename fallback)")

    # Entries that data.json had but the live release no longer has the asset for
    # (shouldn't happen post-sync; reported only).
    ghost = 0
    for tag, m in list(numbered.items()) + list(archives.items()):
        rel = live.get(tag)
        if not rel:
            print(f"Warning: manifest for {tag} has no live release — skipping upload")
            (archives if tag in ("stable", "beta") else numbered).pop(tag)
            ghost += sum(1 for _ in m["files"])
            continue
        live_names = {a["name"] for a in rel.get("assets", [])}
        missing = [f for f in m["files"] if f not in live_names]
        for f in missing:
            print(f"  note: {tag}: manifest entry {f} not in live assets (kept; fold will drop it if still missing)")

    if not args.apply:
        print("\nDRY RUN — nothing uploaded. Re-run with --apply to upload.")
        sample = sorted(numbered.items(), key=lambda kv: kv[0])[-1] if numbered else None
        if sample:
            tag, m = sample
            print(f"\nSample manifest for build {tag} (first 2 files):")
            out = dict(m)
            items = list(out["files"].items())[:2]
            out["files"] = dict(items)
            print(json.dumps(out, indent=2)[:1500])
        return

    tmp = Path(tempfile.mkdtemp(prefix="manifests_"))
    try:
        uploads = list(numbered.items()) + list(archives.items())
        for i, (tag, m) in enumerate(uploads, 1):
            fdir = tmp / re.sub(r"[^A-Za-z0-9._-]", "_", tag)
            fdir.mkdir(parents=True, exist_ok=True)
            fpath = fdir / "build.json"
            with open(fpath, "w", encoding="utf-8") as fh:
                json.dump(m, fh, separators=(",", ":"))
            print(f"[{i}/{len(uploads)}] Uploading build.json to {tag} ({len(m['files'])} files)...")
            run_cmd(f'gh release upload "{tag}" "{fpath}" --clobber -R "{args.repo}"')
        print("Backfill complete.")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
