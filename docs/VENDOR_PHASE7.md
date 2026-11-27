# Vendor App - Phase V7: Push notifications + alerts (app side)

Sirf **Flutter app** (`vendor_app/`). **Backend / database mein koi tabdeeli nahi** (V2 ka server hissa pehle se tayyar: `api/vendor/push-token/`, `app/vendor_push.py`,
migration abhi bhi **0061**). Purana web portal, rider app / API aur V1-V6 ki API bilkul nahi chhedi.

## Kya bana
- **Push service** (`lib/services/push.dart`): Firebase + 2 channel; login ke baad FCM token server par register (`POST /api/vendor/push-token/`), token badle to dobara, register fail ho
  (net / approval) to har refresh par dobara koshish (`Push.sync`); logout par `Push.stop()` (sunna band + token hata) aur `Api.logout(pushToken:)` (server se bhi).
- **Channels** (server `vendor_push.py` inhi ids par bhejta hai):
  | Channel id | Naam | Kis ke liye | Awaaz |
  |---|---|---|---|
  | `new_orders` | Naye orders | naya order | **alag** "ding-dong" (`res/raw/new_order.wav`) + lambi vibration, importance max |
  | `updates` | Baqi updates | cancel, rider cash, review, stock | phone ki default awaaz, importance high |
- **Notification tap -> Order Detail**, teeno haalat: app **band** (`getInitialMessage`), **background** (`onMessageOpenedApp`), **khuli** (in-app banner par tap).
  `data.type`: `new_order` / `order_cancelled` / `review` -> order detail; `low_stock` / `out_of_stock` -> Products tab; `rider_cash` -> Dashboard (aglay phases mein apni screen).
  Vendor abhi load ho raha ho to tap yaad rakha jata hai aur load hote hi khulta hai; approval baqi ho to kuch nahi khulta.
- **Foreground**: push aate hi upar **in-app banner** (`widgets/in_app_banner.dart`, 8 sec, tap / X / upar swipe) + awaaz + vibration, aur orders + dashboard foran taza.
  Poll (har 25 sec) aur push ek hi order par dobara awaaz nahi bajate (`AppState.claimOrderAlert`).
- **Notification ijazat ka saaf screen** (`screens/notification_permission.dart`): approve hone ke baad ek dafa (Android 13+, ijazat na ho to). "Baad mein" par dobara nahi aata.
- **Alerts madad** (`screens/permissions_help.dart`, More > *Alerts & permissions*): notification ijazat, **Battery: Unrestricted**, "is phone ka alert server se juda hai" (+ *Dobara jorein*),
  awaaz ki madad, Xiaomi / Oppo / Vivo / Huawei / Samsung ke steps. Notification band ho to More mein laal nishan.
- `OrderDetailScreen` ab sirf `orderId` se bhi khulta hai (`openOrderById`), push ke liye.

## Android patches (workflow `flutter create` ke baad)
- `tool/patch_notification.py` (NEW): `new_order.wav` ko `res/raw` mein copy, `res/raw/keep.xml` (release shrinker awaaz na hataye), notification ka teal rang + manifest meta-data.
- `tool/patch_manifest.py`: `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` permission (Battery unrestricted ke liye). Play Store release (V17) par is permission ka declaration dekhna hoga.
- `.github/workflows/build_vendor_apk.yml`: naya step "Notification awaaz + rang lagao".

## Files
- NEW  `vendor_app/lib/screens/{notification_permission,permissions_help}.dart`, `vendor_app/lib/widgets/in_app_banner.dart`, `vendor_app/tool/patch_notification.py`, `vendor_app/tool/res/new_order.wav`, `docs/VENDOR_PHASE7.md`
- EDIT `vendor_app/lib/services/{push,app_state}.dart` (push poora likha; app_state mein dedupe + push refresh), `vendor_app/lib/{main,utils}.dart`, `vendor_app/lib/screens/{shell,more,order_detail}.dart`,
  `vendor_app/pubspec.yaml` (`permission_handler`, version `0.7.0+7`), `vendor_app/tool/patch_manifest.py`, `vendor_app/README.md`, `.github/workflows/build_vendor_apk.yml`

## Zaroori nota: purani install par awaaz
Android notification channel ki awaaz pehli dafa banne ke baad badalti nahi. V3-V6 wali APK pehle se phone par ho to **purani app uninstall karke nayi install karein**
(taake `new_orders` channel nayi "ding-dong" awaaz ke saath bane). Naye phone par masla nahi.

## Kaise test karein
1. **Firebase**: vendor package `com.khanewal.vendor.app` ki `google-services.json` GitHub secret `GOOGLE_SERVICES_JSON_VENDOR` mein ho (Actions log mein "google-services.json likh di" aana chahiye). Server par `FCM_SERVICE_ACCOUNT_JSON` ho.
2. Purani vendor app uninstall > Actions > **Build Vendor APK** > artifact `vendor-apk` > install > login. Notification ijazat ka screen aaye > "Ijazat dein" > Allow.
3. Server par: `python manage.py test_vendor_push 03XXXXXXXXX --channel new_orders` (aur `--channel updates`). **App band + screen lock** par alert aaye (new_orders par alag awaaz). Tap par app khule.
4. Customer ki taraf se naya order banayein: app band / background / khuli - teeno mein alert; tap par **wahi order** ka detail khule. Khuli app mein upar banner + awaaz (ek hi baar).
5. Logout karein, phir naya order: us phone par alert **nahi** aana chahiye. Do phone par ek vendor login ho to dono ko aaye. More > *Alerts & permissions* mein sab "Theek hai" dikhna chahiye.

Aglay phase: **V8** (Products tab: list + quick update).
