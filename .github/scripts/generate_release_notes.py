#!/usr/bin/env python3
import os
import re
import json
import glob
from pathlib import Path

def load_json(path, default=None):
    if os.path.exists(path):
        try:
            with open(path, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception as e:
            print(f"Warning: Could not read {path}: {e}")
    return default if default is not None else {}

def resolve_display_name(target_key, info):
    base_name = info.get("display_name") or target_key
    variant = (info.get("variant") or "").strip()
    sub_variant = (info.get("sub_variant") or "").strip()
    extras = []
    if variant and variant.lower() != "default":
        extras.append(variant)
    if sub_variant:
        extras.append(sub_variant)
    if extras:
        return f"{base_name} ({' - '.join(extras)})"
    return base_name

def normalize_arch(arch_raw):
    a = (arch_raw or "").lower().strip()
    if "arm64" in a or "aarch64" in a:
        return "arm64"
    if "arm" in a or "armeabi" in a:
        return "arm"
    if a in ["all", "universal"]:
        return "all"
    if "x86_64" in a or "x64" in a:
        return "x86_64"
    if "x86" in a:
        return "x86"
    return a or "universal"

def main():
    next_ver_code = os.environ.get("NEXT_VER_CODE", "").strip()
    github_server = os.environ.get("GITHUB_SERVER_URL", "https://github.com").rstrip("/")
    github_repo = os.environ.get("GITHUB_REPOSITORY", "").strip()

    build_dir = Path("build")
    build_json_file = Path("build.json")

    build_info = {}
    if build_json_file.exists():
        try:
            with open(build_json_file, "r", encoding="utf-8") as f:
                build_info = json.load(f)
        except Exception as e:
            print(f"Warning: Could not read {build_json_file}: {e}")

    # Discover actual files in build/
    built_files = []
    if build_dir.exists():
        built_files = [f.name for f in build_dir.iterdir() if f.is_file() and f.suffix.lower() in [".apk", ".zip"]]

    # Map target keys to patch groups
    # Group: patch_source -> { "tag": str, "changelog_url": str, "apps": { app_name: { "version": str, "apks": [], "modules": [] } } }
    patch_groups = {}

    for target_key, info in build_info.items():
        patches_source = info.get("patches_source") or ""
        patches_ref = info.get("patches") or ""
        changelog_url = (info.get("changlog") or info.get("changelog") or "").strip()

        # Extract primary patch source and version tag
        primary_source = patches_source.split()[0] if patches_source else (patches_ref.split()[0].split("/")[0] if "/" in patches_ref else "Patched")
        
        # Determine patch version tag
        patch_tag = ""
        if changelog_url:
            first_url = changelog_url.split()[0]
            if "/tag/" in first_url:
                patch_tag = first_url.split("/tag/")[-1].strip("/")
            elif "/-/releases/" in first_url:
                patch_tag = first_url.split("/-/releases/")[-1].strip("/")
            elif "/releases/" in first_url:
                patch_tag = first_url.split("/releases/")[-1].strip("/")

        if not patch_tag and patches_ref:
            ref_part = re.sub(r"\.(mpp|jar|rvp|apk|zip)$", "", patches_ref.split()[0], flags=re.IGNORECASE)
            tag_match = re.search(r"v?\d+(\.\d+)+([.-][a-zA-Z0-9]+)*", ref_part)
            if tag_match:
                matched = tag_match.group(0)
                patch_tag = matched if matched.startswith("v") else f"v{matched}"

        group_key = primary_source
        if group_key not in patch_groups:
            patch_groups[group_key] = {
                "source": primary_source,
                "tag": patch_tag,
                "changelog_url": changelog_url.split()[0] if changelog_url else "",
                "apps": {}
            }

        # Resolve display name directly from structured build info
        display_name = resolve_display_name(target_key, info)
        version = info.get("version", "")
        file_prefix = info.get("name", "")

        app_entry = {
            "display_name": display_name,
            "version": version,
            "apks": [],
            "modules": []
        }

        # Find matching built files
        # apk format: <file_prefix>-v<version>-<arch>.apk
        # module format: <file_prefix>-module-v<version>-<arch>.zip
        for fname in built_files:
            lower = fname.lower()
            prefix_lower = file_prefix.lower()
            if not (lower.startswith(prefix_lower + "-v") or lower.startswith(prefix_lower + "-module-")):
                continue

            # Check if apk
            if lower.endswith(".apk") and not "-module-" in lower:
                # Extract arch from filename
                arch_match = re.search(r"-v[^-]+-([a-zA-Z0-9_-]+)\.apk$", fname, re.IGNORECASE)
                raw_arch = arch_match.group(1) if arch_match else ""
                norm_arch = normalize_arch(raw_arch)
                dl_url = f"{github_server}/{github_repo}/releases/download/{next_ver_code}/{fname}" if (github_repo and next_ver_code) else f"./build/{fname}"
                app_entry["apks"].append((norm_arch, dl_url))

            # Check if module zip
            elif lower.endswith(".zip") and "-module-" in lower:
                arch_match = re.search(r"-v[^-]+-([a-zA-Z0-9_-]+)\.zip$", fname, re.IGNORECASE)
                raw_arch = arch_match.group(1) if arch_match else ""
                norm_arch = normalize_arch(raw_arch)
                dl_url = f"{github_server}/{github_repo}/releases/download/{next_ver_code}/{fname}" if (github_repo and next_ver_code) else f"./build/{fname}"
                app_entry["modules"].append((norm_arch, dl_url))

        # Sort architectures consistently: arm64, arm, all, etc.
        arch_priority = {"arm64": 0, "arm": 1, "all": 2, "universal": 3, "x86_64": 4, "x86": 5}
        app_entry["apks"].sort(key=lambda x: arch_priority.get(x[0], 99))
        app_entry["modules"].sort(key=lambda x: arch_priority.get(x[0], 99))

        if app_entry["apks"] or app_entry["modules"]:
            patch_groups[group_key]["apps"][display_name] = app_entry

    # Build output markdown
    lines = []

    # Sort groups alphabetically
    sorted_group_keys = sorted(patch_groups.keys())

    for gkey in sorted_group_keys:
        group = patch_groups[gkey]
        apps = group["apps"]
        if not apps:
            continue

        # Header format: ### 🧩 source ([tag](url))
        src = group["source"]
        tag = group["tag"]
        cl_url = group["changelog_url"]

        if tag and cl_url:
            tag_str = f" ([{tag}]({cl_url}))"
        elif tag:
            tag_str = f" ({tag})"
        elif cl_url:
            tag_str = f" ([changelog]({cl_url}))"
        else:
            tag_str = ""

        lines.append(f"### 🧩 {src}{tag_str}")

        # List apps in this patch group
        for app_name in sorted(apps.keys()):
            app = apps[app_name]
            ver_str = f" `v{app['version']}`" if app['version'] else ""
            lines.append(f"* **{app['display_name']}**{ver_str}")

            if app["apks"]:
                apk_links = " • ".join([f"[{arch}]({url})" for arch, url in app["apks"]])
                lines.append(f"  * APK: {apk_links}")

            if app["modules"]:
                mod_links = " • ".join([f"[{arch}]({url})" for arch, url in app["modules"]])
                lines.append(f"  * Module: {mod_links}")

        lines.append("")

    # Notes section
    lines.append("---")
    lines.append("")
    lines.append("### ℹ️ Notes")
    lines.append("• Install [MicroG-RE](https://github.com/MorpheApp/MicroG-RE/releases/latest) or [MicroG](https://github.com/ReVanced/GmsCore/releases/latest), required for Google APKs.  ")
    lines.append("• Use [Zygisk Detach](https://github.com/j-hc/zygisk-detach) to stop Play Store from updating Modules.  ")
    lines.append("")
    lines.append("🌐 [GitHub](https://github.com/nullcpy/rvb) | 💬 [Group](https://t.me/rvb27) | ☕ [Donate](https://fahim-ahmed05.github.io/donate) | 🔗 [Website](https://nullcpy.github.io)")
    lines.append("")
    content = "\n".join(lines)
    with open("build.md", "w", encoding="utf-8") as f:
        f.write(content)

    print("Successfully generated build.md")

if __name__ == "__main__":
    main()
