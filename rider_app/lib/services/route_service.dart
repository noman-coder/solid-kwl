import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

/// Aik route ka natija: line ke points, doori (meter) aur andaza waqt (second).
class RouteResult {
  final List<LatLng> points;
  final double distanceM;
  final double durationS;
  const RouteResult(this.points, this.distanceM, this.durationS);

  /// "850 m" ya "3.4 km"
  String get distanceText =>
      distanceM < 1000 ? '${distanceM.round()} m' : '${(distanceM / 1000).toStringAsFixed(1)} km';

  /// "5 min" ya "1 ghanta 10 min"
  String get etaText {
    final m = (durationS / 60).round();
    if (m < 1) return '1 min se kam';
    if (m < 60) return '$m min';
    final h = m ~/ 60;
    final r = m % 60;
    return r == 0 ? '$h ghanta' : '$h ghanta $r min';
  }
}

/// Route dene wale ka interface. Baad mein Google / Mapbox lagana ho to sirf naya provider banao.
abstract class RouteProvider {
  Future<RouteResult?> route(LatLng from, LatLng to);
}

/// OSRM (free demo server). Heavy production ke liye apna OSRM server / Google lagayein.
class OsrmProvider implements RouteProvider {
  final String baseUrl;
  const OsrmProvider({this.baseUrl = 'https://router.project-osrm.org'});

  @override
  Future<RouteResult?> route(LatLng from, LatLng to) async {
    final url = '$baseUrl/route/v1/driving/'
        '${from.longitude},${from.latitude};${to.longitude},${to.latitude}'
        '?overview=full&geometries=geojson';
    try {
      final r = await http.get(Uri.parse(url), headers: {
        'Accept': 'application/json',
        'User-Agent': '88Riders/1.6',
      }).timeout(const Duration(seconds: 12));
      if (r.statusCode != 200) return null;
      final d = jsonDecode(utf8.decode(r.bodyBytes));
      if (d is! Map || d['code'] != 'Ok') return null;
      final routes = d['routes'];
      if (routes is! List || routes.isEmpty) return null;
      final rt = routes.first as Map;
      final coords = (rt['geometry'] as Map)['coordinates'] as List;
      final pts = <LatLng>[];
      for (final c in coords) {
        if (c is List && c.length >= 2) {
          pts.add(LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()));
        }
      }
      if (pts.length < 2) return null;
      return RouteResult(
        pts,
        (rt['distance'] as num?)?.toDouble() ?? 0,
        (rt['duration'] as num?)?.toDouble() ?? 0,
      );
    } catch (_) {
      return null; // internet / server ka masla - map phir bhi chalta rahe
    }
  }
}

/// Map tab isi ko use karta hai. Provider badalna ho to sirf yahan badlein.
class RouteService {
  static RouteProvider provider = const OsrmProvider();
  static const Distance _dist = Distance();

  LatLng? _lastFrom;
  LatLng? _lastTo;
  DateTime _lastAt = DateTime.fromMillisecondsSinceEpoch(0);
  RouteResult? cached;

  /// Route dobara tab mangta hai jab: destination badla, ya rider 150m se zyada chala,
  /// ya 90 second guzar gaye. Warna purana (cached) hi milta hai - server par bojh kam.
  bool needsRefresh(LatLng from, LatLng to) {
    if (_lastFrom == null || _lastTo == null) return true;
    if (_dist(_lastTo!, to) > 5) return true;
    if (_dist(_lastFrom!, from) > 150) return true;
    return DateTime.now().difference(_lastAt).inSeconds > 90;
  }

  Future<RouteResult?> fetch(LatLng from, LatLng to) async {
    _lastFrom = from;
    _lastTo = to;
    _lastAt = DateTime.now();
    final r = await provider.route(from, to);
    cached = r; // null = route nahi mila
    return r;
  }

  void reset() {
    _lastFrom = null;
    _lastTo = null;
    cached = null;
  }
}
