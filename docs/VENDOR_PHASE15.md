# Vendor Phase V15 - Store settings

## Kya badla
Backend (`app/customer/views_vendor_api.py`, `app/urls.py`):
- `GET /api/vendor/store/` -> `settings` (naam, tafseel, category, status, opens_at / closes_at, min_order_amount, delivery_fee,
  delivery_time_min / max, areas, area_groups, areas_extra, logo, cover, location), `store` (is_open / within_hours), `categories`, `limits`.
- `POST /api/vendor/store/` body `{section: basic|timing|delivery|branding, ...}`:
  - basic: `status` (open|busy|closed), `description` (<=1000), `store_category` (id ya khali)
  - timing: `opens_at`, `closes_at` ("HH:MM"; dono khali = hamesha khula)
  - delivery: `min_order_amount`, `delivery_fee`, `delivery_time_min`, `delivery_time_max` (5-600, min <= max), `areas` [labels], `areas_extra` (text)
  - branding: multipart `logo`, `cover_image`, `remove_logo`, `remove_cover`
  Jo field na bheji jaye wo badalti nahi. Ghalti par `400 {ok:false, error, errors:[...], code:'validation'}` aur kuch save nahi hota.
- `POST /api/vendor/store/location/` body `{lat, lng, accuracy, consent: true}` -> blue tick (web jaisi hadein: consent zaroori,
  sahi coordinates, GPS ghalti `VENDOR_LOCATION_MAX_ACCURACY_M` = 500 m tak).
- Har API approved vendor ke liye, sirf apna profile badalta hai (token se), `transaction.atomic` + `select_for_update`.
- Koi migration nahi (aakhri 0064).

App (`vendor_app/`): `screens/store_settings.dart` (hub + Basic / Timing / Delivery / Branding / Location), `models/store_settings.dart`,
`services/api.dart` (store calls + cache), `services/app_state.dart` (`applyStoreChange`), More tab aur Dashboard warning ke links,
`geolocator` + location permission (`tool/patch_manifest.py`), version 0.15.0+17.

## Kaise test karein (5 steps)
1. Backend push karein, Actions `Django CI/CD` chale; apni machine par `python manage.py test app.tests_vendor_store`.
2. `Build Vendor APK` chalayein, APK install karein, login karein.
3. More > Store settings: har hissa badal ke Save karein - web `shop/vendor/store/` par wahi values nazar aayein, customer app / web par bhi.
4. Timing aisi lagayein ke abhi band ho -> Dashboard par "timing se bahar" warning, customer ko store band. Timing hata dein -> dobara khula.
5. Location verify: ittefaq tick karein, GPS location lein, Verify -> store naam ke saath blue tick; GPS off ho to saaf message + "Location on karein" button.

## Jo is phase mein nahi (plan ke khaane)
- Har din ka alag waqt: model mein sirf `opens_at` / `closes_at` hain (koi migration nahi) - ek waqt har din ke liye.
- Free-delivery limit, default prep time: VendorProfile mein field nahi - additive field wale alag phase mein.

Agla phase: **V16 - Profile, account & help**.
