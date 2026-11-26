# Vendor App - Phase V13-A: Coupons

**Database:** koi migration nahi. `Coupon` / `CouponRedemption` (migration 0056) pehle se hain. Agla migration abhi bhi **0064** (Offers - V13-B - ke liye).
Purani web / rider API aur JSON keys nahi badli. Web ka `vendor_coupons` page waise hi chalta hai.

**Offers (product par offer price / badge + tareekh) is phase mein nahi hain.** Plan ke mutabiq woh alag sub-step (V13-B) hai, additive migration ke saath,
kyunke woh customer ki price / checkout ko chhoota hai. Coupons poori tarah tayyar hain.

## Backend (Django) - `app/customer/views_vendor_api.py`
| Endpoint | Kaam |
|---|---|
| `GET /api/vendor/coupons/` | `summary` (ginti: chalu / jald shuru / expire / band, kul istemal, ab tak di gayi chhoot) + `coupons[]` (apne, naya pehle, zyada se zyada 50) |
| `POST /api/vendor/coupons/` | naya coupon. `request_key` (optional) bhejein to retry / double tap par dobara coupon nahi banta |
| `POST /api/vendor/coupons/<id>/` | coupon badlein (code kabhi nahi badalta) |
| `POST /api/vendor/coupons/<id>/toggle/` | body `{active: true/false}` (seedha value: retry par ulta nahi hota); na dein to ulta kar deta hai |
| `POST /api/vendor/coupons/<id>/delete/` | istemal na hua ho to delete; istemal ho chuka ho to sirf **band** (`deleted: false`) |

Coupon ke fields: `code, title, discount_type (percent|fixed|free_delivery), value, max_discount, min_order, usage_limit, per_customer_limit (0 = be-had),
first_order_only, valid_from, valid_until (YYYY-MM-DD)`. Jawab mein `status`, `used`, `remaining`, `given`, `core_locked`, `share_text` bhi.

- **Logic dobara nahi likhi:** validation web wali `views_coupons._clean_vendor_coupon` (code 3-20 harf / number aur unique, percent max 70, tareekhein, limits).
  Us mein 2 chhoti additive tabdeeliyan: `exclude_pk` (edit par apna code "duplicate" na ginay) aur `NaN / Infinity` par crash ki jagah saaf error. Web par koi asar nahi.
- **Checkout par wahi engine:** app se bana coupon `coupons.evaluate` se chalta hai (store ka mel, min order, limits, expiry, first order) - customer side par kuch nahi badla.
- **Ownership:** sirf `vendor=profile.vendor` ke coupons. Doosre vendor ka ya poori-shop (admin) coupon = **404**. Unapproved vendor = 403.
- **Istemal ho chuke coupon par** code / qism / value / max discount nahi badalte (customer ko jo vada kiya wahi rahe); title, min order, limits, tareekhein badal sakte hain.
  `usage_limit` ab tak ke istemal se kam nahi ho sakta.
- **Delete:** coupon row lock hoti hai (`select_for_update`), isi waqt koi order redeem kare to uska record cascade mein na urre. Cancelled order wali redemption ginti mein nahi.
- Tests: `app/tests_vendor_coupons.py`.

## App (Flutter) - version 0.13.0+14
- **More > Promotion > Coupons.**
- Screen: upar 2 cards (Chalu coupons / Ab tak chhoot di), filter chips (Sab / Chalu / Expire / Band), coupon cards: code, status, label (50% off ...), rules,
  expiry ("3 din baqi"), usage bar (kitne istemal / kitne baqi), ab tak di gayi chhoot, **chalu/band switch**, **code copy**, **WhatsApp share**, menu (badlein / delete).
- **Naya coupon / badlein:** qism (Percent / Rs / Free delivery), value, max discount, kam az kam order, kul istemal, har customer, sirf pehla order, tareekhein
  (date picker). Upar **live preview** ("Customer ko aise dikhega"). Ghaltiyan server ki saari list ek saath dikhti hain.
- Double-tap lock, pull-to-refresh, skeleton, empty state, error + retry, net band par purani list + message, delete par confirm.
- **Sust net / VPN:** GET requests (list, dashboard, orders ...) timeout par ek dafa khud dobara try hoti hain; message saaf ("Net / VPN check karein").
  POST (save, confirm, accept ...) kabhi khud dobara nahi bheje jate, taake double action na ho.
- Naye / badle files: `lib/screens/coupons.dart`, `lib/models/coupons.dart`, `Api.coupons / saveCoupon / setCouponActive / deleteCoupon`,
  `ApiException.errors`, `screens/more.dart`. Naya package koi nahi.

## Test (5 steps)
1. Server: `python manage.py test app.tests_vendor_coupons app.tests_coupons` (migrate ki zaroorat nahi).
2. App: More > Coupons > **Naya coupon**: code `WELCOME20`, 20 %, max Rs 150, kam az kam Rs 500, sirf pehla order. Preview card dekhein, save karein: list mein card aaye.
3. Customer app / web par us store ke cart (Rs 500+) par `WELCOME20` lagayein: discount lage. Switch **Band** karein: ab "coupon band hai" aaye. Dobara Chalu karein.
4. Ek order is coupon se karein, phir app mein coupon **Badlein**: code / qism / value band (lock) ho, title / limits badal jayen. **Delete** par "band kar diya" aaye (delete nahi), purana order ka discount record wahi rahe. Istemal na hua coupon delete ho jaye.
5. Share icon se WhatsApp khule (code + shart likhi hon). Net band karke screen kholein: purani list + message aaye. Doosre vendor ka coupon kabhi na dikhe.
