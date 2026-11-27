import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/push.dart';
import '../theme.dart';
import '../utils.dart';
import '../widgets/section_title.dart';

/// Alerts ki madad: notification ki ijazat aur "Battery unrestricted" ka status + seedha button.
/// (Rider app ke permissions_help jaisa; vendor ko location nahi chahiye.)
class PermissionsHelpScreen extends StatefulWidget {
  const PermissionsHelpScreen({super.key});

  @override
  State<PermissionsHelpScreen> createState() => _PermissionsHelpScreenState();
}

class _PermissionsHelpScreenState extends State<PermissionsHelpScreen> with WidgetsBindingObserver {
  bool? _notif;
  bool? _battery;
  bool _linking = false;

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
    bool? notif, battery;
    try {
      notif = await Permission.notification.isGranted;
      battery = await Permission.ignoreBatteryOptimizations.isGranted;
    } catch (_) {}
    if (!mounted) return;
    setState(() {
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

  Future<void> _relink() async {
    if (_linking) return;
    setState(() => _linking = true);
    await Push.sync();
    if (!mounted) return;
    setState(() => _linking = false);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(Push.registered
            ? 'Is phone par alert chalu hain.'
            : 'Abhi nahi juda. Internet check karein aur dobara koshish karein.'),
      ));
  }

  Widget _item({
    required IconData icon,
    required String title,
    required String help,
    required bool? ok,
    required String actionLabel,
    required VoidCallback onAction,
  }) {
    final c = ok == null ? Colors.grey : (ok ? kTeal : Colors.red.shade600);
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
    final pushOn = Push.ready;
    return Scaffold(
      appBar: AppBar(title: const Text('Alerts madad')),
      body: RefreshIndicator(
        onRefresh: _check,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(12),
          children: [
            const Padding(
              padding: EdgeInsets.all(4),
              child: Text(
                'App band ya screen lock ho tab bhi naya order ka alert aaye, is ke liye ye cheezein on honi chahiye.',
                style: TextStyle(color: Colors.black54),
              ),
            ),
            const SizedBox(height: 8),
            _item(
              icon: Icons.notifications_none,
              title: 'Notifications',
              help: 'Naye order, cancel, rider cash aur review ke alert ke liye.',
              ok: _notif,
              actionLabel: 'Ijazat dein',
              onAction: () => _ask(Permission.notification.request),
            ),
            const SizedBox(height: 8),
            _item(
              icon: Icons.battery_saver_outlined,
              title: 'Battery: Unrestricted',
              help: 'Warna phone background mein app band kar sakta hai aur alert late ya gayab ho sakta hai.',
              ok: _battery,
              actionLabel: 'Allow karein',
              onAction: () => _ask(Permission.ignoreBatteryOptimizations.request),
            ),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CircleAvatar(
                      radius: 20,
                      backgroundColor: (pushOn ? kTeal : Colors.orange.shade700).withValues(alpha: 0.13),
                      child: Icon(pushOn ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
                          color: pushOn ? kTeal : Colors.orange.shade700),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Is phone ka alert', style: TextStyle(fontWeight: FontWeight.w800)),
                          const SizedBox(height: 2),
                          Text(
                            !pushOn
                                ? 'Is APK mein push setup nahi (Firebase). App khuli ho tab naye orders har 25 sec mein check hote hain.'
                                : (Push.registered
                                    ? 'Server se juda hua hai.'
                                    : 'Abhi server se nahi juda (internet ya approval).'),
                            style: const TextStyle(fontSize: 13, color: Colors.black54),
                          ),
                          if (pushOn && !Push.registered) ...[
                            const SizedBox(height: 6),
                            OutlinedButton(
                              onPressed: _linking ? null : _relink,
                              child: Text(_linking ? 'Jor raha hai...' : 'Dobara jorein'),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SectionTitle('Awaaz'),
            const Card(
              child: Padding(
                padding: EdgeInsets.all(14),
                child: Text(
                  'Naye order ki awaaz alag hai (do dafa "ding-dong"). Phone ki Silent / Do Not Disturb mode '
                  'mein awaaz nahi aati - naye order ke waqt phone ko Silent par na rakhein. '
                  'Awaaz ya vibration badalni ho to neeche "App ki settings" > Notifications > Naye orders.',
                  style: TextStyle(height: 1.5),
                ),
              ),
            ),
            const SectionTitle('Xiaomi / Oppo / Vivo / Huawei / Samsung'),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Text(
                  '1. Settings > Apps > $kAppName > Battery > Unrestricted (No restrictions)\n'
                  '2. "Autostart" / "Auto-launch" on karein\n'
                  '3. Recent apps mein app ko lock (pin) karein\n'
                  '4. Recent apps se swipe karke band na karein - minimize theek hai',
                  style: const TextStyle(height: 1.5),
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
