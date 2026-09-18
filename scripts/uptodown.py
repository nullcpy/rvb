#!/usr/bin/env python3
import sys
import os
import re
import time
import hmac
import hashlib
import secrets
import json
import urllib.request
import urllib.parse

API_HOST = "www.uptodown.app"
AUTH_PATH = "/eapi/auth/token"
CLIENT_VERSION = "739"
USER_AGENT = "Dalvik/2.1.0 (Linux; U; Android 16; Pixel 8 Pro Build/BP4A.260205.001)"
WEB_USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36"
HMAC_KEY = b"MDGMXUMdvHJBG/vjdFgmqX6LUdy7ecfwvYNd0gyfOCs="

def get_auth_token() -> str:
    identifier = secrets.token_hex(8)
    ts = str(int(time.time()))
    sig = hmac.new(HMAC_KEY, ts.encode("utf-8"), hashlib.sha256).hexdigest()

    params = {"identifier": identifier}
    body = urllib.parse.urlencode({
        "identifier": identifier,
        "id_plataforma": "13",
        "lang": "en",
        "unixtime": ts,
        "hmac": sig
    }).encode("utf-8")

    req = urllib.request.Request(
        f"https://{API_HOST}{AUTH_PATH}?{urllib.parse.urlencode(params)}",
        data=body,
        headers={
            "User-Agent": USER_AGENT,
            "Identificador": "Uptodown_Android",
            "Identificador-Version": CLIENT_VERSION,
            "Content-Type": "application/x-www-form-urlencoded"
        }
    )

    with urllib.request.urlopen(req, timeout=15) as resp:
        data = json.loads(resp.read().decode("utf-8"))
        token = data.get("token")
        if not token:
            raise RuntimeError(f"Failed to get auth token: {data}")
        return token

def get_cdn_download_url(app_id: str, file_id: str, token: str = None) -> str:
    if not token:
        token = get_auth_token()

    req = urllib.request.Request(
        f"https://{API_HOST}/eapi/apps/{app_id}/file/{file_id}/downloadUrl",
        headers={
            "User-Agent": USER_AGENT,
            "Identificador": "Uptodown_Android",
            "Identificador-Version": CLIENT_VERSION,
            "Authorization": f"Bearer {token}"
        }
    )

    with urllib.request.urlopen(req, timeout=15) as resp:
        data = json.loads(resp.read().decode("utf-8"))
        if data.get("success") != 1 or "data" not in data or "downloadURL" not in data["data"]:
            raise RuntimeError(f"Failed to get download URL: {data}")
        return data["data"]["downloadURL"]

def clean_page_url(raw_url: str) -> str:
    url = raw_url.rstrip("/")
    for sfx in ("/versions", "/download", "/files"):
        if url.endswith(sfx):
            url = url[:-len(sfx)]
    return url

def fetch_web_page(url: str) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": WEB_USER_AGENT})
    with urllib.request.urlopen(req, timeout=15) as resp:
        return resp.read().decode("utf-8", errors="ignore")

def extract_app_id(html: str) -> str | None:
    # 1. From h1#detail-app-name data-code
    m = re.search(r'<h1[^>]+id="detail-app-name"[^>]+data-code="([0-9]+)"', html)
    if m:
        return m.group(1)
    # 2. From data-app-id on download button
    m = re.search(r'data-app-id="([0-9]+)"', html)
    if m:
        return m.group(1)
    # 3. From any id="detail-app-name" with data-code
    m = re.search(r'id="detail-app-name"[^>]*data-code="([0-9]+)"', html)
    if m:
        return m.group(1)
    # 4. Fallback data-code
    m = re.search(r'data-code="([0-9]+)"', html)
    if m:
        return m.group(1)
    return None

def extract_package_name(html: str) -> str | None:
    # 1. From Google Play link
    m = re.search(r'play\.google\.com/store/apps/details\?id=([a-zA-Z0-9_.]+)', html)
    if m:
        return m.group(1)
    # 2. From technical-information table
    m = re.search(r'<tr[^>]*>.*?<th[^>]*>\s*Package Name\s*</th>\s*<td[^>]*>(.*?)</td>', html, re.IGNORECASE | re.DOTALL)
    if m:
        pkg = re.sub(r'<[^>]+>', '', m.group(1)).strip()
        if pkg:
            return pkg
    return None

def get_versions(base_url: str, allow_all: bool = False) -> list[str]:
    clean_url = clean_page_url(base_url)
    main_html = fetch_web_page(clean_url)
    app_id = extract_app_id(main_html)
    if not app_id:
        # Fallback: extract from #versions-items-list on main_html
        vers = []
        for m in re.finditer(r'<span class="version">([^<]+)</span>', main_html):
            v = m.group(1).strip()
            if not allow_all and any(kw in v.lower() for kw in ("beta", "alpha", "secondary")):
                continue
            if v and v not in vers:
                vers.append(v)
        return vers

    versions = []
    seen = set()
    for page in range(1, 6):
        try:
            api_url = f"{clean_url}/apps/{app_id}/versions/{page}"
            req = urllib.request.Request(api_url, headers={"User-Agent": WEB_USER_AGENT})
            with urllib.request.urlopen(req, timeout=10) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                items = data.get("data", [])
                if not items:
                    break
                for it in items:
                    v = str(it.get("version", "")).strip()
                    if not v:
                        continue
                    if not allow_all and any(kw in v.lower() for kw in ("beta", "alpha", "secondary")):
                        continue
                    if v not in seen:
                        seen.add(v)
                        versions.append(v)
        except Exception:
            break

    return versions

def resolve_download_variant(base_url: str, version: str, arch: str = "") -> tuple[str, str, bool]:
    """Returns (app_id, file_id, is_bundle)"""
    clean_url = clean_page_url(base_url)
    main_html = fetch_web_page(clean_url)
    app_id = extract_app_id(main_html)
    if not app_id:
        raise RuntimeError(f"Could not extract app_id from {clean_url}")

    arch = arch.lower()
    if arch == "arm-v7a":
        arch = "armeabi-v7a"

    target_ver = version.strip()
    target_clean_ver = target_ver.split("-")[0]

    matched_item = None
    for page in range(1, 15):
        try:
            api_url = f"{clean_url}/apps/{app_id}/versions/{page}"
            req = urllib.request.Request(api_url, headers={"User-Agent": WEB_USER_AGENT})
            with urllib.request.urlopen(req, timeout=10) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                items = data.get("data", [])
                if not items:
                    break
                for it in items:
                    it_v = str(it.get("version", "")).strip()
                    if it_v == target_ver or it_v == target_clean_ver or it_v.startswith(target_clean_ver):
                        matched_item = it
                        break
                if matched_item:
                    break
        except Exception:
            break

    if not matched_item:
        raise RuntimeError(f"Version '{version}' not found on Uptodown for {clean_url}")

    file_id = str(matched_item.get("fileID", ""))
    is_bundle = matched_item.get("kindFile") == "xapk"

    # Check if download page offers architecture variants
    ver_url_obj = matched_item.get("versionURL")
    if isinstance(ver_url_obj, dict):
        dl_page = f"{ver_url_obj.get('url')}/{ver_url_obj.get('extraURL')}/{ver_url_obj.get('versionID')}"
    else:
        dl_page = f"{clean_url}/download/{file_id}"

    try:
        dl_html = fetch_web_page(dl_page)
        # Look for data-version on variants button
        m_var = re.search(r'data-version="([0-9]+)"', dl_html)
        if m_var:
            data_version = m_var.group(1)
            files_url = f"{clean_url.rsplit('/', 1)[0]}/app/{app_id}/version/{data_version}/files"
            req = urllib.request.Request(files_url, headers={"User-Agent": WEB_USER_AGENT})
            with urllib.request.urlopen(req, timeout=10) as resp:
                files_data = json.loads(resp.read().decode("utf-8"))
                content = files_data.get("content", "")
                if content:
                    # Parse variants: <p>arch</p> followed by <div class="variant">...<img ... data-file-id="...">
                    # Split content by <p>
                    sections = re.split(r'<p[^>]*>', content)
                    specific_file_id = None
                    universal_file_id = None

                    for sec in sections[1:]:
                        arch_m = re.match(r'([^<]+)</p>', sec.strip())
                        node_arch = arch_m.group(1).strip().lower() if arch_m else ""
                        fid_m = re.search(r'data-file-id="([0-9]+)"', sec)
                        if not fid_m:
                            continue
                        cur_fid = fid_m.group(1)
                        is_xapk = ('title="xapk"' in sec or 'class="xapk"' in sec)

                        if arch and (arch in node_arch):
                            specific_file_id = (cur_fid, is_xapk)
                            break
                        elif any(u in node_arch for u in ("universal", "arm64-v8a, armeabi-v7a", "noarch")):
                            if not universal_file_id:
                                universal_file_id = (cur_fid, is_xapk)

                    if specific_file_id:
                        file_id, is_bundle = specific_file_id
                    elif universal_file_id:
                        file_id, is_bundle = universal_file_id
    except Exception:
        pass

    return app_id, file_id, is_bundle

def download_file(base_url: str, version: str, dest_path: str, arch: str = "") -> bool:
    app_id, file_id, is_bundle = resolve_download_variant(base_url, version, arch)
    token = get_auth_token()
    cdn_url = get_cdn_download_url(app_id, file_id, token)

    target_dest = dest_path
    if is_bundle and not (target_dest.endswith(".apkm") or target_dest.endswith(".xapk")):
        target_dest = f"{os.path.splitext(target_dest)[0]}.apkm"

    os.makedirs(os.path.dirname(os.path.abspath(target_dest)), exist_ok=True)
    temp_dest = f"{target_dest}.part"

    req = urllib.request.Request(cdn_url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=300) as resp, open(temp_dest, "wb") as f:
        while True:
            chunk = resp.read(1048576)
            if not chunk:
                break
            f.write(chunk)

    if os.path.isfile(temp_dest) and os.path.getsize(temp_dest) > 0:
        if os.path.isfile(target_dest):
            os.remove(target_dest)
        os.rename(temp_dest, target_dest)
        return True

    return False

def main():
    if len(sys.argv) < 2:
        sys.exit(1)

    cmd = sys.argv[1]

    if cmd == "vers":
        if len(sys.argv) < 3:
            sys.exit(1)
        url = sys.argv[2]
        allow_all = (sys.argv[3].lower() == "true") if len(sys.argv) > 3 else False
        vers = get_versions(url, allow_all=allow_all)
        if vers:
            print(" ".join(vers))
            sys.exit(0)
        sys.exit(1)

    if cmd == "pkg":
        if len(sys.argv) < 3:
            sys.exit(1)
        url = sys.argv[2]
        clean_url = clean_page_url(url)
        html = fetch_web_page(clean_url)
        pkg = extract_package_name(html)
        if not pkg:
            # Check /download page
            try:
                dl_html = fetch_web_page(f"{clean_url}/download")
                pkg = extract_package_name(dl_html)
            except Exception:
                pass
        if pkg:
            print(pkg)
            sys.exit(0)
        sys.exit(1)

    if cmd == "download-url":
        if len(sys.argv) < 4:
            sys.exit(1)
        url = sys.argv[2]
        version = sys.argv[3]
        arch = sys.argv[4] if len(sys.argv) > 4 else ""
        app_id, file_id, is_bundle = resolve_download_variant(url, version, arch)
        token = get_auth_token()
        cdn_url = get_cdn_download_url(app_id, file_id, token)
        print(f"{cdn_url}\t{str(is_bundle).lower()}")
        sys.exit(0)

    if cmd == "download":
        if len(sys.argv) < 5:
            sys.exit(1)
        url = sys.argv[2]
        version = sys.argv[3]
        dest = sys.argv[4]
        arch = sys.argv[5] if len(sys.argv) > 5 else ""
        success = download_file(url, version, dest, arch)
        sys.exit(0 if success else 1)

    sys.exit(1)

if __name__ == "__main__":
    main()
