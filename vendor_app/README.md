# Vendor App (Khanewal Connect - Android)

Store owner (vendor) ke liye app. Rider app ke dhanche par bani hai; backend JSON API `api/vendor/...` hai
(`app/customer/views_vendor_api.py`). Abhi **Phase V7**: foundation (login, 5-tab shell, APK build) + **Dashboard tab** + **Orders tab** + **Order detail + live tracking** + **Push notifications (app band ho tab bhi naya order alert)**.
Baqi tabs (Products, Sales, More ke andar ka kaam) "Jald aa raha hai" hain, aglay phases mein bharenge.

- App ka naam (placeholder): **Vendor App** - `.github/workflows/build_vendor_apk.yml` ke `env: APP_NAME` se badlein (sirf ek jagah).
- Package name: `com.khanewal.vendor.app` (workflow `env: APP_ID`). Rider app (`com.khanewal.riders88.app`) se alag.
- Server fixed: `https://khanewalconnect.store` (workflow `env: API_BASE`) - app mein kahin dikhta nahi.

## Abhi kya chalta hai
- Login (phone + password, Bearer token, 30 din). Ghalat password / lock / "approval baqi" ke saaf Roman Urdu messages.
- Approval baqi ho to sirf "Approval baqi" screen (Dobara check + Logout).
- 5 tabs: Dashboard, Orders, Products, Sales, More. More mein store card, logout, version.
- **Dashboard (V4):** salam + store naam + rating, **Open/Closed switch** (band karne se pehle confirm), alerts (naye orders, stock,
  rider cash, products ki approval, store band / timing se bahar), aaj ki sale + orders, hafta / mahina, orders ki ginti
  (Naye / Chal rahe / Mukammal), kamai (sale, commission, aap ka hissa), rating, products + kam stock, 7 din ka chart, quick actions.
  Pull-to-refresh, loading par skeleton, error + retry. Net band ho to purana data + "Offline" message (data phone mein save rehta hai).
  Orders tab par naye orders ka badge.
- **Orders (V5):** Naye / Chal rahe / Mukammal tabs (ginti ke saath), search (order no / naam / phone), order card (customer + call, items, COD/Online, total).
  **Qubool** (tayyari ka time: 10/20/30/45 ya apna), **Reject** (wajah list), **Tayyar**, **Deliver** (confirm) - double-tap lock, ek hi order par do jagah se action
  par saaf message. App khuli ho to har 25 sec naye orders ka poll (list khud taza + halki awaaz/vibration). Pull-to-refresh, agla page, skeleton, empty, error + retry.
- **Order detail + live tracking (V6):** order card par tap -> status stepper (Naya > Qubool > Tayyar > Raste mein > Deliver), **live map** (OpenStreetMap: store, customer, rider; rider ki location har 12 sec),
  rider card (call, **Rider dein / badlein**), customer card (Call / WhatsApp / Map), items photo ke saath, payment + commission ka andaza, history. Neeche wahi Qubool / Reject / Tayyar / Deliver buttons.
  Rider na ho to "Rider abhi assign nahi hua"; order band hone par map khud hat jata hai; location purani ho to warning.
- Token ghalat / password badalne par khud login screen par wapas.
- **Push notifications (V7):** login ke baad phone ka FCM token server par register (token badle to dobara, logout par hat jata hai). App band / screen lock / background - teeno haalat mein naya order, cancel, rider cash, review, stock ka alert.
  Do channel: **Naye orders** (alag "ding-dong" awaaz + lambi vibration) aur **Baqi updates**. Notification par **tap -> seedha wohi order** (app band, background ya khuli - teeno haalat). App khuli ho to upar **in-app banner + awaaz**
  (poll aur push mil kar ek hi baar bajate hain). Login ke baad ek dafa **notification ijazat ka saaf screen** (Android 13+), **More > Alerts & permissions** mein ijazat, **Battery: Unrestricted** aur "is phone ka alert server se juda hai?" ka status + Xiaomi/Oppo/Vivo/Samsung ki madad.
  Do phone par ek vendor login ho to dono ko alert. Logout ke baad us phone par alert nahi. Firebase secret na ho to app pehle jaisi chalti hai (sirf poll).

## GitHub par APK banane ka tareeqa
1. Pura project (`vendor_app` + `.github/workflows/build_vendor_apk.yml`) GitHub repo mein push karein.
   **`license_private.key` push na karein** (`.gitignore` mein hai).
2. **Firebase (push ke liye, ek dafa):** https://console.firebase.google.com par apne project mein *Add app > Android*,
   package name **`com.khanewal.vendor.app`** (rider wali app se ALAG app). `google-services.json` download karein >
   GitHub > Settings > Secrets > **`GOOGLE_SERVICES_JSON_VENDOR`** (poora text paste).
   Push ke liye ye secret **zaroori** hai (Phase V7). Na ho to bhi APK ban jati hai, bas push band rehta hai.
   Server par wahi `FCM_SERVICE_ACCOUNT_JSON` secret (rider push wala) - alag kuch nahi.
3. GitHub > **Actions** > **Build Vendor APK** > **Run workflow**.
4. 5-10 minute baad run ke neeche **Artifacts > vendor-apk** download karein (zip ke andar `Vendor-App.apk`).
5. Phone mein install karein (Unknown sources allow karna hoga).

## Folder
`lib/main.dart`, `theme.dart`, `utils.dart` | `lib/services` (api, app_state, push) | `lib/models` (vendor, dashboard, orders, order_detail) |
`lib/screens` (login, shell, dashboard, orders, order_detail, pending, more, placeholder_tab, notification_permission, permissions_help) |
`lib/widgets` (empty_state, skeleton, notice_card, loading, section_title, stat_card, week_chart, status_stepper, live_map, in_app_banner) |
`tool/` (patch_gradle, patch_manifest, patch_push, patch_notification + `res/new_order.wav` - workflow `flutter create` ke baad chalata hai) | `assets/icon/`.
Tafseel: `docs/VENDOR_PHASE3.md` (foundation), `docs/VENDOR_PHASE4.md` (dashboard), `docs/VENDOR_PHASE5.md` (orders), `docs/VENDOR_PHASE6.md` (order detail + live tracking), `docs/VENDOR_PHASE7.md` (push notifications).
