#!/usr/bin/env python3
"""Prunes unchanged APKs and modules from build/ before release.

Compares content-aware hashes of newly built artifacts against the archive
manifest on the `website` branch. If an artifact's uncompressed bytecode,
resources, and assets are byte-for-byte identical to the currently released version,
the artifact is pruned from `build/`, preventing false update notifications in Obtainium.
"""
import json
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from content_hash import compute_content_hash  # noqa: E402


def main():
    archive_tag = (os.environ.get("ARCHIVE_TAG") or "stable").strip().lower()
    if archive_tag not in ["stable", "beta"]:
        archive_tag = "beta" if "beta" in archive_tag else "stable"

    build_dir = Path("build")
    built_files = (
        [f for f in build_dir.iterdir() if f.is_file() and f.suffix.lower() in [".apk", ".zip"]]
        if build_dir.exists()
        else []
    )
    if not built_files:
        return

    # Read archive manifest directly from the website branch
    res = subprocess.run(
        ["git", "show", f"origin/website:archive/{archive_tag}.json"],
        capture_output=True,
        text=True,
    )
    if res.returncode != 0 or not res.stdout.strip():
        return

    try:
        data = json.loads(res.stdout)
        old_hashes = {
            fname: meta.get("contentHash")
            for fname, meta in data.get("files", {}).items()
            if meta.get("contentHash")
        }
    except Exception:
        return

    pruned = False
    for f in built_files:
        prev_hash = old_hashes.get(f.name)
        if prev_hash and compute_content_hash(f) == prev_hash:
            print(f"::notice title=Unchanged Build Skipped::{f.name} matches existing release ({prev_hash[:12]}). Dropping from release.")
            f.unlink()
            pruned = True

    # Refresh release notes (build.md) if any files were pruned
    if pruned:
        gen_script = Path(".github/scripts/generate_release_notes.py")
        if gen_script.exists():
            subprocess.run([sys.executable, str(gen_script)], check=False)


if __name__ == "__main__":
    main()
