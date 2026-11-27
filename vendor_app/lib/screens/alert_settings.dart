import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../services/prefs.dart';
import '../theme.dart';
import '../widgets/notice_card.dart';
import '../widgets/section_title.dart';
import 'permissions_help.dart';

/// Phase V16: kaun si alert kaise aaye (banner / awaaz / vibration).
///
/// Ye switches sirf is phone par aur sirf tab lagte hain jab **app khuli ho**. App band / background ho to notification Android
/// khud dikhata hai - uski awaaz ya on/off Android ki notification settings ("Naye orders" / "Baqi updates") se hota hai.
Future<void> openAlertSettingsScreen(BuildContext context) {
  return Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AlertSettingsScreen()));
}

class AlertSettingsScreen extends StatefulWidget {
  const AlertSettingsScreen({super.key});

  @override
  State<AlertSettingsScreen> createState() => _AlertSettingsScreenState();
}

class _AlertSettingsScreenState extends State<AlertSettingsScreen> {
  Widget _sw(String title, String sub, bool value, Future<void> Function(bool) save) {
    return SwitchListTile(
      value: value,
      onChanged: (v) async {
        setState(() {}); // switch foran
        await save(v);
        if (mounted) setState(() {});
      },
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
      subtitle: Text(sub, style: const TextStyle(color: Colors.black54, fontSize: 12.5)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Alert settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const NoticeCard(
            level: NoticeLevel.info,
            text: 'Ye switches sirf tab lagte hain jab app khuli ho. App band ya screen lock ho tab alert Android ki apni settings se aata hai.',
          ),
          const SectionTitle('Naya order (app khuli ho)'),
          Card(
            child: Column(
              children: [
                _sw('Upar banner', 'Naya order aate hi screen ke upar bar', Prefs.orderBanner, Prefs.setOrderBanner),
                const Divider(height: 1),
                _sw('Awaaz', 'Naye order par beep', Prefs.orderSound, Prefs.setOrderSound),
                const Divider(height: 1),
                _sw('Vibration', 'Naye order par do dafa vibration', Prefs.orderVibrate, Prefs.setOrderVibrate),
              ],
            ),
          ),
          const SectionTitle('Baqi alerts (app khuli ho)'),
          Card(
            child: _sw('Upar banner', 'Cancel, rider cash, review aur stock ke alert', Prefs.updateBanner,
                Prefs.setUpdateBanner),
          ),
          const SectionTitle('App band ho tab'),
          Card(
            child: Column(
              children: [
                ListTile(
                  onTap: () async {
                    try {
                      await openAppSettings();
                    } catch (_) {}
                  },
                  leading: const Icon(Icons.settings_outlined, color: kTeal),
                  title: const Text('Android ki notification settings', style: TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: const Text('Notifications > "Naye orders" / "Baqi updates" ki awaaz ya band karna',
                      style: TextStyle(color: Colors.black54, fontSize: 12.5)),
                  trailing: const Icon(Icons.open_in_new, size: 20),
                ),
                const Divider(height: 1),
                ListTile(
                  onTap: () => Navigator.of(context)
                      .push(MaterialPageRoute<void>(builder: (_) => const PermissionsHelpScreen())),
                  leading: const Icon(Icons.notifications_active_outlined, color: kTeal),
                  title: const Text('Alerts & permissions', style: TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: const Text('Ijazat, battery unrestricted, phone ka status',
                      style: TextStyle(color: Colors.black54, fontSize: 12.5)),
                  trailing: const Icon(Icons.chevron_right),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
