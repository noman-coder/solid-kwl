# Vendor App - Phase V12: Rider cash handover (receive / confirm)

**Database:** koi migration nahi. `RiderCashHandover` (migration 0058) aur `RiderSettlement` pehle se hain. Agla migration abhi bhi **0064**.
Purani web / rider API aur JSON keys nahi badli. Web ka `vendor_rider_cash` page waise hi chalta hai.

## Backend (Django) - `app/customer/views_vendor_api.py`
| Endpoint | Kaam |
|---|---|
| `GET /api/vendor/rider-cash/?page=` | `summary` (pending ginti + raqam, ab tak confirm jod, reject ginti), `pending` (page 1 par, sab, naya pehle), `history` (confirm / reject, 20 ek page, `has_more`) |
| `POST /api/vendor/rider-cash/<id>/confirm/` | cash mil gaya: `RiderSettlement(cash_in)` banti hai, rider ka cash-in-hand kam hota hai |
| `POST /api/vendor/rider-cash/<id>/reject/` | body `{reason}` (zaroori, max 200). Raqam rider ke paas hi rehti hai, wajah rider ko jati hai |

- **Logic dobara nahi likhi:** `rider_cash_service.confirm_handover / reject_handover` (web wali wahi) - `transaction.atomic` + `select_for_update`,
  double tap / do phone se confirm par sirf ek settlement, confirm ke baghair rider ka balance nahi badalta.
- **Ownership:** sirf `receiver='vendor'` aur `vendor=profile.vendor` ke handovers. Doosre vendor ya admin ka handover = **404** (`not_found`). Unapproved vendor = 403.
- **Raqam ki dobara tasdeeq (optional):** body mein `amount` bhejein; handover ki raqam isse alag ho to **409** `changed` (galat raqam confirm nahi hoti). App hamesha bhejti hai.
- Pehle hi confirm / reject ho chuka, ya rider ke paas ab itna cash hisab mein nahi = **409** `handover` (service ka saaf message).
- Naya handover aane par push (`vendor_push.notify_rider_cash`, V2) pehle se rider API se judi hai; tap par app seedha Rider cash screen kholti hai.
- Tests: `app/tests_vendor_cash.py`.

## App (Flutter) - version 0.12.0+13
- **More > Paisa > Rider se cash** (confirm baqi ho to badge + raqam). Dashboard ke "Rider cash confirm karna baqi" card par tap bhi yahin khulta hai.
- Screen: upar 2 cards (Confirm baqi / Ab tak mila), **pending cards** (rider ka naam, call button, raqam, note, kin orders ka cash, kitni der pehle),
  **Confirm** (dialog mein raqam dobara dikhti hai) aur **Reject** (wajah ke chips ya apna text, wajah zaroori), neeche **history** (infinite scroll, reject par wajah).
- Double-tap lock (action ke dauran dono button band), pull-to-refresh, skeleton, empty state, error + retry, net band par purana data + message.
  Raqam badal gayi / pehle hi confirm ho chuka ho to message dikha kar list khud taza.
- Confirm / reject ke baad dashboard ka cash badge khud taza. **Push** `rider_cash` par tap = seedha yahi screen.
- Naye / badle files: `lib/screens/rider_cash.dart`, `lib/models/rider_cash.dart`, `Api.riderCash / riderCashAction`, `AppState.cashChanged`,
  `screens/more.dart`, `screens/dashboard.dart`, `screens/shell.dart`, `services/push.dart` (`isRiderCash`). Naya package koi nahi.

## Test (5 steps)
1. Server: `python manage.py test app.tests_vendor_cash app.tests_vendor_dashboard app.tests_vendor_push app.tests_rider_cash` (migrate ki zaroorat nahi).
2. Rider app se vendor ko cash handover bhejein (misal Rs 3000): vendor ke phone par push aaye; tap karein to Rider se cash screen khule, card par Rs 3000 aur rider ka naam.
3. **Confirm** (dialog mein raqam dekh kar): card history mein chala jaye, "Ab tak mila" barhe, dashboard ka badge ghate; rider app / admin mein rider ka cash-in-hand utna kam ho.
4. Doosra handover **Reject** karein: wajah ke baghair button na chale; wajah ke saath reject ho, rider ko wajah dikhe, rider ka balance **wahi** rahe.
5. Do phone par ek hi vendor login karke ek handover par saath confirm: ek chale, doosre ko "pehle hi confirm ho chuka" message aaye. Doosre vendor ka handover kabhi na dikhe.
