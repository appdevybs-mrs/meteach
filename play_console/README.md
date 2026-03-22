# Play Console Upload Package

This folder contains the operational notes needed to publish `Taqyim DZ` on Google Play.

## Publisher Information

- Developer name: `Seddik Bouyakoub`
- Company name: `Intilak`
- Contact email: `appdevybs@gmail.com`

## Generated Android Signing Files

- Keystore: `android/app/upload-keystore.jks`
- Key properties: `android/key.properties`
- Alias: `upload`

## Build Command

Run from project root:

```bash
flutter build appbundle --release
```

Output bundle:

- `build/app/outputs/bundle/release/app-release.aab`

## Before Upload to Play Console

1. Create app in Play Console with package id `com.intilak.taqyimdz`
2. Upload the first `.aab`
3. Fill store listing metadata using files in this folder
4. Complete App content questionnaires (ads, data safety, content rating, target audience)
5. Add screenshots and app icon assets
6. Submit release for review
