# WarrantyVault — combined Flutter project

Blue/white Stitch-inspired Flutter app for tracking purchase warranties and receipts.

## Included in source
- Home vault with search, status filters, expiry banner, product cards and countdowns.
- Add/edit purchases, categories, price/date, warranty duration presets, extended warranty, receipt photo/gallery/camera scan, ML Kit OCR, notes, serial number, coverage and support hotline.
- Purchase details with status/countdown, coverage progress, receipt image zoom/fullscreen, PDF export/share, serial-number copy, edit and delete.
- Settings: Google Drive backup/restore, local expiry alerts, biometric/device authentication check, CSV export, ZIP backup export and local storage size.
- SQLite schema migration from version 1 to 2 that adds fields without dropping existing purchase data.
- Android launcher icon resources and biometric permissions/activity configuration.

## Run on Windows
1. Extract the ZIP.
2. Open `warrantyvault_flutter_starter` in Android Studio.
3. Run `flutter pub get`.
4. Run `flutter build apk --debug`.
5. Install `build/app/outputs/flutter-apk/app-debug.apk` on your Android phone.

## Important setup / verification notes
- Flutter SDK is not installed in the generation environment, so this source has **not** been compiled or device-tested here. Resolve any dependency/API issues shown by your local Flutter version.
- Google Drive requires Google Cloud Drive API and Android OAuth client configuration; see `SETUP_UR.md`.
- Biometric control performs a device-authentication check when tapped; it is not yet a persistent app-wide lock that automatically gates every launch.
- PDF uses the platform share/print sheet. OCR uses ML Kit Latin text recognition; review extracted fields before saving, especially Urdu receipts.
- Preserve a copy of your previous project and database before testing.
