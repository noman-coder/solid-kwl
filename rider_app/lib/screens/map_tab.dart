import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/order.dart';
import '../services/app_state.dart';
import '../services/location_hub.dart';
import '../services/route_service.dart';
import '../services/tracker.dart';
import '../theme.dart';
import '../utils.dart';
import '../widgets/notice_card.dart';

/// Phase 6: live map (OpenStreetMap) + route (OSRM).
/// - Rider ka marker (heading ke saath) online hote hi / map khulte hi dikhta hai.
/// - Active order ho to store (assigned) ya customer (picked_up / in_transit) tak route line,
///   doori aur ETA.
/// - Server ko location Tracker bhejta hai (sirf active order par) - ye tab sirf dikhata hai.
class MapTab extends StatefulWidget {
  const MapTab({super.key});

  @override
  State<MapTab> createState() => _MapTabState();
}

class _MapTabState extends State<MapTab> {
  static const LatLng _fallbackCenter = LatLng(30.3753, 69.3451); // Pakistan

  final MapController _mc = MapController();
  final RouteService _routes = RouteService();

  AppState? _st;
  bool _mapReady = false;
  bool _follow = true; // marker ke peeche chalna
  bool _centeredOnce = false;
  bool _gpsDenied = false;
  bool _startingLocal = false;
  bool _routeLoading = false;
  bool _routeFailed = false;
  RouteResult? _route;
  String _routeKey = '';
  int? _selectedId;

  @override
  void initState() {
    super.initState();
    LocationHub.fix.addListener(_onFix);
  }

  @override
  void dispose() {
    LocationHub.fix.removeListener(_onFix);
    LocationHub.stopLocal();
    _mc.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _st = AppScope.of(context);
    // build ke dauran setState na ho - is liye frame ke baad
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _syncLocal();
      _maybeRoute();
    });
  }

  // ------------------------------------------------------------------
  // Helpers
  // ------------------------------------------------------------------

  List<RiderOrder> get _active => (_st?.mine ?? const <RiderOrder>[])
      .where((o) => o.status == 'assigned' || o.status == 'picked_up' || o.status == 'in_transit')
      .toList();

  RiderOrder? get _current {
    final list = _active;
    if (list.isEmpty) return null;
    for (final o in list) {
      if (o.id == _selectedId) return o;
    }
    return list.first;
  }

  /// assigned = pehle store jao, uske baad customer.
  Place _target(RiderOrder o) => o.isAssigned ? o.store : o.customer;

  LatLng? _targetPoint(RiderOrder? o) {
    if (o == null) return null;
    final t = _target(o);
    return t.hasCoords ? LatLng(t.lat!, t.lng!) : null;
  }

  LatLng? get _me {
    final f = LocationHub.fix.value;
    return f == null ? null : LatLng(f.lat, f.lng);
  }

  // ------------------------------------------------------------------
  // Location: Tracker chal raha ho to wahi, warna map dikhte waqt local stream
  // ------------------------------------------------------------------

  Future<void> _syncLocal() async {
    final st = _st;
    if (st == null) return;
    final visible = st.tab == 2;
    if (Tracker.running) {
      // Tracker khud location de raha hai - dosra stream nahi chahiye
      if (LocationHub.localRunning) await LocationHub.stopLocal();
      if (_gpsDenied && mounted) setState(() => _gpsDenied = false);
      return;
    }
    if (visible) {
      if (LocationHub.localRunning || _startingLocal) return;
      _startingLocal = true;
      final ok = await LocationHub.startLocal();
      _startingLocal = false;
      if (mounted && _gpsDenied == ok) setState(() => _gpsDenied = !ok);
    } else if (LocationHub.localRunning) {
      await LocationHub.stopLocal(); // map nahi dikh raha - battery bachao
    }
  }

  void _onFix() {
    final me = _me;
    if (me == null || !mounted) return;
    if (_mapReady && (_follow || !_centeredOnce)) {
      try {
        final z = _centeredOnce ? _mc.camera.zoom : 16.0;
        _mc.move(me, z);
        _centeredOnce = true;
      } catch (_) {}
    }
    _maybeRoute();
    setState(() {});
  }

  // ------------------------------------------------------------------
  // Route
  // ------------------------------------------------------------------

  Future<void> _maybeRoute() async {
    final st = _st;
    if (st == null || !mounted) return;
    final o = _current;
    final me = _me;
    final to = _targetPoint(o);

    // Order / status badla to purana route hata do
    final key = o == null ? '' : '${o.id}-${o.status}';
    if (key != _routeKey) {
      _routeKey = key;
      _routes.reset();
      if (_route != null || _routeFailed) {
        setState(() {
          _route = null;
          _routeFailed = false;
        });
      }
    }
    if (o == null || me == null || to == null) return;
    if (st.tab != 2) return; // map dikh nahi raha to route server ko tang na karo
    if (_routeLoading || !_routes.needsRefresh(me, to)) return;

    setState(() => _routeLoading = true);
    final r = await _routes.fetch(me, to);
    if (!mounted) return;
    setState(() {
      _routeLoading = false;
      // agar is dauran order badal gaya ho to purana jawab na lagao
      if (key == _routeKey) {
        _route = r;
        _routeFailed = r == null;
      }
    });
  }

  // ------------------------------------------------------------------
  // Buttons
  // ------------------------------------------------------------------

  void _center() {
    final me = _me;
    if (me == null) {
      _st?.toast('Location abhi nahi mili - GPS on karke thora intezar karein');
      return;
    }
    setState(() => _follow = true);
    try {
      _mc.move(me, math.max(_mc.camera.zoom, 16));
    } catch (_) {}
  }

  void _fit() {
    final pts = <LatLng>[];
    if (_route != null) {
      pts.addAll(_route!.points);
    } else {
      final me = _me;
      final to = _targetPoint(_current);
      if (me != null) pts.add(me);
      if (to != null) pts.add(to);
    }
    if (pts.length < 2) {
      _center();
      return;
    }
    setState(() => _follow = false);
    try {
      _mc.fitCamera(CameraFit.coordinates(
        coordinates: pts,
        padding: const EdgeInsets.fromLTRB(40, 110, 40, 230),
        maxZoom: 17,
      ));
    } catch (_) {}
  }

  Future<void> _retryGps() async {
    setState(() => _gpsDenied = false);
    await _syncLocal();
  }

  // ------------------------------------------------------------------
  // UI
  // ------------------------------------------------------------------

  Widget _circleMarker(IconData icon, Color color, {double size = 40}) => Container(
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 6, offset: Offset(0, 2))],
        ),
        child: Icon(icon, color: Colors.white, size: size * 0.52),
      );

  List<Marker> _markers(RiderOrder? o) {
    final list = <Marker>[];
    if (o != null) {
      if (o.store.hasCoords) {
        list.add(Marker(
          point: LatLng(o.store.lat!, o.store.lng!),
          width: o.isAssigned ? 46 : 38,
          height: o.isAssigned ? 46 : 38,
          child: _circleMarker(Icons.storefront_rounded, Colors.orange.shade700,
              size: o.isAssigned ? 46 : 38),
        ));
      }
      if (o.customer.hasCoords) {
        list.add(Marker(
          point: LatLng(o.customer.lat!, o.customer.lng!),
          width: o.isAssigned ? 38 : 46,
          height: o.isAssigned ? 38 : 46,
          child: _circleMarker(Icons.home_rounded, Colors.red.shade600,
              size: o.isAssigned ? 38 : 46),
        ));
      }
    }
    final f = LocationHub.fix.value;
    if (f != null) {
      final hasHeading = f.heading >= 0 && f.speed > 0.8; // khade hon to arrow na ghoome
      list.add(Marker(
        point: LatLng(f.lat, f.lng),
        width: 48,
        height: 48,
        child: Transform.rotate(
          angle: hasHeading ? f.heading * math.pi / 180 : 0,
          child: _circleMarker(
            hasHeading ? Icons.navigation_rounded : Icons.my_location_rounded,
            kGreen,
            size: 48,
          ),
        ),
      ));
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    final o = _current;
    final me = _me;
    final target = _targetPoint(o);
    final active = _active;

    final LatLng center = me ?? target ?? _fallbackCenter;
    final double zoom = (me != null || target != null) ? 15.5 : 5;

    return Stack(
      children: [
        FlutterMap(
          mapController: _mc,
          options: MapOptions(
            initialCenter: center,
            initialZoom: zoom,
            minZoom: 3,
            maxZoom: 19,
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
            ),
            onMapReady: () {
              _mapReady = true;
              final m = _me;
              if (m != null) {
                try {
                  _mc.move(m, 16);
                  _centeredOnce = true;
                } catch (_) {}
              }
            },
            onPositionChanged: (pos, hasGesture) {
              if (hasGesture && _follow) setState(() => _follow = false);
            },
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.khanewal.riders88.app',
            ),
            if (_route != null)
              PolylineLayer(polylines: [
                Polyline(
                  points: _route!.points,
                  strokeWidth: 6,
                  color: Colors.blue.shade700,
                  borderStrokeWidth: 2,
                  borderColor: Colors.white,
                ),
              ]),
            MarkerLayer(markers: _markers(o)),
            RichAttributionWidget(
              alignment: AttributionAlignment.bottomLeft,
              attributions: [TextSourceAttribution('© OpenStreetMap contributors')],
            ),
          ],
        ),

        // ---- Upar: warnings, order chips, route ka khulasa ----
        Positioned(
          top: 10,
          left: 10,
          right: 10,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_gpsDenied) ...[
                NoticeCard(
                  level: NoticeLevel.warn,
                  text: 'Location nahi mil rahi. GPS on karein aur ijazat dein.',
                  actionLabel: 'Dobara',
                  onAction: _retryGps,
                ),
                const SizedBox(height: 8),
              ],
              if (!st.online) ...[
                const NoticeCard(
                  text: 'Aap Offline hain - Dashboard se Online hon taake naye orders milein.',
                ),
                const SizedBox(height: 8),
              ],
              if (active.length > 1) ...[
                SizedBox(
                  height: 40,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (final a in active)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text('#${a.orderNo}'),
                            selected: a.id == o?.id,
                            backgroundColor: Colors.white,
                            onSelected: (_) {
                              setState(() => _selectedId = a.id);
                              _maybeRoute();
                            },
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
              ],
              if (o != null && target != null) _routeSummary(o),
            ],
          ),
        ),

        // ---- Neeche: buttons + order card ----
        Positioned(
          left: 10,
          right: 10,
          bottom: 12,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FloatingActionButton.small(
                      heroTag: null,
                      tooltip: 'Poora route',
                      backgroundColor: Colors.white,
                      foregroundColor: Colors.black87,
                      onPressed: _fit,
                      child: const Icon(Icons.zoom_out_map_rounded),
                    ),
                    const SizedBox(height: 8),
                    FloatingActionButton(
                      heroTag: null,
                      tooltip: 'Mujhe center karo',
                      backgroundColor: _follow ? kGreen : Colors.white,
                      foregroundColor: _follow ? Colors.white : Colors.black87,
                      onPressed: _center,
                      child: const Icon(Icons.my_location_rounded),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              _bottomCard(o),
            ],
          ),
        ),
      ],
    );
  }

  Widget _routeSummary(RiderOrder o) {
    final toStore = o.isAssigned;
    final label = toStore ? 'Store tak' : 'Customer tak';
    Widget body;
    if (_route != null) {
      body = Row(
        children: [
          Text(_route!.distanceText,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          const SizedBox(width: 10),
          Text('•  ${_route!.etaText}',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: kGreen)),
        ],
      );
    } else if (_routeLoading) {
      body = const Text('Route dhoond raha hai...', style: TextStyle(fontWeight: FontWeight.w600));
    } else if (_routeFailed) {
      body = const Text('Route nahi mila (internet?) - Google Maps se navigate karein',
          style: TextStyle(fontWeight: FontWeight.w600));
    } else if (_me == null) {
      body = const Text('Aap ki location ka intezar...',
          style: TextStyle(fontWeight: FontWeight.w600));
    } else {
      body = const SizedBox.shrink();
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Icon(toStore ? Icons.storefront_rounded : Icons.home_rounded,
                color: toStore ? Colors.orange.shade700 : Colors.red.shade600),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(
                          fontSize: 12, color: Colors.black54, fontWeight: FontWeight.w700)),
                  body,
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bottomCard(RiderOrder? o) {
    if (o == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(14),
          child: Text(
            'Abhi koi active order nahi. Order accept karte hi store / customer ka route yahan dikhega.',
            style: TextStyle(fontWeight: FontWeight.w600, color: Colors.black54),
          ),
        ),
      );
    }
    final t = _target(o);
    final toStore = o.isAssigned;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${toStore ? 'Store' : 'Customer'}: ${t.name.isEmpty ? '-' : t.name}',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
            ),
            if (t.address.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(t.address,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.black54)),
              ),
            if (!t.hasCoords)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  'Is jagah ka map pin nahi hai - Google Maps address se dhoondega.',
                  style: TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () async {
                      final ok = await openUrl(t.mapUrl);
                      if (!ok) _st?.toast('Google Maps nahi khul saka');
                    },
                    icon: const Icon(Icons.navigation_rounded),
                    label: const Text('Google Maps mein navigate'),
                  ),
                ),
                if (t.phone.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    onPressed: () => openUrl('tel:${t.phone}'),
                    icon: const Icon(Icons.call_rounded),
                    tooltip: 'Call',
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
