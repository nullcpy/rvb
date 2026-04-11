import re
import sys
import json
import datetime

if len(sys.argv) < 2:
    sys.exit(0)
tag = sys.argv[1]

with open("build.json", encoding="utf-8") as f:
    build_data = json.load(f)
with open("README.md", encoding="utf-8") as f:
    readme = f.read()

for key, info in build_data.items():
    version = info["version"]
    name = info["name"]
    arch = info.get("arch", "")
    exts = info.get("exts", [])

    badge_version = version.replace("-", ".").replace(" ", "")
    link_version = re.sub(
        r"\.+", ".", re.sub(r"[^a-zA-Z0-9@+\-_.]", ".", version.replace(" ", ""))
    )

    details_pattern = rf'<details>\s*<summary id="{re.escape(key)}"[^>]*>.*?</details>'
    matches = list(re.finditer(details_pattern, readme, re.IGNORECASE | re.DOTALL))
    if not matches:
        continue

    for match in reversed(matches):
        old_details = match.group(0)
        new_details = re.sub(
            r'(src="[^"]*?-v)\d[^"]*?(-gray\?)', rf"\g<1>{badge_version}\g<2>", old_details
        )

        for ext in exts:
            if not ext:
                continue
            if ext.endswith(".apk"):
                new_file = f"{name}-v{link_version}-{arch}{ext}"
            else:
                new_file = f"{name}-module-v{link_version}-{arch}{ext}"

            link_pattern = (
                rf'((?:\.\./)*releases/download/)[^\s)"\'<>]*{re.escape(ext)}'
            )
            new_details = re.sub(link_pattern, rf"\g<1>{tag}/{new_file}", new_details)

        current_date = datetime.datetime.now().strftime("%Y-%m-%d")
        patches = info.get("patches", "")
        changelog_url = info.get("changlog", "")
        if patches and changelog_url:
            patches_line = f"Patches: [{patches}]({changelog_url})"
        else:
            patches_line = f"Patches: {patches}"

        new_content = (
            f"\n\n[Release {current_date}](../../releases/tag/{tag})<br>\n{patches_line}"
        )
        if info.get("applied_patches"):
            for patch in info["applied_patches"]:
                if patch.strip():
                    new_content += f"\n- {patch.strip()}"

        new_blockquote = f"<blockquote>{new_content}\n</blockquote>"
        new_details = re.sub(
            r"<blockquote>\s*\n.*?\n</blockquote>",
            new_blockquote,
            new_details,
            flags=re.DOTALL,
        )

        readme = readme[: match.start()] + new_details + readme[match.end() :]
    print(f"✓ {key} v{version} → release/{tag}")

with open("README.md", "w", encoding="utf-8") as f:
    f.write(readme)

print("✓ README updated")
