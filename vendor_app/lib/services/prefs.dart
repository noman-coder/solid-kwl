import 'package:shared_preferences/shared_preferences.dart';

/// Phase V16: is phone ki alert pasand (sirf is phone par, server par nahi).
///
/// Ye switches sirf tab lagte hain jab **app khuli ho** (in-app banner, awaaz, vibration). App band / background ho to
/// notification Android khud dikhata hai - uski awaaz / on-off Android ki notification settings (channel) se hoti hai.
class Prefs {
  static bool orderBanner = true; // naye order par upar banner
  static bool orderSound = true; // naye order par awaaz
  static bool orderVibrate = true; // naye order par vibration
  static bool updateBanner = true; // baqi alerts (cancel, cash, review, stock) ka banner

  static const String _kOrderBanner = 'pref_order_banner';
  static const String _kOrderSound = 'pref_order_sound';
  static const String _kOrderVibrate = 'pref_order_vibrate';
  static const String _kUpdateBanner = 'pref_update_banner';

  static Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      orderBanner = p.getBool(_kOrderBanner) ?? true;
      orderSound = p.getBool(_kOrderSound) ?? true;
      orderVibrate = p.getBool(_kOrderVibrate) ?? true;
      updateBanner = p.getBool(_kUpdateBanner) ?? true;
    } catch (_) {}
  }

  static Future<void> _put(String key, bool v) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(key, v);
    } catch (_) {}
  }

  static Future<void> setOrderBanner(bool v) {
    orderBanner = v;
    return _put(_kOrderBanner, v);
  }

  static Future<void> setOrderSound(bool v) {
    orderSound = v;
    return _put(_kOrderSound, v);
  }

  static Future<void> setOrderVibrate(bool v) {
    orderVibrate = v;
    return _put(_kOrderVibrate, v);
  }

  static Future<void> setUpdateBanner(bool v) {
    updateBanner = v;
    return _put(_kUpdateBanner, v);
  }
}
