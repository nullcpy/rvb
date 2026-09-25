#!/usr/bin/env python3
"""Rebuild an archive release's cumulative build.json from the numbered releases.

Recovery tool for the failure mode where merge_archive_manifest.sh lost the
previous cumulative manifest (a transient `gh release download` failure fell
back to an empty old manifest, so the archive build.json restarted from the
latest build's entries only). This script:
  1. lists the APK/ZIP assets actually present on the archive release,
  2. downloads build.json from every numbered release,
  3. merges in the entries whose filenames still live on the archive
     (newest originBuild wins for files covered by several releases),
  4. synthesizes filename-derived fallback entries (empty appliedPatches)
     for live assets no release manifest covers — reported separately.

Idempotent; dry-run by default.

Usage:
    python3 .github/scripts/repair_archive_manifest.py [--archive stable] [--apply]

Env:
    RVB_REPO   owner/repo (default: nullcpy/rvb)
"""
import argparse
import datetime
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from backfill_manifests import fallback_entry  # noqa: E402

SCHEMA_VERSION = 1


def run_args(args, check=True, stdout=None):
    # argv list (no shell) so single-quoted jq filters work on Windows too.
    result = subprocess.run(
        args, capture_output=stdout is None, text=True, stdout=stdout)
    if check and result.returncode != 0:
        err = result.stderr if stdout is None else ""
        print(
            f"Error running command: {' '.join(args)}\n{err}", file=sys.stderr)
        sys.exit(1)
    return (result.stdout or "").strip()


def archive_live_assets(repo, tag):
    raw = run_args(["gh", "api", "--paginate", f"repos/{repo}/releases/tags/{tag}",
                    "-q", ".assets[].name"])
    return [l for l in raw.splitlines() if l.lower().endswith((".apk", ".zip"))]


def numbered_releases(repo):
    """All non-draft numbered releases, ascending by tag, with their build.json asset id."""
    raw = run_args(["gh", "api", "--paginate",
                   f"repos/{repo}/releases?per_page=100"])
    out = []
    for r in json.loads(raw):
        tag = r["tag_name"]
        if r.get("draft") or not re.fullmatch(r"\d+", tag):
            continue
        asset_id = next((a["id"] for a in r.get("assets", [])
                        if a["name"] == "build.json"), None)
        out.append({"tag": tag, "asset_id": asset_id,
                    "published_at": (r.get("published_at") or "").replace("+00:00", "Z")})
    return sorted(out, key=lambda r: int(r["tag"]))


def fetch_release_manifest(repo, rel, tmpdir):
    if rel["asset_id"] is None:
        return None
    fpath = Path(tmpdir) / f"{rel['tag']}.json"
    with open(fpath, "wb") as fh:
        proc = subprocess.run(
            ["gh", "api", "-H", "Accept: application/octet-stream",
             f"repos/{repo}/releases/assets/{rel['asset_id']}"],
            stdout=fh, stderr=subprocess.PIPE, text=True)
    if proc.returncode != 0:
        print(f"Warning: failed to fetch build.json for {rel['tag']}: {proc.stderr.strip()}",
              file=sys.stderr)
        return None
    try:
        return json.loads(fpath.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        print(
            f"Warning: build.json for {rel['tag']} is not valid JSON — skipping", file=sys.stderr)
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--archive", default="stable", choices=["stable", "beta"],
                    help="archive release tag to repair")
    ap.add_argument("--apply", action="store_true",
                    help="upload the rebuilt manifest (default: dry run)")
    ap.add_argument(
        "--repo", default=os.environ.get("RVB_REPO", "nullcpy/rvb"))
    args = ap.parse_args()

    live = archive_live_assets(args.repo, args.archive)
    live_set = set(live)
    print(f"Archive '{args.archive}': {len(live)} live APK/ZIP assets")

    releases = numbered_releases(args.repo)
    if releases:
        print(
            f"Numbered releases to scan: {len(releases)} ({releases[0]['tag']}..{releases[-1]['tag']})")
    else:
        print("No numbered releases found")

    files = {}
    tmpdir = tempfile.mkdtemp(prefix="repair_manifest_")
    try:
        for rel in releases:  # ascending: newer builds overwrite older entries
            m = fetch_release_manifest(args.repo, rel, tmpdir)
            if not m:
                continue
            hits = 0
            for fname, entry in (m.get("files") or {}).items():
                if fname in live_set:
                    files[fname] = entry
                    hits += 1
            if hits:
                print(
                    f"  {rel['tag']}: {hits} entries still live on {args.archive}")
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)

    missing = sorted(live_set - set(files))
    for fname in missing:
        files[fname] = fallback_entry(fname, None, "")
    if missing:
        print(f"\n{len(missing)} live assets covered by NO release manifest "
              f"(fallback entries, appliedPatches empty):")
        for f in missing:
            print(f"  {f}")

    now_iso = datetime.datetime.now(
        datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    manifest = {
        "schema": SCHEMA_VERSION,
        "kind": "archive",
        "meta": {"build": args.archive, "channel": args.archive, "publishedAt": now_iso},
        "files": files,
    }
    print(f"\nRebuilt manifest: {len(files)} entries for {len(live)} live assets "
          f"({len(files) - len(missing)} from release manifests, {len(missing)} fallback)")

    out_path = Path("temp/manifest") / f"repair-{args.archive}-build.json"
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(
        manifest, separators=(",", ":")), encoding="utf-8")
    print(f"Wrote {out_path}")

    if not args.apply:
        print("\nDRY RUN — nothing uploaded. Re-run with --apply to upload.")
        return

    # gh names the uploaded asset after the file's basename, so stage a copy
    # literally called build.json (same pattern as temp/archive-upload/ in CI).
    upload_path = Path("temp/manifest") / "repair-upload" / \
        args.archive / "build.json"
    upload_path.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(out_path, upload_path)
    run_args(["gh", "release", "upload", args.archive,
             str(upload_path), "--clobber", "-R", args.repo])
    print(f"Uploaded rebuilt build.json to {args.archive}.")


if __name__ == "__main__":
    main()
