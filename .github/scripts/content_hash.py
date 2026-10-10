#!/usr/bin/env python3
"""Deterministic content hashing for APKs and modules.

Extracts entries and hashes uncompressed bytes, ignoring ZIP timestamps,
entry order differences, APK signing blocks (v2/v3), and META-INF signatures (v1).
"""
import hashlib
import io
import os
import zipfile
from pathlib import Path
from typing import Union


def compute_apk_content_hash(path: Union[str, Path, io.BytesIO]) -> str:
    """Computes a deterministic content hash for an APK.

    Ignores:
      - ZIP entry timestamps (Local File Header and Central Directory mod times)
      - Entry ordering (sorted by filename)
      - META-INF/ signatures (v1 scheme: MANIFEST.MF, CERT.SF, CERT.RSA)
      - APK Signing Block (v2/v3 scheme: resides outside ZIP entries)
    """
    h = hashlib.sha256()
    with zipfile.ZipFile(path, "r") as z:
        for name in sorted(z.namelist()):
            # Ignore v1 signatures, certificate files, and directory entries
            if name.startswith("META-INF/"):
                continue
            info = z.getinfo(name)
            if info.is_dir():
                continue
            h.update(name.encode("utf-8"))
            h.update(z.read(name))
    return h.hexdigest()


def compute_module_content_hash(path: Union[str, Path]) -> str:
    """Computes a deterministic content hash for a Magisk module ZIP.

    Normalizes module.prop by stripping the dynamic `versionCode=...` line,
    and applies content hashing to any embedded APKs.
    """
    h = hashlib.sha256()
    with zipfile.ZipFile(path, "r") as z:
        for name in sorted(z.namelist()):
            info = z.getinfo(name)
            if info.is_dir():
                continue
            h.update(name.encode("utf-8"))
            if name == "module.prop":
                # Filter out versionCode=... which is stamped with the runner build number
                content = z.read(name).decode("utf-8", errors="replace")
                lines = [
                    line
                    for line in content.splitlines()
                    if not line.strip().startswith("versionCode=")
                ]
                h.update("\n".join(lines).encode("utf-8"))
            elif name.endswith(".apk"):
                # Nested APK inside the module: compute content hash on the raw APK bytes
                apk_bytes = z.read(name)
                nested_hash = compute_apk_content_hash(io.BytesIO(apk_bytes))
                h.update(nested_hash.encode("utf-8"))
            else:
                h.update(z.read(name))
    return h.hexdigest()


def compute_content_hash(path: Union[str, Path]) -> str:
    """Dispatch content hash calculation based on file extension."""
    p = Path(path)
    lower = p.name.lower()
    if lower.endswith(".apk"):
        return compute_apk_content_hash(p)
    elif lower.endswith(".zip") and "-module-" in lower:
        return compute_module_content_hash(p)
    else:
        # Generic file fallback
        h = hashlib.sha256()
        with open(p, "rb") as f:
            while chunk := f.read(65536):
                h.update(chunk)
        return h.hexdigest()


if __name__ == "__main__":
    import sys

    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <file.apk|file.zip>", file=sys.stderr)
        sys.exit(1)
    print(compute_content_hash(sys.argv[1]))
