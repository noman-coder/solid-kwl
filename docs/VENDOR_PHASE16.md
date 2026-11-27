# Vendor Phase V16 - Profile, account & help

## Kya badla
Backend (`app/customer/views_vendor_api.py`, `app/customer/views_account_deletion.py`, `app/urls.py`):
- `GET /api/vendor/profile/` -> `profile` (store_name, owner_name, phone, email, city, address, approved, commission_percent, joined, last_login,
  open_orders, can_delete), `vendor`, `support` (name, phone, email, whatsapp_url, privacy_url, delete_url).
- `POST /api/vendor/profile/` body: `owner_name`, `email`, `city`, `address` (jo bheji wohi badlegi). Ghalti par `400 {ok:false, error, errors:[...], code:'validation'}`,
  kuch save nahi hota. Phone aur store ka naam yahan se nahi badalte. Email unique (doosre account par ho to reject).
- `POST /api/vendor/password/` body `{old_password, new_password, push_token?}` -> naya `token`. Purane token (doosre phones) khud band (token mein password ka hissa hai).
  `push_token` wale phone ke ilawa is vendor ke baqi push token server se hat jate hain. 5 galat purane password -> 429 `locked` (10 min).
- `POST /api/vendor/account/delete/` body `{password, confirm: true}`. Web `delete_account_vendor` jaisi rules; chal rahe order ho to `409 open_orders`;
  5 galat password -> 429 (web ke saath ek hi counter `delete_account:<user id>`).
- `views_account_deletion.py`: web wala wipe ab `wipe_vendor_account(user)` + `vendor_has_active_orders(vendor)` helpers mein (web + app dono use karte hain).
  Web behaviour wahi; ek izafa: vendor ke push tokens bhi saaf.
- Har API approved vendor ke liye, sirf apna data. Koi migration nahi (aakhri 0064).

App (`vendor_app/`): `screens/profile.dart` (Profile, Password, Account delete), `screens/help.dart` (Madad & support), `screens/alert_settings.dart`,
`models/profile.dart`, `services/prefs.dart` (is phone ki alert pasand), `services/api.dart` (profile / password / delete + cache),
`services/app_state.dart` (`applyProfileChange`, `accountDeleted`, awaaz / vibration prefs), `screens/shell.dart` (banner prefs), `screens/more.dart`, `main.dart`
(shell ki key ab token par nahi - password badalne par shell dobara nahi banta). Version 0.16.0+18. Naya package koi nahi.

## Kaise test karein (5 steps)
1. Backend push karein, Actions `Django CI/CD` chale; apni machine par `python manage.py test app.tests_vendor_profile`.
2. `Build Vendor APK` chalayein, install karein. More > Account > **Profile**: naam / city badlein, Save - web vendor portal par bhi wahi. Email kisi aur vendor ka likhein -> reject.
3. **Password badlein**: do phones par login rakhein; ek par password badlein -> doosre phone ka agla action login screen par le jaye aur us phone par push na aaye; naya password se login chale.
4. **Alert settings**: naye order ka banner / awaaz band karein, doosre phone se test order dein -> app khuli ho to list taza hoti hai par banner / awaaz nahi. App band ho tab alert phir bhi aata hai (Android settings se hi band hota hai).
5. **Account delete** (test vendor par): chal raha order ho to "orders chal rahe hain" ke saath band; order mukammal karke password + tick + confirm -> login screen, purane password se login nahi, customer ko store / products nahi dikhte.

## Jo is phase mein nahi
- **Language (Roman Urdu / English):** poora app Roman Urdu mein likha hai; English ke liye har screen ka text alag karna padega - V17 (polish) ya alag phase mein.
- **Server par alert-wise band karna** (jaise sirf review ka push band): iske liye table mein naya field chahiye (migration). Abhi alert settings sirf is phone par, app khuli ho tab lagti hain.
- Store ka naam / phone badalna (hisaab ke records se jude hain).

Agla phase: **V17 - Polish, security & release**.
