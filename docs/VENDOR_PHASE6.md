# Vendor App - Phase V6: Order detail + live tracking (backend + app)

Backend API + Flutter Order Detail screen. **Database mein koi tabdeeli nahi** (migration abhi bhi **0061**). Purana web portal, rider app/API aur
V1-V5 ki API bilkul nahi chhedi (sirf 3 nayi routes, jo purane `orders/<id>/<action>/` route se PEHLE rakhi hain taake `track` / `assign-rider`
usay `action` na samjha jaye).

## Backend (NEW routes, sab `@vendor_api`: Bearer token, approved vendor, sirf apna data)
| Route | Kaam |
|---|---|
| `GET /api/vendor/orders/<id>/` | Order ka poora detail |
| `GET /api/vendor/orders/<id>/track/` | Rider ki taza location (sirf delivery chal rahi ho tab) |
| `GET /api/vendor/orders/<id>/assign-rider/` | Dene layak riders (online pehle, kam masroof pehle) |
| `POST /api/vendor/orders/<id>/assign-rider/` | Body `{rider_id}` - rider dena |

Naya business logic nahi likha:
- **Detail**: V5 ka `_order_json` + `items[]` (naam, qty, rate, total, **image**), `customer{..., lat, lng}`, `coupon{code, discount}`, `commission{percent, base, amount, vendor_gets, estimated}`, `steps[]` (Naya > Qubool > Tayyar > Raste mein > Deliver; reject par Naya > Reject), `timeline[]` (`OrderTracking`), `rider{name, phone, vehicle, status}`, `can_track`, `can_assign_rider`, `store_point`, `whatsapp_url` (`store_orders.whatsapp_link`). Commission **andaza** hai (items discount ke baad x vendor ka commission %); asli hisaab bill banne par.
- **Track**: wahi `RiderLiveLocation` jo customer ke map ko milti hai. `active:false` + `reason` (`no_rider` = "Rider abhi assign nahi hua", `not_started`, `finished` = order mukammal/reject) - in surtaon mein **location bheji hi nahi jati**. Active ho to `pos`, `age_sec`, `stale` (2 min se purani), `store`, `dest`, `rider{name, phone}`.
- **Rider dena**: `views_rider_portal._assign` (web `vendor_assign_rider` ke wahi rules): sirf **Ready** order par; rider maal utha chuka ho to badal nahi sakte; `transaction.atomic` + `select_for_update`; rider ko notification. Conflict par **409** + order ki taza haalat. Band/ghalat rider -> 404/400.
- **Privacy**: har endpoint par `vendor=profile.vendor`; doosre vendor ka order -> **404** (customer ka phone / location / rider ki location kabhi nahi milti). Unapproved -> 403, bina token -> 401.

## App (Flutter)
- `lib/models/order_detail.dart` (NEW) - `OrderDetail`, `TrackData`, `RiderList`, `StepInfo` ...
- `lib/screens/order_detail.dart` (NEW) - order card par tap se khulta hai: status stepper, **live map**, rider card (call, **Rider dein / badlein** sheet), customer card (Call / WhatsApp / Map), items (photo ke saath), payment + commission andaza, history. Neeche Qubool / Reject / Tayyar / Deliver buttons (card wali wahi logic, `runOrderAction`).
- `lib/widgets/status_stepper.dart`, `lib/widgets/live_map.dart` (NEW) - OpenStreetMap (free, `flutter_map`), store / customer / rider markers, "poora route" button. Map **har 12 sec** rider ki location leta hai (detail har ~36 sec); app background mein jaye to timer band. Order band hone par map khud hat jata hai. Location 2 min se purani ho to warning.
- `lib/screens/orders.dart` - card tap -> detail; sheets/actions public (`runOrderAction`, `AcceptSheet`, `RejectSheet`); behaviour pehle jaisa.
- `lib/services/api.dart` - `orderDetail`, `orderTrack`, `riders`, `assignRider`. `app_state.dart` - `handleApiError`, `ordersChanged`.
- `pubspec.yaml`: `flutter_map`, `latlong2`; version `0.6.0+6`. Koi nayi Android permission nahi (vendor ko GPS nahi chahiye).

## Files
- NEW  `app/tests_vendor_detail.py`, `vendor_app/lib/models/order_detail.dart`, `vendor_app/lib/screens/order_detail.dart`, `vendor_app/lib/widgets/{status_stepper,live_map}.dart`, `docs/VENDOR_PHASE6.md`
- EDIT `app/customer/views_vendor_api.py` (V6 section), `app/urls.py` (3 routes), `vendor_app/lib/{utils,services/api,services/app_state,screens/orders}.dart`, `vendor_app/pubspec.yaml`, `vendor_app/README.md`

## Kaise test karein
1. Backend: `python manage.py test app.tests_vendor_detail app.tests_vendor_orders app.tests_vendor_dashboard app.tests_vendor_api app.tests_vendor_push` (migration koi nahi).
2. API (Postman): login > `GET /api/vendor/orders/<id>/` > Ready order par `GET .../assign-rider/` phir `POST .../assign-rider/` `{"rider_id": 1}` > `GET .../track/`.
3. App: Actions > **Build Vendor APK** > artifact `vendor-apk` > install. Orders mein kisi card par tap karein.
4. Rider app se order accept karwayein aur chalayein: vendor ke detail mein map par rider hilta dikhe (12 sec mein). Rider na ho to "Rider abhi assign nahi hua"; order deliver/reject ho to map hat jaye.
5. Doosre vendor ke order ka id API mein dein -> 404. Customer ka phone sirf us vendor ko jise order mila.
