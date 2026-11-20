# WarrantyVault — Android Studio Setup (Roman Urdu)

## Is ZIP mein kya hai
- Google Stitch ke 4 original screen designs (reference ZIP)
- Flutter source: Home, Add/Edit Purchase, Purchase Details, Settings
- SQLite purchases database aur receipt image storage
- Google Drive appDataFolder backup/restore service
- Local warranty expiry notifications: expiry se 7 din pehle aur expiry wale din, 9:00 AM Pakistan time

## 1) Project open/run karna
1. ZIP ko ek NEW folder mein extract karein. Apne purane project/backup ko overwrite na karein.
2. Android Studio > Open > extracted `warrantyvault_flutter_starter` folder.
3. Android Studio Terminal mein `flutter pub get` chalayein.
4. Android phone USB debugging ke saath connect karein, phir Run karein.

## 2) Google Drive ko attach karna (required one-time setup)
Google Drive integration code included hai, lekin Google OAuth credentials har developer ke app/package ke liye alag hote hain. Is liye pehli dafa yeh setup lazmi hai:
1. https://console.cloud.google.com/ par apne Google account se project banayein.
2. APIs & Services > Library > **Google Drive API** enable karein.
3. APIs & Services > OAuth consent screen configure karein. Testing mode mein apna Google account Test User ke taur par add karein.
4. Android Studio Terminal mein `cd android` phir Windows par `gradlew signingReport` (PowerShell: `./gradlew signingReport`) chalayein. Debug variant ka SHA-1 copy karein.
5. Google Cloud > APIs & Services > Credentials > Create Credentials > OAuth client ID > Android select karein. Android package name aur debug SHA-1 enter karein.
6. Package name maloom karne ke liye `android/app/build.gradle` ya `android/app/build.gradle.kts` mein `applicationId` dekhein. Google Console mein bilkul wahi likhein.
7. Agar OAuth consent screen Testing mode mein hai to jis Google account se backup karna hai usay Test users mein add karein.
8. App ko dobara run karein. Settings > Backup to Google Drive par tap karke sign-in karein.

Backup aapke Google Drive mein `WarrantyVault_backup.zip` naam ki file ke taur par save hota hai. App `drive.file` scope use karti hai, jo app ki banayi hui backup file ko access karne ke liye limited permission hai. Restore current local vault ko backup se replace karta hai, is liye confirmation dialog hai.

## 3) Android notification setup
`android/app/src/main/AndroidManifest.xml` ke `<manifest>` ke andar, `<application>` se pehle yeh permission add karein:

```xml
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED" />
```

`flutter_local_notifications` package apne required receivers manifest merge ke zariye add karta hai. Android Studio mein Gradle sync hone dein. Android 13+ par app notifications ki permission maangegi. Phone Settings mein WarrantyVault notifications allow honi chahiye.

## Important limitations / honesty
- Is environment mein Flutter SDK available nahi tha, is liye main Android APK compile ya phone par run karke verify nahi kar saka.
- Google Drive use karne se pehle upar wala Google Cloud OAuth setup karna zaroori hai. API key khareedne ki zaroorat aam personal usage ke liye nahi hoti.
- Notifications scheduled local hain; app ke andar saved purchases ke liye 7-days-before aur expiry-day alerts schedule hotay hain. Android battery restrictions kuch devices par delivery delay kar sakti hain.
- Restore se current local database replace hota hai. Restore se pehle zaroori ho to pehle current backup bana lein.
