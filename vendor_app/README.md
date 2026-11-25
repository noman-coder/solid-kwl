# Vendor App (Khanewal Connect - Android)

Store owner (vendor) ke liye app. Rider app ke dhanche par bani hai; backend JSON API `api/vendor/...` hai
(`app/customer/views_vendor_api.py`). Abhi **Phase V11**: foundation (login, 5-tab shell, APK build) + **Dashboard tab** + **Orders tab** + **Order detail + live tracking** + **Push notifications (app band ho tab bhi naya order alert)** + **Products tab (list, search, filters, show/hide, quick update)** + **Product add / edit form (step-wise: Basic / Rate-Stock / Photo / Review)** + **product ki photo (camera / gallery, crop, compress, progress, retry)** + **Stock section (kam / khatam list, stock add / kam, kai products ek saath, kam-stock ki hadd, history)** + **Sales tab (bikri, cash vs online, profit, commission, statement, CSV / PDF share)**.
Baqi (More ke andar ka kaam) aglay phases mein bharega.

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
`lib/main.dart`, `theme.dart`, `utils.dart` | `lib/services` (api, app_state, push) | `lib/models` (vendor, dashboard, orders, order_detail, products, stock, sales) |
`lib/screens` (login, shell, dashboard, orders, order_detail, products, product_form, stock, sales, pending, more, placeholder_tab, notification_permission, permissions_help) |
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
