# Vendor App (Khanewal Connect - Android)

Store owner (vendor) ke liye app. Rider app ke dhanche par bani hai; backend JSON API `api/vendor/...` hai
(`app/customer/views_vendor_api.py`). Abhi **Phase V17 (polish, security, release)** - ab sab 17 phase mukammal (details `RELEASE.md`). Pehle ke phases: **Phase V16 (profile, account & help)**: foundation (login, 5-tab shell, APK build) + **Dashboard tab** + **Orders tab** + **Order detail + live tracking** + **Push notifications (app band ho tab bhi naya order alert)** + **Products tab (list, search, filters, show/hide, quick update)** + **Product add / edit form (step-wise: Basic / Rate-Stock / Photo / Review)** + **product ki photo (camera / gallery, crop, compress, progress, retry)** + **Stock section (kam / khatam list, stock add / kam, kai products ek saath, kam-stock ki hadd, history)** + **Sales tab (bikri, cash vs online, profit, commission, statement, CSV / PDF share)** + **Rider cash (rider ka COD cash confirm / reject, history)** + **Coupons (banao / badlo / chalu-band / delete, preview, WhatsApp share)** + **Offers (product par start-end tareekh wala discount)** + **Reviews (customers ki rating dekhna aur jawab dena)** + **Store settings (basic, timing, delivery, areas, logo / banner, location verify)** + **Profile, password, account delete, madad & alert settings**.
**V17:** har API par rate limit + gzip + security headers, list ki chhoti tasveeren (thumb), global crash safety, offline patti, splash, haptics, signed **AAB** workflow (`build_vendor_release.yml`). Release ka tareeqa: `RELEASE.md`.

- App ka naam (placeholder): **Vendor App** - `.github/workflows/build_vendor_apk.yml` aur `build_vendor_release.yml` ke `env: APP_NAME` se badlein (phone ka icon-naam aur app ke andar ka naam dono yahin se).
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
- **Products tab (V8):** search (naam / barcode), chips (Sab / Approved / Pending / Rejected / Kam stock / Khatam, har ek par ginti),
  list ya grid (yaad rehta hai), har product par **shop show/hide switch** (sirf approved; off karne par customer ko nahi dikhta),
  stock badge (khatam = laal, kam = narangi), rejected par **wajah**, pending par "Approval baqi". Card par tap = **quick edit**
  (rate, discount 0-90%, naya stock jama karna; web quick-update jaisi validation, negative stock nahi ban sakta). Neeche scroll par
  agla page, pull-to-refresh, skeleton, empty, error + retry, net band par purani list + "offline" message.
- **Product add / edit (V9-A):** Products tab par **Naya product** button (ya khali list par "Pehla product add karein"); card par tap > quick edit > **Poora edit**.
  3 step: **Basic** (naam, category search sheet, brand, unit, tafseel) > **Rate / Stock** (rate, discount, stock + "customer ko rate" aur "aap ko milega" ka live andaza) > **Review**.
  Category / brand / unit na mile to search box mein naam likh kar **"+ naya banayein"** (wohi naam ho to wohi chun liya jata hai). Naye product ka adhoora form **phone mein draft** ban kar bachta hai
  (net chala jaye ya app band ho). Submit dobara dabane / retry par product dohra nahi banta. Edit mein stock **jama** hota hai (kam nahi). Photo (**V9-B**): form ka **Photo** step - Camera / Gallery, crop, upload se pehle khud compress (lambi side ~1280 px, quality ~80, 1 MB se kam; server limit 5 MB), preview, hatana / badalna.
  Product ki **sirf ek main photo** hoti hai. Submit par **progress bar**; net toote to form + compressed photo bacha rehta hai aur "Dobara koshish karein" se wohi product (request key) dobara bheji jati hai.
  Draft mein photo ka path bhi hota hai (kamyab submit par draft + temp photo saaf). Submit ke baad message **server** ka (live / admin approval / photo badli). Bina photo wale products ke card par **"Photo lagayein"** nishan - tap par seedha edit form ka Photo step.
  Photo badalne par (auto-approve band ho to) product dobara admin review mein jata hai - form pehle hi bata deta hai. Edit mein photo na chunein to purani photo bani rehti hai.
  Camera system camera app se khulta hai aur Android 13+ par gallery system photo picker se - is liye CAMERA / gallery ki alag permission manifest mein nahi.
- **Push notifications (V7):** login ke baad phone ka FCM token server par register (token badle to dobara, logout par hat jata hai). App band / screen lock / background - teeno haalat mein naya order, cancel, rider cash, review, stock ka alert.
  Do channel: **Naye orders** (alag "ding-dong" awaaz + lambi vibration) aur **Baqi updates**. Notification par **tap -> seedha wohi order** (naye review ka alert **Reviews screen** kholta hai) (app band, background ya khuli - teeno haalat). App khuli ho to upar **in-app banner + awaaz**
  (poll aur push mil kar ek hi baar bajate hain). Login ke baad ek dafa **notification ijazat ka saaf screen** (Android 13+), **More > Alerts & permissions** mein ijazat, **Battery: Unrestricted** aur "is phone ka alert server se juda hai?" ka status + Xiaomi/Oppo/Vivo/Samsung ki madad.
  Do phone par ek vendor login ho to dono ko alert. Logout ke baad us phone par alert nahi. Firebase secret na ho to app pehle jaisi chalti hai (sirf poll).

- **Offers (V13-B):** More > **Offers**. Product chunein (sirf approved + chalu), discount % (chips: 5/10/15/20/25/30), shuru aur khatam ki tareekh, neeche
  **"Customer ko aise dikhega"** preview. Card par chalu/band switch, tap = badlein, WhatsApp share, delete. Chips: Sab / Chalu / Jald shuru / Khatam.
  Offer product ki asli price kabhi nahi badalta: customer ko sirf us dauran kam price + OFF badge dikhta hai, khatam hote hi price khud pehli jaisi.
  **Do discount jama nahi hote** - product ka apna discount ho to jo bara ho wohi lagta hai. Ek product par ek waqt mein ek hi offer (peeche-peeche theek hain).
  Hadd: 1% se, zyada se zyada 90 din, aur discount ki oopri hadd = commission ke hisaab se (neeche dekhein). Chalu offer ki shuruaat nahi badalti; khatam offer dobara chalu nahi hota.
  Cart mein jo item pehle se hai us ki price add karne ke waqt wali rehti hai (product discount ka bhi yahi usool hai).

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
`lib/main.dart`, `theme.dart`, `utils.dart` | `lib/services` (api, app_state, push, prefs) | `lib/models` (vendor, profile, dashboard, orders, order_detail, products, stock, sales, rider_cash, coupons, offers, reviews, store_settings) |
`lib/screens` (login, shell, dashboard, orders, order_detail, products, product_form, stock, sales, rider_cash, coupons, offers, pending, more, profile, help, alert_settings, placeholder_tab, notification_permission, permissions_help) |
`lib/widgets` (empty_state, skeleton, notice_card, loading, section_title, stat_card, week_chart, sales_charts, status_stepper, live_map, in_app_banner) |
`tool/` (patch_gradle, patch_manifest, patch_push, patch_notification + `res/new_order.wav` - workflow `flutter create` ke baad chalata hai) | `assets/icon/`.
Tafseel: `docs/VENDOR_PHASE3.md` (foundation), `docs/VENDOR_PHASE4.md` (dashboard), `docs/VENDOR_PHASE5.md` (orders), `docs/VENDOR_PHASE6.md` (order detail + live tracking), `docs/VENDOR_PHASE7.md` (push notifications).

## Phase V10: Stock & inventory (Products tab -> upar ka Stock nishan)
- Stock screen: chips **Kam + Khatam / Kam / Khatam / Sab** (ginti ke saath), search (naam / barcode), har card par **Stock add** aur **Kam karein**,
  teen-dot menu mein **kam-stock ki hadd badlein** aur **is ki history**. Upar history nishan = poore store ki history.
- **Stock add / kam sheet:** quantity, wajah (naya maal / wapsi / kharab / expire / gum ...), note, "Stock: 5 -> 35" preview. Negative stock ya orders ke liye
  roka hua (reserved) stock kam nahi hota - server saaf message deta hai. Net toot kar dobara dabane par stock do dafa nahi lagta.
- **Bulk:** upar ke "+" nishan se kai products ka naya stock ek screen par likh kar ek tap mein add.
- Push: stock kam / khatam hote hi alert (din mein ek dafa per product) + roz ek **summary** push (server par `python manage.py vendor_stock_summary` cron se).
  Push par tap = seedha Stock screen.
- Barcode scan (optional) abhi nahi: search box mein barcode likhne / bolne se product mil jata hai (naya native package nahi joda).

## Phase V11: Sales, cash & profit (Sales tab)
- Muddat chips: Aaj / 7 din / 30 din / Tareekh chunein. Summary: kul bikri, aap ki kamayi (commission ke baad), orders, aosat order. Din ba din line chart.
- **Cash (COD) vs Online** donut (tap = un ke orders). **Munafa (profit):** sirf un products par jin par *Kharid rate* bhara ho (Product edit > Rate / Stock);
  kharid rate khali ho to **N/A**. Commission ka tafseeli hisaab, top aur kam chalne wale products, ab tak ka poora hisaab.
- **Statement:** din wise kamayi (sirf deliver hue orders). **Share:** CSV ya PDF report WhatsApp / email par.
- Numbers web vendor portal ke Analytics se milte hain. Tafseel + test: `docs/VENDOR_PHASE11.md`.

## Phase V12: Rider cash (More > Rider se cash)
- Rider COD ka cash vendor ko deta hai aur handover bhejta hai: vendor ko push aata hai (tap = seedha yahi screen). Pending card par raqam, rider ka naam / call, kin orders ka cash.
- **Confirm** (raqam dobara dikha kar) = rider ka cash-in-hand utna kam; **Reject** (wajah zaroori) = balance wahi, rider ko wajah. Confirm ke baghair balance nahi badalta.
- History (confirm / reject) aur ab tak mila hua jod. Dashboard par pending cash badge. Tafseel + test: `docs/VENDOR_PHASE12.md`.

## Phase V13: Coupons (More > Promotion > Coupons)
- Apne store ke coupons: percent / Rs off / free delivery, kam az kam order, kul istemal ki hadd, har customer ki hadd, sirf pehla order, shuru / khatam ki tareekh. Banate waqt **preview** ("Customer ko aise dikhega").
- Card par usage bar, ab tak di gayi chhoot, **chalu / band switch**, code copy, **WhatsApp share**. Istemal ho chuka coupon delete nahi hota (band hota hai) aur uska code / qism / value badal nahi sakta.
- Validation aur checkout web wala hi (`_clean_vendor_coupon`, `coupons.evaluate`).
- Sust net / VPN par GET requests khud ek dafa dobara try hoti hain. Tafseel + test: `docs/VENDOR_PHASE13.md`.

## Phase V13-B: Offers (More > Promotion > Offers)
- Product par waqt-wala discount: product chunein, discount %, shuru / khatam tareekh. Customer ko kam price + OFF badge sirf us dauran; khatam hote hi price khud pehli jaisi. **Product ki asli price / discount DB mein kabhi nahi badalti.**
- Asar = max(product ka apna discount, offer %) - jama nahi hote. Ek product par ek waqt mein ek offer. Zyada se zyada 90 din, 100 offers.
- **Commission ki hadd:** vendor ka hissa stock batch ke 'cost' mein pehle se tay hota hai, offer use nahi badalta; is liye offer price vendor ke hisse se neeche jaye to shop ka commission minus ho jata. Default mein offer % ki oopri hadd `100 x (1 - (1-d)(1-c))` hai (c = vendor ka commission, d = product ka discount). Hadd hatani ho to settings mein `VENDOR_OFFER_CAP_TO_COMMISSION = False` (tab 70% tak).
- Backend: `app/customer/offers.py` (engine), `ProductOffer` table (migration **0064**, sirf nayi table), `api/vendor/offers/...`. Customer side: `get_product_final_price`, store page, shop home, product detail. `Product.save()` offer ko kabhi DB mein nahi likhta.
- Tests: `python manage.py test app.tests_vendor_offers`.


## Phase V14: Reviews & ratings (More > Customers > Reviews)
- Upar card: **average rating** + 5-1 star ki patti (patti par tap = sirf us star ke reviews; dobara tap = hata do). Chips: **Sab / Jawab nahi diya / Jawab diya** (har ek par ginti).
- Review card: customer ka naam (privacy ke liye **"Hadi A."** - phone / address kabhi nahi), star, order no, waqt, comment, **"Order dekhein"**.
- **Jawab dein / badlein / hatayein:** bottom sheet, 300 akshar tak (counter ke saath), "jaldi jawab" ke 2 nuskhe (4-5 star aur 1-3 star ke liye alag). Jawab customer ko store page par dikhta hai.
  Khali karke bhejne par jawab hat jata hai. Lamba jawab server chupke kaat nahi deta, saaf error deta hai.
- Naye review par push (V2) ab tap par seedha **Reviews screen** kholti hai (pehle order detail). Pull-to-refresh, agla page (20-20), skeleton, empty, error + retry, net band par purani list + message.
- Backend: `GET /api/vendor/reviews/`, `POST /api/vendor/reviews/<id>/reply/` (`views_vendor_api.py`), jawab save karne ki logic web wali `views_extras.save_vendor_reply`. Koi migration nahi.
- Tests: `python manage.py test app.tests_vendor_reviews`. Tafseel: `docs/VENDOR_PHASE14.md`.

## Phase V15: Store settings (More > Store > Store settings)
- **Hub screen:** upar store card (logo, banner, naam, blue tick, abhi khula / band aur wajah), neeche 5 hisse - har hissa **alag screen, alag Save** (ek ki ghalti doosre ko nahi roakti).
- **Basic:** store ki halat (Khula / Busy / Band - Band karne se pehle confirm), category, tafseel (1000 akshar tak).
- **Timing:** "Hamesha khula" switch ya khulne / band hone ka waqt (time picker). Raat ko paar hone wala waqt (18:00 se 02:00) theek hai. Timing ke bahar customer ko store band dikhta hai (server `is_open_now`). Waqt **har din ke liye ek hi** hai (model mein har din ka alag waqt nahi, is phase mein koi migration nahi).
- **Delivery:** minimum order, delivery fee, delivery time (min - max, 5-600 minute), areas - admin ki list se shehar-wise tick + list mein na hone wale areas apne likhein (zyada se zyada 50).
- **Branding:** logo aur banner - camera / gallery, crop, upload se pehle compress (5 MB hadd), progress bar, "Hatayein" (confirm ke saath).
- **Location verify:** privacy ka saaf matn + ittefaq ka checkbox, phir button se GPS location (map par pin + GPS ghalti ka ghera). Ghalti 500 m se zyada ho to verify band (store ke andar / khuli jagah dobara lein). Verify par store naam ke saath **blue tick**. Dashboard ki "location verify nahi" warning dabane par seedha yahi screen kholti hai.
- Backend: `GET/POST /api/vendor/store/` (POST mein `section`: basic / timing / delivery / branding), `POST /api/vendor/store/location/` (`views_vendor_api.py`). Validation web ki `vendor_store_settings` / `vendor_location_verify` wali hi (`_parse_time`, `_parse_money`, `_areas_from_post`, `_validate_image`, `parse_coords`). Koi migration nahi (aakhri 0064).
- Naya package: `geolocator` (rider app wala version) aur `tool/patch_manifest.py` mein sirf foreground location permission (ACCESS_FINE / COARSE, background nahi).
- Plan ke 2 khaane is phase mein nahi: **free-delivery limit** aur **default prep time** - VendorProfile mein ye fields maujood nahi, aur is phase mein migration ki ijazat nahi. Zarurat ho to alag chhote phase mein additive field ke saath.
- Tests: `python manage.py test app.tests_vendor_store`. Tafseel: `docs/VENDOR_PHASE15.md`.

## Phase V16: Profile, account & help (More > Account)
- **Profile:** owner ka naam, email, city, address badlein (sirf badle hue fields server ko jate hain; ghalti par saaf list, kuch save nahi hota). **Store ka naam, phone (login ID) aur commission yahan se nahi badalte** (hisaab ke records se jude hain) - badalna ho to support se. Email kisi aur account par ho to reject. Net band ho to purani copy + "Offline" message.
- **Password badlein:** purana + naya (kam az kam 6) + dobara. 5 galat purane password par 10 minute ka lock (web login jaisa). Kamyab hone par is phone ko naya token mil jata hai, **doosre phones ke token khud band** (unka agla call login screen par le jata hai) aur un phones ke **push token bhi server se hat jate hain** (logout hue phone par alert na aaye).
- **Account delete:** More ke neeche "Account delete karein". Password + tick + akhri confirm dialog. Rules web jaise: chal rahe order ho (pending / confirmed / processing / ready / partially delivered) to nahi hota; 5 galat password par 10 minute lock (web ke saath ek hi counter). Phir store band, products chhup, naam / email / address / logo saaf, login band, push token hat jate hain. Profile row hisaab ke liye rehti hai. Rider cash confirm baqi ho to app pehle se yaad dilati hai (web bhi rokta nahi).
- **Madad & support:** company ke WhatsApp / call / email (server se), "Alerts nahi aa rahe?" madad, Privacy policy aur Account delete ka public web page (Play Store ki zarurat), app version.
- **Alert settings:** naye order ka banner / awaaz / vibration aur baqi alerts ka banner - **sirf is phone par aur sirf app khuli ho tab**. App band ho tab awaaz / on-off Android ki notification settings ("Naye orders" / "Baqi updates") se; screen se seedha button hai.
- Backend: `GET/POST /api/vendor/profile/`, `POST /api/vendor/password/`, `POST /api/vendor/account/delete/` (`views_vendor_api.py`). Web delete ab shared `views_account_deletion.wipe_vendor_account` use karta hai (web ka behaviour wahi, upar se push tokens bhi saaf). Koi migration nahi (aakhri 0064).
- Tests: `python manage.py test app.tests_vendor_profile`. Tafseel: `docs/VENDOR_PHASE16.md`.

