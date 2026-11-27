# Rider App - Phase 5: Dashboard + Orders tabs

Sirf Flutter (`rider_app/`). Backend, migrations, web portals waise hi. Naye packages nahi. Version 1.2.0+3.

## Dashboard tab
Online switch + aaj ke numbers (OnlineCard), server ki warnings (cash limit, pending / rejected handover), GPS / internet ke cards,
naye offers ka tile (dabane par Orders > Naye), active orders (dabane par detail), Aaj / Hafta / Mahina kamai,
Cash in hand (limit ki progress bar) + due, rating, pichle 7 din ka bar chart (bagair package). Pull-to-refresh.

## Orders tab (3 sub-tabs)
- **Naye (n)**: offers + Accept. Offline ho to "Online hon" button. Cash limit poori ho to Accept band + laal notice.
- **Active (n)**: mere orders + Maal le liya / Deliver (COD / Paid dialog).
- **History**: Sab / Delivered / Cancelled, date range, summary (deliveries, kamai, cash), "aur dikhayein" + scroll par agla page.
- Card dabane par **Order detail**: COD / Paid banner, status stepper (Accept > Maal le liya > Deliver), store + customer
  (Map / Call / WhatsApp), items + total + fee, order ki history, neeche Navigate + action button.

## Naya order alert
Sound + do dafa vibration + toast ("Dekhein" button seedha Naye tab kholta hai) + Orders icon par badge.

## Files
- NEW  `screens/order_detail.dart`, `screens/history_tab.dart`
- NEW  `models/dashboard.dart`, `models/history.dart`, `models/order_detail.dart`
- NEW  `widgets/week_chart.dart`, `widgets/status_stepper.dart`, `widgets/deliver_dialog.dart`
- EDIT `screens/dashboard.dart`, `screens/orders.dart`, `screens/shell.dart`
- EDIT `services/app_state.dart` (dashboard, tab navigation, AppEvent toast, run() ab true/false deta hai), `widgets/order_card.dart` (onTap), `utils.dart`

## Dhyan do
- Backend `api_accept` abhi cash limit (Rs. 5,000) ko khud nahi rokta - app mein Accept band hota hai, magar server par rok nahi.
  Chahein to ek chhota backend step (api_accept mein limit check) alag se laga sakte hain.
- WhatsApp link Pakistani number (03xx -> 92...) ke hisaab se banta hai.

## Test (asli phone)
1. Dashboard: numbers, 7-din chart, warnings; pull-to-refresh.
2. Offline > Orders > Naye: "Online hon" button. Online hone par offers aayen; naya offer aaye to sound + vibration + toast.
3. Accept (card ya detail se) > Active mein chala jaye > Maal le liya > Deliver (COD dialog) > History mein dikhe, Dashboard ke numbers badlein.
4. Order detail: stepper, Call, WhatsApp, Map / Navigate.
5. History: filter + date range + agla page.
6. Internet band: laal error card, crash nahi. Web rider portal / vendor / admin pehle jaisa.

Agla: Phase 6 (Map tab - live location + route).
