#!/usr/bin/env python3
"""Single source of truth for "which patch sources changed since the last run".

Before this module the same diff was re-derived in four places with subtly
different rules:
  * sync_patch_sources.py   -> TRIGGER_STABLE / TRIGGER_BETA booleans
  * ci_check_app_patches.py -> which repos' bundles to download and hash
  * ci_generate_configs.sh  -> active.stable.json  (via jq)
  * ci_generate_configs.sh  -> active.beta.json    (via jq, plus a date gate)

They agreed only by accident: the beta "is it actually newer than stable" gate
existed in three of the four, and only one copy honored an `enabled: false`
source. Keeping the gate as a *field on each record* rather than as a filter
inside one consumer is what lets all four agree without any of them narrowing
or widening what they look at.

Reads   : tags_old.json, tags_new.json   (written by sync_patch_sources.py)
Writes  : changed_sources.json           (records; consumers project from it)
"""
import json
import os
import sys

OLD_FILE = "tags_old.json"
NEW_FILE = "tags_new.json"
OUT_FILE = "changed_sources.json"


def _repo_name(key, entry):
    """Mirror the historical jq fallback chain: repo, else key, else skip."""
    return ((entry.get("repo") if isinstance(entry, dict) else None) or key or "").strip()


def derive(tags_old, tags_new):
    """Return one record per (source, channel) whose tag moved since last run.

    A source that is blocked, or explicitly disabled, never yields records.
    """
    records = []
    for key, new in tags_new.items():
        if not isinstance(new, dict):
            continue
        # blocked = API/access failure; enabled:false = operator opt-out.
        if new.get("blocked") is True or new.get("enabled") is False:
            continue

        old = tags_old.get(key) or {}
        if not isinstance(old, dict):
            old = {}
        repo = _repo_name(key, new).lower()
        if not repo:
            continue

        stable_tag = new.get("stable") or ""
        stable_date = new.get("stable_date") or ""
        if stable_tag and stable_tag != (old.get("stable") or ""):
            records.append({
                "key": key, "repo": repo, "channel": "stable",
                "tag": stable_tag, "tag_date": stable_date,
                "base_date": stable_date, "newer_than_base": True,
            })

        beta_tag = new.get("beta") or ""
        beta_date = new.get("beta_date") or ""
        if beta_tag and beta_tag != (old.get("beta") or ""):
            records.append({
                "key": key, "repo": repo, "channel": "beta",
                "tag": beta_tag, "tag_date": beta_date,
                "base_date": stable_date,
                # Lexicographic on purpose: the dates are ISO-8601 UTC, which is
                # what the three pre-existing copies compared. Preserved so the
                # refactor cannot shift a boundary case.
                "newer_than_base": bool(beta_date) and beta_date > stable_date,
            })
    return records


def load_json(path):
    if not os.path.exists(path):
        return {}
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def main():
    records = derive(load_json(OLD_FILE), load_json(NEW_FILE))
    with open(OUT_FILE, "w", encoding="utf-8") as f:
        json.dump(records, f, indent=2, sort_keys=True)

    stable = sorted({r["repo"] for r in records if r["channel"] == "stable"})
    beta_all = sorted({r["repo"] for r in records if r["channel"] == "beta"})
    beta_gated = sorted({r["repo"] for r in records
                         if r["channel"] == "beta" and r["newer_than_base"]})
    print(f"Changed sources: stable={len(stable)} "
          f"beta={len(beta_all)} (beta newer than stable: {len(beta_gated)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
