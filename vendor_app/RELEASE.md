# Vendor App - Release (Phase V17)

## 1. Audit (V17 se pehle ki haalat -> kya kiya)

| Hissa | Mila | Kya kiya |
|---|---|---|
| Ownership | Sab 43 `@vendor_api` endpoints `profile.vendor` se filter karte hain; login ke ilawa koi endpoint bina token ke nahi | Naya test: har `vendor_api_*` URL bina token 401 (`tests_vendor_release.TokenAuditTests`) |
| Token | 30 din expiry + password badalne par band (pehle se) | Expired / tampered token ke tests |
| Rate limit | Sirf login par phone+IP lockout | **Har API par** ek vendor ke liye 240 requests / 60 sec (429 + `Retry-After`), login par IP hadd 60 / 5 min. Settings: `VENDOR_API_RATE_LIMIT`, `VENDOR_API_RATE_WINDOW`, `VENDOR_LOGIN_IP_LIMIT` (0 = band; tests mein khud band) |
| Response size | Koi compression nahi | **gzip** (sirf vendor API par, poori site par nahi) |
| Cache / headers | - | API jawab par `Cache-Control: no-store`, `X-Content-Type-Options: nosniff` (login ke token wale jawab par bhi) |
| Images | Lists mein poori bari photo | **Thumbnail** (360 px JPEG, `media/thumbs/`) - products / offers list mein naya `thumb` key; purani `image` key waisi hi. Cloud storage ya koi masla ho to asli photo ka link (crash nahi) |
| DB queries | Lists (orders, reviews, rider cash, products) mein `select_related` / `prefetch_related` pehle se | Koi N+1 nahi mila; badlav nahi |
| Logging | Password / token kahin log nahi | Source-scan test is ko pakka rakhta hai (`LoggingTests`) |
| Crash safety | Sirf screens ke andar try/catch | Global handlers (`FlutterError`, `PlatformDispatcher`, zone) + release mein saaf "yeh hissa nahi khul saka" widget |
| Offline | Har screen par purana data + message | Shell par **"Internet nahi hai"** patti (+ Dobara) - kamyab request par khud hat jati hai |
| Timeouts | 20 sec (GET par ek retry), upload 120 sec | Pehle se theek; badlav nahi |
| UI states | Har data screen par skeleton / empty / error + retry | Audit mein koi screen khali nahi mili |
| Polish | - | Page transition, tab badalne par halki haptic, splash screen (teal + icon), version 1.0.0 (19) |
| Release | Sirf debug-signed APK | **Signed AAB + APK** workflow (`build_vendor_release.yml`), secrets se |

**Nahi kiya (jaan-boojh kar):** dark mode (plan mein optional tha), app ka final naam (aap ne abhi nahi bataya - neeche dekhein), Play Store listing / screenshots (aap ka kaam).

## 2. Final naam

App ka naam abhi placeholder **Vendor App** hai. Naam **sirf `APP_NAME`** se badalta hai: dono workflows
(`build_vendor_apk.yml` aur `build_vendor_release.yml`) ke `env:` mein, ek hi lafz (phone ke icon ka naam aur app ke andar ka naam dono yahin se).

## 3. Release signing (ek dafa ka kaam)

1. Apne computer par keystore banayein (**yeh file kabhi repo / zip mein na daalein, aur kahin safe backup rakhein - kho gayi to Play Store update band**):
   ```
   keytool -genkeypair -v -keystore vendor-upload.jks -alias vendor -keyalg RSA -keysize 2048 -validity 10000
   ```
2. Base64 text banayein: `base64 -w0 vendor-upload.jks` (Windows: `certutil -encode vendor-upload.jks out.txt` ya Git Bash mein wohi command).
3. GitHub > repo > Settings > Secrets and variables > Actions > New repository secret:
   - `VENDOR_KEYSTORE_BASE64` = upar ka base64 text
   - `VENDOR_KEYSTORE_PASSWORD`, `VENDOR_KEY_ALIAS` (jaise `vendor`), `VENDOR_KEY_PASSWORD`
   - `GOOGLE_SERVICES_JSON_VENDOR` (pehle se hona chahiye)
4. Actions > **Build Vendor Release (Play Store AAB)** > Run workflow. Secret kam ho to workflow saaf error ke saath ruk jata hai (debug key se kabhi release nahi banti).
5. Artifact `vendor-release`: `Vendor-App-release.aab` (Play Store) aur `Vendor-App-release.apk` (phone par install karke dekhne ke liye).

Version badalna ho: `vendor_app/pubspec.yaml` ka `version:` (naam+build number, har Play Store upload par build number **badhana zaroori**) aur `lib/utils.dart` ka `kAppVersion` ek saath.

## 4. Backend ke baad

- Migration koi nahi (aakhri 0064). Naye settings optional hain (upar ki table).
- Tests: `python manage.py test app.tests_vendor_release` (aur purane `app.tests_vendor_*`).
- Server par `media/thumbs/` folder khud ban jata hai (media wale folder mein likhne ki ijazat chahiye). Cloud storage par thumbnail nahi bante, asli photo chalti hai.

## 5. Play Store ki list

- [ ] Privacy policy ka public link (app ke Madad / Profile mein link pehle se, Play Console mein bhi dein)
- [ ] Account delete ka link (app ke andar + web: `shop/vendor/account/delete/`) - Play Console "Data safety" mein likhein
- [ ] Data safety form: phone number, naam, address, store location (verify ke waqt), photos, FCM token
- [ ] Notification permission (Android 13+) aur location (sirf foreground, store verify) ki wajah likhein
- [ ] Screenshots (phone), 512x512 icon (`assets/icon/app_icon.png`), feature graphic
- [ ] Signed AAB upload, pehle "Internal testing" track par

## 6. Final QA (PDF ka aakhri checklist) - aap ke phone par

Login / lockout / unapproved | token expire | password badalne par doosra phone logout | naya order alert (app band + lock screen) |
Accept / Reject / Ready / Delivered | live map | doosre vendor ka data nahi | product add (photo) / edit / on-off / quick update |
bari image par error | sales web ke barabar | profit N/A | rider cash confirm / reject | export khule | coupon checkout par chale |
review reply | store settings customer par nazar aayein | slow net par chale | net band par purana data + patti | chhote / bade phone par layout |
signed release install ho, version 1.0.0 (19) | privacy + account delete link.
