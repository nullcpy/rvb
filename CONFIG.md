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
parallel-jobs = 1                    # amount of cores to use for parallel patching, if not set $(nproc) is used
compression-level = 9                # module zip compression level
remove-rv-integrations-checks = true # remove checks from the revanced integrations
dpi = "nodpi anydpi 120-640dpi"      # dpi packages to be searched in order. default: "nodpi anydpi"

patches-source = "revanced/revanced-patches" # where to fetch patches bundle from. default: "MorpheApp/morphe-patches"
patches-source-host = "github"               # source host for patches: "github" or "gitlab". default: "github"
cli-source = "ReVanced/revanced-cli"             # where to fetch cli from. default: "MorpheApp/morphe-cli"
cli-source-host = "github"                       # source host for cli: "github" or "gitlab". default: "github"
# options like cli-source can also set per app
rv-brand = "ReVanced Extended" # rebrand from 'ReVanced' to something different. default: patches-source owner

patches-version = "v2.160.0" # 'latest', 'dev', or a version number. default: "latest"
cli-version = "v5.0.0"       # 'latest', 'dev', or a version number. default: "latest"

[Some-App]
app-name = "SomeApp" # if set, release name becomes SomeApp instead of Some-App. default is same as table name, which is 'Some-App' here.
enabled = true       # whether to build the app. default: true
build-mode = "both"  # 'both', 'apk' or 'module'. default: apk

# 'auto' option gets the latest possible version supported by all the included patches
# 'latest' gets the latest stable without checking patches support. 'beta' gets the latest beta/alpha
# whitespace seperated list of patches to exclude. default: ""
version = "auto"     # 'auto', 'latest', 'beta' or a version number (e.g. '17.40.41'). default: auto

# optional args to be passed to cli. can be used to set patch options
# multiline strings in the config is supported
patcher-args = """\
  -OdarkThemeBackgroundColor=#FF0F0F0F \
  -Oanother-option=value \
  """

excluded-patches = """\
  'Some Patch' \
  'Some Other Patch' \
  """

included-patches = "'Some Patch'"                          # whitespace seperated list of non-default patches to include. default: ""
include-stock = "merged"                                   # 'merged', 'split' or 'disable'. default: merged
exclusive-patches = false                                  # exclude all patches by default. default: false

apkmirror-dlurl = "https://www.apkmirror.com/apk/inc/app"
uptodown-dlurl = "https://spotify.en.uptodown.com/android"
apkpure-dlurl = "https://apkpure.com/some-app/com.some.app"
apkcombo-dlurl = "https://apkcombo.com/some-app/com.some.app"
# github release tag url. downloads apk assets from that release.
github-dlurl = "https://github.com/nvbangg/apks/releases/tag/com.some.app"
# direct download url. the url must have point to an apk file with name format shown in this example
direct-dlurl = "https://website/com.google.android.youtube-20.40.45-all.apk"

module-prop-name = "some-app-module"                       # module prop name.
dpi = "360-480dpi"                                         # used to select apk variant from apkmirror. 'auto' matches whatever is available. default: nodpi anydpi
arch = "arm64-v8a"                                         # 'auto', 'arm64-v8a', 'arm-v7a', 'all', 'both'. 'both' downloads both arm64-v8a and arm-v7a. 'auto' tries all → arm64-v8a → arm-v7a, using the first available. default: auto
```

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

> [!WARNING]
> **Current Limitations**: 
> Due to how the underlying CLIs handle arguments, `included-patches` and `excluded-patches` currently only apply to the **last** patch bundle in your `patches-source` list. 
> Per-bundle selective inclusion/exclusion (e.g. including one patch from the first bundle, and excluding another from the second) is not currently supported in this config format. If you use multiple sources, it is recommended to apply all patches from the preceding bundles.

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
