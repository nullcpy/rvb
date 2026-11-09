#!/usr/bin/env python3
"""Render the permanent build archive's markdown site from its per-build manifests.

Reads `manifests/*.json` (schema v1, written by push_archive_manifest.sh onto the
archive repo's `website` branch) and writes a browsable markdown tree: an index
plus one page set per app, grouped by brand then variant, with the union of applied
patches folded once above the build table that shares that exact scope.

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
- Blocks are keyed by the whole scope signature, the patch set of every kind and
  arch in the build, not by one reference list. That is what lets a patch carry a
  marker: inside a block the marker holds for every build in it. Measured on the
  current archive, 138 blocks become 144.
- A patch line is tagged only when some artifact lacks it, with the shortest exact
  phrase: `module omit`, `arm omit`, `arm64 only`, or an explicit list such as
  `arm apk` `arm64 module omit` when no single phrase covers the lacking set.
- Builds are listed individually inside a block, never as a range, because a patch
  set can appear, stop, and come back.
- A build table's link column is headed `Download` while the index heads its count
  `Downloads`, one letter apart on purpose: the app page offers files, the index
  reports how often they were taken, and the same word would read as the same thing.
- Everything is sorted, including ties, because an unstable order would make every
  regeneration rewrite files whose data did not change.
- The index's Downloads column only appears with `--counts`, a JSON map the render
  workflow writes after reading the mirror's own release counters. An app missing
  from it gets an empty cell, never a 0: no data is not the same as nobody
  downloading, and a guessed number is a claim about people we never saw. The header
  line under the title reports the two totals the table adds up to, in the same
  compact form, and drops the downloads figure for the same reason the column does.

CLI:
    --manifests DIR     required
    --out DIR           required
    --cap N             table rows per page, default 50
    --counts FILE       optional {tag: {asset name: downloads}}

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
import sys

RELEASES = "https://github.com/nullcpy/archive/releases"
DEFAULT_SITE = "https://github.com/nullcpy/archive/blob/main"
# Rendering order for artifact kinds and architectures, and for tie-free sorts.
ARCH_ORDER = {"arm64": 0, "arm": 1, "all": 2, "universal": 3, "x86_64": 4, "x86": 5}
KIND_ORDER = {"APK": 0, "Module": 1}
DEFAULT_VARIANT = "Standard"
# Written as an escape so the source stays ASCII: a test-tube after the build
# link marks a build published on the beta channel.
BETA_MARK = " \U0001f9ea"


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
        stamp = meta.get("publishedAt") or ""
        date = stamp[:10]
        for fname, entry in (manifest.get("files") or {}).items():
            rows.append(
                {
                    "tag": tag,
                    "date": date,
                    "stamp": stamp,
                    "channel": meta.get("channel") or "stable",
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
                }
            )
    rows.sort(key=lambda r: r["tag"], reverse=True)
    return rows


def load_counts(path):
    """`{release tag: {asset name: downloads}}`, as written by the render workflow.

    A path that cannot be read is a hard error rather than a missing column: the
    workflow only passes the flag when its own fetch succeeded, so quietly going
    empty here would publish an index whose numbers are all blank.
    """
    try:
        with open(path, encoding="utf-8") as fh:
            raw = json.load(fh)
        return {
            str(tag): {str(name): int(n) for name, n in files.items()}
            for tag, files in raw.items()
        }
    except (OSError, ValueError, AttributeError, TypeError) as exc:
        raise SystemExit(f"counts file {path} is unreadable: {exc}")


def compact(n):
    """Downloads as a narrow label: 475, 1.2k, 12.9k, 3.1M.

    Four digits and up collapse to one decimal, and a round thousand drops its
    `.0`, so 2,000 reads as `2k` rather than `2.0k`.
    """
    for unit, suffix in ((1000000, "M"), (1000, "k")):
        if n >= unit:
            return f"{n / unit:.1f}".rstrip("0").rstrip(".") + suffix
    return str(n)


def app_downloads(rows, counts):
    """Downloads per app key, summed over every artifact on its own release."""
    totals = {}
    for r in rows:
        n = counts.get(r["tag"], {}).get(r["fname"])
        if n is None:
            continue
        totals[r["app"]] = totals.get(r["app"], 0) + n
    return totals


def signature(rows_of_build):
    """The block key: every artifact's own kind, arch and patch set."""
    return tuple(sorted((r["kind"], r["arch"], r["patches"]) for r in rows_of_build))


def arch_link(row):
    return f"[{row['arch']}]({RELEASES}/download/{row['tag']}/{row['fname']})"


def build_link(tag):
    return f"[{tag}]({RELEASES}/tag/{tag})"


def variant_sort_key(name):
    """The unlabelled line is the main one: show it as Standard and keep it first."""
    return (0, "") if name == DEFAULT_VARIANT else (1, name.lower())


def sub_sort_key(name):
    """The unnamed sub-group is the base build: Standard first, then alphabetical."""
    return (0, "") if name is None else (1, name.lower())


def sections(rows):
    """brand -> variant -> sub-variant -> patch list -> builds, newest first."""
    by_brand = collections.defaultdict(
        lambda: collections.defaultdict(
            lambda: collections.defaultdict(lambda: collections.defaultdict(list))
        )
    )
    brand_names, newest = {}, {}
    for r in rows:
        # A lone sub-variant is the app's variant: Piko's Clone gets the same h3 as
        # Instafel's variant Clone. When a variant exists, the sub stays below it as
        # an h4 (Prime Video's Android TV, then Clone).
        variant = r["variant"] or r["sub"] or DEFAULT_VARIANT
        sub = r["sub"] if r["variant"] else None
        brand = r["brand"] or "unknown"
        by_brand[brand][variant][sub][r["tag"]].append(r)
        brand_names.setdefault(brand, r["brandName"] or brand)
        newest[brand] = max(newest.get(brand, ""), r["tag"])
    out = []
    # Tie-break on the brand key so two brands first seen in the same build never
    # fall back on dictionary insertion order.
    for brand in sorted(by_brand, key=lambda b: (newest[b], b), reverse=True):
        variants = []
        for variant in sorted(by_brand[brand], key=variant_sort_key):
            subs = []
            for sub in sorted(by_brand[brand][variant], key=sub_sort_key):
                builds = by_brand[brand][variant][sub]
                # Scoped to this sub-group: one build carries artifacts for
                # several groups, and a shared map would let the last one answer
                # for all. It also keeps Clone's patch list off the base build.
                per_build = {}
                blocks = collections.defaultdict(list)
                for tag in sorted(builds, reverse=True):
                    blocks[signature(builds[tag])].append(tag)
                    per_build[tag] = builds[tag]
                ordered = collections.OrderedDict(
                    sorted(blocks.items(), key=lambda kv: max(kv[1]), reverse=True)
                )
                subs.append((sub, ordered, per_build))
            variants.append((variant, subs))
        out.append((brand_names[brand], variants))
    return out


def block_rows(items):
    """Flatten to renderable items, keeping brand, variant and sub labels."""
    flat = []
    for brand, variants in items:
        for variant, subs in variants:
            for sub, blocks, per_build in subs:
                for tags in blocks.values():
                    flat.append((brand, variant, sub, tags, per_build))
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


def block_artifacts(tags, per_build):
    """Every artifact of every build in one block."""
    return [r for tag in tags for r in per_build[tag]]


def audience_word(kind, arch, with_kind):
    """How an audience reads in a tag: arch first, kind named when it is a module
    or when several audiences are listed together."""
    if kind == "Module":
        return f"{arch} module"
    return f"{arch} apk" if with_kind else arch


def scope_markers(artifacts):
    """Patch name to the HTML tag naming who lacks it; absent means all have it.

    The block is keyed by the full scope signature, so a tag printed here holds for
    every build in the block. The phrase is the shortest one that stays exact: a
    whole kind, then a whole arch, then `only` when a single audience carries the
    patch, and otherwise an explicit list with the verb on the last audience.
    """

    def order(a):
        return (ARCH_ORDER.get(a[1], 9), KIND_ORDER.get(a[0], 9))

    audiences = sorted({(r["kind"], r["arch"]) for r in artifacts}, key=order)
    have = {}
    for kind, arch in audiences:
        have[(kind, arch)] = {
            p
            for r in artifacts
            if r["kind"] == kind and r["arch"] == arch
            for p in r["patches"]
        }
    by_kind = {
        kind: {a for a in audiences if a[0] == kind}
        for kind in {k for k, _ in audiences}
    }
    by_arch = {
        arch: {a for a in audiences if a[1] == arch}
        for arch in {x for _, x in audiences}
    }

    markers = {}
    for patch in {p for s in have.values() for p in s}:
        holders = {a for a in audiences if patch in have[a]}
        lacking = set(audiences) - holders
        if not lacking:
            continue
        if lacking == by_kind.get("Module"):
            markers[patch] = "<code>module omit</code>"
        elif lacking == by_kind.get("APK"):
            markers[patch] = "<code>apk omit</code>"
        else:
            whole_arch = next(
                (arch for arch, group in by_arch.items() if lacking == group), None
            )
            if whole_arch:
                markers[patch] = f"<code>{whole_arch} omit</code>"
            elif len(holders) == 1:
                kind, arch = next(iter(holders))
                word = audience_word(kind, arch, False)
                markers[patch] = f"<code>{word} only</code>"
            else:
                words = [
                    audience_word(k, a, True) for k, a in sorted(lacking, key=order)
                ]
                tags = [f"<code>{w}</code>" for w in words[:-1]]
                tags.append(f"<code>{words[-1]} omit</code>")
                markers[patch] = " ".join(tags)
    return markers


def render_table(tags, per_build):
    lines = ["| Build | Date | Version | Download |", "|---|---|---|---|"]
    for tag in sorted(tags, reverse=True):
        artifacts = per_build[tag]
        mark = BETA_MARK if artifacts[0]["channel"] == "beta" else ""
        by_version = collections.defaultdict(list)
        for row in artifacts:
            by_version[row["version"]].append(row)
        for version in sorted(by_version, reverse=True):
            by_kind = collections.defaultdict(list)
            for row in by_version[version]:
                by_kind[row["kind"]].append(row)
            cells = []
            for kind in sorted(by_kind, key=lambda k: KIND_ORDER.get(k, 9)):
                ordered = sorted(
                    by_kind[kind], key=lambda r: ARCH_ORDER.get(r["arch"], 9)
                )
                cells.append(f"{kind}: " + " • ".join(arch_link(r) for r in ordered))
            lines.append(
                f"| {build_link(tag)}{mark} | {artifacts[0]['date']} | "
                f"`{version}` | {' · '.join(cells)} |"
            )
    return lines


def patch_list_html(patches, markers):
    """The folded patch list as raw HTML, each line tagged with its scope.

    Tags rather than a markdown list because Jekyll's kramdown leaves markdown
    inside an HTML block unparsed: a `- patch` list reaches the published site as
    one run of text. Tags render the same on both surfaces. Escaping happens here
    so a patch name containing `&` or `<` cannot break the page.
    """
    lines = ["<ul>"]
    for patch in patches:
        text = html.escape(patch, quote=False)
        marker = markers.get(patch, "")
        lines.append(f"<li>{text}{' ' + marker if marker else ''}</li>")
    lines.append("</ul>")
    return lines


def render_page(app_name, items, page, total, page_url, front_matter):
    """One page for one surface. page is 0-based; page_url takes a 1-based number."""
    lines = []
    if front_matter:
        lines += ["---", f"title: {app_name}", "---", ""]
    lines += [f"# {app_name}", ""]
    if total > 1:
        nav = []
        if page > 0:
            nav.append(f"[newer builds →]({page_url(page)})")
        if page + 1 < total:
            nav.append(f"[← older builds]({page_url(page + 2)})")
    last_brand, last_variant, last_sub = None, None, None
    for brand, variant, sub, tags, per_build in items:
        if brand != last_brand:
            lines += [f"## {brand}", ""]
            last_brand, last_variant, last_sub = brand, None, None
        if variant != last_variant:
            lines += [f"### {variant}", ""]
            last_variant, last_sub = variant, None
        # The base build is the variant itself and needs no heading. A named
        # sub-variant sits one level down, so Clone never reads as its own app.
        if sub and sub != last_sub:
            lines += [f"#### {sub}", ""]
            last_sub = sub
        artifacts = block_artifacts(tags, per_build)
        patches = sorted({p for r in artifacts for p in r["patches"]}, key=str.lower)
        markers = scope_markers(artifacts)
        lines.append(
            f"<details><summary><b>Applied patches: {len(patches)}</b>"
            f" . {len(tags)} build(s)</summary>"
        )
        lines += patch_list_html(patches, markers)
        lines += ["</details>", ""]
        lines += render_table(tags, per_build)
        lines.append("")
    if total > 1:
        lines += [" . ".join(nav), ""]
    return "\n".join(lines) + "\n"


def render_index(
    app_names, last_build, app_url, nullstore_url, front_matter, downloads=None
):
    counted = downloads is not None
    # The totals ride under the title so the table does not have to be scrolled to
    # learn the size of the mirror. The downloads figure only exists when the
    # counters came in: a made-up zero beside a real app count reads as a fact. It is
    # compacted like the cells, because the mirror never prunes and that sum is the
    # one number here guaranteed to outgrow four digits.
    stats = [f"<b>{len(app_names)}</b> apps"]
    if counted:
        stats.append(f"<b>{compact(sum(downloads.values()))}</b> downloads")
    lines = []
    if front_matter:
        lines += ["---", "title: NullStore Archive", "---", ""]
    lines += [
        '<h1><span class="accent">NullStore</span> Archive</h1>',
        "",
        '<p class="stats">' + " · ".join(stats) + "</p>",
        "",
        "Every build NullForge has published, kept permanently. For the newest "
        "versions and for one-tap Obtainium adds, use "
        f"[NullStore]({nullstore_url}).",
        "",
        "| App | Last build |" + (" Downloads |" if counted else ""),
        "|---|---|" + ("---:|" if counted else ""),
    ]
    for app_key, display in app_names:
        # The timestamp stays in the markup so github.com and a JS-less reader see
        # the date; the archive site's script computes the local relative label.
        stamp = last_build[app_key]
        date = stamp[:10]
        cell = ""
        if counted:
            n = downloads.get(app_key)
            cell = f" {compact(n)} |" if n is not None else " |"
        lines.append(
            f"| [{display}]({app_url(app_key)}) "
            f'| <time datetime="{stamp}" data-relative>{date}</time> |' + cell
        )
    return "\n".join(lines) + "\n"


def write(path, text):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)


def surfaces(site_base, pages_base):
    """One entry per rendered surface. Continuation pages must have distinct file
    names across surfaces: both write into the same app directory, so a shared
    `2.md` would let whichever surface runs last overwrite the other's page."""
    out = [
        {
            "index": "README.md",
            "page": lambda n: "README.md" if n == 1 else f"{n}.md",
            "url": lambda k, n: f"{site_base}/apps/{k}/"
            + ("README.md" if n == 1 else f"{n}.md"),
            "front_matter": False,
        }
    ]
    if pages_base:
        out.append(
            {
                "index": "index.md",
                "page": lambda n: "index.md" if n == 1 else f"page-{n}.md",
                "url": lambda k, n: f"{pages_base}/apps/{k}/"
                + ("" if n == 1 else f"page-{n}.html"),
                "front_matter": True,
            }
        )
    return out


def build(
    manifest_dir, out_dir, cap, site_base, nullstore_url, pages_base, counts_path=None
):
    rows = load_manifests(manifest_dir)
    if not rows:
        raise SystemExit(f"no manifests found in {manifest_dir}")
    downloads = app_downloads(rows, load_counts(counts_path)) if counts_path else None
    by_app = collections.defaultdict(list)
    for r in rows:
        by_app[r["app"]].append(r)
    # Stable, human-sensible index order; ties broken by key so it never depends
    # on filesystem listing order.
    ordered_apps = sorted(by_app, key=lambda k: (by_app[k][0]["appName"].lower(), k))
    # The full timestamp, not the UTC date slice: the reader's script turns it
    # into a local day, so a build late in the UTC day still lands on the right
    # local date.
    last_build = {k: max((r["stamp"] or r["date"] for r in by_app[k])) for k in by_app}

    written = 0
    for surface in surfaces(site_base, pages_base):
        for app_key in ordered_apps:
            app_rows = by_app[app_key]
            pages = paginate(block_rows(sections(app_rows)), cap)
            display = app_rows[0]["appName"]
            for i, items in enumerate(pages):
                write(
                    os.path.join(out_dir, "apps", app_key, surface["page"](i + 1)),
                    render_page(
                        display,
                        items,
                        i,
                        len(pages),
                        lambda n, k=app_key: surface["url"](k, n),
                        surface["front_matter"],
                    ),
                )
                written += 1
        app_link = (
            (lambda k: f"{site_base}/apps/{k}/README.md")
            if not surface["front_matter"]
            else (lambda k: f"{pages_base}/apps/{k}/")
        )
        write(
            os.path.join(out_dir, surface["index"]),
            render_index(
                [(k, by_app[k][0]["appName"]) for k in ordered_apps],
                last_build,
                app_link,
                nullstore_url,
                surface["front_matter"],
                downloads,
            ),
        )
        written += 1
    return len(ordered_apps), written, len(rows)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--manifests", required=True, help="directory of *.json manifests")
    ap.add_argument("--out", required=True, help="directory to write the site into")
    ap.add_argument("--cap", type=int, default=50, help="table rows per page")
    ap.add_argument(
        "--counts",
        help="JSON {tag: {asset: downloads}} for the "
        "index's Downloads column; omit it and the "
        "column is not rendered",
    )
    args = ap.parse_args()

    # A written-in hub URL would keep advertising an old host after a move and
    # nothing would fail, so an unset one is a hard error instead of a guess.
    nullstore_url = os.environ.get("NULLSTORE_URL", "").strip()
    if not nullstore_url:
        raise SystemExit("NULLSTORE_URL is not set; refusing to invent a hub link")
    site_base = os.environ.get("ARCHIVE_SITE_BASE", DEFAULT_SITE).rstrip("/")
    pages_base = os.environ.get("ARCHIVE_PAGES_BASE", "").strip().rstrip("/")

    apps, pages, artifacts = build(
        args.manifests,
        args.out,
        args.cap,
        site_base,
        nullstore_url,
        pages_base,
        args.counts,
    )
    extra = f", pages base {pages_base}" if pages_base else ", README only"
    extra += ", counted" if args.counts else ", uncounted"
    print(
        f"wrote {pages} pages for {apps} apps from {artifacts} artifacts"
        f" ({args.manifests} -> {args.out}{extra})"
    )


if __name__ == "__main__":
    main()
