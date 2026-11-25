import 'dart:async';
import 'dart:typed_data';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

import '../utils.dart';
import 'api.dart';

/// Notification se aaya "kahan kholna hai" (server `vendor_push.py` ka data).
///
/// `type`: new_order | order_cancelled | rider_cash | review | low_stock | out_of_stock | stock_summary | test
class PushTarget {
  final String type;
  final int orderId; // 0 = is notification ka order nahi
  final String orderNo;
  final String title;
  final String body;

  const PushTarget({
    required this.type,
    this.orderId = 0,
    this.orderNo = '',
    this.title = '',
    this.body = '',
  });

  factory PushTarget.fromMessage(RemoteMessage m) {
    final d = m.data;
    return PushTarget(
      type: s(d['type']),
      orderId: toI(d['order_id']),
      orderNo: s(d['order_no']),
      title: s(m.notification?.title),
      body: s(m.notification?.body),
    );
  }

  bool get isNewOrder => type == 'new_order';

  /// Tap par Order Detail khulni chahiye.
  bool get hasOrder =>
      orderId > 0 && (type == 'new_order' || type == 'order_cancelled' || type == 'review');

  bool get isStock => type == 'low_stock' || type == 'out_of_stock' || type == 'stock_summary';
}

/// Push notification (Firebase Cloud Messaging) - Phase V7.
///
/// App band ho / screen lock ho - bas phone mein internet ho - naya order aate hi alert aata hai. Notification
/// Android khud dikhata hai (app chalne ki zaroorat nahi). Server (vendor_push.py) do channel par bhejta hai:
///   new_orders -> 'Naye orders'  (alag awaaz + lambi vibration)
///   updates    -> 'Baqi updates' (cancel, rider cash, review, stock)
///
/// Kaam:
///  * [init]   main() mein ek dafa: Firebase + dono channel.
///  * [start]  login ke baad (shell se): token lo, server par register karo, token badle to dobara,
///             notification tap sunno (app band / background / khuli - teeno haalat).
///  * [stop]   logout par: sunna band, is phone ka token hatao (is phone par alert nahi aayega).
///
/// APK Firebase config (google-services.json) ke baghair bani ho to [init] khamoshi se band ho jata hai aur
/// baqi app pehle jaisi chalti hai (orders ka 25 sec wala poll phir bhi chalta hai).
class Push {
  /// Server (vendor_push.py) in channel ids par bhejta hai.
  static const String newOrdersChannel = 'new_orders';
  static const String updatesChannel = 'updates';

  static bool ready = false;
  static bool _started = false;
  static bool _registered = false;
  static bool _registering = false;
  static bool _initialHandled = false;
  static String? token;

  /// App khuli ho aur push aaye: shell in-app banner + awaaz dikhata hai.
  static void Function(PushTarget)? onMessage;

  /// Notification par tap (background ya app band se khuli): shell sahi screen kholta hai.
  static void Function(PushTarget)? onOpen;

  static PushTarget? _pendingOpen;
  static final List<StreamSubscription<dynamic>> _subs = [];

  /// Is phone ka token server tak pahunch chuka hai?
  static bool get registered => _registered;

  /// main() mein ek dafa. Firebase na ho to push band, app chalti rahe.
  static Future<void> init() async {
    try {
      await Firebase.initializeApp();
      ready = true;
    } catch (e) {
      debugPrint('Push band (Firebase config nahi): $e');
      return;
    }
    try {
      final plugin = FlutterLocalNotificationsPlugin();
      await plugin.initialize(const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ));
      final android =
          plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      // Alag awaaz: res/raw/new_order.wav (tool/patch_notification.py lagata hai).
      // Android channel ki awaaz / importance pehli dafa banne ke baad badalti nahi - purani app par naya
      // awaaz lene ke liye app uninstall karke install karein.
      await android?.createNotificationChannel(AndroidNotificationChannel(
        newOrdersChannel,
        'Naye orders',
        description: 'Naya order aane par alag awaaz ke saath alert',
        importance: Importance.max,
        playSound: true,
        sound: const RawResourceAndroidNotificationSound('new_order'),
        enableVibration: true,
        vibrationPattern: Int64List.fromList([0, 500, 250, 500, 250, 800]),
      ));
      await android?.createNotificationChannel(const AndroidNotificationChannel(
        updatesChannel,
        'Baqi updates',
        description: 'Cancel, rider cash, review, stock alert',
        importance: Importance.high,
      ));
    } catch (e) {
      debugPrint('Push channel nahi bane: $e');
    }
  }

  /// Notification ki ijazat di hui hai? (Android 12 aur purane par hamesha true.)
  static Future<bool> notificationsOn() async {
    try {
      return await Permission.notification.isGranted;
    } catch (_) {
      return true;
    }
  }

  /// Login ke baad (VendorShell se). Bar bar call karna theek hai.
  static Future<void> start() async {
    if (!ready || _started) return;
    _started = true;
    try {
      token = await FirebaseMessaging.instance.getToken();
      _registered = false;
      await ensureRegistered();
      _subs.add(FirebaseMessaging.instance.onTokenRefresh.listen((t) {
        token = t;
        _registered = false;
        ensureRegistered();
      }));
      // App khuli hai: system notification nahi dikhata, shell in-app banner dikhata hai
      _subs.add(FirebaseMessaging.onMessage.listen((m) => onMessage?.call(PushTarget.fromMessage(m))));
      // App background mein thi, notification par tap
      _subs.add(FirebaseMessaging.onMessageOpenedApp.listen((m) => _opened(PushTarget.fromMessage(m))));
      // App band thi, notification par tap se khuli (sirf ek dafa)
      if (!_initialHandled) {
        _initialHandled = true;
        final first = await FirebaseMessaging.instance.getInitialMessage();
        if (first != null) _opened(PushTarget.fromMessage(first));
      }
    } catch (e) {
      _started = false;
      debugPrint('Push start nahi hua: $e');
    }
  }

  /// Token server par jaye. Net na ho to agli dafa dobara koshish (AppState.refresh se [sync]).
  static Future<void> ensureRegistered() async {
    final t = token;
    if (!ready || t == null || _registered || _registering || Api.token == null) return;
    _registering = true;
    try {
      await Api.registerPushToken(t);
      _registered = true;
    } catch (_) {
      // approval baqi / net band: agli refresh par dobara
    } finally {
      _registering = false;
    }
  }

  /// Chalu na ho to start, chalu ho to token register ki dobara koshish.
  static Future<void> sync() => _started ? ensureRegistered() : start();

  static void _opened(PushTarget t) {
    final cb = onOpen;
    if (cb != null) {
      cb(t);
    } else {
      _pendingOpen = t;
    }
  }

  /// Shell bante hi: tap pehle ho chuka ho to wo target milta hai (aur saaf ho jata hai).
  static PushTarget? takePendingOpen() {
    final v = _pendingOpen;
    _pendingOpen = null;
    return v;
  }

  /// Logout par: is phone ko push band. Purana token server se `Api.logout(pushToken:)` hata deta hai.
  static Future<void> stop() async {
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    _started = false;
    _registered = false;
    _registering = false;
    _pendingOpen = null;
    token = null;
    if (!ready) return;
    try {
      await FirebaseMessaging.instance.deleteToken().timeout(const Duration(seconds: 6));
    } catch (_) {}
  }
}
