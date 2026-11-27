import 'package:flutter/material.dart';

import '../models/profile.dart';
import '../services/api.dart';
import '../services/app_state.dart';
import '../theme.dart';
import '../utils.dart';
import '../widgets/empty_state.dart';
import '../widgets/notice_card.dart';
import '../widgets/section_title.dart';
import '../widgets/skeleton.dart';
import 'permissions_help.dart';

/// Phase V16: Madad & support - WhatsApp / call / email, alerts ki madad, privacy policy, account delete ka tareeqa, app version.
/// Support ki maloomat server se aati hai (company ki settings); net band ho to purani copy.
Future<void> openHelpScreen(BuildContext context) {
  final state = AppScope.read(context);
  return Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => AppScope(state: state, child: const HelpScreen()),
  ));
}

class HelpScreen extends StatefulWidget {
  const HelpScreen({super.key});

  @override
  State<HelpScreen> createState() => _HelpScreenState();
}

class _HelpScreenState extends State<HelpScreen> {
  SupportInfo? _support;
  bool _loading = true;
  bool _stale = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      if (_support == null) _loading = true;
    });
    if (_support == null) {
      final cached = await Api.cachedProfile();
      if (!mounted) return;
      if (cached != null) {
        setState(() {
          _support = cached.support;
          _stale = true;
          _loading = false;
        });
      }
    }
    try {
      final p = await Api.profile();
      if (!mounted) return;
      setState(() {
        _support = p.support;
        _stale = false;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      if (await AppScope.read(context).handleApiError(e)) {
        if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
        return;
      }
      setState(() {
        _loading = false;
        if (_support == null) {
          _error = e.message;
        } else {
          _stale = true;
        }
      });
    }
  }

  Future<void> _open(String url, String failMsg) async {
    final ok = await openUrl(url);
    if (!ok && mounted) {
      final m = ScaffoldMessenger.of(context);
      m.hideCurrentSnackBar();
      m.showSnackBar(SnackBar(content: Text(failMsg)));
    }
  }

  Widget _tile(IconData icon, String title, String subtitle, VoidCallback onTap, {Color? color}) => ListTile(
        onTap: onTap,
        leading: Icon(icon, color: color ?? kTeal),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: subtitle.isEmpty ? null : Text(subtitle, style: const TextStyle(color: Colors.black54, fontSize: 12.5)),
        trailing: const Icon(Icons.chevron_right),
      );

  Widget _supportCard(SupportInfo s) {
    if (!s.hasAny) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('Support ka number abhi set nahi hai. Admin se rabta karein.',
              style: TextStyle(color: Colors.black54)),
        ),
      );
    }
    return Card(
      child: Column(
        children: [
          if (s.whatsappUrl.isNotEmpty)
            _tile(Icons.chat_outlined, 'WhatsApp par likhein', s.name.isEmpty ? 'Sab se tez jawab' : s.name,
                () => _open(s.whatsappUrl, 'WhatsApp nahi khul saka.'),
                color: const Color(0xFF25D366)),
          if (s.whatsappUrl.isNotEmpty && s.phone.isNotEmpty) const Divider(height: 1),
          if (s.phone.isNotEmpty)
            _tile(Icons.call_outlined, 'Call karein', s.phone, () => _open('tel:${s.phone}', 'Call nahi lag saki.')),
          if ((s.whatsappUrl.isNotEmpty || s.phone.isNotEmpty) && s.email.isNotEmpty) const Divider(height: 1),
          if (s.email.isNotEmpty)
            _tile(Icons.mail_outline, 'Email bhejein', s.email,
                () => _open('mailto:${s.email}', 'Email app nahi khuli.')),
        ],
      ),
    );
  }

  Widget _body(SupportInfo s) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(16),
      children: [
        if (_stale)
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: NoticeCard(level: NoticeLevel.warn, text: 'Offline: purani maloomat dikh rahi hain.'),
          ),
        const SectionTitle('Rabta'),
        _supportCard(s),
        const SectionTitle('Madad'),
        Card(
          child: _tile(Icons.notifications_active_outlined, 'Alerts nahi aa rahe?',
              'Notification ijazat, battery unrestricted, phone ka status', () {
            Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PermissionsHelpScreen()));
          }),
        ),
        const SectionTitle('Qanooni'),
        Card(
          child: Column(
            children: [
              if (s.privacyUrl.isNotEmpty)
                _tile(Icons.privacy_tip_outlined, 'Privacy policy', 'Hum aap ka data kaise sambhalte hain',
                    () => _open(s.privacyUrl, 'Page nahi khul saka.')),
              if (s.privacyUrl.isNotEmpty && s.deleteUrl.isNotEmpty) const Divider(height: 1),
              if (s.deleteUrl.isNotEmpty)
                _tile(Icons.delete_outline, 'Account delete ka tareeqa', 'Web page par tafseel',
                    () => _open(s.deleteUrl, 'Page nahi khul saka.')),
            ],
          ),
        ),
        const SizedBox(height: 20),
        const Center(
          child: Text('$kAppName  •  Version $kAppVersion', style: TextStyle(color: Colors.black45, fontSize: 12)),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = _support;
    return Scaffold(
      appBar: AppBar(title: const Text('Madad & support')),
      body: s != null
          ? RefreshIndicator(onRefresh: _load, child: _body(s))
          : (_error != null
              ? ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    const SizedBox(height: 80),
                    EmptyState(
                      icon: Icons.cloud_off_outlined,
                      title: 'Madad ki maloomat nahi aa sakin',
                      message: _error,
                      action: FilledButton(onPressed: _load, child: const Text('Dobara koshish')),
                    ),
                  ],
                )
              : (_loading
                  ? const Padding(padding: EdgeInsets.all(16), child: SkeletonList(count: 3, height: 80))
                  : const SizedBox.shrink())),
    );
  }
}
