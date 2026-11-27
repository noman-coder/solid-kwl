# Vendor App - Phase V2: Vendor push token + naya order alert (backend)

Sirf backend. Flutter app mein koi kaam nahi (push ka app hissa Phase V7 mein). Database: **additive migration 0061** (sirf 1 nayi table).

## Kya bana
- **Model** `VendorPushToken` (`app/models/trade/vendor_push.py`): profile (VendorProfile), token (unique), device, platform, created/updated. Ek vendor ke max 5 phone; ek token ek hi vendor ka (doosra vendor usi phone par login kare to token us ka ho jata hai).
- **Migration** `0061_vendor_push_token.py`: sirf CreateModel. Koi drop / rename / RunSQL nahi.
- **API** `POST /api/vendor/push-token/` body `{token, platform?, device?}` (approved vendor, Bearer token). Ghalat token -> 400. `POST /api/vendor/logout/` body `{push_token}` -> sirf usi phone ka token hat jata hai.
- **`app/vendor_push.py`**: FCM sender `rider_push.py` ka hi (dobara nahi likha). `notify_vendor(vendor, title, body, data)` + events:

| Event | Kab | Channel | data.type |
|---|---|---|---|
| Naya order | order bante hi (`store_orders.notify_vendor_new_order`, web + auth wale dono raste) | `new_orders` | `new_order` |
| Customer ne cancel kiya | customer cancel view (vendor ke apne reject par push nahi) | `updates` | `order_cancelled` |
| Rider cash handover | rider ne vendor ko cash bheja | `updates` | `rider_cash` |
| Naya review | customer ne store ko rating di | `updates` | `review` |
| Stock kam / khatam | vendor ke product ka stock `low_stock_threshold` se neeche / 0 (signal on Inventory) | `updates` | `low_stock` / `out_of_stock` |

- Stock alert **din mein ek dafa** har product ka har qism ka (kam / khatam alag). Naya Inventory row (naya product add) nazar-andaz.
- Order wale events transaction commit ke **baad** aur background thread mein jate hain. Har hook try/except mein: push fail ho (galat token, FCM down) to order / rating / handover phir bhi ban jata hai.
- `FCM_SERVICE_ACCOUNT_JSON` na ho to server crash nahi karta: ek dafa log, push chhod di jati hai.
- Dead token (app uninstall) FCM batate hi DB se hat jata hai.
- **Command** `python manage.py test_vendor_push 03211234567 [--channel new_orders|updates]`.
- `rider_push.py` mein sirf 2 optional parameter (`channel_id`, `ttl`) jore gaye; default wahi, rider ka behaviour jyon ka tyon.

## Files
- NEW  `app/models/trade/vendor_push.py`, `app/migrations/0061_vendor_push_token.py`, `app/vendor_push.py`, `app/vendor_push_signals.py`, `app/management/commands/test_vendor_push.py`, `app/tests_vendor_push.py`, `docs/VENDOR_PHASE2.md`
- EDIT `app/models/__init__.py` (1 line), `app/apps.py` (1 line), `app/urls.py` (1 route), `app/rider_push.py` (optional params), `app/customer/views_vendor_api.py` (push-token + logout), `app/customer/store_orders.py` (new order hook), `app/customer/views_customer_portal.py` (cancel hook), `app/customer/views_rider_api.py` (cash hook), `app/customer/views_reviews.py` (review hook)

## Kaise test karein
1. Deploy ke baad migrate log mein `0061_vendor_push_token` OK dekhein. Tests: `python manage.py test app.tests_vendor_push app.tests_vendor_api app.tests_rider_push`.
2. Token API (Postman / curl): login se token lo, phir `POST /api/vendor/push-token/` `{"token":"<kam az kam 20 chars>"}` -> `{"ok":true}`.
3. Asli push (Phase V7 ki app ke baad, ya Firebase console se mila token DB mein daal kar): `python manage.py test_vendor_push 03xxxxxxxxx` -> `sent=1`.
4. Naya order banao (customer side) -> vendor ke token par push; galat/purana token ho to bhi order ban jaye.
5. `FCM_SERVICE_ACCOUNT_JSON` hata kar order banao -> order theek, log mein sirf "Vendor push band hai".

## Agla: Phase V3 (Flutter foundation + APK build)
