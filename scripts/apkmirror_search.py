#!/usr/bin/env python3
import sys
import re

def extract_versions(html_content: str, allow_all: bool = False) -> list[str]:
    # Restrict search to primary content / listWidget area to avoid scraping
    # sidebar widgets ("Popular in last 24 hours", trending apps, etc.)
    content_to_search = html_content
    m_primary = re.search(r'(?:id="primary"|class="[^"]*listWidget[^"]*")(.*)', html_content, re.DOTALL)
    if m_primary:
        content_to_search = m_primary.group(1)

    m_secondary = re.search(r'(?:id="secondary"|<aside\b|class="[^"]*sidebar[^"]*")', content_to_search, re.IGNORECASE)
    if m_secondary:
        content_to_search = content_to_search[:m_secondary.start()]

    # Extract links with class fontBlack pointing to releases
    links = re.findall(r'<a\s+[^>]*class="[^"]*fontBlack[^"]*"[^>]*href="([^"]*-release/)"[^>]*>(.*?)</a>', content_to_search, re.DOTALL)
    if not links:
        # Fallback in case attribute order differs
        links = re.findall(r'<a\s+[^>]*href="([^"]*-release/)"[^>]*class="[^"]*fontBlack[^"]*"[^>]*>(.*?)</a>', content_to_search, re.DOTALL)

    versions = []
    seen = set()
    for href, text in links:
        clean_text = re.sub(r'<[^>]+>', '', text).strip()
        if not clean_text:
            continue
        lower = clean_text.lower()
        if not allow_all and any(kw in lower for kw in ("beta", "alpha", "secondary")):
            continue

        m_ver = re.search(r'(\d+(?:\.\d+)+(?:[a-zA-Z0-9._-]*))', clean_text)
        ver = m_ver.group(1) if m_ver else clean_text.split()[-1]
        if ver and ver not in seen:
            seen.add(ver)
            versions.append(ver)

    return versions

def extract_package_name(html_content: str) -> str | None:
    m = re.search(r'play\.google\.com/store/apps/details\?id=([a-zA-Z0-9_.]+)', html_content)
    if m:
        return m.group(1)
    m2 = re.search(r'id=([a-zA-Z0-9_.]+)"\s+class="[^"]*accent_color', html_content)
    if m2:
        return m2.group(1)
    return None

def apkmirror_search(html_content, dpi, arch, apk_bundle, clean_search_version, search_version, target_vc):
    dpi_str = dpi if dpi else "nodpi anydpi auto"
    appdpi = ["nodpi", "anydpi"]
    match_any_dpi = False
    if dpi_str:
        appdpi.extend(dpi_str.split())
        if "auto" in appdpi:
            match_any_dpi = True

    best_fallback_url = ""
    specific_arch_url = ""
    specific_arch_fallback_url = ""

    # Split rows by table-row headerFont
    parts = re.split(r'<div class="[^"]*table-row[^"]*headerFont[^"]*"[^>]*>', html_content)
    if len(parts) <= 1:
        return None
    rows = parts[1:]

    # Reverse rows to match bash nth-last-child traversal order
    reversed_rows = list(reversed(rows))

    for r in reversed_rows:
        href_m = re.search(r'href="((?:https://www\.apkmirror\.com)?/apk/[^"]+)"', r)
        if not href_m:
            continue
        dlurl = href_m.group(1)
        if not dlurl.startswith("http"):
            dlurl = "https://www.apkmirror.com" + dlurl

        badge_m = re.search(r'class="[^"]*apkm-badge[^"]*"[^>]*>([^<]+)</span>', r)
        node_apk_bundle = badge_m.group(1).strip() if badge_m else "APK"

        cells = re.findall(r'<div class="table-cell[^"]*"[^>]*>(.*?)</div>', r, re.DOTALL)
        node_arch = re.sub(r'<[^>]+>', '', cells[1]).strip() if len(cells) > 1 else ""
        node_dpi = re.sub(r'<[^>]+>', '', cells[3]).strip() if len(cells) > 3 else ""

        node_vc = ""
        if len(cells) > 0:
            spans = re.findall(r'<span\s+class="([^"]*colorLightBlack[^"]*)"[^>]*>(.*?)</span>', cells[0], re.DOTALL)
            for cls, content in spans:
                if "dateyear_utc" in cls or "wrapText" in cls or "dateyear_utc" in content:
                    continue
                clean_txt = re.sub(r'<[^>]+>', '', content).strip()
                if clean_txt.isdigit():
                    node_vc = clean_txt
                    break
        if not node_vc:
            vc_m = re.search(r'class="colorLightBlack"[^>]*>([0-9]+)</span>', r)
            if not vc_m:
                vc_m = re.search(r'span class="[^"]*colorLightBlack[^"]*"[^>]*>.*?([0-9]+).*?</span>', r, re.DOTALL)
            node_vc = vc_m.group(1).strip() if vc_m else ""

        if node_apk_bundle != apk_bundle:
            continue

        if clean_search_version:
            if clean_search_version not in dlurl and search_version not in dlurl:
                continue

        if target_vc:
            if node_vc and node_vc == target_vc:
                return dlurl
            else:
                continue

        # Pass 1 Logic: Return Universal/Fat Bundles immediately to optimize cache size
        if node_arch in ['universal', 'noarch', 'arm64-v8a + x86_64', 'arm64-v8a + armeabi-v7a']:
            if node_dpi in appdpi:
                return dlurl
            elif match_any_dpi and not best_fallback_url:
                best_fallback_url = dlurl
        # Pass 2 Logic: If it's strictly the requested arch, save it as a fallback in case no universal is found
        elif node_arch == arch:
            if node_dpi in appdpi:
                if not specific_arch_url:
                    specific_arch_url = dlurl
            elif match_any_dpi and not specific_arch_fallback_url:
                specific_arch_fallback_url = dlurl

    if best_fallback_url:
        return best_fallback_url
    if specific_arch_url:
        return specific_arch_url
    if specific_arch_fallback_url:
        return specific_arch_fallback_url
    return None

def main():
    if len(sys.argv) < 2:
        sys.exit(1)

    subcmd = sys.argv[1]

    if subcmd == "vers":
        allow_all = (sys.argv[2].lower() == "true") if len(sys.argv) > 2 else False
        html_content = sys.stdin.read()
        vers = extract_versions(html_content, allow_all=allow_all)
        if vers:
            print("\n".join(vers))
            sys.exit(0)
        sys.exit(1)

    if subcmd == "pkg":
        html_content = sys.stdin.read()
        pkg = extract_package_name(html_content)
        if pkg:
            print(pkg)
            sys.exit(0)
        sys.exit(1)

    if len(sys.argv) < 7:
        sys.exit(1)

    dpi = sys.argv[1]
    arch = sys.argv[2]
    apk_bundle = sys.argv[3]
    clean_search_version = sys.argv[4]
    search_version = sys.argv[5]
    target_vc = sys.argv[6] if len(sys.argv) > 6 else ""

    html_content = sys.stdin.read()
    if not html_content:
        sys.exit(1)

    url = apkmirror_search(html_content, dpi, arch, apk_bundle, clean_search_version, search_version, target_vc)
    if url:
        print(url)
        sys.exit(0)
    else:
        sys.exit(1)

if __name__ == '__main__':
    main()
