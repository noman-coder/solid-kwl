import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

/// Rider ki taaza location (phone ka GPS).
class Fix {
  final double lat;
  final double lng;
  final double heading; // degree (0 = shumal), -1 = maloom nahi
  final double speed; // m/s
  final double accuracy;
  const Fix(this.lat, this.lng, this.heading, this.speed, this.accuracy);

  factory Fix.fromPosition(Position p) => Fix(
        p.latitude,
        p.longitude,
        (p.heading.isNaN || p.heading < 0) ? -1 : p.heading,
        p.speed.isNaN ? 0 : p.speed,
        p.accuracy,
      );
}

/// Map ko location dene wala. Do source:
///  1) Tracker (background service) chal raha ho to wahi feed karta hai.
///  2) Warna map khulne par chhota local stream (sirf phone par, server ko kuch nahi jata).
class LocationHub {
  static final ValueNotifier<Fix?> fix = ValueNotifier<Fix?>(null);
  static StreamSubscription<Position>? _local;

  /// Tracker se aane wali location.
  static void push(Position p) => fix.value = Fix.fromPosition(p);

  static bool get localRunning => _local != null;

  /// Local stream (foreground). Permission na ho to false.
  static Future<bool> startLocal() async {
    if (_local != null) return true;
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return false;
      var p = await Geolocator.checkPermission();
      if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
      if (p == LocationPermission.denied || p == LocationPermission.deniedForever) return false;
      // Pehle turant aakhri maloom location dikha do
      final last = await Geolocator.getLastKnownPosition();
      if (last != null && fix.value == null) fix.value = Fix.fromPosition(last);
      _local = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 5),
      ).listen((pos) => fix.value = Fix.fromPosition(pos), onError: (_) {});
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> stopLocal() async {
    await _local?.cancel();
    _local = null;
  }
}
