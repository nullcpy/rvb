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

def main():
    if len(sys.argv) < 2:
        sys.exit(2)

    url = sys.argv[1]
    cookie_file = sys.argv[2] if len(sys.argv) > 2 else ""

    # Try modern Chrome browser fingerprints supported by curl_cffi
    impersonate_targets = ["chrome133", "chrome124", "chrome120", "chrome110"]
    
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
                sys.exit(1)

            if resp.status_code == 200 and resp.text:
                sys.stdout.write(resp.text)
                sys.exit(0)
            else:
                sys.exit(1)
        except Exception:
            continue

    sys.exit(1)

if __name__ == "__main__":
    main()
