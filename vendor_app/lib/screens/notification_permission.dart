import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../theme.dart';
import 'permissions_help.dart';

/// Login ke baad ek dafa: notification ki ijazat ka saaf screen (Android 13+ ka system sawal isi ke baad aata hai).
/// "Baad mein" dabane par dobara nahi aata - More > Alerts & permissions se kabhi bhi on kar sakte hain.
class NotificationPermissionScreen extends StatefulWidget {
  const NotificationPermissionScreen({super.key});

  @override
  State<NotificationPermissionScreen> createState() => _NotificationPermissionScreenState();
}

class _NotificationPermissionScreenState extends State<NotificationPermissionScreen> {
  bool _busy = false;
  bool _granted = false;
  String? _note;

  Future<void> _allow() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _note = null;
    });
    PermissionStatus? st;
    try {
      st = await Permission.notification.request();
    } catch (_) {}
    if (!mounted) return;
    if (st != null && st.isGranted) {
      setState(() {
        _busy = false;
        _granted = true;
      });
      return;
    }
    if (st != null && st.isPermanentlyDenied) {
      await openAppSettings();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _note = 'Settings mein Notifications on karein, phir wapas aayein.';
      });
      return;
    }
    setState(() {
      _busy = false;
      _note = 'Ijazat nahi mili. Baad mein More > Alerts & permissions se on kar sakte hain.';
    });
  }

  void _openBattery() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(builder: (_) => const PermissionsHelpScreen()),
    );
  }

  Widget _point(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: kTeal, size: 22),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 15, height: 1.35))),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 18),
                      Center(
                        child: CircleAvatar(
                          radius: 48,
                          backgroundColor: kTeal.withValues(alpha: 0.12),
                          child: Icon(_granted ? Icons.check_circle_rounded : Icons.notifications_active_rounded,
                              size: 54, color: kTeal),
                        ),
                      ),
                      const SizedBox(height: 22),
                      Text(
                        _granted ? 'Alerts chalu ho gaye' : 'Naya order ka alert na chhootay',
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w900),
                      ),
                      const SizedBox(height: 18),
                      if (!_granted) ...[
                        _point(Icons.phonelink_lock_outlined, 'App band ya screen lock ho tab bhi naya order ka alert aaye.'),
                        _point(Icons.music_note_outlined, 'Naye order ki alag awaaz, taake foran pata chal jaye.'),
                        _point(Icons.touch_app_outlined, 'Alert par tap karte hi seedha wohi order khul jaye.'),
                      ] else ...[
                        const Text(
                          'Ab naye orders ka alert aayega. Ek aakhri cheez: "Battery: Unrestricted" bhi kar dein, '
                          'warna kuch phones background mein app band kar dete hain aur alert late ho jata hai.',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 15, height: 1.4),
                        ),
                      ],
                      if (_note != null) ...[
                        const SizedBox(height: 14),
                        Text(_note!,
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.orange.shade800, fontWeight: FontWeight.w600)),
                      ],
                    ],
                  ),
                ),
              ),
              if (!_granted) ...[
                FilledButton(
                  onPressed: _busy ? null : _allow,
                  child: Text(_busy ? 'Ek lamha...' : 'Ijazat dein'),
                ),
                const SizedBox(height: 6),
                TextButton(
                  onPressed: _busy ? null : () => Navigator.of(context).pop(),
                  child: const Text('Baad mein'),
                ),
              ] else ...[
                FilledButton(onPressed: _openBattery, child: const Text('Battery setting dekhein')),
                const SizedBox(height: 6),
                TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Theek hai')),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
