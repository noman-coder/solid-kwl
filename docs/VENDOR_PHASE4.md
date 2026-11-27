# Vendor App - Phase V4: Dashboard tab (backend + app)

Backend API + Flutter Dashboard screen. **Database mein koi tabdeeli nahi** (migration abhi bhi **0061**; store Open/Closed ke liye
`VendorProfile.store_status` ka purana field use hua). Purana web portal, rider app/API aur V1-V3 ki API bilkul nahi chhedi.

## Backend (NEW routes)
| Route | Kaam |
|---|---|
| `GET /api/vendor/dashboard/` | Ek nazar mein poora business (approved vendor, Bearer token, sirf apna data) |
| `POST /api/vendor/store/open/` | Store Open/Closed switch. Body `{"open": true|false}` |

Naya business logic nahi likha - hisaab wahi hai jo web portal ka hai:
- **Sale / orders** (aaj, hafta = 7 din, mahina = 30 din, 7 din ka chart): `views_vendor_tools._analytics_data` (web "Analytics" page). Cancelled order shamil nahi. Mahina "pichle 30 din" hai (web ka `30 din` range).
- **Kamai (earnings)**: `vendor_commission.vendor_earnings` (web dashboard ka card): kul bikri, commission, aap ka hissa (payable).
- **Rating**: `views_reviews.vendor_rating`. **Commission %**: `commission_percent`.
- **Orders ki ginti**: web ke tabs (`ORDER_TABS`): Naye = pending, Chal rahe = confirmed/processing/ready, Mukammal = baqi. Saath mein `by_status`.
- **Products**: approved / pending / rejected. **Stock**: `views_vendor_tools._stock_rows` (approved aur stock <= product ka `low_stock_threshold`): `low` (kam, stock > 0), `out` (khatam), `items` (sab se kam 5 ke naam).
- **Rider cash**: vendor ke confirm ka intezar karte `RiderCashHandover` (ginti + raqam).
- **Warnings** (`code`, `level` info/warn/error, Roman Urdu `text`): `store_closed`, `outside_hours`, `store_busy`, `new_orders`, `rider_cash`, `out_of_stock`, `low_stock`, `rejected_products`, `pending_products`, `location_unverified`.

Jawab ka dhancha: `ok, generated_at, vendor, store{status, switch_on, is_open, within_hours, opens_at, closes_at, location_verified}, today/week/month{sales, orders}, orders{new, active, done, by_status, cancelled_30d}, new_orders, earnings{units, sales, commission, payable}, commission_percent, rating{avg, count}, products{approved, pending, rejected, total}, stock{low, out, items[]}, rider_cash{count, amount}, chart[7]{date, label, sales, orders}, warnings[]`. Paisay float (2 decimal).

Store switch: `open=false` -> `store_status='closed'` (customer is store se order nahi de sakta). `open=true` -> `'open'` (agar 'busy' tha to busy hi rehta hai). Sirf `store_status` update hota hai (baqi profile fields nahi chhedte). Timing ke bahar khulne par message batata hai ke customer ko abhi band dikhega. Ghalat value -> 400. Unapproved -> 403, bina token -> 401.

## App (Flutter)
- `lib/models/dashboard.dart` - `DashboardData` + chhote models. `lib/utils.dart` - `listOfMaps`, `clockText`.
- `lib/services/api.dart` - `dashboard()` (kamyab jawab phone mein save hota hai), `cachedDashboard()`, `setStoreOpen()`, `absUrl()`. Logout / login par saved dashboard mit jata hai (doosre vendor ko purane numbers nahi dikhte).
- `lib/services/app_state.dart` - `dashboard`, `loadDashboard()`, `refreshAll()`, `setStoreOpen()` (double-tap lock), `newOrders`. Session expire par login screen; approval hat jaye to Approval screen.
- `lib/screens/dashboard.dart` (NEW) - salam + store naam + rating + **Open/Closed switch**, alerts (dabane par Orders / Products tab), aaj, hafta / mahina, orders chips, kamai, rider cash, rating, products + kam stock, 7 din chart, quick actions. Pull-to-refresh, skeleton, error + retry, offline par purana data + "Offline" notice.
- `lib/widgets/stat_card.dart`, `week_chart.dart` (NEW, rider_app se, vendor ke hisab se; koi extra package nahi).
- `lib/screens/shell.dart` - Dashboard tab asli screen se, Orders tab par naye orders ka badge, app resume par profile + dashboard dono taza.
- `pubspec.yaml` version `0.4.0+4`.

## Files
- NEW  `app/tests_vendor_dashboard.py`, `vendor_app/lib/models/dashboard.dart`, `vendor_app/lib/screens/dashboard.dart`, `vendor_app/lib/widgets/stat_card.dart`, `vendor_app/lib/widgets/week_chart.dart`, `docs/VENDOR_PHASE4.md`
- EDIT `app/customer/views_vendor_api.py` (dashboard + store/open), `app/urls.py` (2 routes), `vendor_app/lib/{utils,services/api,services/app_state,screens/shell}.dart`, `vendor_app/pubspec.yaml`, `vendor_app/README.md`

## Kaise test karein
1. Backend: `python manage.py test app.tests_vendor_dashboard app.tests_vendor_api app.tests_vendor_push` (migration koi nahi). Deploy ke baad CI/CD (`Django CI/CD`) ka log aur ntfy alert dekhein.
2. API (Postman): login se token lo -> `GET /api/vendor/dashboard/` (Authorization: Bearer ...). Numbers web `Vendor Dashboard` / `Analytics` se milayein.
3. App: Actions > **Build Vendor APK** > Run workflow > artifact `vendor-apk` > phone mein install.
4. Dashboard tab: numbers web se milayein; switch band karein (confirm aayega) -> customer side par store band dikhe; dobara khol dein.
5. Net band karke (airplane mode) app kholein -> purana data + "Offline" message; net wapas aaye to pull-to-refresh.

## Test checklist (Master Plan)
- [ ] Numbers web dashboard se match karein.
- [ ] Switch band karein -> customer side par store band dikhe.
- [ ] Net band ho to purana data + 'offline' message.

## Agla: Phase V5 (Orders tab: list + actions - `api/vendor/orders/`, `orders/<id>/<action>/`, `orders/poll/`)
