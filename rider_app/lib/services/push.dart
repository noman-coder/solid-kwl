import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'api.dart';

/// Push notification (Firebase Cloud Messaging).
///
/// App band ho / screen lock ho - bas phone mein internet (data) on ho - naya order "Ready" hote hi
/// notification aati hai. Notification Android khud dikhata hai (app chalne ki zaroorat nahi).
///
/// Agar APK Firebase config (google-services.json) ke baghair bani ho to [init] khamoshi se band ho jata hai
/// aur baqi app pehle jaisi chalti hai.
class Push {
  /// Server (rider_push.py) isi channel id par bhejta hai. High importance = awaaz + screen par popup.
  static const String channelId = 'new_orders';

  static bool _ready = false;
  static bool _started = false;
  static bool _registered = false;
  static bool _openPending = false;
  static String? token;

  /// App khuli ho aur push aaye: orders foran refresh karo.
  static VoidCallback? onMessage;

  /// Notification par tap: Orders > Naye tab kholo.
  static VoidCallback? onOpen;

  static final List<StreamSubscription<dynamic>> _subs = [];

  /// main() mein ek dafa. Firebase na ho to push band, app chalti rahe.
  static Future<void> init() async {
    try {
      await Firebase.initializeApp();
      _ready = true;
    } catch (e) {
      debugPrint('Push band (Firebase config nahi): $e');
      return;
    }
    try {
      final plugin = FlutterLocalNotificationsPlugin();
      await plugin.initialize(const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ));
      await plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(const AndroidNotificationChannel(
            channelId,
            'Naye orders',
            description: 'Naya order tayyar hone par alert',
            importance: Importance.max,
            playSound: true,
            enableVibration: true,
          ));
    } catch (e) {
      debugPrint('Push channel nahi bana: $e');
    }
  }

  /// Login ke baad (RiderShell se). Bar bar call karna theek hai.
  static Future<void> start() async {
    if (!_ready || _started) return;
    _started = true;
    try {
      // Android 13+: notification ki ijazat ka sawal
      await FirebaseMessaging.instance.requestPermission(alert: true, badge: true, sound: true);
      token = await FirebaseMessaging.instance.getToken();
      _registered = false;
      await ensureRegistered();
      _subs.add(FirebaseMessaging.instance.onTokenRefresh.listen((t) {
        token = t;
        _registered = false;
        ensureRegistered();
      }));
      _subs.add(FirebaseMessaging.onMessage.listen((_) => onMessage?.call()));
      _subs.add(FirebaseMessaging.onMessageOpenedApp.listen((_) => _opened()));
      final first = await FirebaseMessaging.instance.getInitialMessage(); // app notification se khuli
      if (first != null) _opened();
    } catch (e) {
      _started = false;
      debugPrint('Push start nahi hua: $e');
    }
  }

  /// Token server par jaye (net na ho to agli dafa dobara koshish - AppState.refresh se).
  static Future<void> ensureRegistered() async {
    final t = token;
    if (!_ready || t == null || _registered || Api.token == null) return;
    try {
      await Api.registerPushToken(t);
      _registered = true;
    } catch (_) {
      // agli refresh par dobara
    }
  }

  static void _opened() {
    final cb = onOpen;
    if (cb != null) {
      cb();
    } else {
      _openPending = true;
    }
  }

  /// Shell bante hi: tap pehle ho chuka ho to true.
  static bool takePendingOpen() {
    final v = _openPending;
    _openPending = false;
    return v;
  }

  /// Logout par: is phone ko push band. Purana token server se Api.logout(pushToken:) hata deta hai.
  static Future<void> stop() async {
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    _started = false;
    _registered = false;
    token = null;
    if (!_ready) return;
    try {
      await FirebaseMessaging.instance.deleteToken();
    } catch (_) {}
  }
}
