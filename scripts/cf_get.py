#!/usr/bin/env python3
import sys
import os

try:
    from curl_cffi import requests
except ImportError:
    # Exit 2: curl_cffi not installed, caller should fall back to Trawl/curl
    sys.exit(2)

def is_challenge(status_code: int, text: str) -> bool:
    if status_code in (403, 503):
        return True
    lower = text.lower()
    return any(phrase in lower for phrase in (
        "just a moment...",
        "attention required!",
        "please wait... | cloudflare",
        "verify you are human",
        "turnstile"
    ))

def get_impersonate_targets() -> list:
    targets = []
    BrowserType = None
    for module_name in (
        "curl_cffi.requests",
        "curl_cffi.requests.session",
        "curl_cffi.requests.impersonate",
        "curl_cffi",
    ):
        try:
            mod = __import__(module_name, fromlist=["BrowserType"])
            bt = getattr(mod, "BrowserType", None)
            if bt:
                BrowserType = bt
                break
        except Exception:
            continue

    if BrowserType:
        try:
            import re
            members = [m.value for m in BrowserType if hasattr(m, "value")]

            def sort_key(name: str):
                m_num = re.search(r"\d+", str(name))
                ver = int(m_num.group(0)) if m_num else 0
                name_str = str(name).lower()
                if "chrome" in name_str and "android" not in name_str:
                    return (3, ver)
                elif "safari" in name_str:
                    return (2, ver)
                elif "edge" in name_str:
                    return (1, ver)
                return (0, ver)

            sorted_members = sorted(members, key=sort_key, reverse=True)
            for t in sorted_members:
                if t not in targets:
                    targets.append(t)
        except Exception:
            pass

    # Ensure rolling aliases are prioritized
    if "chrome" not in targets:
        targets.insert(0, "chrome")
    if "safari" not in targets:
        targets.append("safari")

    # Pick rolling alias + top modern distinct targets (capped to 8)
    return targets[:8]

def main():
    if len(sys.argv) < 2:
        sys.exit(2)

    url = sys.argv[1]
    cookie_file = sys.argv[2] if len(sys.argv) > 2 else ""

    impersonate_targets = get_impersonate_targets()
    
    for imp in impersonate_targets:
        try:
            s = requests.Session(impersonate=imp)
            if cookie_file and os.path.isfile(cookie_file):
                try:
                    with open(cookie_file, "r", encoding="utf-8", errors="ignore") as f:
                        for line in f:
                            parts = line.strip().split("\t")
                            if len(parts) >= 7 and not line.startswith("#"):
                                s.cookies.set(parts[5], parts[6], domain=parts[0])
                except Exception:
                    pass

            resp = s.get(url, timeout=15, allow_redirects=True)
            if is_challenge(resp.status_code, resp.text):
                continue  # try next fingerprint instead of giving up

            if resp.status_code == 200 and resp.text:
                sys.stdout.write(resp.text)
                sys.exit(0)
            else:
                continue  # non-200, try next fingerprint
        except Exception:
            continue

    sys.exit(1)

if __name__ == "__main__":
    main()
