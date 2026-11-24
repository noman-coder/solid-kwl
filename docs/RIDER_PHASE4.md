# Rider App - Phase 4: Flutter bunyad (foundation)

Sirf Flutter (`rider_app/`). Backend / migrations / web portals ko haath nahi lagaya. Naye packages nahi (pubspec mein sirf version 1.1.0+2).

## Kya bana
- 5 tabs wala bottom `NavigationBar`: Dashboard, Orders, Map, Wallet, Profile (Orders par naye offers ka badge, upar Online/Offline dikhta hai).
- Theme (green 0xFF16A34A, Material 3, light, rounded cards, bari buttons): `lib/theme.dart`.
- Global refresh: `AppState` mein 12-sec timer EK jagah; saare tabs share karte hain (`AppScope.of(context)`). GPS tracking sync, new-order sound/vibration, toast bhi yahin.
- Api layer naye endpoints ke saath extend (purani methods waisi hi): dashboard, history, orderDetail, wallet, handovers, submitHandover, profile, updateProfile, changePassword.
- Common widgets: StatCard, OrderCard, EmptyState, Loading, NoticeCard, OnlineCard, SectionTitle.

## Folders
    lib/main.dart                 app + login/shell ka darwaza
    lib/theme.dart, utils.dart
    lib/models/                   order.dart (RiderOrder, Place, OrderItem), rider.dart (RiderMini)
    lib/services/                 api.dart, tracker.dart (pehle lib/ mein thay), app_state.dart
    lib/widgets/                  empty_state, loading, notice_card, stat_card, section_title, online_card, order_card
    lib/screens/                  login, shell, orders (purani home ka kaam), dashboard / map_tab / wallet (khali), profile (info + logout)

`lib/home.dart` hata diya gaya - uska kaam `orders.dart` + `app_state.dart` + widgets mein chala gaya.

## Dhyan do
- `ApiException.authExpired` naya hai: sirf token ghalat hone par logout hota hai. Ghalat purana password (Phase 8) logout nahi karayega.
- Dashboard / Map / Wallet abhi khali (placeholder) hain - Phase 5 / 6 / 7. Profile mein abhi sirf naam, phone, server, Logout.
- Orders tab abhi purani home jaisa hai (online switch + mere orders + naye orders); Phase 5 mein 3 sub-tabs banenge.

## Test (asli phone / GitHub Action)
1. GitHub > Actions > Build Rider APK > Run workflow (api_base daalein). APK install karein.
2. Login > 5 tabs dikhein, Orders tab purane jaisa chale (Online switch, Accept, Maal le liya, Deliver + COD dialog).
3. Naya offer aaye to Orders icon par badge, sound + vibration + toast.
4. Accept ke baad GPS permission maange, "Live location ON" dikhe.
5. Profile > Logout. Internet band karke pull-to-refresh: laal error card, app crash nahi.
6. Web rider portal / vendor / admin pehle jaisa (backend nahi badla).

Agla: Phase 5 (Dashboard + Orders tabs).
