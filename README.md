# ReVanced Builder
**Automatically builds and publishes APKs & Modules whenever new patches are released.**

---

### 💬 [Telegram Support Group](https://t.me/rvbygeo)
Get notified whenever new build drops.

---

### 📦 [Download Prebuilt APKs & Modules from GitHub Releases](https://github.com/geologically/revanced-builder/releases)
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
github.com/WSTxda/MicroG-RE
```
5. Scroll down to the **Filter APKs by regular expression** field.
6. Enter the appropriate regex from the table below for the app you want.
7. Tap the **Add** button next to the URL field to begin the download.

---

### 🔍 Regex Patterns for ReVanced APK Filtering
| Patch                                                                      | App            | Arch       | Regex Pattern                                                |
|----------------------------------------------------------------------------|----------------|------------|--------------------------------------------------------------|
| [revanced/revanced-patches](https://github.com/revanced/revanced-patches)  | YouTube        | universal  | `^youtube-revanced-v[\d.]+-all\.apk$`                        |
|                                                                            | YouTube Music  | arm64      | `^music-revanced-v[\d.]+-arm64-v8a\.apk$`                    |
|                                                                            |                | arm32      | `^music-revanced-v[\d.]+-arm-v7a\.apk$`                      |
|                                                                            | Google Photos  | arm64      | `^photos-revanced-v[\d.]+-arm64-v8a\.apk$`                   |
|                                                                            |                | arm32      | `^photos-revanced-v[\d.]+-arm-v7a\.apk$`                     |
| [inotia00/revanced-patches](https://github.com/inotia00/revanced-patches)  | YouTube        | universal  | `^youtube-revanced-extended-v[\d.]+-all\.apk$`               |
|                                                                            | YouTube Music  | arm64      | `^music-revanced-extended-v[\d.]+-arm64-v8a\.apk$`           |
|                                                                            |                | arm32      | `^music-revanced-extended-v[\d.]+-arm-v7a\.apk$`             |
|                                                                            | Reddit         | arm64      | `^reddit-revanced-extended-v[\d.]+-arm64-v8a\.apk$`          |
|                                                                            |                | arm32      | `^reddit-revanced-extended-v[\d.]+-arm-v7a\.apk$`            |
| [anddea/revanced-patches](https://github.com/anddea/revanced-patches)      | YouTube        | universal  | `^youtube-revanced-anddea-v[\d.]+-all\.apk$`                 |
|                                                                            | YouTube Music  | arm64      | `^music-revanced-anddea-v[\d.]+-arm64-v8a\.apk$`             |
|                                                                            |                | arm32      | `^music-revanced-anddea-v[\d.]+-arm-v7a\.apk$`               |
|                                                                            | Reddit         | arm64      | `^reddit-revanced-anddea-v[\d.]+-arm64-v8a\.apk$`            |
|                                                                            |                | arm32      | `^reddit-revanced-anddea-v[\d.]+-arm-v7a\.apk$`              |
|                                                                            | Spotify        | universal  | `^spotify-revanced-anddea-v[\d.]+-all\.apk$`                 |

`universal` : For all devices. <br>
`arm32`     : For most older (before 2017) or low-end devices. <br>
`arm64`     : For most modern devices (after 2017).

---

### ℹ️ Notes
- If you're unsure which version to use, go with the `revanced` build. The `revanced-extended` and `revanced-anddea` versions offer more features but are not updated as frequently and may stop working unexpectedly.
- These builds are intended for users who want prebuilt APKs without having to compile or patch them manually. All credit goes to the respective patch authors.
- Modules are available for YouTube, YouTube Music, and Google Photos.
- Modules can be updated directly from within Magisk or KSU; no need to install manually. 
- If you find any problem, please open a GitHub issue or report it in the Telegram group.



