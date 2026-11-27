# Vendor App - Phase V10: Stock & inventory tools

**Database:** ek nayi table `VendorStockLog` - migration **0062** (sirf CreateModel + AddIndex, koi drop/rename nahi). Agla migration 0063.
Purani web/rider API ya JSON keys nahi badli. Product ki `low_stock_threshold` pehle se maujood thi (per-product), wohi use hui.

## Backend (Django)
| Endpoint | Kaam |
|---|---|
| `GET /api/vendor/stock/?filter=need\|low\|out\|all&q=&page=` | Approved products ka stock (sab se kam pehle), `summary` (kam/khatam/theek), `reserved` + `available`, add/minus ki wajah ki list |
| `POST /api/vendor/stock/adjust/` | `{items:[{id, mode:'add'\|'minus', qty, reason, note?}], request_key?}` (ek product ho to seedha `{id, mode, qty}`); max 50; har product alag transaction |
| `POST /api/vendor/stock/threshold/` | `{id, threshold}` (1 - 1,000,000) - sirf `low_stock_threshold` column badalta hai |
| `GET /api/vendor/stock/history/?product=&page=` | Stock ki tabdeeliyon ka record (kitna tha -> kitna hua, wajah) - sirf apni entries |

- **Logic:** `app/customer/vendor_stock.py`. Add = web quick-update wala `_add_stock` (Inventory + StockBatch, margin rule wahi). Minus = FIFO (purane batch pehle, bikri jaisa) + `Inventory.update_stock`.
  `transaction.atomic` + `select_for_update` (product, inventory, batches).
- **Negative stock nahi:** minus <= (stock - reserved). Doosre vendor / unapproved product par saaf error, kuch nahi badalta.
- **Retry safe:** `request_key` wahi dobara aaye to stock dobara nahi lagta (`status: 'same'`).
- **History:** Stock adjust + quick-update ka "naya stock" (`source=quick_update`) dono `VendorStockLog` mein.
- **Push (V2 ka `notify_vendor`):** order se ya adjust se stock threshold se neeche jaye to wohi purana `check_stock_alert` (din mein ek dafa per product, kam / khatam alag). Naya: roz ek summary
  `vendor_push.notify_stock_summary` (din mein ek dafa per vendor) - management command **`python manage.py vendor_stock_summary [--dry-run]`**, cron / scheduler se roz ek dafa (misal subah 9 baje).
- Tests: `app/tests_vendor_stock.py`.

## App (Flutter) - version 0.10.0+11
- `lib/screens/stock.dart` (naya): Stock screen, add/kam sheet, bulk, hadd sheet, history sheet. `lib/models/stock.dart` (naya). `Api.stock / adjustStock / setStockThreshold / stockHistory`.
- Products tab ki search bar mein Stock nishan (kam + khatam ki ginti ke badge ke saath). Stock push par tap = Stock screen (`stock_summary` type bhi).
- Stock badalne par Products ki lists aur dashboard khud taza (`AppState.stockChanged`).
- Barcode scan (`mobile_scanner`) jaan-boojh kar nahi joda (optional tha, naya native package + camera permission blind build mein risk); search mein barcode kaam karta hai.

## Test (5 steps)
1. Server: `python manage.py migrate` (0062 lage) phir `python manage.py test app.tests_vendor_stock app.tests_vendor_push app.tests_vendor_products`.
2. App (naya APK) mein Products tab -> upar Stock nishan: kam / khatam products ki list aani chahiye.
3. Kisi product par **Stock add** (misal +20, wajah "Naya maal aaya") -> stock badhe, kam/khatam list se hat jaye; History mein record dikhe.
4. **Kam karein** par stock se zyada likhein -> saaf error; theek quantity likhein -> stock ghate; phir `Orders` mein reserved wala stock kam karne ki koshish blocked.
5. Threshold se neeche le jayein -> phone par low-stock push (din mein ek dafa); `python manage.py vendor_stock_summary --dry-run` se summary check karein.
