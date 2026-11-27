import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/order_detail.dart';
import '../theme.dart';

/// Live map (OpenStreetMap, free): store, customer aur rider ka marker.
/// Rider ki position badle to map khud dobara fit hoti hai (jab tak vendor ne khud map na hilayi ho).
class LiveMap extends StatefulWidget {
  final GeoPoint? store;
  final GeoPoint? customer;
  final GeoPoint? rider;
  final double height;

  const LiveMap({
    super.key,
    required this.store,
    required this.customer,
    required this.rider,
    this.height = 260,
  });

  @override
  State<LiveMap> createState() => _LiveMapState();
}

class _LiveMapState extends State<LiveMap> {
  static const LatLng _fallback = LatLng(30.3753, 69.3451); // Pakistan
  final MapController _mc = MapController();
  bool _ready = false;
  bool _userMoved = false;

  @override
  void dispose() {
    _mc.dispose();
    super.dispose();
  }

  LatLng _ll(GeoPoint p) => LatLng(p.lat, p.lng);

  List<LatLng> get _points => [
        if (widget.store != null) _ll(widget.store!),
        if (widget.customer != null) _ll(widget.customer!),
        if (widget.rider != null) _ll(widget.rider!),
      ];

  @override
  void didUpdateWidget(covariant LiveMap old) {
    super.didUpdateWidget(old);
    if (!_userMoved && _ready && _changed(old)) {
      // build ke dauran map ko na chhedein - frame ke baad fit karo
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _fit();
      });
    }
  }

  bool _changed(LiveMap o) =>
      o.rider?.lat != widget.rider?.lat ||
      o.rider?.lng != widget.rider?.lng ||
      o.store?.lat != widget.store?.lat ||
      o.customer?.lat != widget.customer?.lat;

  void _fit() {
    final pts = _points;
    if (pts.isEmpty) return;
    try {
      if (pts.length == 1) {
        _mc.move(pts.first, 15);
      } else {
        _mc.fitCamera(CameraFit.bounds(bounds: LatLngBounds.fromPoints(pts), padding: const EdgeInsets.all(48), maxZoom: 17));
      }
    } catch (_) {}
  }

  Marker _marker(LatLng p, IconData icon, Color color, String label) {
    return Marker(
      point: p,
      width: 84,
      height: 62,
      alignment: Alignment.topCenter,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), boxShadow: const [
              BoxShadow(color: Colors.black26, blurRadius: 3),
            ]),
            child: Text(label, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800), maxLines: 1),
          ),
          const SizedBox(height: 2),
          CircleAvatar(
            radius: 15,
            backgroundColor: color,
            child: Icon(icon, size: 18, color: Colors.white),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pts = _points;
    final center = pts.isEmpty ? _fallback : pts.first;
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        height: widget.height,
        child: Stack(
          children: [
            FlutterMap(
              mapController: _mc,
              options: MapOptions(
                initialCenter: center,
                initialZoom: pts.isEmpty ? 5 : 14,
                minZoom: 3,
                maxZoom: 19,
                interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
                onMapReady: () {
                  _ready = true;
                  _fit();
                },
                onPositionChanged: (pos, hasGesture) {
                  if (hasGesture) _userMoved = true;
                },
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.khanewal.vendor.app',
                ),
                MarkerLayer(markers: [
                  if (widget.store != null) _marker(_ll(widget.store!), Icons.storefront, kTeal, 'Store'),
                  if (widget.customer != null)
                    _marker(_ll(widget.customer!), Icons.home_rounded, Colors.red.shade600, 'Customer'),
                  if (widget.rider != null)
                    _marker(_ll(widget.rider!), Icons.delivery_dining, Colors.blue.shade700, 'Rider'),
                ]),
                RichAttributionWidget(
                  alignment: AttributionAlignment.bottomLeft,
                  attributions: [TextSourceAttribution('© OpenStreetMap contributors')],
                ),
              ],
            ),
            Positioned(
              right: 8,
              top: 8,
              child: FloatingActionButton.small(
                heroTag: null,
                tooltip: 'Poora route',
                backgroundColor: Colors.white,
                foregroundColor: Colors.black87,
                onPressed: () {
                  _userMoved = false;
                  _fit();
                },
                child: const Icon(Icons.zoom_out_map_rounded),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
