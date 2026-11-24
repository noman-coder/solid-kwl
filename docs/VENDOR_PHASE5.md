# Vendor App - Phase V5: Orders tab (backend + app)

Backend API + Flutter Orders tab. **Database mein koi tabdeeli nahi** (migration abhi bhi **0061**). Purana web portal, rider app/API aur
V1-V4 ki API bilkul nahi chhedi.

## Backend (NEW routes, sab `@vendor_api`: Bearer token, approved vendor, sirf apna data)
| Route | Kaam |
|---|---|
| `GET /api/vendor/orders/?tab=new\|active\|done&page=1&q=` | Orders ki list (web `vendor_orders` jaisi tabs) |
| `POST /api/vendor/orders/<id>/<action>/` | `accept` \| `reject` \| `ready` \| `delivered` |
| `GET /api/vendor/orders/poll/` | Halka: naye (pending) orders ki ginti + sab se naya order id |

Naya business logic nahi likha:
- **Tabs**: `views_vendor_portal.ORDER_TABS` - Naye = pending, Chal rahe = confirmed/processing/ready, Mukammal = partially_delivered/delivered/invoiced/cancelled. Naye: purana pehle; baqi: naya pehle. Ghalat `tab` -> `new`.
- **Action**: `store_orders.apply_vendor_action` (wahi jo web mein hai: status check, reject wajah, delivered par auto invoice, customer/admin notification). Accept par `prep_minutes` 1-600 (web jaisa check), reject par `reason_code` + `reason_note` (`store_orders.clean_reject_reason`).
- **Safety**: `transaction.atomic` + `select_for_update`. Ek hi order par do phone se action aaye to ek chalta hai, doosre ko **409** + saaf message (`code: conflict`) aur order ki taza haalat. Doosre vendor ka order -> **404** JSON (`code: not_found`), order chhua nahi jata. Unapproved -> 403, bina token -> 401, ghalat action naam -> 400, GET par action -> 405.
- **Search** `q`: order no, customer naam ya phone (sirf is vendor ke orders mein). **Page** 20 orders ka, `has_more`.
- Queries orders ki ginti se nahi badhti (`select_related` customer + delivery_info/rider, `prefetch_related` items/product).

List jawab: `ok, generated_at, tab, page, has_more, q, counts{new,active,done}, tabs[], orders[], reject_reasons[{code,label}], prep_options[10,20,30,45]`.
Order: `id, order_no, status, status_label, tab, created_at, customer{name,phone,address}, items_count, items_qty, items_preview[3]{name,qty,price,total}, items_more, subtotal, delivery_fee, discount, total, payment{method,is_cod,label}, notes, prep_minutes, reject_reason, responded_at, delivery{type,status,rider_name,rider_phone}|null, actions[]`.
Action jawab: `ok, message, order, next_tab, counts`.

## App (Flutter)
- `lib/models/orders.dart` (NEW) - `VendorOrder`, `OrdersPage`, `OrderActionResult`, `OrdersPoll`.
- `lib/screens/orders.dart` (NEW) - search, 3 tabs (count badge), order card (no, waqt, status, customer + call, address, items, note, COD/Online, total, tayyari time / reject wajah / rider), buttons: **Qubool karein** (chips 10/20/30/45 ya apna time), **Reject** (wajah list, "Doosri wajah" par note zaroori), **Order tayyar hai**, **Deliver ho gaya** (confirm). Action ke baad order khud agli tab mein chala jata hai. Skeleton, empty state, error + retry, pull-to-refresh, neeche scroll par agla page, offline par purani list + notice.
- `lib/services/app_state.dart` - orders ki list/page/state, `orderAction` (double-tap lock: jab tak action chal raha ho button band), poll **har 25 sec jab app khuli ho** (background mein band), naya order aane par list + dashboard taza + halki awaaz + vibration + "Naya order aaya hai!" message, Orders tab ka badge ab orders ki asli ginti se.
- `lib/services/api.dart` - `orders()`, `orderAction()`, `ordersPoll()`. `lib/utils.dart` - `agoText`, `dateTimeText`. `lib/screens/shell.dart` - Orders tab asli screen se, app resume/pause par poll.
- Version `0.5.0+5`.

## Files
- NEW  `app/tests_vendor_orders.py`, `vendor_app/lib/models/orders.dart`, `vendor_app/lib/screens/orders.dart`, `docs/VENDOR_PHASE5.md`
- EDIT `app/customer/views_vendor_api.py` (V5 section), `app/urls.py` (3 routes), `vendor_app/lib/{utils,services/api,services/app_state,screens/shell}.dart`, `vendor_app/pubspec.yaml`, `vendor_app/README.md`

## Kaise test karein
1. Backend: `python manage.py test app.tests_vendor_orders app.tests_vendor_dashboard app.tests_vendor_api app.tests_vendor_push` (migration koi nahi). Deploy ke baad `Django CI/CD` ka log aur ntfy alert dekhein.
2. API (Postman): login se token -> `GET /api/vendor/orders/?tab=new` -> `POST /api/vendor/orders/<id>/accept/` body `{"prep_minutes": 20}`. Web "Orders" page se status milayein.
3. App: Actions > **Build Vendor APK** > Run workflow > artifact `vendor-apk` > phone mein install.
4. Customer side se naya order dein -> app khuli ho to 25-30 sec mein khud aaye (awaaz + vibration), Naye tab + badge. Qubool (time chunein) -> "Chal rahe" -> Tayyar -> Deliver -> "Mukammal". Reject: wajah chunein.
5. Do phone / app + web se ek hi order par action karein -> ek chale, doosre ko saaf message aur list taza.

## Test checklist (Master Plan)
- [ ] Accept/Reject/Ready/Delivered web jaisa hi status badlein.
- [ ] Doosre vendor ka order action 404.
- [ ] Unapproved vendor action na kar sake.
- [ ] Ek hi order par do phone se action -> ek hi chale, doosre ko saaf message.

## Note
Push (app band ho tab alert) Phase V7 mein aayega; V5 mein naya order sirf app khuli ho tab poll se aata hai.

## Agla: Phase V6 (Order detail + live tracking - `orders/<id>/`, `orders/<id>/track/`, `assign-rider/`)
