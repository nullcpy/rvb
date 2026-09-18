#!/usr/bin/env python3
import sys
import os
import time

try:
    from curl_cffi import requests
    from curl_cffi.requests import Response
except ImportError:
    # Exit 2: curl_cffi not installed, caller should fall back to curl/solver
    sys.exit(2)

def is_challenge(status_code: int, text: str, headers: dict = None) -> bool:
    if status_code in (403, 503):
        return True
    if headers and "cf-mitigated" in headers:
        return True
    lower = (text or "").lower()
    return any(phrase in lower for phrase in (
        "just a moment...",
        "attention required!",
        "please wait... | cloudflare",
        "verify you are human",
        "turnstile",
        "challenges.cloudflare.com",
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

    # Ensure standard aliases are prioritized
    if "chrome" not in targets:
        targets.insert(0, "chrome")
    if "safari" not in targets:
        targets.append("safari")

    return targets[:8]

def load_cookies(session, cookie_file: str):
    if not cookie_file or not os.path.isfile(cookie_file):
        return
    try:
        with open(cookie_file, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                parts = line.strip().split("\t")
                if len(parts) >= 7 and not line.startswith("#"):
                    session.cookies.set(parts[5], parts[6], domain=parts[0], path=parts[2])
    except Exception:
        pass

    # Check companion user agent file if available
    temp_dir = os.path.dirname(os.path.abspath(cookie_file))
    ua_path = os.path.join(temp_dir, "cf_ua.txt")
    if os.path.isfile(ua_path):
        try:
            with open(ua_path, "r", encoding="utf-8", errors="ignore") as f:
                ua = f.read().strip()
                if ua:
                    session.headers["User-Agent"] = ua
        except Exception:
            pass

def save_cookies(session, cookie_file: str, user_agent: str = ""):
    if not cookie_file:
        return
    try:
        temp_dir = os.path.dirname(os.path.abspath(cookie_file))
        os.makedirs(temp_dir, exist_ok=True)
        with open(cookie_file, "w", encoding="utf-8") as f:
            f.write("# Netscape HTTP Cookie File\n")
            for c in session.cookies:
                domain = getattr(c, "domain", "") or ""
                path = getattr(c, "path", "/") or "/"
                secure = "TRUE" if getattr(c, "secure", False) else "FALSE"
                expires = str(int(getattr(c, "expires", 0) or 0))
                name = getattr(c, "name", "")
                val = getattr(c, "value", "")
                f.write(f"{domain}\tTRUE\t{path}\t{secure}\t{expires}\t{name}\t{val}\n")

        if user_agent:
            with open(os.path.join(temp_dir, "cf_ua.txt"), "w", encoding="utf-8") as f:
                f.write(user_agent)

        cookie_header = "; ".join(f"{c.name}={c.value}" for c in session.cookies)
        if cookie_header:
            with open(os.path.join(temp_dir, "cf_cookies.txt"), "w", encoding="utf-8") as f:
                f.write(cookie_header)
    except Exception:
        pass

def solve_challenge(url: str, session) -> tuple[bool, str]:
    solver_url = os.getenv("CF_SOLVER_URL", "http://localhost:8000").rstrip("/")
    try:
        resp = requests.get(f"{solver_url}/cookies", params={"url": url}, timeout=60)
        if resp.status_code == 200:
            data = resp.json()
            cookies = data.get("cookies", {})
            user_agent = data.get("user_agent", "")
            if isinstance(cookies, dict):
                for k, v in cookies.items():
                    session.cookies.set(k, v)
            elif isinstance(cookies, list):
                for c in cookies:
                    if isinstance(c, dict) and "name" in c and "value" in c:
                        session.cookies.set(c["name"], c["value"])

            if user_agent:
                session.headers["User-Agent"] = user_agent
            return True, user_agent
    except Exception as e:
        sys.stderr.write(f"[cf_get] Solver error connecting to {solver_url}: {e}\n")
    return False, ""

def fetch_from_solver_html(url: str) -> str | None:
    solver_url = os.getenv("CF_SOLVER_URL", "http://localhost:8000").rstrip("/")
    try:
        resp = requests.get(f"{solver_url}/html", params={"url": url}, timeout=60)
        if resp.status_code == 200 and resp.text:
            if not is_challenge(resp.status_code, resp.text, getattr(resp, "headers", None)):
                return resp.text
    except Exception:
        pass
    return None

def download_file(url: str, dest_path: str, referer: str = "", cookie_file: str = "") -> bool:
    os.makedirs(os.path.dirname(os.path.abspath(dest_path)), exist_ok=True)
    temp_dest = f"{dest_path}.part"
    impersonate_targets = get_impersonate_targets()

    for imp in impersonate_targets:
        try:
            s = requests.Session(impersonate=imp)
            load_cookies(s, cookie_file)
            headers = {}
            if referer:
                headers["Referer"] = referer

            resp = s.get(url, headers=headers, timeout=(10, 300), stream=True, allow_redirects=True)
            if is_challenge(resp.status_code, "", getattr(resp, "headers", None)):
                solved, ua = solve_challenge(url, s)
                if solved:
                    save_cookies(s, cookie_file, ua)
                    resp = s.get(url, headers=headers, timeout=(10, 300), stream=True, allow_redirects=True)

            if resp.status_code == 200:
                with open(temp_dest, "wb") as f:
                    for chunk in resp.iter_content(chunk_size=1048576):
                        if chunk:
                            f.write(chunk)
                if os.path.isfile(temp_dest) and os.path.getsize(temp_dest) > 0:
                    if os.path.isfile(dest_path):
                        os.remove(dest_path)
                    os.rename(temp_dest, dest_path)
                    save_cookies(s, cookie_file)
                    return True
        except Exception as e:
            sys.stderr.write(f"[cf_get] Download error with target {imp}: {e}\n")
            if os.path.isfile(temp_dest):
                try:
                    os.remove(temp_dest)
                except Exception:
                    pass
            continue

    return False

def main():
    if len(sys.argv) < 2:
        sys.exit(2)

    # Handle download subcommand: cf_get.py download <url> <dest> [referer] [cookie_file]
    if sys.argv[1] == "download":
        if len(sys.argv) < 4:
            sys.exit(2)
        dl_url = sys.argv[2]
        dest = sys.argv[3]
        referer = sys.argv[4] if len(sys.argv) > 4 else ""
        cookie_file = sys.argv[5] if len(sys.argv) > 5 else ""
        success = download_file(dl_url, dest, referer, cookie_file)
        sys.exit(0 if success else 1)

    url = sys.argv[1]
    cookie_file = sys.argv[2] if len(sys.argv) > 2 else ""

    impersonate_targets = get_impersonate_targets()

    for imp in impersonate_targets:
        try:
            s = requests.Session(impersonate=imp)
            load_cookies(s, cookie_file)

            resp = s.get(url, timeout=15, allow_redirects=True)
            if is_challenge(resp.status_code, resp.text, getattr(resp, "headers", None)):
                solved, ua = solve_challenge(url, s)
                if solved:
                    save_cookies(s, cookie_file, ua)
                    # Retry with solved clearance cookies + User-Agent
                    resp = s.get(url, timeout=15, allow_redirects=True)
                    if not is_challenge(resp.status_code, resp.text, getattr(resp, "headers", None)) and resp.status_code == 200:
                        sys.stdout.write(resp.text)
                        sys.exit(0)

                # Fallback: query solver's direct /html endpoint
                solver_html = fetch_from_solver_html(url)
                if solver_html:
                    sys.stdout.write(solver_html)
                    sys.exit(0)

                continue  # try next impersonation target

            if resp.status_code == 200 and resp.text:
                save_cookies(s, cookie_file)
                sys.stdout.write(resp.text)
                sys.exit(0)
            else:
                continue
        except Exception:
            continue

    # Final fallback if curl_cffi failed on all targets: try solver /html endpoint directly
    solver_html = fetch_from_solver_html(url)
    if solver_html:
        sys.stdout.write(solver_html)
        sys.exit(0)

    sys.exit(1)

if __name__ == "__main__":
    main()
