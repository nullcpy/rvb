#!/usr/bin/env python3
"""Deterministic md5 content fingerprint of a (patched) APK.

Duplicate-build detection reads content, not file bytes: every rebuild rezips
and re-signs, so raw bytes differ even when the APK did not change. Mirrors the
bucketing shape of ci_check_app_patches.py's patch-bundle hash — entries walked
in sorted() order, keyed by name + CRC32 + size, read from the central directory
alone (no decompression):
  - META-INF/* is skipped (v1 signatures; they move with any content change
    anyway, so they carry no signal).
  - v2/v3 signatures live in the APK Signing Block, outside the zip central
    directory — invisible to zipfile, nothing to exclude.
  - Entry contents are never read, which also keeps any per-run stamp that a
    future container might carry (build numbers in file bodies) out of the
    digest as long as it lives in the signing/metadata space this skips.

Not a security property: md5 here only answers "did our own pipeline produce
the same content again", never "can this artifact be trusted".

CLI: print the hex digest for one file; exit non-zero (no digest) when the file
is not a readable zip, so callers treat it as "no verdict".
"""
import hashlib
import sys
import zipfile


def content_hash(path):
    h = hashlib.md5()
    with zipfile.ZipFile(path) as z:
        for info in sorted(z.infolist(), key=lambda i: i.filename):
            if info.is_dir():
                continue
            if info.filename.startswith("META-INF/"):
                continue
            h.update(info.filename.encode("utf-8"))
            h.update(str(info.CRC).encode())
            h.update(str(info.file_size).encode())
    return h.hexdigest()


def main(argv):
    if len(argv) != 2:
        print(f"usage: {argv[0]} <apk>", file=sys.stderr)
        return 2
    try:
        print(content_hash(argv[1]))
    except Exception as e:  # not a zip / unreadable → no verdict for the caller
        print(f"content_hash: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
