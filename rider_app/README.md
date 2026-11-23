# K-Conn Rider (Android app)

Rider login, Online/Offline, naye orders, Accept, Maal le liya, Deliver, aur
**background live location** (notification ke saath, app minimize/screen lock par bhi).

## GitHub par APK banane ka tareeqa
1. Pura project (rider_app folder + `.github/workflows/build_rider_apk.yml`) GitHub repo mein push karein.
2. GitHub > **Actions** > **Build Rider APK** > **Run workflow**.
3. `api_base` mein apni website likhein, e.g. `https://shop.example.com` (https behtar hai).
4. 5-10 minute baad run ke neeche **Artifacts > kconn-rider-apk** download karein (zip ke andar `app-release.apk`).
5. APK rider ke phone mein install karein (Unknown sources allow karna hoga).

Server address baad mein bhi app ke login screen par "Server address badlein" se badal sakte hain.

## Release signing (khud ba khud)
Kuch karna nahi. **Build Rider APK** chalane par workflow:
1. Pehli dafa khud release key banata hai aur GitHub **cache** mein rakhta hai.
2. Agle builds mein usi cache se key uthata hai - is liye har APK usi key se sign hoti hai aur update ho jati hai.
3. Artifacts mein 3 cheezein deta hai: `kconn-rider-apk` (APK), `kconn-rider-aab` (Play Store), aur
   **`kconn-rider-keystore-BACKUP`** (key + password, 90 din).

**Zaroori:** GitHub cache 7 din na chalne par khatam ho sakta hai. Pehle build ke baad
`kconn-rider-keystore-BACKUP` ek dafa download karke mehfooz jagah rakh lein. Agar cache chala gaya aur backup nahi hai,
to nayi key banegi aur purani APK ke upar update install nahi hoga (uninstall karke dobara install karna parega).
Behtar: backup ke andar ki values ko repo Secrets (`KEYSTORE_BASE64`, `KEYSTORE_PASSWORD`, `KEY_ALIAS`) mein daal dein -
workflow pehle Secrets use karta hai.
Backup artifact mein password hai: repo private rakhein.

## Pehli dafa rider ko ye karna hai
- Login karein, Online hon, order accept karein, "Maal le liya" dabayein.
- Jab app location mange: **"Allow all the time"** chunein (warna app band hone par location nahi jayegi).
- Battery: **Unrestricted / Don't optimize** allow karein. Xiaomi/Oppo/Vivo/Huawei/Samsung par
  Settings > Apps > K-Conn Rider > Battery > Unrestricted, aur "Autostart" on karein.
- Recent apps se app ko swipe karke band na karein; minimize kar dena theek hai.

## Backend
Server par `app/customer/views_rider_api.py` aur `app/urls.py` ke `api/rider/...` URLs chahiye
(is project mein shamil hain). Koi nayi table nahi.

| URL | Kaam |
|---|---|
| POST `/api/rider/login/` | phone + password -> token |
| GET `/api/rider/orders/` | offers + mere orders |
| POST `/api/rider/online/` | online/offline |
| POST `/api/rider/orders/<id>/accept/` | order lena |
| POST `/api/rider/orders/<id>/pickup/` , `/deliver/` | maal liya / deliver |
| POST `/api/rider/location/` | GPS bhejna |
