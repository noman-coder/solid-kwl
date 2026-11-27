# Rider App - Phase 7: Wallet tab (cash handover + kamai)

Sirf Flutter (`rider_app/`). Backend, migrations, web portals waise hi - Phase 1-2 ke API (`/api/rider/wallet/`, `/cash/handover/`, `/cash/handovers/`) use hoti hain. Naye packages nahi. Version 1.4.0+5.

## Wallet tab
- **Cash in hand (COD)** bara card + cash limit (Rs 5,000) ki progress bar (hari / peeli / laal). Hadd poori ho to laal notice.
- **Cash handover** button -> Handover screen. Cash na ho to button band.
- **Kamai milni hai (due)** aur **ab tak mil chuki** cards; **Kamai**: aaj / is hafta / is mahina (deliveries + Rs).
- **Mere handovers**: Pending / Confirm / Reject chip, receiver (Admin ya vendor ka naam), raqam, tareekh. Reject par wajah + "raqam aap ke paas hi hai".
- **Vendor-wise cash**: collect hua / vendor ko diya / baqi (+ pending confirm).
- **Hisab ki history**: cash jama hua (cash_in) aur kamai ada hui (payout).
- Pull-to-refresh. Tab khulne par, deliver hone par, aur pending handover ho to har 20 sec mein khud refresh (receiver confirm kare to jald dikhe).

## Handover screen
- Receiver: **Admin** ya **Vendor** (vendor sirf wahi jin ke COD orders rider ne deliver kiye; vendor chips + us ka baqi cash).
- Raqam: shuru mein poora available cash; partial allowed; "Poora" button. Limit = cash in hand - pending (server wali hi limit).
- Note (optional). Bhejne se pehle confirm dialog. Double tap se bachao (busy flag; server bhi 15 sec ka double-submit rokta hai).
- Kaamyabi par toast, wallet + dashboard dobara load. Receiver ke confirm tak status "Pending".

## Files
- NEW  `models/wallet.dart`, `screens/handover.dart`
- EDIT `screens/wallet.dart` (poora naya), `pubspec.yaml` (version), `README.md`

## Test (asli phone)
1. COD order deliver karein -> Wallet mein cash in hand barhe.
2. Handover (Admin, partial) -> Pending dikhe; admin web par Confirm -> 20 sec mein "Confirm" + cash in hand kam.
3. Handover vendor ko -> vendor portal par notification, Confirm par hisab update.
4. Reject -> rider ko wajah, cash rider ke paas hi.
5. Zyada raqam / double tap -> error ya sirf ek handover. Internet band -> error card, app chale.
6. Cash Rs 5,000 se upar -> laal notice (Orders mein Accept band, Phase 5 se).

## Agla: Phase 8 (Profile tab)
