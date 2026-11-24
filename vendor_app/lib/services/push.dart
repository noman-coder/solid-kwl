import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Push notification ki buniyad (Firebase).
///
/// Phase V3: sirf Firebase chalu karna aur dono notification channels banana (server inhi naam se bhejta hai).
/// Token register karna, alert dikhana aur tap par screen kholna Phase V7 mein aayega.
///
/// APK Firebase config (google-services.json) ke baghair bani ho to [init] khamoshi se band ho jata hai,
/// baqi app normal chalti hai.
class Push {
  /// Server (vendor_push.py) in channel ids par bhejta hai.
  static const String newOrdersChannel = 'new_orders';
  static const String updatesChannel = 'updates';

  static bool ready = false;

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
      await android?.createNotificationChannel(const AndroidNotificationChannel(
        newOrdersChannel,
        'Naye orders',
        description: 'Naya order aane par alert',
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
      ));
      await android?.createNotificationChannel(const AndroidNotificationChannel(
        updatesChannel,
        'Updates',
        description: 'Cancel, rider cash, review, stock alert',
        importance: Importance.high,
      ));
    } catch (e) {
      debugPrint('Push channel nahi bane: $e');
    }
  }
}
