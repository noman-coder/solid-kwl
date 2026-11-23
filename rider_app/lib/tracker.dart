import 'dart:async';

import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import 'api.dart';

/// Background GPS: Android "foreground service" (notification ke saath) chalata hai,
/// is liye app minimize / screen lock par bhi location jati rehti hai.
class Tracker {
  static StreamSubscription<Position>? _sub;
  static DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);

  static bool get running => _sub != null;

  /// null = sab theek, warna rider ko dikhane wala message.
  static Future<String?> ensurePermissions() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return 'Phone ki Location (GPS) on karein';
    }
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied) {
      p = await Geolocator.requestPermission();
    }
    if (p == LocationPermission.denied || p == LocationPermission.deniedForever) {
      return 'Location ki ijazat dein: Settings > Apps > K-Conn Rider > Permissions > Location';
    }
    // "Allow all the time" - app band/minimize hone par bhi location ke liye
    if (!await Permission.locationAlways.isGranted) {
      await Permission.locationAlways.request();
    }
    await Permission.notification.request();
    if (!await Permission.ignoreBatteryOptimizations.isGranted) {
      await Permission.ignoreBatteryOptimizations.request();
    }
    return null;
  }

  static Future<void> start() async {
    if (_sub != null) return;
    final settings = AndroidSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 0,
      intervalDuration: const Duration(seconds: 10),
      foregroundNotificationConfig: ForegroundNotificationConfig(
        notificationTitle: 'Delivery tracking chal rahi hai',
        notificationText: 'Customer ko aap ki live location dikh rahi hai',
        enableWakeLock: true,
        setOngoing: true,
      ),
    );
    _sub = Geolocator.getPositionStream(locationSettings: settings).listen(_onPos, onError: (_) {});
  }

  static Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
  }

  static void _onPos(Position p) {
    final now = DateTime.now();
    if (now.difference(_last).inSeconds < 8) return; // server par ~10s throttle
    _last = now;
    Api.sendLocation(p.latitude, p.longitude, p.accuracy, p.speed, p.heading).catchError((_) {});
  }
}
