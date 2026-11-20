# WarrantyVault — combined Flutter project

Blue/white Stitch-inspired Flutter app for tracking purchase warranties and receipts.

## Included in source
- Home vault with search, status filters, expiry banner, product cards and countdowns.
- Add/edit purchases, categories, price/date, warranty duration presets, extended warranty, receipt photo/gallery/camera scan, ML Kit OCR, notes, serial number, coverage and support hotline.
- Purchase details with status/countdown, coverage progress, receipt image zoom/fullscreen, PDF export/share, serial-number copy, edit and delete.
- Settings: Google Drive backup/restore, local expiry alerts, biometric/device authentication check, CSV export, ZIP backup export and local storage size.
- SQLite schema migration from version 1 to 2 that adds fields without dropping existing purchase data.
- Android launcher icon resources and biometric permissions/activity configuration.

## Screenshots
<img width="1896" height="872" alt="Screenshot 2026-11-20 140848" src="https://github.com/user-attachments/assets/2c51306e-7a0f-4651-a2b9-a1d356d07900" />
<img width="1907" height="897" alt="Screenshot 2026-11-20 140831" src="https://github.com/user-attachments/assets/0a9124f3-9502-4000-95c2-dd2fe069c7b2" />
<img width="1901" height="890" alt="Screenshot 2026-11-20 140807" src="https://github.com/user-attachments/assets/d02b15a2-42e6-4b9f-996d-4157be7124aa" />
<img width="1902" height="857" alt="Screenshot 2026-11-20 140921" src="https://github.com/user-attachments/assets/8b42bf96-ed33-412e-9f1d-95e7533889f4" />
<img width="1908" height="877" alt="Screenshot 2026-11-20 140908" src="https://github.com/user-attachments/assets/2e7b17ff-aab2-4a25-83f4-5f0e5965623e" />


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
