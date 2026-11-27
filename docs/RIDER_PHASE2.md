# Rider App - Phase 2: Receiver (Admin + Vendor) confirm / reject

Backend only. Koi naya migration nahi (0058 hi kaafi hai). Purani API / JSON keys / web portals waise hi.

## Flow
1. Rider app se handover bheje (Phase 1) -> status `pending`.
2. Receiver confirm / reject kare:
   - **Admin ko diya**: `Riders > rider ka naam` (rider_detail) page par "Pending cash handovers" card.
   - **Vendor ko diya**: vendor portal `/shop/vendor/rider-cash/` ("Rider se cash" button, dashboard par pending badge).
3. **Confirm** -> ek transaction mein `RiderSettlement(kind='cash_in')` banti hai, `handover.settlement` se judti hai,
   `rider_balances().cash_in_hand` kam hota hai. Rider ko notification.
4. **Reject** -> wajah zaroori. Settlement nahi banti, raqam rider ke paas rehti hai. Rider ko wajah ki notification.

## Hifazati qaide
- admin handover sirf superuser decide kare; vendor handover sirf wahi vendor (doosra vendor / admin nahi).
- `select_for_update()` (handover + rider row): double click / double confirm se sirf ek settlement.
- Confirm par check: raqam <= rider ka cash_in_hand (agar admin ne purane "Cash jama" form se pehle jama kar liya ho to
  confirm band, receiver ko reject karne ko kaha jata hai).
- Purana admin "Cash jama" / "Kamai ada" form waise hi chalta hai.

## Files
- NEW  `app/customer/rider_cash_service.py` (confirm / reject logic)
- NEW  `templates/customer_portal/vendor/rider_cash.html`
- NEW  `app/management/commands/remind_pending_handovers.py` (24 ghante pending -> admin reminder, auto-confirm NAHI)
- EDIT `app/customer/views_rider_portal.py` (rider_detail: handover_confirm / handover_reject + context)
- EDIT `app/customer/views_vendor_portal.py` (vendor_rider_cash, vendor_rider_cash_action, dashboard badge)
- EDIT `app/customer/views_rider_api.py` (vendor notification link -> /shop/vendor/rider-cash/)
- EDIT `app/urls.py`, `templates/customer_portal/rider/detail.html`, `templates/customer_portal/vendor/dashboard.html`
- EDIT `app/tests_rider_cash.py` (Phase 2 tests add)

## Test
    python manage.py test app.tests_rider_cash
    python manage.py remind_pending_handovers          # roz ek dafa cron se (--hours 24)

Screens: (1) rider API se handover banao -> admin `/shop/rider/manage/<id>/` par Confirm -> "Hisab ki history" mein
cash_in line, cash card kam. (2) vendor handover -> vendor login `/shop/vendor/rider-cash/` -> Confirm / Reject.
(3) Reject -> `GET /api/rider/cash/handovers/` mein `status=rejected` + `reject_reason`.

Agla: Phase 3 (Dashboard / History / Profile API).
