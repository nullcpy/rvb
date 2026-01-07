<div align="center"><a href="https://github.com/Safouene1/support-palestine-banner/blob/master/Markdown-pages/Support.md"><img src="https://raw.githubusercontent.com/Safouene1/support-palestine-banner/master/banner-support.svg" alt="Support Palestine" style="width: 100%;"></a></div>


# ![ReVanced Builder Icon](./.github/assets/icon.png) ReVanced Builder
**Automatically builds and publishes ReVanced APKs & Magisk/KernelSU Modules whenever new patches are released.**

> [!Important]
> **Please star the repo! 🙏🥺**

### 🗨️ [Join the Telegram Group](https://t.me/rvbygeo)
Get notified instantly when new builds are released and download easily.

### 📦 [Download from GitHub](https://github.com/geologically/revanced-builder/releases)
If you don’t see the app you want in the latest release, check older ones.

### 🗃️ [Download from Mirrors](./.github/pages/mirrors.md)
GitHub only retains recent 20 builds, for older builds look here.

### 🍀 [Download FiorenMas Builds](./.github/pages/FiorenMas.md)
Contains APKs of many more apps from different ReVanced patches.

### 📥 How to Install via [Obtainium](https://github.com/ImranR98/Obtainium)
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
5. Enter the appropriate regex from the table below for the app you want.  
6. Tap **Add** to begin downloading.

### 🔎 Regex Patterns for Filtering APKs
| Patch                                                                      | App             | Arch      | Regex Pattern                                                               |
|----------------------------------------------------------------------------|-----------------|-----------|-----------------------------------------------------------------------------|
| [Official](https://github.com/revanced/revanced-patches)                   | YouTube         | universal | `^youtube-revanced-v[\d.]+-all\.apk$`                                       |
|                                                                            | Duolingo        |           | `^duolingo-revanced-v[\d.]+-all\.apk$`                                      |
|                                                                            | TikTok          |           | `^tiktok-revanced-v[\d.]+-all\.apk$`                                        |
|                                                                            | Twitch          |           | `^twitch-revanced-v[\d.]+-all\.apk$`                                        |
|                                                                            | Twitter         |           | `^twitter-revanced-v[\d.]+-all\.apk$`                                       |
|                                                                            | Samsung Radio   |           | `^samsung-radio-revanced-v[\d.]+-all\.apk$`                                 |
|                                                                            | Proton Mail     |           | `^proton-mail-revanced-v[\d.]+-all\.apk$`                                   |
|                                                                            | Proton VPN      |           | `^proton-vpn-revanced-v[\d.]+-all\.apk$`                                    |
|                                                                            | YouTube Music   | arm64     | `^youtube-music-revanced-v[\d.]+-arm64-v8a\.apk$`                           |
|                                                                            |                 | arm32     | `^youtube-music-revanced-v[\d.]+-arm-v7a\.apk$`                             |
|                                                                            | Google Photos   | arm64     | `^google-photos-revanced-v[\d.]+-arm64-v8a\.apk$`                           |
|                                                                            |                 | arm32     | `^google-photos-revanced-v[\d.]+-arm-v7a\.apk$`                             |
|                                                                            | Adobe Lightroom | arm64     | `^lightroom-revanced-v[\d.]+-arm64-v8a\.apk$`                               |
|                                                                            | Google Recorder | arm64     | `^google-recorder-revanced-v[\d.]+-arm64-v8a\.apk$`                         |
| [Extended](https://github.com/inotia00/revanced-patches)                   | YouTube         | universal | `^youtube-revanced-extended-v[\d.]+-all\.apk$`                              |
|                                                                            | Reddit          |           | `^reddit-revanced-extended-v[\d.]+-all\.apk$`                               |
|                                                                            | YouTube Music   | arm64     | `^youtube-music-revanced-extended-v[\d.]+-arm64-v8a\.apk$`                  |
|                                                                            |                 | arm32     | `^youtube-music-revanced-extended-v[\d.]+-arm-v7a\.apk$`                    |
| [Advanced](https://github.com/anddea/revanced-patches)                     | YouTube         | universal | `^youtube-revanced-advanced-v[\d.]+-all\.apk$`                              |
|                                                                            | Reddit          |           | `^reddit-revanced-advanced-v[\d.]+-all\.apk$`                               |
|                                                                            | Spotify         |           | `^spotify-revanced-advanced-v[\d.]+-all\.apk$`                              |
|                                                                            | YouTube Music   | arm64     | `^youtube-music-revanced-advanced-v[\d.]+-arm64-v8a\.apk$`                  |
|                                                                            |                 | arm32     | `^youtube-music-revanced-advanced-v[\d.]+-arm-v7a\.apk$`                    |
| [Morphe](https://github.com/MorpheApp/morphe-patches)                      | YouTube         | universal | `^youtube-morphe-v[\d.]+-all\.apk$`                                         |
|                                                                            | YouTube Music   | arm64     | `^youtube-music-morphe-v[\d.]+-arm64-v8a\.apk$`                             |
|                                                                            |                 | arm32     | `^youtube-music-morphe-v[\d.]+-arm-v7a\.apk$`                               |
| [Piko](https://github.com/crimera/piko)                                    | Twitter         | arm64     | `twitter-revanced-piko-v\d+\.\d+\.\d+-[a-z]+\.\d-arm64-v8a\.apk`            |
|                                                                            |                 | arm32     | `twitter-revanced-piko-v\d+\.\d+\.\d+-[a-z]+\.\d-arm-v7a\.apk`              |

`universal` : For all devices. <br>
`arm32`     : For most older (before 2017) or low-end devices. <br>
`arm64`     : For most modern devices (after 2017).

### 📝 Notes
- All modules can be updated directly from Magisk and KSU.
- If you want pre-release updates via Obtainium then turn on include prereleases in additional options.
- [MicroG](https://github.com/WSTxda/MicroG-RE/releases/latest/download/microg-release.apk) is required for Google APKs to work properly.

### ⁉️ Report
- Want a app? Request it in the [Telegram Group](https://t.me/rvbygeo).
- Found a bug? Report it in the [Telegram Group](https://t.me/rvbygeo).

### ⭐ Credits
- All credit goes to the original patch developers and maintainers.
- This repo is based on [revanced-magisk-module](https://github.com/j-hc/revanced-magisk-module).
- Icon is from [ReVanced](https://github.com/revanced). 
