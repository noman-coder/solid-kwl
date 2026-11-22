# Traffic Analytics (admin)

Menu: People -> Traffic Analytics   (URL: /traffic-analytics/, permission: view_analytics)

Tracked (shop only, bots and staff are skipped):
- Page views, unique visitors, device, traffic source (Facebook/WhatsApp/Google/direct...), peak hours
- Product views, add-to-cart / buy-now
- Every search keyword, even when no product matches (results = 0 -> "Not Found" list)
- Orders come from the existing CustomerOrder tables (cancelled orders excluded)

Database safety:
- Migration 0051 only CREATES 3 new tables (ShopTrafficEvent, ShopSearchLog, ShopTrafficDaily).
  No existing table or column is changed or dropped.
- Raw rows are kept 90 days. After that they are first saved as a daily summary
  (ShopTrafficDaily, kept forever) and only then removed. This runs automatically once a day
  when the dashboard is opened, or manually:  python manage.py cleanup_shop_traffic [--dry-run]
- Tracking errors are caught: a tracking problem can never stop a shop page or an order.

## v2 additions
- **Not Found -> Action**: har 0-result keyword par "Action": maujooda product se alias jodein (shop search ab alias bhi dhoondti hai),
  naya product banayein (naam pehle se bhara aata hai) ya Ignore karein. Sirf ENTRY add hoti hai, kuch delete nahi hota.
- **Daily email**: roz subah 8 baje ke baad pehle visitor par kal ki summary email (receiver = GitHub secret `SUMMERY_REC`,
  kai address comma se). Din mein aik hi baar (ShopTrafficMailLog). Manual: dashboard ka button ya
  `python manage.py send_traffic_summary [--date YYYY-MM-DD] [--to a@b.com]`.
- **Area-wise traffic**: visitors / product views / cart / orders / order value har area ke hisaab se.
- **Export**: Excel (6 sheets) aur CSV (daily, products, searches, notfound, areas).
- Migration `0052`: apne hi naye table mein 1 column + 2 naye tables. Purana kuch change/drop nahi.

## v3 additions
- **Orders fix**: shop ke asli orders `SaleOrder` ("WEB ORDER" note) hain; dashboard ab wahi gintha hai (cancelled shamil nahi).
- **Abandoned carts**: cart mein dala, 1 ghante baad bhi order nahi. Login customer ka naam/phone + WhatsApp follow-up button
  ("Manage Orders" permission chahiye). Follow-up ka nishan lagta hai. Guest ka phone nahi hota.
- **Checkout drop-off**: visitors -> product -> cart -> cart page -> checkout -> order, har qadam par kitne gaye, aur seedhi salaah.
- **Naye vs wapas aane wale**: 1 saal ki cookie `kc_vid` se (ShopVisitor table, kabhi delete nahi hota).
- **Banner performance**: banner click `/shop/banner/<id>/go/` se guzar kar asli link par jata hai; clicks aur CTR.
- **Store performance**: har store ke page views, product views, cart, orders, revenue.
- **Broken links (404)**: jo pages customers ko nahi mile (bots/scanners/images ke 404 shamil nahi). "Theek ho gaya" se list se chhup jata hai.
- **"Aksar saath khareeda jata hai"**: product page par section (orders se, kam hon to saath dekhe gaye products se; 6 ghante cache).
  Dashboard mein top jodiyan (bundle ideas).
- Migration `0053`: apne traffic table mein naye columns + 3 naye tables. Purana kuch change/drop nahi.
