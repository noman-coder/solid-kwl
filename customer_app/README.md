# Customer App (Khanewal Connect - Android)

Grahak (customer) ke liye app. Vendor app (`vendor_app/`) aur rider app ke dhanche par; backend JSON API `api/customer/...`
(`app/customer/views_customer_api.py`). Phase wise ban rahi hai (plan: `docs/Customer_App_Master_Plan.pdf`).

**Abhi: Phase C7 (Cart)** - Product / store / search ke "+" ab asli cart mein dalte hain. Cart tab: item card (qty stepper, swipe se
hatao + "Wapas"), subtotal, delivery fee, minimum order warning, free-delivery bar (jahan web deta hai), "qeemat badal gayi" aur "stock
khatam / store band" alert, tab par badge. Guest ka cart phone mein rehta hai aur login par server cart mein jud jata hai. Ek waqt mein
ek store. "Checkout karein" abhi C8 ka intezar karta hai.
Backend: `app/customer/views_customer_cart.py` (+ nayi table `CustomerCart`, migration 0066) - `docs/CUSTOMER_PHASE7.md`.
Pehle: C3 (Flutter foundation + APK build) - `docs/CUSTOMER_PHASE3.md`; C4 (Area + Home) - `docs/CUSTOMER_PHASE4.md`;
C5 (Stores) - `docs/CUSTOMER_PHASE5.md`; C6 (Products: search, detail) - `docs/CUSTOMER_PHASE6.md`.

- App ka naam (placeholder): **Customer App** - `.github/workflows/build_customer_apk.yml` ke `env: APP_NAME` se.
- Package: `com.khanewal.customer.app` (`env: APP_ID`). Server: `env: API_BASE` (app mein kahin dikhta nahi).
- Build: GitHub > Actions > **Build Customer APK** > artifact `customer-apk`. Push ke liye secret `GOOGLE_SERVICES_JSON_CUSTOMER`.
- Static jaanch: `python3 tool/check_app.py`.
