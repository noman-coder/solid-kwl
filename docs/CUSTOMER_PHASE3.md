# Customer App - Phase C3 (Flutter foundation + APK build)

Sirf **app** ka kaam: naya `customer_app/` Flutter project (vendor_app ke dhanche par) + GitHub APK workflow.
**Backend / database mein koi tabdeeli nahi** (migration nahi; C1 ki API `api/customer/...` use hoti hai). Agli migration C16 ki (0066).

Files: `customer_app/` (poora project) | `.github/workflows/build_customer_apk.yml` | `.gitignore` (customer_app/android, build...) |
`customer_app/tool/` (`patch_gradle.py`, `patch_manifest.py`, `patch_push.py`, `patch_notification.py`, `check_app.py`).

## App mein kya hai

| Hissa | File | Kaam |
|---|---|---|
| Theme | `lib/theme.dart` | Garam narangi (asli action) + hara (faida / kamyabi), gol card, halka saya, ek font family (system default), page transition, NavigationBar |
| Server / token | `lib/services/api.dart` | Bearer token (30 din), JSON, timeout, GET par ek dafa auto-retry (POST kabhi nahi), net band par `Api.offline`, 401 `auth` par khud session khatam. Server URL sirf yahin (`--dart-define=API_BASE`), app mein kahin dikhta nahi |
| Halat | `lib/services/app_state.dart` | Guest / login, tab, cart badge (C7 bharegi), `AppScope.of(context)` |
| Login | `lib/screens/login.dart` | Phone + password, saaf error (ghalat password, 5 koshish lock, band account), `ensureLoggedIn(context)` (checkout / orders ke liye) |
| Register | `lib/screens/register.dart` | Server ke qaide (naam, phone 03XX, email, shehar, address 10+ harf, password 8+ harf+number, Privacy Policy), double-tap lock |
| OTP | `lib/screens/otp.dart` | Email par 6-digit code, 60 sec resend, "Baad mein"; bharosay-mand customer ko "zaroorat nahi". Checkout (C8) yahi screen dobara use karega |
| Forgot | `lib/screens/forgot.dart` | Step 1 phone -> code, Step 2 code + naya password |
| Shell | `lib/screens/shell.dart` | 5 tabs: Home, Stores, Cart, Orders, Account ("jald aa raha hai" placeholder; Account tab abhi bhara hua) |
| Guest mode | shell + `account_tab.dart` | Bina login browse; Orders / Account par Login ka button |
| Widgets | `lib/widgets/` | skeleton (pulse), empty state, notice card, offline patti, crash view, busy button, auth layout |

Responsive: form screens ek hadd tak chaurai (460 / 560 dp) mein beech mein, scroll hoti hain (keyboard khule to bhi), text size 1.3x tak
clamp (ya phone ka text bara ho to bhi layout nahi toota), lambe naam / email `ellipsis`.

Android: package `com.khanewal.customer.app`, permissions: INTERNET, POST_NOTIFICATIONS, VIBRATE, location (foreground, area ke liye).
Push ka app hissa C11 mein (firebase packages tab judenge); abhi sirf secret / gradle taiyari.

## GitHub par ek dafa setup

1. Repo mein is zip ka sab kuch push karein (`customer_app/` naya folder hai).
2. **Firebase**: apne project mein *naya Android app* banayein, package **`com.khanewal.customer.app`** (vendor / rider wale se alag), `google-services.json` download karein.
3. GitHub > Settings > Secrets and variables > Actions > New secret: naam **`GOOGLE_SERVICES_JSON_CUSTOMER`**, value = us file ka poora text.
   (Secret na ho to APK phir bhi banti hai, bas push band rehta hai; package ghalat ho to build saaf error se rukta hai.)
4. Actions > **Build Customer APK** > Run workflow. Artifact **`customer-apk`** (`Customer-App.apk`).
5. App ka naam badalna ho to sirf workflow `env: APP_NAME`; package / server bhi wahin (`APP_ID`, `API_BASE`).

## Test kaise karein (5 line)

1. Actions mein Build Customer APK chalayein; green hone par artifact se `Customer-App.apk` download + install.
2. Account tab > Register: naya account (phone 03XXXXXXXXX, email). Phir OTP screen khulti hai: email ka code likhein ya "Baad mein".
3. Logout, phir Login: sahi password se andar; ghalat password par saaf lal message; 5 galat koshish par "10 minute baad".
4. Login > "Password bhool gaye?": code mangwayein, naya password rakhein, phir naye password se login. Purane phone par purana login band.
5. 5 tabs khol kar dekhein; chhote aur bade phone par layout; app mein server ka URL kahin nazar na aaye. Net band kar ke app kholein: offline patti.

Static jaanch (bina Flutter): `python3 customer_app/tool/check_app.py` - workflow build se pehle khud chalata hai
(brackets, imports, server URL sirf api.dart mein, koi secret nahi).

## Yaad rakhein

- Is phase ka code ek aisi jagah likha gaya jahan Flutter SDK nahi tha: static jaanch + patch scripts ka test hua, lekin APK ka pehla build GitHub par hi hoga.
  Agar Actions mein `flutter build` / analyzer ka koi error aaye to log (ya screenshot) bhej dein, wohi phase theek kar dein.
- `flutter_launcher_icons` / `flutter_native_splash` icons `customer_app/assets/icon/` se banate hain (narangi bag icon; apna icon dena ho to
  `app_icon.png` (1024x1024) aur `app_icon_fg.png` (transparent, beech mein 66% hissa) badal dein).
- Agla phase: **C4** (area / location + Home tab).
