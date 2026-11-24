import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import '../theme.dart';
import '../widgets/section_title.dart';

/// Permissions ki madad: har cheez ka status (theek / baqi) aur seedha button.
/// Background location ke liye "Allow all the time" aur battery "Unrestricted" zaroori hain.
class PermissionsHelpScreen extends StatefulWidget {
  const PermissionsHelpScreen({super.key});

  @override
  State<PermissionsHelpScreen> createState() => _PermissionsHelpScreenState();
}

class _PermissionsHelpScreenState extends State<PermissionsHelpScreen> with WidgetsBindingObserver {
  bool? _gps;
  bool? _loc;
  bool? _always;
  bool? _notif;
  bool? _battery;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Settings se wapas aane par status dobara dekho
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    bool? gps, loc, always, notif, battery;
    try {
      gps = await Geolocator.isLocationServiceEnabled();
      loc = await Permission.location.isGranted;
      always = await Permission.locationAlways.isGranted;
      notif = await Permission.notification.isGranted;
      battery = await Permission.ignoreBatteryOptimizations.isGranted;
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _gps = gps;
      _loc = loc;
      _always = always;
      _notif = notif;
      _battery = battery;
    });
  }

  Future<void> _ask(Future<PermissionStatus> Function() request) async {
    try {
      final r = await request();
      if (r.isPermanentlyDenied) await openAppSettings();
    } catch (_) {
      await openAppSettings();
    }
    _check();
  }

  Widget _item({
    required IconData icon,
    required String title,
    required String help,
    required bool? ok,
    required String actionLabel,
    required VoidCallback onAction,
  }) {
    final c = ok == null ? Colors.grey : (ok ? kGreen : Colors.red.shade600);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              radius: 20,
              backgroundColor: c.withValues(alpha: 0.13),
              child: Icon(ok == true ? Icons.check_rounded : icon, color: c),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 2),
                  Text(help, style: const TextStyle(fontSize: 13, color: Colors.black54)),
                  const SizedBox(height: 6),
                  if (ok == true)
                    Text('Theek hai', style: TextStyle(color: c, fontWeight: FontWeight.w700))
                  else
                    OutlinedButton(onPressed: onAction, child: Text(actionLabel)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Permissions madad')),
      body: RefreshIndicator(
        onRefresh: _check,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(12),
          children: [
            const Padding(
              padding: EdgeInsets.all(4),
              child: Text(
                'Order ke dauran app band / minimize ho to bhi customer ko aap ki location dikhne ke liye ye sab on hona chahiye.',
                style: TextStyle(color: Colors.black54),
              ),
            ),
            const SizedBox(height: 8),
            _item(
              icon: Icons.gps_fixed,
              title: 'Phone ki Location (GPS)',
              help: 'Phone ki Location on rakhein.',
              ok: _gps,
              actionLabel: 'Location settings',
              onAction: () async {
                await Geolocator.openLocationSettings();
                _check();
              },
            ),
            const SizedBox(height: 8),
            _item(
              icon: Icons.location_on_outlined,
              title: 'Location ki ijazat',
              help: 'App ko location use karne dein.',
              ok: _loc,
              actionLabel: 'Ijazat dein',
              onAction: () => _ask(Permission.location.request),
            ),
            const SizedBox(height: 8),
            _item(
              icon: Icons.my_location,
              title: 'Allow all the time',
              help: 'App minimize / screen lock par bhi location jaye. Settings > Location mein "Allow all the time" chunein.',
              ok: _always,
              actionLabel: 'Allow all the time',
              onAction: () => _ask(Permission.locationAlways.request),
            ),
            const SizedBox(height: 8),
            _item(
              icon: Icons.notifications_none,
              title: 'Notifications',
              help: 'Tracking chalne ka notification aur alerts ke liye.',
              ok: _notif,
              actionLabel: 'Ijazat dein',
              onAction: () => _ask(Permission.notification.request),
            ),
            const SizedBox(height: 8),
            _item(
              icon: Icons.battery_saver_outlined,
              title: 'Battery: Unrestricted',
              help: 'Warna phone background mein app band kar sakta hai.',
              ok: _battery,
              actionLabel: 'Allow karein',
              onAction: () => _ask(Permission.ignoreBatteryOptimizations.request),
            ),
            const SectionTitle('Xiaomi / Oppo / Vivo / Huawei / Samsung'),
            const Card(
              child: Padding(
                padding: EdgeInsets.all(14),
                child: Text(
                  '1. Settings > Apps > 88 Riders > Battery > Unrestricted (No restrictions)\n'
                  '2. "Autostart" / "Auto-launch" on karein\n'
                  '3. Recent apps mein app ko lock (pin) karein\n'
                  '4. Recent apps se swipe karke band na karein - minimize theek hai',
                  style: TextStyle(height: 1.5),
                ),
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () async {
                await openAppSettings();
              },
              icon: const Icon(Icons.settings_outlined),
              label: const Text('App ki settings kholein'),
            ),
            const SizedBox(height: 30),
          ],
        ),
      ),
    );
  }
}
