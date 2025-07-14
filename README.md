# ReVanced Builder

**Automatically builds and publishes APKs whenever new patches are released.**

---

### 📦 [Download Prebuilt APKs from GitHub Releases](https://github.com/geologically/revanced-apks/releases)

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
| Patch                                                                      | App            | Arch       | Regex Pattern                                                |
|----------------------------------------------------------------------------|----------------|------------|--------------------------------------------------------------|
| [revanced/revanced-patches](https://github.com/revanced/revanced-patches)  | YouTube        | universal  | `^youtube-revanced-v[\d.]+-all\.apk$`                        |
|                                                                            | YouTube Music  | arm64      | `^music-revanced-v[\d.]+-arm64-v8a\.apk$`                    |
|                                                                            |                | arm32      | `^music-revanced-v[\d.]+-arm-v7a\.apk$`                      |
|                                                                            | Spotify        | universal  | `^spotify-revanced-v[\d.]+-all\.apk$`                        |
|                                                                            | Google Photos  | arm64      | `^photos-revanced-v[\d.]+-arm64-v8a\.apk$`                   |
|                                                                            |                | arm32      | `^photos-revanced-v[\d.]+-arm-v7a\.apk$`                     |
|                                                                            | Reddit         | universal  | `^reddit-revanced-v[\d.]+-all\.apk$`                         |
| [inotia00/revanced-patches](https://github.com/inotia00/revanced-patches)  | YouTube        | universal  | `^youtube-revanced-extended-v[\d.]+-all\.apk$`               |
|                                                                            | YouTube Music  | arm64      | `^music-revanced-extended-v[\d.]+-arm64-v8a\.apk$`           |
|                                                                            |                | arm32      | `^music-revanced-extended-v[\d.]+-arm-v7a\.apk$`             |
|                                                                            | Reddit         | universal  | `^reddit-revanced-extended-v[\d.]+-all\.apk$`                |
| [anddea/revanced-patches](https://github.com/anddea/revanced-patches)      | YouTube        | universal  | `^youtube-revanced-anddea-v[\d.]+-all\.apk$`                 |
|                                                                            | YouTube Music  | arm64      | `^music-revanced-anddea-v[\d.]+-arm64-v8a\.apk$`             |
|                                                                            |                | arm32      | `^music-revanced-anddea-v[\d.]+-arm-v7a\.apk$`               |
|                                                                            | Reddit         | universal  | `^reddit-revanced-anddea-v[\d.]+-all\.apk$`            |
|                                                                            | Spotify        | universal  | `^spotify-revanced-anddea-v[\d.]+-all\.apk$`                 |

- `universal`: For all devices.
- `arm32`: For most older (before 2017) or low-end devices.
- `arm64`: For most modern devices (after 2017).

### 🔎 Regex Patterns for MicroG APK Filtering

| App                        | Variant    | Regex Pattern                                                           |
|----------------------------|------------|-------------------------------------------------------------------------|
| GmsCore (microG Services)  | Huawei     | `^app\.revanced\.android\.gms-[\d]+-hw-signed\.apk$`                    |
| GmsCore (microG Services)  | Default    | `^app\.revanced\.android\.gms-[\d]+-signed\.apk$`                       |

---

### ℹ️ Notes

- Install [GmsCore (a.k.a. MicroG)](https://github.com/ReVanced/GmsCore/releases) if you use Google apps (GApps).
- If you're unsure which version to use, go with the `revanced` build. The `revanced-extended` and `revanced-anddea` versions offer more features but are not updated as frequently and may stop working unexpectedly.
- These builds are intended for users who want prebuilt APKs without having to compile or patch them manually. All credit goes to the respective patch authors.





