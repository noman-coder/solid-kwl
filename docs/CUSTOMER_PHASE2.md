# Customer API - Phase C2 (push token + order status alerts, backend)

Files: `app/customer_push.py` (bhejne ka kaam) | `app/customer_push_signals.py` (status hooks) |
`app/models/trade/customer_push.py` (`CustomerPushToken`) | `app/customer/views_customer_api.py` (`api_push_token`, logout) |
`app/management/commands/test_customer_push.py` | Tests: `app/tests_customer_push.py`.
Migration: **0065_customer_push_token** (sirf `CreateModel`, 1 nayi table; master plan mein 0064 likha tha lekin 0064 vendor offers
le chuka hai, is liye 0065). Customer inbox table (C16) ab **0066** se.

## API

| Endpoint | Method | Auth | Kaam |
|---|---|---|---|
| `/api/customer/push-token/` | POST | token | body `{token, platform?, device?}` -> `{ok:true}`. Save / refresh (dobara bhejne par naya row nahi). Ghalat token -> 400 `bad_token`. |
| `/api/customer/logout/` | POST | token | body `{push_token}` (ya `{token}`) bhejein to **sirf is customer ka** wo token hat jata hai. Body khali ho to bhi `ok`. |
| `/api/customer/reset-password/` | POST | - | kamyabi par us customer ke **sab** push token hat jate hain (purane login band hue). |

Token ke qaide: 20-255 characters, beech mein space nahi. Token **ek hi customer** ka hota hai (doosra customer usi phone par login kare to
token us ka ho jata hai). Ek customer ke zyada se zyada **5 phone**; 6th par sab se purana khud hat jata hai.
Customer ka web account delete ho to (`views_account_deletion.delete_account_customer`) us ke token bhi hat jate hain.

## Kab push jati hai

Order ka customer jis ne customer app mein login karke token register kiya ho. Status kahin se bhi badle (vendor app, vendor portal,
admin, rider app, customer cancel) - signal pakad leta hai; purane views mein koi tabdeeli nahi.

| Hua kya | `data.type` | Title |
|---|---|---|
| Vendor ne accept (`confirmed`) | `order_accepted` | Order #.. qubool ho gaya (taqreeban N minute) |
| `cancelled` + `reject_reason` bhari (vendor reject) | `order_rejected` | Order #.. qubool nahi hua (wajah ke saath) |
| `cancelled` bina wajah (customer / admin cancel) | `order_cancelled` | Order #.. cancel ho gaya |
| `ready` | `order_ready` | Order #.. tayyar hai (pickup order par "le jayein") |
| Rider assign hua / badla (`DeliveryInfo` -> `assigned`) | `rider_assigned` | Rider mil gaya (rider ka naam) |
| `picked_up` ya `in_transit` | `order_on_the_way` | Order raste mein hai (dono ke liye ek hi push) |
| `delivered` | `order_delivered` | Order pahunch gaya |

`data` mein hamesha `type`, `order_id`, `order_no` (C11: tap par Order Detail). Channel `order_updates`, TTL 6 ghante.
`processing`, `partially_delivered`, `invoiced` par push nahi.

Qaide: transaction commit ke **baad**, background thread mein; har function try/except mein (push fail ho to order kabhi nahi rukta);
ek order ka ek event 24 ghante mein ek dafa (cache dedupe; rider badle to naya push); jis customer ke paas token nahi us ke liye kuch nahi hota.
`FCM_SERVICE_ACCOUNT_JSON` na ho to server crash nahi karta, sirf ek dafa log likhta hai.

Naya coupon / offer push (optional): `customer_push.notify_customer(customer, title, body, data, channel=customer_push.OFFERS_CHANNEL)`
tayyar hai; C13 (coupons/offers) mein jahan coupon bante hain wahan se bulayein. Abhi koi coupon hook nahi lagaya.

## Test kaise karein (5 line)

1. Deploy ke baad migrate log mein `0065_customer_push_token` OK dekhein.
2. Customer app (C3/C11 ke baad) mein login karein, phir server par: `python manage.py test_customer_push 03XXXXXXXXX`
   (`--channel offers` se offers channel). Output: `tokens=1 sent=1 failed=0 dead_removed=0`.
3. Vendor app se us customer ka order Accept karein -> customer ke phone par "qubool ho gaya".
4. FCM secret hata kar order accept karein -> order ka status phir bhi badle, log mein sirf "Customer push band hai".
5. Backend tests: `python manage.py test app.tests_customer_push app.tests_customer_api -v 2`.

Is phase mein Flutter app ka koi kaam nahi (push ka app hissa C11 mein).
