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
