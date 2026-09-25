#!/usr/bin/env python3
"""(Re)build the content of the `website` manifest branch from live release assets.

Downloads every release's build.json asset of the rvb repo and lays them out in
the branch structure consumed by the website catalog rebuild:

  <out>/archive/stable.json     cumulative stable manifest (as published)
  <out>/archive/beta.json       cumulative beta manifest (as published)
  <out>/manifests/<tag>.json    per-numbered-release manifest

Used once to seed the branch and available afterwards to reconstruct it from
scratch if the branch ever needs to be rebuilt from release assets.

Usage:
  python3 .github/scripts/seed_website_branch.py --out temp/website-branch
Env:
  RVB_REPO (default nullcpy/rvb)
"""
import argparse
import json
import os
import subprocess
import sys
from pathlib import Path


def run_args(args):
    proc = subprocess.run(args, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(
            f"{' '.join(args[:3])}... failed: {proc.stderr.strip()[:300]}")
    return proc.stdout


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--repo", default=os.environ.get("RVB_REPO", "nullcpy/rvb"))
    ap.add_argument("--out", required=True,
                    help="output directory for branch content")
    args = ap.parse_args()

    out = Path(args.out)
    (out / "archive").mkdir(parents=True, exist_ok=True)
    (out / "manifests").mkdir(parents=True, exist_ok=True)

    raw = run_args(["gh", "api", "--paginate",
                    f"repos/{args.repo}/releases?per_page=100"])
    releases = json.loads(raw)
    print(f"Fetched {len(releases)} releases.")

    written = archives = 0
    for rel in releases:
        tag = rel.get("tag_name")
        if not tag or rel.get("draft"):
            continue
        asset = next((a for a in rel.get("assets", [])
                      if a["name"] == "build.json"), None)
        if not asset:
            print(f"  {tag}: no build.json asset, skipped")
            continue
        api_path = asset["url"].replace("https://api.github.com/", "")
        body = run_args(["gh", "api", "-H",
                         "Accept: application/octet-stream", api_path])
        manifest = json.loads(body)  # fail loudly on corrupt asset
        if tag in ("stable", "beta"):
            dest = out / "archive" / f"{tag}.json"
            archives += 1
        else:
            dest = out / "manifests" / f"{tag}.json"
        dest.write_text(json.dumps(
            manifest, indent=1, separators=(",", ": ")) + "\n", encoding="utf-8")
        written += 1

    print(f"Wrote {written} manifests ({archives} archives) to {out}.")
    if archives != 2:
        print("Warning: expected both stable and beta archive manifests",
              file=sys.stderr)


if __name__ == "__main__":
    main()
