# Vendor App - Phase V11: Sales, cash & profit tab

**Database:** migration **0063** - `Product.purchase_rate` (nullable DecimalField, sirf AddField; koi drop/rename/RunSQL nahi).
Purani products ka rate NULL rehta hai, is liye profit "N/A" dikhta hai (galat number nahi). Agla migration 0064.
Purani web/rider API aur JSON keys nahi badli. `views_vendor_tools._analytics_data` mein sirf ek optional `end=None` argument juda
(custom date range ke liye); web ise nahi bhejta, to web ka rawayya bilkul wahi hai.

## Backend (Django) - `app/customer/views_vendor_api.py`
| Endpoint | Kaam |
|---|---|
| `GET /api/vendor/sales/?period=today\|week\|month\|custom&from=&to=` | summary (bikri, orders, avg, commission, net), COD vs Online, profit, din wise chart, top 10, kam chalne wale 5, `lifetime` |
| `GET /api/vendor/sales/statement/?period=...` | din wise kamayi - **sirf mukammal (delivered / invoiced)** orders: bikri, commission, aap ka hissa |
| `GET /api/vendor/sales/orders/?period=...&group=sales\|all\|done\|open\|cancelled&day=&payment=cod\|online&page=` | number par tap karne ka drill-down (order ka JSON wahi jo Orders tab ka hai) |
| `GET /api/vendor/sales/export/?period=...&format=csv\|pdf` | report file (max 5000 orders); CSV mein Excel formula injection se bachao |

- **Numbers web analytics se milte hain:** bikri = cancelled ke baghair orders ke items ka total (`_analytics_data`), commission = bikri - bikri x (100 - %) / 100.
  Muddat: `today` = aaj, `week` = 7 din, `month` = 30 din (web ke ranges jaise); `custom` mein dono tareekhein shamil, aaj se aage ki tareekh aaj par ruk jati hai, zyada se zyada 366 din, ghalat input par saaf 400.
- **Profit:** sirf un items par jin ke product par `purchase_rate` bhara ho. gross = bikri - (qty x purchase_rate); commission = us bikri par %; net = gross - commission.
  Koi product rate wala na ho to `profit.available = false` aur baqi sab `null` (app "N/A"). Aadhe products par rate ho to sirf un ki bikri hisaab mein, aur `products_with_rate / products_total` bhi milta hai.
- **Purchase rate kahan bharte hain:** product add / edit API ab optional `purchase_rate` leti hai (0 se bara, `MAX_PRICE` tak; khali string = hata do; key na bhejein = jo hai wahi). `form-data` mein `product.purchase_rate` bhi aata hai.
  Web portal ka product form nahi badla.
- **Ownership:** har query `vendor=profile.vendor` par; unapproved vendor 403 (`pending`); doosre vendor ka data kabhi nahi.
- Tests: `app/tests_vendor_sales.py`.

## App (Flutter) - version 0.11.0+12
- **Sales tab:** muddat chips (Aaj / 7 din / 30 din / Tareekh chunein), summary cards (bikri, aap ki kamayi, orders, aosat order), din ba din line chart,
  **Cash vs Online donut**, **Munafa (profit) card**, commission ka tafseeli hisaab, top / kam chalne wale products, **Statement**, **Share** (CSV / PDF), ab tak ka poora hisaab.
- Bikri / orders / Cash / Online par tap = **un ke orders ki list** (order par tap = poora detail). Statement ki din wali line par tap = us din ke mukammal orders.
- Purchase rate khali ho to profit card par **N/A** aur batata hai ke kharid rate kahan likhna hai. **Product form > Rate / Stock** mein naya optional field **Kharid rate**.
- Pull-to-refresh, skeleton, empty, error + retry, net band par purana data + "Offline" message (har muddat ka aakhri data phone mein; logout par saaf).
  Sales tab par wapas aane par data 1 minute se purana ho to khud taza.
- Naye / badle files: `lib/screens/sales.dart`, `lib/models/sales.dart`, `lib/widgets/sales_charts.dart`, `Api.sales / cachedSales / salesStatement / salesOrders / salesExport`,
  `utils.dart` (`dateText`, `ymdOf`), `product_form.dart` + `models/products.dart` (kharid rate), `shell.dart` (Sales tab). Naya package: `share_plus`.

## Test (5 steps)
1. Server: `python manage.py migrate` (0063 lage) phir `python manage.py test app.tests_vendor_sales app.tests_vendor_dashboard app.tests_vendor_product_form`.
2. Web vendor portal ke **Analytics** (7 din / 30 din) ke numbers se app ke Sales tab (7 din / 30 din) ki Kul bikri, Orders, Aosat order, Commission milayein.
3. Pehle kisi product par Kharid rate na ho: profit **N/A**. Phir product edit > Rate / Stock mein kharid rate likhein (misal bikri rate 100, kharid 60), us ka order banwa kar Sales dekhein: munafa = (100 - 60) - 10% commission = 30 per unit.
4. "Tareekh chunein" se muddat chunein: chart aur numbers badlein; ek din ka cash / online par tap karke wahi orders ki list dekhein.
5. Share > CSV / PDF: WhatsApp / email mein file khule; Statement mein sirf deliver hue orders ki din wise kamayi ho.
