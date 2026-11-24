# Rider App - Phase 9: Polish + branding + APK

Sirf Flutter / GitHub Action. **Backend, models, migrations mein koi change nahi.** Version 1.6.0+7.

## Branding
- App ka naam: **88 Riders** (phone par icon ke neeche; `tool/patch_manifest.py`).
- Package name: **com.khanewal.riders88.app** (`tool/patch_gradle.py`, workflow `APP_ID`).
  Aap ne `com.khanewal.88riders.app` kaha tha, magar Android / Java package ka har hissa harf se shuru hona zaroori hai
  (digit se shuru hone par build / install fail hota hai), is liye `88riders` -> `riders88`.
- Icon: aap ka Khanewal Connect logo (`assets/icon/app_icon.png`). Adaptive icon ke liye logo ko safe zone mein rakh kar
  `assets/icon/app_icon_fg.png` banaya (circle crop mein kate nahi). Workflow mein `dart run flutter_launcher_icons` mipmaps banata hai.
- Splash: app khulte hi logo + "88 Riders" (Flutter splash); login screen par bhi logo.

## Server static
- `https://khanewalconnect.store` code mein fixed (`kDefaultServer` in `services/api.dart`).
- Login screen se "Server address" field / button hata diya, Profile se Server tile hata diya. Purane build ka saved address bhi ignore hota hai.
- Kisi error message mein server ka link nahi aata.

## Polish
- Skeleton (dhundle pulse karte cards) loaders: Dashboard, Orders, Wallet, Profile. Error / no-internet cards aur pull-to-refresh pehle se har tab mein hain.

## Workflow (`.github/workflows/build_rider_apk.yml`)
- Koi input nahi (api_base hata diya). Steps: flutter create -> package name -> manifest -> pub get -> icon -> release APK -> `88-Riders.apk`.
- Artifact: **88-riders-apk**.
- `.gitignore`: `license_private.key`, keystore files, `rider_app/android/` (generated) shamil.

## Database / deploy (audit)
- Rider app ke liye sirf **migration 0058** hai: `CreateModel RiderCashHandover` (+ M2M table). Koi RemoveField / DeleteModel / RenameModel / RunSQL / RunPython nahi.
  Model aur migration ke fields match karte hain.
- `deploy.yml` mein `DROP DATABASE` sirf GitHub runner ke **temporary local MySQL** par hai (Drive ke snapshot se restore ke liye); live data ko drop nahi karta.
- Dhyan: `deploy.yml` har run par `makemigrations --noinput || true` chalata hai aur migrate fail ho to `migrate --fake` karta hai.
  Is se agar kisi model aur migration mein farq ho to CI khud naya migration bana sakta hai, aur fail hone par table banay baghair "done" dikha sakta hai.
  Deploy ke baad log mein "Migrations applied." dekhein (aur "Forcing state sync with --fake" na ho). Chahein to ye step alag se saaf kar dein.

## Test (section 9 ki checklist, asli phone par)
1. APK install: naam "88 Riders", aap ka logo icon.
2. Login: server ka koi field nahi; login chale.
3. Online > order > Accept > Pickup > Deliver (COD / Paid dialog).
4. Map: marker move, route line, app minimize par server ko location.
5. Handover admin / vendor ko, confirm / reject, over-limit / double tap.
6. Internet band / server down: error card, crash nahi.
7. Web rider portal + vendor + admin pehle jaisa (regression).
