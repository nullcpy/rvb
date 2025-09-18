# ReVanced Builder
**Automatically builds and publishes APKs & Modules whenever new patches are released.**

---

### 💬 [Telegram Support Group](https://t.me/rvbygeo)
Get notified whenever new build drops.

---

### 📦 [Download Prebuilt APKs & Modules from GitHub Releases](https://github.com/geologically/revanced-apks/releases)
If your desired APK or Module is not in the latest release then check older releases.

---

### 📥 Install via [Obtainium](https://github.com/ImranR98/Obtainium)
1. Open the **Obtainium** app.
2. Tap **Add App**.
3. In the **App source URL** field, enter: <br>
- **For ReVanced APKs**
```
github.com/geologically/revanced-builder
```
- **For MicroG Apk**
```
github.com/ReVanced/GmsCore
```
5. Scroll down to the **Filter APKs by regular expression** field.
6. Enter the appropriate regex from the table below for the app you want.
7. Tap the **Add** button next to the URL field to begin the download.

---

### 🔍 Regex Patterns for ReVanced APK Filtering
| Patch                                                                      | App            | Arch       | Regex Pattern                                                | Status   |
|----------------------------------------------------------------------------|----------------|------------|--------------------------------------------------------------|----------|
| [revanced/revanced-patches](https://github.com/revanced/revanced-patches)  | YouTube        | universal  | `^youtube-revanced-v[\d.]+-all\.apk$`                        | Active   |
|                                                                            | YouTube Music  | arm64      | `^music-revanced-v[\d.]+-arm64-v8a\.apk$`                    | Active   |
|                                                                            |                | arm32      | `^music-revanced-v[\d.]+-arm-v7a\.apk$`                      |          |
|                                                                            | Spotify        | universal  | `^spotify-revanced-v[\d.]+-all\.apk$`                        | Inactive |
|                                                                            | Google Photos  | arm64      | `^photos-revanced-v[\d.]+-arm64-v8a\.apk$`                   | Active   |
|                                                                            |                | arm32      | `^photos-revanced-v[\d.]+-arm-v7a\.apk$`                     |          |
|                                                                            | Twitch         | arm64      | `^twitch-revanced-v[\d.]+-arm64-v8a\.apk$`                   | Inactive |
|                                                                            |                | arm32      | `^twitch-revanced-v[\d.]+-arm-v7a\.apk$`                     |          |
|                                                                            | Twitter        | arm64      | `^twitter-revanced-v[\d.]+-arm64-v8a\.apk$`                  | Inactive |
|                                                                            |                | arm32      | `^twitter-revanced-v[\d.]+-arm-v7a\.apk$`                    |          |
|                                                                            | Reddit         | arm64      | `^reddit-revanced-v[\d.]+-arm64-v8a\.apk$`                   | Inactive |
|                                                                            |                | arm32      | `^reddit-revanced-v[\d.]+-arm64-v8a\.apk$`                   | Inactive |
|                                                                            | Duolingo       | universal  | `^duolingo-revanced-v[\d.]+-all\.apk$`                       | Inactive |
|                                                                            | TikTok         | universal  | `^tikTok-revanced-v[\d.]+-all\.apk$`                         | Inactive |
| [inotia00/revanced-patches](https://github.com/inotia00/revanced-patches)  | YouTube        | universal  | `^youtube-revanced-extended-v[\d.]+-all\.apk$`               | Active   |
|                                                                            | YouTube Music  | arm64      | `^music-revanced-extended-v[\d.]+-arm64-v8a\.apk$`           | Active   |
|                                                                            |                | arm32      | `^music-revanced-extended-v[\d.]+-arm-v7a\.apk$`             |          |
|                                                                            | Reddit         | arm64      | `^reddit-revanced-extended-v[\d.]+-arm64-v8a\.apk$`          | Active   |
|                                                                            |                | arm32      | `^reddit-revanced-extended-v[\d.]+-arm-v7a\.apk$`            |          |
| [anddea/revanced-patches](https://github.com/anddea/revanced-patches)      | YouTube        | universal  | `^youtube-revanced-anddea-v[\d.]+-all\.apk$`                 | Active   |
|                                                                            | YouTube Music  | arm64      | `^music-revanced-anddea-v[\d.]+-arm64-v8a\.apk$`             | Active   |
|                                                                            |                | arm32      | `^music-revanced-anddea-v[\d.]+-arm-v7a\.apk$`               |          |
|                                                                            | Reddit         | arm64      | `^reddit-revanced-anddea-v[\d.]+-arm64-v8a\.apk$`            | Active   |
|                                                                            |                | arm32      | `^reddit-revanced-anddea-v[\d.]+-arm-v7a\.apk$`              |          |
|                                                                            | Spotify        | universal  | `^spotify-revanced-anddea-v[\d.]+-all\.apk$`                 | Active   |

> `universal` : For all devices. <br>
> `arm32`     : For most older (before 2017) or low-end devices. <br>
> `arm64`     : For most modern devices (after 2017).

### 🔎 Regex Patterns for MicroG APK Filtering
| App                        | Variant    | Regex Pattern                                                           |
|----------------------------|------------|-------------------------------------------------------------------------|
| GmsCore (microG Services)  | Huawei     | `^app\.revanced\.android\.gms-[\d]+-hw-signed\.apk$`                    |
| GmsCore (microG Services)  | Default    | `^app\.revanced\.android\.gms-[\d]+-signed\.apk$`                       |

> `Default` : For all devices except Huawei. <br>
> `Huawei`  : For only Huawei devices.

---

### ℹ️ Notes
- Install [GmsCore (a.k.a. MicroG)](https://github.com/ReVanced/GmsCore/releases) if you use Google apps (GApps).
- If you're unsure which version to use, go with the `revanced` build. The `revanced-extended` and `revanced-anddea` versions offer more features but are not updated as frequently and may stop working unexpectedly.
- These builds are intended for users who want prebuilt APKs without having to compile or patch them manually. All credit goes to the respective patch authors.
- **Magisk modules are available for YouTube, YouTube Music, and Google Photos. There is no need to install MicroG if you install modules for these apps.**
- **Magisk modules also work on KSU.**
- Modules can be updated directly from within Magisk or KSU; no need to install manually. 
- If you find any problem, please open a GitHub issue or report it in the Telegram group.
- [MicroG RE](https://github.com/WSTxda/MicroG-RE) (GmsCore for ReVanced with *Material 3 Expressive*)



