# Manifest branch (generated — do not edit)

Canonical storage of build.json manifests consumed by the
nullcpy/nullcpy.github.io catalog rebuild (rebuild_catalog.py --manifest-dir).

- `archive/<channel>.json` — cumulative stable/beta manifests, merged and
  live-filtered by .github/scripts/merge_archive_branch.sh on every build.
- `manifests/<tag>.json` — per-numbered-release manifests, pruned for deleted
  releases by .github/scripts/cleanup_website_branch.sh.

Rewritten by CI; history here is the recovery path after any manifest loss
(`git log -p archive/stable.json`, `git show <rev>:archive/stable.json`).
Recreate from release assets with .github/scripts/seed_website_branch.py.
