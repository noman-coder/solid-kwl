# Vendor App - Phase V3: Flutter foundation + APK build

Sirf app (Flutter) + GitHub workflow. **Backend / database mein koi tabdeeli nahi** (V1 ki API use hoti hai; migration abhi bhi 0061 par).
Purana web portal aur rider app/API bilkul nahi chhede.

## Kya bana (NEW)
- `vendor_app/` - rider_app ke dhanche par naya Flutter project (`kconn_vendor`, version 0.3.0+3).
  - `lib/main.dart` - splash, login / shell ka faisla, logout.
  - `lib/theme.dart` - teal theme, rounded cards, ek font family, NavigationBar.
  - `lib/services/api.dart` - Bearer token, `login`, `logout`, `me`, `registerPushToken`. Server `API_BASE` (dart-define) se, UI mein nahi dikhta. Error `{ok:false, error, message, code}`; `code == 'auth'` (401) = dobara login.
  - `lib/services/app_state.dart` - vendor / approval status, tab, refresh (pull + app resume). Aglay phases ka shared state yahin judega.
  - `lib/services/push.dart` - Firebase init (config na ho to khamoshi se band) + channels `new_orders`, `updates`.
  - `lib/screens/` - `login` (show/hide password, double-tap lock, error card), `shell` (5 tabs), `pending` (approval baqi), `more` (store card, logout, version), `placeholder_tab` ("jald aa raha hai").
  - `lib/widgets/` - empty_state, skeleton, notice_card, loading, section_title (rider_app se, vendor ke hisab se).
  - `tool/patch_gradle.py`, `patch_push.py`, `patch_manifest.py` - rider wale ki tarah; manifest mein sirf INTERNET, POST_NOTIFICATIONS, WAKE_LOCK, VIBRATE (GPS nahi). App ka naam workflow se aata hai.
  - `assets/icon/` - vendor ka alag icon (teal + dukan).
- `.github/workflows/build_vendor_apk.yml` - `APP_NAME`, `APP_ID=com.khanewal.vendor.app`, `API_BASE`; secret `GOOGLE_SERVICES_JSON_VENDOR`; artifact **`vendor-apk`** (`Vendor-App.apk`).
- `docs/VENDOR_PHASE3.md` (yeh file).

## EDIT
- `.gitignore` - `vendor_app/android/`, `build/`, `.dart_tool/` (workflow mein `flutter create` banata hai).

## Firebase (alag app)
Vendor ka package alag hai, is liye Firebase mein **naya Android app** `com.khanewal.vendor.app` banayein aur uski `google-services.json` secret `GOOGLE_SERVICES_JSON_VENDOR` mein daalein. Rider wali file se kaam nahi chalega. `patch_push.py` package check karta hai aur ghalat ho to saaf error deta hai. Secret na ho to APK phir bhi banti hai (push band).

## Kaise test karein
1. Zip ko GitHub repo mein push karein (`license_private.key` nahi). Actions > **Build Vendor APK** > Run workflow.
2. Run hari ho jaye to Artifacts > **vendor-apk** se `Vendor-App.apk` download karke phone mein install karein.
3. Sahi vendor login -> 5 tabs khulen, More mein store ka naam / rating / commission dikhe. Ghalat password -> saaf error; 5 ghalat koshish -> "10 minute baad" message.
4. Unapproved vendor se login -> "Approval baqi" screen (Dobara check + Logout). Vendor password web se badlein -> app dobara login par le aaye.
5. More > Logout kaam kare; app mein server ka URL kahin na dikhe.

## Test checklist (Master Plan)
- [ ] GitHub Action se APK ban jaye.
- [ ] Install, login chale, galat password par saaf error.
- [ ] 5 tabs khulen, logout kaam kare.
- [ ] Server URL app mein kahin na dikhe.

## Agla: Phase V4 (Dashboard tab - backend `api/vendor/dashboard/` + app screen)
