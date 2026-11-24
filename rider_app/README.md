# 88 Riders (Khanewal Connect Rider app - Android)

Rider login, Online/Offline, naye orders, Accept, Maal le liya, Deliver, live map + route, wallet (cash handover),
profile, aur **background live location** (notification ke saath, app minimize/screen lock par bhi).

- App ka naam: **88 Riders**
- Package name (applicationId): `com.khanewal.riders88.app`
  (Android mein package ka koi hissa digit se shuru nahi ho sakta, is liye `88riders` ki jagah `riders88`.)
- Server fixed: `https://khanewalconnect.store` - app mein kahin dikhta nahi, rider badal nahi sakta.

## GitHub par APK banane ka tareeqa
1. Pura project (`rider_app` folder + `.github/workflows/build_rider_apk.yml`) GitHub repo mein push karein.
   **`license_private.key` push na karein** (`.gitignore` mein hai).
2. GitHub > **Actions** > **Build Rider APK (88 Riders)** > **Run workflow** (koi input nahi).
3. 5-10 minute baad run ke neeche **Artifacts > 88-riders-apk** download karein (zip ke andar `88-Riders.apk`).
4. APK rider ke phone mein install karein (Unknown sources allow karna hoga).

Server / naam / package badalna ho to sirf `.github/workflows/build_rider_apk.yml` ke upar wale `env` (APP_ID, API_BASE) aur
`tool/patch_manifest.py` (app ka naam) mein badlein.

## Pehli dafa rider ko ye karna hai
- Login karein, Online hon, order accept karein, "Maal le liya" dabayein.
- Jab app location mange: **"Allow all the time"** chunein (warna app band hone par location nahi jayegi).
- Battery: **Unrestricted / Don't optimize** allow karein. Xiaomi/Oppo/Vivo/Huawei/Samsung par
  Settings > Apps > 88 Riders > Battery > Unrestricted, aur "Autostart" on karein. (Profile > Permissions madad mein bhi hai.)
- Recent apps se app ko swipe karke band na karein; minimize kar dena theek hai.

## App ka dhancha
5 tabs: Dashboard, Orders, Map, Wallet, Profile. Code: `lib/screens` (tabs), `lib/widgets`, `lib/services`
(api, tracker, app_state, route_service, location_hub), `lib/models`. Icon: `assets/icon/` (GitHub Action `flutter_launcher_icons` se
mipmaps banata hai). Tafseel: `docs/RIDER_PHASE4.md` ... `docs/RIDER_PHASE9.md`.

## Backend
Server par `app/customer/views_rider_api.py` aur `app/urls.py` ke `api/rider/...` URLs chahiye (is project mein shamil hain).
Nayi tables sirf additive migrations se aati hain (0058 `RiderCashHandover`).

| URL | Kaam |
|---|---|
| POST `/api/rider/login/` | phone + password -> token |
| GET `/api/rider/orders/` | offers + mere orders |
| POST `/api/rider/online/` | online/offline |
| POST `/api/rider/orders/<id>/accept/` | order lena |
| POST `/api/rider/orders/<id>/pickup/` , `/deliver/` | maal liya / deliver |
| POST `/api/rider/location/` | GPS bhejna |
| GET `/api/rider/dashboard/` `/history/` `/wallet/` `/profile/` | tabs ka data |
| POST `/api/rider/cash/handover/` | cash handover |

## Push notification (app band ho tab bhi naya order alert)

Naya order "Ready" hote hi **online** riders ko notification aati hai (app band ho / screen lock ho, bas internet on ho).
Vendor kisi rider ko order de to sirf usi ko "Order aap ko mila" jata hai.

**Ek dafa setup (Firebase, free):**
1. https://console.firebase.google.com par project banayein > *Add app* > Android, package name: `com.khanewal.riders88.app`
2. `google-services.json` download karein > GitHub > Settings > Secrets > **`GOOGLE_SERVICES_JSON`** (poora text paste)
3. Firebase > Project settings > *Service accounts* > *Generate new private key* > us JSON ko GitHub Secret
   **`FCM_SERVICE_ACCOUNT_JSON`** mein paste karein (server ke liye)
4. "Build Rider APK" dobara chalayein, nayi APK install karein, login karke *Notifications* allow karein.

**Test:** `python manage.py test_rider_push 03xxxxxxxxx`

**Xiaomi / Oppo / Vivo:** Settings > Apps > 88 Riders > *Autostart* on + Battery *No restrictions*. Warna app swipe-close karne par
phone notification roak deta hai. (Force Stop karne par koi bhi app notification nahi le sakti.)

