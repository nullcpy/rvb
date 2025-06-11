# ReVanced Builder

**Automatically builds and publishes APKs whenever new patches are released.**

---

### 📦 [Download Prebuilt APKs from GitHub Releases](https://github.com/geologically/revanced-apks/releases)

---

### 📥 Install via [Obtainium](https://github.com/ImranR98/Obtainium)

1. Open the **Obtainium** app.
2. Tap **Add App**.
3. In the **App source URL** field, enter: `https://github.com/geologically/revanced-builder/`
4. Scroll down to the **Filter APKs by regular expression** field.
5. Enter the appropriate regex from the table below for the app you want.
6. Tap the **Add** button next to the URL field to begin the download.

---

### 🔍 Regex Patterns for APK Filtering

| Patch                                                                      | App            | Regex Pattern                                                |
|----------------------------------------------------------------------------|----------------|--------------------------------------------------------------|
| [revanced/revanced-patches](https://github.com/revanced/revanced-patches)  | YouTube        | `^youtube-revanced-v[\d.]+-all\.apk$`                        |
|                                                                            | YouTube Music  | `^music-revanced-v[\d.]+-arm64-v8a\.apk$`                    |
|                                                                            | Spotify        | `^spotify-revanced-v[\d.]+-all\.apk$`                        |
|                                                                            | Google Photos  | `^photos-revanced-v[\d.]+-arm64-v8a\.apk$`                   |
| [inotia00/revanced-patches](https://github.com/inotia00/revanced-patches)  | YouTube        | `^youtube-revanced-extended-v[\d.]+-all\.apk$`               |
|                                                                            | YouTube Music  | `^music-revanced-extended-v[\d.]+-arm64-v8a\.apk$`           |
|                                                                            | Reddit         | `^reddit-revanced-extended-v[\d.]+-arm64-v8a\.apk$`          |
| [anddea/revanced-patches](https://github.com/anddea/revanced-patches)      | YouTube        | `^youtube-revanced-anddea-v[\d.]+-all\.apk$`                 |
|                                                                            | YouTube Music  | `^music-revanced-anddea-v[\d.]+-arm64-v8a\.apk$`             |
|                                                                            | Reddit         | `^reddit-revanced-anddea-v[\d.]+-arm64-v8a\.apk$`            |
|                                                                            | Spotify        | `^spotify-revanced-anddea-v[\d.]+-all\.apk$`                 |

---

### 🔎 Regex Patterns for MicroG APK Filtering

| App                        | Variant    | Regex Pattern                                                           |
|----------------------------|------------|-------------------------------------------------------------------------|
| GmsCore (microG Services)  | Huawei     | `^app\.revanced\.android\.gms-[\d]+-hw-signed\.apk$`                    |
| GmsCore (microG Services)  | Default    | `^app\.revanced\.android\.gms-[\d]+-signed\.apk$`                       |

---

### ℹ️ Notes
- Install [GmsCore a.k.a MicroG](https://github.com/ReVanced/GmsCore/releases) for GApps.
- These builds are intended for users who want prebuilt APKs without having to compile or patch manually. All credits go to the respective patch authors.



