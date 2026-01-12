<div align="center"><a href="https://github.com/Safouene1/support-palestine-banner/blob/master/Markdown-pages/Support.md"><img src="https://raw.githubusercontent.com/Safouene1/support-palestine-banner/master/banner-support.svg" alt="Support Palestine" style="width: 100%;"></a></div>


# ![ReVanced Builder Icon](./.github/assets/icon.png) ReVanced Builder
**Automatically builds and publishes ReVanced APKs & Magisk/KernelSU Modules whenever new patches are released.**

> [!Important]
> **Please star the repo! 🙏🥺**

## 🗨️ [Join the Telegram Group](https://t.me/rvb27)
Get instant notifications when new builds are released and download them easily.

## 📢 [Join the Telegram Channel](https://t.me/rvb28)
For quick access to the latest download links via Telegram or your browser. [`t.me/s/rvb28`](https://t.me/s/rvb28)

## 📦 [Download from GitHub](../../releases)
If the app you need isn’t in the latest version, check older releases.

## 🗃️ [Download from Mirrors](./.github/pages/mirrors.md)
Use these links if GitHub is slow, blocked, or unreliable.

## 🍀 [Download FiorenMas Builds](./.github/pages/FiorenMas.md)
A collection of additional APKs built from various ReVanced patches.

## 📥 How to Install via [Obtainium](https://github.com/ImranR98/Obtainium)
Obtainium is the easiest way to install and update ReVanced APKs.

1. Open the **Obtainium** app.  
2. Tap **Add app**.  
3. In the **App source URL** box, enter one of the following:

- **For ReVanced APKs:**  
  ```
  https://github.com/geologically/revanced-builder
  ```

- **For MicroG (required for Google APKs):**  
  ```
  https://github.com/WSTxda/MicroG-RE
  ```

4. Scroll down to **Filter APKs by regular expression**.  
5. Enter the regex from the table below for the app you want.  
6. Tap **Add** to begin downloading.

### 🔎 Regex Patterns for Filtering APKs
| Patch                                                                          | App             | Arch      | Regex Pattern                                                               |
|--------------------------------------------------------------------------------|-----------------|-----------|-----------------------------------------------------------------------------|
| [revanced](https://github.com/revanced/revanced-patches)                       | YouTube         | universal | `^youtube-revanced-v[\d.]+-all\.apk$`                                       |
|                                                                                | Duolingo        |           | `^duolingo-revanced-v[\d.]+-all\.apk$`                                      |
|                                                                                | TikTok          |           | `^tiktok-revanced-v[\d.]+-all\.apk$`                                        |
|                                                                                | Twitch          |           | `^twitch-revanced-v[\d.]+-all\.apk$`                                        |
|                                                                                | Twitter         |           | `^twitter-revanced-v[\d.]+-all\.apk$`                                       |
|                                                                                | Samsung Radio   |           | `^samsung-radio-revanced-v[\d.]+-all\.apk$`                                 |
|                                                                                | Proton Mail     |           | `^proton-mail-revanced-v[\d.]+-all\.apk$`                                   |
|                                                                                | Proton VPN      |           | `^proton-vpn-revanced-v[\d.]+-all\.apk$`                                    |
|                                                                                | YouTube Music   | arm64     | `^youtube-music-revanced-v[\d.]+-arm64-v8a\.apk$`                           |
|                                                                                |                 | arm32     | `^youtube-music-revanced-v[\d.]+-arm-v7a\.apk$`                             |
|                                                                                | Google Photos   | arm64     | `^google-photos-revanced-v[\d.]+-arm64-v8a\.apk$`                           |
|                                                                                |                 | arm32     | `^google-photos-revanced-v[\d.]+-arm-v7a\.apk$`                             |
|                                                                                | Adobe Lightroom | arm64     | `^lightroom-revanced-v[\d.]+-arm64-v8a\.apk$`                               |
|                                                                                | Google Recorder | arm64     | `^google-recorder-revanced-v[\d.]+-arm64-v8a\.apk$`                         |
| [inotia00](https://github.com/inotia00/revanced-patches)                       | YouTube         | universal | `^youtube-rvx-v[\d.]+-all\.apk$`                              |
|                                                                                | YouTube Music   | arm64     | `^youtube-music-revanced-extended-v[\d.]+-arm64-v8a\.apk$`                  |
|                                                                                |                 | arm32     | `^youtube-music-revanced-extended-v[\d.]+-arm-v7a\.apk$`                    |
| [anddea](https://github.com/anddea/revanced-patches)                           | YouTube         | universal | `^youtube-anddea-v[\d.]+-all\.apk$`                              |
|                                                                                | Reddit          |           | `^reddit-anddea-v[\d.]+-all\.apk$`                               |
|                                                                                | Spotify         |           | `^spotify-anddea-v[\d.]+-all\.apk$`                              |
|                                                                                | YouTube Music   | arm64     | `^youtube-jkennethcarino-v[\d.]+-arm64-v8a\.apk$`                  |
|                                                                                |                 | arm32     | `^youtube-music-revanced-advanced-v[\d.]+-arm-v7a\.apk$`                    |
| [jkennethcarino](https://github.com/jkennethcarino/privacy-revanced-patches)   | Reddit          | universal | `^reddit-revanced-privacy-v[\d.]+-all\.apk$`                                |
| [morphe](https://github.com/MorpheApp/morphe-patches)                          | YouTube         | universal | `^youtube-morphe-v[\d.]+-all\.apk$`                                         |
|                                                                                | YouTube Music   | arm64     | `^youtube-music-morphe-v[\d.]+-arm64-v8a\.apk$`                             |
|                                                                                |                 | arm32     | `^youtube-music-morphe-v[\d.]+-arm-v7a\.apk$`                               |
| [rvx-morphed](https://github.com/wchill/rvx-morphed)                           | Reddit          | universal | `^reddit-rvx-morphed-v[\d.]+-all\.apk$`                                     |
| [piko](https://github.com/crimera/piko)                                        | Twitter         | arm64     | `twitter-piko-v\d+\.\d+\.\d+-[a-z]+\.\d-arm64-v8a\.apk`                     |
|                                                                                |                 | arm32     | `twitter-piko-v\d+\.\d+\.\d+-[a-z]+\.\d-arm-v7a\.apk`                       |

`universal`: For all devices. <br>
`arm64`: For most modern devices (after 2017). <br>
`arm32`: For most older (before 2017) or low-end devices.

## 📝 Notes
- Pre-release builds use dev patches.
- [MicroG](https://github.com/WSTxda/MicroG-RE/releases/latest/download/microg-release.apk) is required for Google APKs to work properly.
- All modules can be updated directly from Magisk and KSU.
- For Obtainium pre-release updates, enable “Include prereleases” in additional options.
- If you want an app built from a rarely updated or discontinued patch, check the [mirrors](./.github/pages/mirrors.md) page or the [build archive](https://t.me/revanced_builder/1139) topic on Telegram.

## ⁉️ Report
- Want an app? Request it in the [Telegram Group](https://t.me/rvb27).
- Found a bug? Report it in the [Telegram Group](https://t.me/rvb27).

## ⭐ Credits
- Icon is from [ReVanced](https://github.com/revanced). 
- This repo is based on [revanced-magisk-module](https://github.com/j-hc/revanced-magisk-module).
- All credit goes to the original patch developers and maintainers.
