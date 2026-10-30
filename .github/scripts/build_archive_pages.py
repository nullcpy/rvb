#!/usr/bin/env python3
"""Render the permanent build archive's markdown site from its per-build manifests.

Reads `manifests/*.json` (schema v1, written by push_archive_manifest.sh onto the
archive repo's `website` branch) and writes a browsable markdown tree: an index
plus one page set per app, grouped by brand then variant, with every distinct
applied-patch list folded once above the build table it covers.

Two surfaces come out of one pass, because the same tree is read two ways:

- `README.md` is what github.com renders when someone browses a folder, so its
  links point at `blob/main` and it carries no front matter (GitHub would render
  front matter as a metadata table above the content).
- `index.md` is what GitHub Pages (Jekyll) turns into `/` and `/apps/<key>/`, so
  it carries front matter, which Jekyll requires before it will convert a file at
  all, and its links point at the published site.

The mirror holds numbered releases only, so this reads the per-build manifests
directly and never needs the cumulative archive manifest or a live asset check.
Stdlib only and no network: the archive repo's workflow imports it from a sparse
clone of this repo's `main`, the same import-not-copy rule as naming.py.

Layout choices that are deliberate, not incidental:
- One canonical patch list per build (the widest APK arch when present), so a
  module that drops one patch does not duplicate a 100-item list. The delta is
  stated once per kind and only when every artifact of that kind agrees; a
  difference confined to one arch or one build is left out rather than misstated.
- Builds are listed individually inside a block, never as a range, because a patch
  set can appear, stop, and come back.
- Everything is sorted, including ties, because an unstable order would make every
  regeneration rewrite files whose data did not change.

Env:
    ARCHIVE_SITE_BASE   absolute base for README links, default the archive repo's main
    ARCHIVE_PAGES_BASE  optional published site base; when set, index.md files are
                        written as well. Unset means GitHub-only output.
    NULLSTORE_URL       required; the hub the index points live users to
Writes:
    <out>/README.md, <out>/apps/<appKey>/README.md
    and, when ARCHIVE_PAGES_BASE is set, the index.md mirror of each.
"""
import argparse
import collections
import html
import json
import os
import re
import sys

RELEASES = "https://github.com/nullcpy/archive/releases"
DEFAULT_SITE = "https://github.com/nullcpy/archive/blob/main"
# Rendering order for artifact kinds and architectures, and for tie-free sorts.
ARCH_ORDER = {"arm64": 0, "arm": 1, "all": 2,
              "universal": 3, "x86_64": 4, "x86": 5}
KIND_ORDER = {"APK": 0, "Module": 1}
DEFAULT_VARIANT = "Standard"


def load_manifests(src_dir):
    """Every artifact in the tree, newest build first, tagged with its build."""
    rows = []
    for name in sorted(os.listdir(src_dir), reverse=True):
        if not name.endswith(".json"):
            continue
        with open(os.path.join(src_dir, name), encoding="utf-8") as fh:
            manifest = json.load(fh)
        meta = manifest.get("meta") or {}
        tag = str(meta.get("build") or name[:-5])
        date = (meta.get("publishedAt") or "")[:10]
        for fname, entry in (manifest.get("files") or {}).items():
            rows.append({
                "tag": tag, "date": date,
                "app": entry.get("appKey") or "?",
                "appName": entry.get("appName") or "?",
                "brand": entry.get("brandKey") or "",
                "brandName": entry.get("brandName") or "",
                "variant": entry.get("variant"),
                "sub": entry.get("subVariant"),
                "arch": entry.get("arch") or "",
                "kind": entry.get("fileType") or "APK",
                "version": entry.get("version") or "",
                "fname": fname,
                "patches": tuple(dict.fromkeys(entry.get("appliedPatches") or [])),
            })
    rows.sort(key=lambda r: r["tag"], reverse=True)
    return rows


def canonical(rows_of_build):
    """Reference patch list for one build: the widest APK arch present."""
    apks = [r for r in rows_of_build if r["kind"] == "APK"]
    for arch in ARCH_ORDER:
        for row in apks:
            if row["arch"] == arch:
                return row["patches"]
    return (apks or rows_of_build)[0]["patches"]


def arch_link(row):
    return f"[{row['arch']}]({RELEASES}/download/{row['tag']}/{row['fname']})"


def build_link(tag):
    return f"[{tag}]({RELEASES}/tag/{tag})"


def variant_sort_key(name):
    """The unlabelled line is the main one: show it as Standard and keep it first."""
    return (0, "") if name == DEFAULT_VARIANT else (1, name.lower())


def sections(rows):
    """brand -> variant -> patch list -> builds, each newest build first."""
    by_brand = collections.defaultdict(lambda: collections.defaultdict(
        lambda: collections.defaultdict(list)))
    brand_names, newest = {}, {}
    for r in rows:
        variant = r["variant"] or r["sub"] or DEFAULT_VARIANT
        brand = r["brand"] or "unknown"
        by_brand[brand][variant][r["tag"]].append(r)
        brand_names.setdefault(brand, r["brandName"] or brand)
        newest[brand] = max(newest.get(brand, ""), r["tag"])
    out = []
    # Tie-break on the brand key so two brands first seen in the same build never
    # fall back on dictionary insertion order.
    for brand in sorted(by_brand, key=lambda b: (newest[b], b), reverse=True):
        variants = []
        for variant in sorted(by_brand[brand], key=variant_sort_key):
            builds = by_brand[brand][variant]
            # Scoped to this variant: one build carries artifacts for several
            # variants, and a shared map would let the last variant answer for all.
            per_build = {}
            blocks = collections.defaultdict(list)
            for tag in sorted(builds, reverse=True):
                blocks[canonical(builds[tag])].append(tag)
                per_build[tag] = builds[tag]
            ordered = collections.OrderedDict(
                sorted(blocks.items(), key=lambda kv: max(kv[1]), reverse=True))
            variants.append((variant, ordered, per_build))
        out.append((brand_names[brand], variants))
    return out


def block_rows(items):
    """Flatten to renderable items, keeping brand and variant labels attached."""
    flat = []
    for brand, variants in items:
        for variant, blocks, per_build in variants:
            for patches, tags in blocks.items():
                flat.append((brand, variant, patches, tags, per_build))
    return flat


def paginate(flat, cap):
    """Group render items into pages of at most `cap` table rows.

    Splitting happens between blocks, never inside one, so a folded patch list is
    never separated from the builds it describes.
    """
    pages, current, used = [], [], 0
    for item in flat:
        rows_in_item = len(item[3])
        if current and used + rows_in_item > cap:
            pages.append(current)
            current, used = [], 0
        current.append(item)
        used += rows_in_item
    if current:
        pages.append(current)
    return pages or [[]]


def delta_lines(tags, patches, per_build):
    """A whole-kind note, and only when that kind deviates identically everywhere.

    A deviation limited to one arch or one build cannot be phrased without naming
    that arch or build, and the table has no column for it, so it is left out by
    design rather than stated wrongly.
    """
    artifacts = [r for tag in tags for r in per_build[tag]]
    lines = []
    for kind in sorted({r["kind"] for r in artifacts},
                       key=lambda k: KIND_ORDER.get(k, 9)):
        of_kind = [r for r in artifacts if r["kind"] == kind]
        actual = {r["patches"] for r in of_kind}
        if len(actual) != 1:
            continue
        only = next(iter(actual))
        if only == patches:
            continue
        missing = sorted(set(patches) - set(only))
        extra = sorted(set(only) - set(patches))
        bits = []
        if missing:
            bits.append("omit " + ", ".join(f"`{p}`" for p in missing))
        if extra:
            bits.append("add " + ", ".join(f"`{p}`" for p in extra))
        if not bits:
            continue
        plural = len({r["arch"] for r in of_kind}) > 1
        who = f"{kind} artifacts" if plural else kind
        lines.append(f"- {who} {' and '.join(bits)}")
    return lines


def render_table(tags, per_build):
    lines = ["| Build | Date | Version | Downloads |", "|---|---|---|---|"]
    for tag in sorted(tags, reverse=True):
        artifacts = per_build[tag]
        by_version = collections.defaultdict(list)
        for row in artifacts:
            by_version[row["version"]].append(row)
        for version in sorted(by_version, reverse=True):
            by_kind = collections.defaultdict(list)
            for row in by_version[version]:
                by_kind[row["kind"]].append(row)
            cells = []
            for kind in sorted(by_kind, key=lambda k: KIND_ORDER.get(k, 9)):
                ordered = sorted(by_kind[kind],
                                 key=lambda r: ARCH_ORDER.get(r["arch"], 9))
                cells.append(f"{kind}: " + " • ".join(arch_link(r)
                             for r in ordered))
            lines.append(f"| {build_link(tag)} | {artifacts[0]['date']} | `{version}` "
                         f"| {' · '.join(cells)} |")
    return lines


def patch_list_html(tags, patches, per_build):
    """The folded patch list as raw HTML.

    Tags rather than a markdown list because Jekyll's kramdown leaves markdown
    inside an HTML block unparsed: a `- patch` list reaches the published site as
    one run of text. Tags render the same on both surfaces. Escaping happens here
    so a patch name containing `&` or `<` cannot break the page.
    """
    items = [html.escape(p, quote=False) for p in patches]
    for line in delta_lines(tags, patches, per_build):
        text = html.escape(line[2:], quote=False)
        items.append(re.sub(r"`([^`]+)`", r"<code>\1</code>", text))
    return ["<ul>"] + [f"<li>{item}</li>" for item in items] + ["</ul>"]


def render_page(app_name, items, page, total, page_url, front_matter):
    """One page for one surface. page is 0-based; page_url takes a 1-based number."""
    lines = []
    if front_matter:
        lines += ["---", f"title: {app_name}", "---", ""]
    lines += [f"# {app_name}", ""]
    if total > 1:
        nav = []
        if page > 0:
            nav.append(f"[newer builds]({page_url(page)})")
        if page + 1 < total:
            nav.append(f"[older builds]({page_url(page + 2)})")
        lines += [" . ".join(nav), ""]
    last_brand, last_variant = None, None
    for brand, variant, patches, tags, per_build in items:
        if brand != last_brand:
            lines += [f"## {brand}", ""]
            last_brand, last_variant = brand, None
        if variant != last_variant:
            lines += [f"### {variant}", ""]
            last_variant = variant
        lines.append(f"<details><summary><b>Applied patches: {len(patches)}</b>"
                     f" . {len(tags)} build(s)</summary>")
        lines += patch_list_html(tags, patches, per_build)
        lines += ["</details>", ""]
        lines += render_table(tags, per_build)
        lines.append("")
    return "\n".join(lines) + "\n"


def render_index(app_names, last_build, app_url, nullstore_url, front_matter):
    lines = []
    if front_matter:
        lines += ["---", "title: NullStore Archive", "---", ""]
    lines += [
        '<h1><span class="accent">NullStore</span> Archive</h1>',
        "",
        "Every build NullForge has published, kept permanently. For the newest "
        "versions and for one-tap Obtainium adds, use "
        f"[NullStore]({nullstore_url}).",
        "",
        "| App | Last build |",
        "|---|---|",
    ]
    for app_key, display in app_names:
        lines.append(
            f"| [{display}]({app_url(app_key)}) | {last_build[app_key]} |")
    return "\n".join(lines) + "\n"


def write(path, text):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)


def surfaces(site_base, pages_base):
    """One entry per rendered surface. Continuation pages must have distinct file
    names across surfaces: both write into the same app directory, so a shared
    `2.md` would let whichever surface runs last overwrite the other's page."""
    out = [{
        "index": "README.md",
        "page": lambda n: "README.md" if n == 1 else f"{n}.md",
        "url": lambda k, n: f"{site_base}/apps/{k}/"
        + ("README.md" if n == 1 else f"{n}.md"),
        "front_matter": False,
    }]
    if pages_base:
        out.append({
            "index": "index.md",
            "page": lambda n: "index.md" if n == 1 else f"page-{n}.md",
            "url": lambda k, n: f"{pages_base}/apps/{k}/"
            + ("" if n == 1 else f"page-{n}.html"),
            "front_matter": True,
        })
    return out


def build(manifest_dir, out_dir, cap, site_base, nullstore_url, pages_base):
    rows = load_manifests(manifest_dir)
    if not rows:
        raise SystemExit(f"no manifests found in {manifest_dir}")
    by_app = collections.defaultdict(list)
    for r in rows:
        by_app[r["app"]].append(r)
    # Stable, human-sensible index order; ties broken by key so it never depends
    # on filesystem listing order.
    ordered_apps = sorted(by_app, key=lambda k: (
        by_app[k][0]["appName"].lower(), k))
    last_build = {k: max(r["date"] for r in by_app[k]) for k in by_app}

    written = 0
    for surface in surfaces(site_base, pages_base):
        for app_key in ordered_apps:
            app_rows = by_app[app_key]
            pages = paginate(block_rows(sections(app_rows)), cap)
            display = app_rows[0]["appName"]
            for i, items in enumerate(pages):
                write(os.path.join(out_dir, "apps", app_key,
                                   surface["page"](i + 1)),
                      render_page(display, items, i, len(pages),
                                  lambda n, k=app_key: surface["url"](k, n),
                                  surface["front_matter"]))
                written += 1
        app_link = ((lambda k: f"{site_base}/apps/{k}/README.md")
                    if not surface["front_matter"]
                    else (lambda k: f"{pages_base}/apps/{k}/"))
        write(os.path.join(out_dir, surface["index"]),
              render_index([(k, by_app[k][0]["appName"]) for k in ordered_apps],
                           last_build, app_link, nullstore_url,
                           surface["front_matter"]))
        written += 1
    return len(ordered_apps), written, len(rows)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--manifests", required=True,
                    help="directory of *.json manifests")
    ap.add_argument("--out", required=True,
                    help="directory to write the site into")
    ap.add_argument("--cap", type=int, default=50, help="table rows per page")
    args = ap.parse_args()

    # A written-in hub URL would keep advertising an old host after a move and
    # nothing would fail, so an unset one is a hard error instead of a guess.
    nullstore_url = os.environ.get("NULLSTORE_URL", "").strip()
    if not nullstore_url:
        raise SystemExit(
            "NULLSTORE_URL is not set; refusing to invent a hub link")
    site_base = os.environ.get("ARCHIVE_SITE_BASE", DEFAULT_SITE).rstrip("/")
    pages_base = os.environ.get("ARCHIVE_PAGES_BASE", "").strip().rstrip("/")

    apps, pages, artifacts = build(args.manifests, args.out, args.cap,
                                   site_base, nullstore_url, pages_base)
    extra = f", pages base {pages_base}" if pages_base else ", README only"
    print(f"wrote {pages} pages for {apps} apps from {artifacts} artifacts"
          f" ({args.manifests} -> {args.out}{extra})")


if __name__ == "__main__":
    main()
