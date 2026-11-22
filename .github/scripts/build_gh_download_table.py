#!/usr/bin/env python3
"""Render the ## Downloads section of a GitHub build log from a release note.

The input is the archive-linked note (build.archive.md), so every per-file URL
already points at the permanent mirror. Nothing is reconstructed here: a rename
of the archive repo only has to change generate_release_notes.py, and this table
follows it. Stdlib only, no network, deterministic order from the note.
"""
import os
import re
import sys

SOURCE_RE = re.compile(r"^### (🧩 .*)$")
APP_RE = re.compile(r"^\* \*\*(.+?)\*\*(?: `([^`]+)`)?$")
KIND_RE = re.compile(r"^  \* (APK|Module): (.+)$")
LINK_RE = re.compile(r"\[([^\]]+)\]\(([^)]+)\)")


def cell(value):
    """A GFM table cell: escape the one character that ends a cell."""
    return str(value or "—").replace("|", "\\|")


def render(lines):
    groups = []  # [(source heading, [(app, version, apks, modules), ...])]
    group = None
    app = None
    version = ""
    apks = []
    modules = []

    def flush_app():
        nonlocal app, version, apks, modules
        if app is not None:
            group[1].append((app, version, " • ".join(apks), " • ".join(modules)))
        app = None
        version = ""
        apks = []
        modules = []

    for line in lines:
        if line.strip() == "---":
            break  # notes/footer carry no download links
        match = SOURCE_RE.match(line)
        if match:
            flush_app()
            group = (match.group(1), [])
            groups.append(group)
            continue
        match = APP_RE.match(line)
        if match:
            flush_app()
            if group is None:
                continue
            app = match.group(1)
            version = match.group(2) or ""
            continue
        match = KIND_RE.match(line)
        if match and app is not None:
            links = [f"[{label}]({url})" for label, url in LINK_RE.findall(match.group(2))]
            if match.group(1) == "APK":
                apks.extend(links)
            else:
                modules.extend(links)

    flush_app()

    out = ["## 📦 Downloads", ""]
    for source, rows in groups:
        if not rows:
            continue
        out.append(f"#### {source}")
        out.append("")
        out.append("| App | Version | APK | Module |")
        out.append("|---|---|---|---|")
        for name, ver, apk_links, module_links in rows:
            ver_cell = f"`{ver}`" if ver else "—"
            out.append(
                f"| {cell(name)} | {ver_cell} | {cell(apk_links)} | {cell(module_links)} |"
            )
        out.append("")
    if len(out) == 2:
        out.append("> No files were published in this build.")
        out.append("")
    return "\n".join(out).rstrip()


def main():
    # The GFM body is assembled on the runner; keep its newlines identical on
    # Linux and on a Windows developer machine (where stdout would turn \n into
    # \r\n and leave the body with mixed endings).
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(newline="\n")
    path = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("NOTES_FILE", "build.archive.md")
    try:
        with open(path, "r", encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    except OSError as exc:
        print(f"::error::Cannot read release note {path}: {exc}", file=sys.stderr)
        return 1
    print(render(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
