# Config

Adding another revanced app is as easy as this:
```toml
[Some-App]
apkmirror-dlurl = "https://www.apkmirror.com/apk/inc/app"
# or uptodown-dlurl = "https://app.en.uptodown.com/android"
```

> [!WARNING]
> When a patch name itself contains a single quote, double it inside the string (e.g. 'Hide ''Get Music Premium''').

## More about other options:

There exists an example below with all defaults shown and all the keys explicitly set.  
**All keys are optional** (except download urls) and are assigned to their default values if not set explicitly.  

```toml
compression-level = 9                # module zip compression level
remove-rv-integrations-checks = true # remove checks from the revanced integrations
dpi = "320dpi nodpi"            # dpi packages to be searched in order. 'auto' matches whatever is available. default: "nodpi anydpi auto"

patches-source = "revanced/revanced-patches" # where to fetch patches bundle from. default: "MorpheApp/morphe-patches"
patches-source-host = "github"               # source host for patches: "github" or "gitlab". default: "github"
cli-source = "ReVanced/revanced-cli"             # where to fetch cli from. default: "MorpheApp/morphe-desktop"
cli-source-host = "github"                       # source host for cli: "github" or "gitlab". default: "github"
# options like cli-source can also set per app
brand = "Morphe"                     # patch brand/engine identity (e.g. "ReVanced Advanced", "Piko", "Morphe", "Android TV"). default: patches-source owner.

author = "nullcpy"                   # module author name. default: "nullcpy"
author-page = "github.com/nullcpy/rvb" # module author page/link printed during installation. default: "github.com/nullcpy/rvb"

patches-version = "stable"  # 'stable', 'beta', 'both', or a version number. default: "stable"
cli-version = "stable"      # 'stable', 'beta', or a version number. default: "stable"

> [!TIP]
> **File-Level Defaults in Modular Configs:**  
> Keys defined at the top of the file before the first `[...]` section (such as `patches-source`, `cli-source`, `patches-version`, `brand`, `variant`, `arch`, and `build-mode`) act as file-level defaults for all apps in that file. Apps automatically inherit them unless overridden.

[Some-App]
app-name = "SomeApp"     # clean display name (e.g. "YouTube", "Instagram"). Default is table name.
brand = "Piko"           # per-app patch brand override (e.g. "Piko", "Adobo", "ReVanced Advanced").
variant = "Nord"         # optional feature/visual variant (e.g. "Nord", "Mocha", "MaterialYou").
sub-variant = "clone"    # optional packaging/install variant (e.g. "clone", "alt").
pkg-name = "com.some.app" # stock package name (used by APKMirror/Uptodown scrapers and version checking).
patched-pkg-name = "com.some.app.clone" # optional override for the resulting installed package name (e.g. for clone patches). If omitted, the builder auto-detects the actual package ID from the compiled APK manifest via aapt2.
patch-folder = "someapp" # explicit patch folder name override. forces the CI to strictly match patches inside this exact folder name, bypassing fallback heuristics (useful for resolving collisions like youtube vs youtube-music). Supports multiple folders space-separated (e.g. "ad backup geo"), or a wildcard "*" to force mapping every single patch folder in the repo.
enabled = true       # whether to build the app. default: true
build-mode = "both"  # 'both', 'apk' or 'module'. default: apk
arch = "both"        # 'both', 'auto', 'all', 'arm64-v8a', 'arm-v7a', 'x86_64', or 'x86'. default: both

# 'auto' option gets the latest possible version supported by all the included patches
# 'exp' gets the latest experimental version from patches.json. falls back to 'latest' if none found.
# 'latest' gets the latest stable without checking patches support. 'beta' gets the latest beta/alpha
# whitespace seperated list of patches to exclude. default: ""
version = "auto"     # 'auto', 'exp', 'latest', 'beta' or a version number (e.g. '17.40.41'). default: auto
# target Android versionCode. 'auto' automatically resolves the supported versionCode from patch metadata (e.g. Morphe Desktop).
# can also be set to an explicit versionCode (e.g. '473623755') or mapped per-architecture ('arm64-v8a: 473623755 | arm-v7a: 473623748').
# used by APKMirror to select the exact build variant and to validate/invalidate cached and downloaded APKs. default: "" (or auto when resolved)
version-code = "auto"

# optional args to be passed to cli. can be used to set patch options
# multiline strings in the config is supported
patcher-args = """\
  -OdarkThemeBackgroundColor=#FF0F0F0F \
  -Oanother-option=value \
  """

excluded-patches = """\
  'Some Patch' \
  'Some Other Patch' \
  """                                                      # whitespace seperated list of patches to exclude. When mixing multiple `patches-source` bundles, you can use `|` to separate the patches for each bundle. To skip a bundle, leave the side empty (e.g. `" | 'Patch for second bundle'"`).

included-patches = "'Some Patch'"                          # whitespace seperated list of non-default patches to include. default: "". When mixing multiple `patches-source` bundles, you can use `|` to separate the patches for each bundle. To skip a bundle, leave the side empty (e.g. `" | 'Patch for second bundle'"`).
include-stock = "merged"                                   # 'merged', 'split' or 'disable'. default: merged
exclusive-patches = false                                  # exclude all patches by default. Accepts `true`, `false`, or a string of patch sources (e.g. `"'jkennethcarino/adobo'"`). When a specific patch source is provided, only that bundle becomes exclusive, while others retain their default patches. default: false

apkmirror-dlurl = "https://www.apkmirror.com/apk/inc/app"
uptodown-dlurl = "https://spotify.en.uptodown.com/android"
apkpure-dlurl = "https://apkpure.com/some-app/com.some.app"
apkcombo-dlurl = "https://apkcombo.com/some-app/com.some.app"
# github release url or repo url (e.g. 'https://github.com/developer/app', '.../releases/latest', or '.../releases/tag/v1.0').
github-dlurl = "https://github.com/developer/app"
# regex used to filter releases when querying a repo url without a fixed tag (e.g. multi-channel repos).
# if omitted, the script automatically checks if table, brand, or variant targets a channel (beta, nightly, alpha, canary) or filters for stable releases.
github-release-regex = "^Beta"
# regex used to pick the exact apk file from the github release assets. supports {version} and {arch} string interpolation.
# you can define a generic regex, or map architectures to specific regexes using 'arch: regex | arch2: regex2'.
github-regex = "arm64-v8a: 'MyApp-arm64-v{version}\\.apk' | arm-v7a: 'MyApp-arm-v{version}\\.apk'"
# direct download url. the url must have point to an apk file with name format shown in this example
direct-dlurl = "https://website/com.google.android.youtube-20.40.45-all.apk"

module-prop-name = "some-app-module"                       # module prop name. default: "<app>-<author>"
dpi = "360-480dpi"                                         # used to select apk variant from apkmirror. 'auto' matches whatever is available. default: nodpi anydpi auto
```

### Naming & Catalog Hierarchy

The declarative keys define both the asset filename and how the app appears in release notes and the website catalog:
- **`app-name`**: Sets the human-readable display name (e.g. `YouTube`, `Instagram`, `Prime Video`).
- **`brand`**: Declares the canonical patch brand or creator identity (e.g. `ReVanced Advanced`, `Piko`, `Adobo`, `Paresh`, `Android TV`, `Morphe`).
- **`variant`**: (Optional) Declares visual or feature variations (e.g. `Nord`, `Mocha`, `MaterialYou`).
- **`sub-variant`**: (Optional) Declares packaging or installation variations (e.g. `clone`, `alt`).
- **`pkg-name`**: Sets the upstream stock application package name (e.g. `com.amazon.amazonvideo.livingroom`), used by scrapers (APKMirror, Uptodown) and patch bytecode checkers.
- **`patched-pkg-name`**: (Optional) Declares the resulting installed package name when changed by a clone patch (e.g. `com.amazon.amazonvideo.livingroom.clone`). Used by the website catalog and Obtainium for installation tracking. If omitted on cloned apps, the build engine automatically extracts the real package ID from the built APK's manifest using `aapt2`.

#### Direct Slug Resolution

The build engine (`utils.sh`) automatically derives filename slugs directly from your declarative configuration using clean kebab-casing:
- `brand = "ReVanced Advanced"` ➔ `revanced-advanced` (or `brand = "Anddea"` ➔ `anddea`)
- `brand = "Android TV"` ➔ `android-tv`
- `brand = "Piko"` ➔ `piko`
- `brand = "Morphe"` ➔ `morphe`
- `app-name = "YouTube Music"` ➔ `youtube-music`

Every configuration is self-contained in its TOML file with zero external lookup files.

**Output Filename Structure:**
```
${app_slug}-${brand_slug}${variant:+-$variant}${sub_variant:+-$sub_variant}-v${version}-${arch}.apk
```

Examples:
- `app-name = "YouTube"`, `brand = "ReVanced Advanced"`, `variant = "Nord"` ➔ `youtube-revanced-advanced-nord-v20.51.39-arm64-v8a.apk`
- `app-name = "YouTube Music"`, `brand = "Anddea"` ➔ `youtube-music-anddea-v8.11.51-arm64-v8a.apk`
- `app-name = "Instagram"`, `brand = "Piko"`, `sub-variant = "clone"` ➔ `instagram-piko-clone-v439.0.0.37.89-arm64-v8a.apk`
- `app-name = "Prime Video"`, `brand = "Android TV"`, `sub-variant = "clone"` ➔ `prime-video-android-tv-clone-v3.0.354-arm-v7a.apk`
- `app-name = "TikTok"`, `brand = "Morphe"`, `sub-variant = "alt"` ➔ `tiktok-morphe-alt-v37.5.4-arm64-v8a.apk`
- `app-name = "Disney+"`, `brand = "Android TV"`, `sub-variant = "clone"` ➔ `disney-android-tv-clone-v3.0.354-arm-v7a.apk`

## Multiple Patch Sources

You can pass multiple patch bundles to the CLI by specifying `patches-source` as a quoted list (same format as `excluded-patches`).
When using multiple sources, the CLI merges the patch bundles. However, please see the **Current Limitations** below regarding `included-patches` and `excluded-patches`.

```toml
# single-line format
patches-source = "'MorpheApp/morphe-patches' 'other/patches'"

# multiline format
patches-source = """\
  'MorpheApp/morphe-patches' \
  'other/patches' \
  """

# If all sources are on the same host, a single string applies to all:
patches-source-host = "github"

# If sources span different hosts, provide one value per source in order:
patches-source-host = "'github' 'gitlab'"

# Same rule applies to patches-version:
patches-version = "latest"                        # applies to all sources
patches-version = "'latest' 'v1.2.3'"             # per-source versions
```

> [!TIP]
> **Per-bundle patch selection**: When using multiple sources, separate patch lists 
> with `|` to control each bundle independently:
> ```toml
> patches-source = "'MorpheApp/morphe-patches' 'other/patches'"
> excluded-patches = "'Patch A' | 'Patch B'"    # Patch A from bundle 1, Patch B from bundle 2
> included-patches = "'' | 'Patch X'"           # nothing from bundle 1, Patch X from bundle 2
> ```
> Without `|`, the same list applies to all bundles (backward compatible).

## Xposed Modules (NPatch / LSPatch)

You can natively inject Xposed modules into an app using `7723mod/NPatch` or `LSPatch` directly from your config. Simply set the `cli-source` to the NPatch repository and the `patches-source` to the Xposed module repository.

```toml
[Discord]
cli-source = "7723mod/NPatch"                            # Use NPatch as the CLI
cli-version = "latest"
patches-source = "revenge-mod/revenge-xposed"            # Provide the Xposed module as the patches bundle
patches-version = "latest"
version = "auto"                                         # 'auto' safely falls back to 'latest' since modules don't list supported versions
arch = "auto"
github-dlurl = "https://github.com/discord/releases/..." # Or apkmirror, etc.
```

When the script detects `npatch` or `lspatch` in the CLI source, it will automatically bypass ReVanced CLI arguments and execute the correct injection command. You can also pass extra options to NPatch using `patcher-args = "-l 2"`.

## Instafel Patcher (Instagram Alpha)

You can natively build Instagram Alpha using the Instafel Patcher engine (`instafel/p-rel`) and Patcher Core (`instafel/pc-rel`).

```toml
[instagram-instafel]
cli-source = "instafel/p-rel"                            # Use Instafel Patcher CLI
cli-version = "stable"
patches-source = "instafel/pc-rel"                       # Provide Instafel Patcher Core
patches-version = "stable"
included-patches = "'unlock_developer_options' 'remove_snooze_warning' 'remove_ads' 'instafel'"
```

## Modular Configuration Directory & Dynamic Pool Routing

Configurations are organized in `.github/configs/patches/*.toml` (e.g. `morphe.toml`, `anddea.toml`, `piko.toml`, `ajstrick81.toml`).

You do **not** need separate files for stable and beta:
- **Single-File Co-existence**: All variants and builds for a brand or patch source can reside in the same `.toml` file.
- **Top-Level Inheritance**: Keys defined at the top of the file before the first `[...]` header (such as `patches-source`, `brand`, `variant`, and `patches-version`) act as file-level defaults. Apps automatically inherit them, keeping app blocks concise and DRY.
- **Default CLI Engine**: `cli-source` defaults to `"MorpheApp/morphe-desktop"` globally and can be completely omitted unless using alternative tools like `7723mod/NPatch` or `instafel/p-rel`.
- **Dynamic Pool Routing**:
  - **Both Pools (Default)**: If neither the file-level header nor the app specifies `patches-version`, the app is automatically compiled into **both** stable and beta pools.
  - **Stable Only**: Setting `patches-version = "stable"` routes the app exclusively to the stable build pool.
  - **Beta Only**: Setting `patches-version = "beta"` routes the app exclusively to the beta (pre-release) build pool.
  - **File-Level Defaults**: Setting `patches-version = "stable"` (or `"beta"`) at the top applies that channel to all apps in the file unless individually overridden.
  - **Filename Inference**: A filename with `.stable.toml` or `.beta.toml` automatically defaults all apps in that file to that channel. Renaming to `*.toml` enables dual-pool compilation by default.
  - **Disabling an App**: Set `enabled = false` to disable an app across all pools.

## Automated Patch Sources State Tracking

Patch sources and their release versions in `.github/configs/patch_sources.json` are **100% automated**:
- The CI automatically scans all `.toml` files, discovers every active `patches-source` repository and host (`github` or `gitlab`), and checks for new stable and beta releases.
- Unreferenced or deleted patch sources are pruned automatically.
- **You do not need to manually edit `patch_sources.json`.** Simply add or update `patches-source` in your `.toml` files.

## Automatic App Version Checking

The CI workflow automatically detects when a new version of an app is released on APKMirror, Uptodown, or Archive.org.

### How it Works
1. **Version Fetching**: During the CI run, it reads all enabled apps from the `.github/configs/patches/*.toml` configurations and queries the URLs (`uptodown-dlurl`, `apkmirror-dlurl`, etc.).
2. **Comparison**: It checks the newly fetched versions against the currently stored versions in `.github/configs/app_versions.json`.
3. **Triggering**: If a new version is detected, the app is added to a temporary `active_apps.json` list, and the CI is triggered to build it.
### Tracking File
App versions are permanently tracked and committed to `.github/configs/app_versions.json`.
You can manually update this file if you need to force a specific version state, but the CI will automatically manage it during scheduled runs.

**Selective Checking:** If you only want the CI to check specific apps (instead of all enabled apps in your config), you can add `"_check_only_listed": true` to the top level of `app_versions.json`. When this is true, the script will only check for updates for the apps that already exist as keys in the file, saving time and resources.

## Release Cleanup & Catalog Synchronization

Maintenance and cleanup workflows ensure GitHub Releases, changelogs, and the website catalog remain pruned and synchronized with live metrics.

### Automated Routine Cleanup (`cleanup.yml`)
- **Numbered Releases**: Retains the latest 98 numbered releases via `ophub/delete-releases-workflows`.
- **Archive Releases**: Retains rolling `stable` and `beta` releases, keeping up to 2 versions per asset group via `cleanup-archive-assets.py`.
- **Website Catalog Sync (`sync_website_catalog.py`)**:
  - Pulls live `download_count` numbers directly from GitHub Releases API in a single bulk request (`releases?per_page=100`).
  - Updates asset download metrics and recalculates `totalDownloads` for every brand and app in `data.json`.
  - Prunes deleted builds and empty apps, and reconciles variant pointers (`latestStable`, `latestBeta`).
  - **Circuit Breaker**: Hard-aborts if GitHub API returns `< 10` releases to protect `data.json` from accidental corruption.

### Full Clean Slate / Rebuilding from Scratch
To completely wipe all historical releases (including `stable` and `beta`) and rebuild everything with clean Schema v2 naming conventions:
1. In `.github/workflows/cleanup.yml`, set:
   ```yaml
   releases_keep_latest: 0
   workflows_keep_day: 0
   # (omit releases_keep_keyword: stable/beta)
   ```
2. Set `ALLOW_EMPTY_CATALOG: "true"` in the `Synchronize Website Catalog Data` step.
3. Trigger the **Cleanup** workflow via `workflow_dispatch`.
   - All past releases, tags, and workflow logs are purged.
   - `sync_website_catalog.py` resets `data.json` on `nullcpy.github.io` to `apps: []` without tripping the circuit breaker.
4. Subsequent CI builds will author clean numbered releases and rolling archives from scratch.
5. **Restoring Routine Configuration**: After the clean-slate rebuild has run, restore `.github/workflows/cleanup.yml` back to standard retention:
   ```yaml
   releases_keep_latest: 98
   releases_keep_keyword: stable/beta
   workflows_keep_day: 0
   ```
   and remove `ALLOW_EMPTY_CATALOG: "true"` (or set to `"false"`) to re-arm the circuit breaker.
