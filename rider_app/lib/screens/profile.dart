import 'package:flutter/material.dart';

import '../models/profile.dart';
import '../services/api.dart';
import '../services/app_state.dart';
import '../theme.dart';
import '../utils.dart';
import '../widgets/skeleton.dart';
import '../widgets/notice_card.dart';
import '../widgets/section_title.dart';
import 'password.dart';
import 'permissions_help.dart';

/// Profile tab (Phase 8): profile + rating + reviews, naam / vehicle edit, password,
/// permissions madad, server address, about / version, account delete, logout.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  AppState? _st;
  ProfileData? _p;
  bool _loading = false;
  String? _error;
  int _lastTab = -1;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final st = AppScope.of(context);
    _st = st;
    final reload = st.tab == 4 && _lastTab != 4; // tab khulte hi taaza data
    _lastTab = st.tab;
    if (reload) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    }
  }

  Future<void> _load() async {
    if (_loading) return;
    _loading = true;
    if (mounted) setState(() {});
    try {
      final d = await Api.profile();
      if (!mounted) return;
      _p = ProfileData.fromJson(d['profile']);
      _error = null;
    } on ApiException catch (e) {
      if (e.authExpired) {
        await _st?.onLogout();
        return;
      }
      _error = e.message;
    } finally {
      _loading = false;
      if (mounted) setState(() {});
    }
  }

  // ------------------------------------------------------------------
  // Actions
  // ------------------------------------------------------------------

  Future<void> _edit() async {
    final p = _p;
    final st = _st;
    if (p == null || st == null) return;
    final done = await showDialog<bool>(
      context: context,
      builder: (_) => _EditDialog(name: p.name, vehicle: p.vehicle, st: st),
    );
    if (done == true) {
      st.toast('✅ Profile update ho gaya');
      await _load();
      st.refresh();
    }
  }

  Future<void> _deleteAccount() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Account delete?'),
        content: const Text('Website ka account delete page khulega. Wahan login karke delete ki tasdeeq karni hogi.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Nahi')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade600),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Page kholein'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final base = Api.server.trim().replaceAll(RegExp(r'/+$'), '');
    final opened = await openUrl('$base/shop/rider/account/delete/');
    if (!opened) _st?.toast('❌ Link nahi khul saka');
  }

  Future<void> _logout() async {
    final st = _st;
    if (st == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Logout?'),
        content: const Text('Logout par aap offline ho jayenge.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Nahi')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Logout')),
        ],
      ),
    );
    if (ok == true) await st.onLogout();
  }

  void _about() {
    showAboutDialog(
      context: context,
      applicationName: '88 Riders',
      applicationVersion: kAppVersion,
      applicationIcon: const Icon(Icons.two_wheeler, size: 40, color: kGreen),
      children: const [Text('Khanewal Connect ke riders ke liye delivery app.')],
    );
  }

  // ------------------------------------------------------------------
  // UI
  // ------------------------------------------------------------------

  Widget _stars(double v, {double size = 18}) {
    final full = v.round().clamp(0, 5);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 1; i <= 5; i++)
          Icon(i <= full ? Icons.star_rounded : Icons.star_border_rounded,
              size: size, color: Colors.amber.shade700),
      ],
    );
  }

  Widget _tile(IconData icon, String title, {String? subtitle, VoidCallback? onTap, Color? color}) {
    return Card(
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(title, style: TextStyle(fontWeight: FontWeight.w700, color: color)),
        subtitle: subtitle == null ? null : Text(subtitle),
        trailing: onTap == null ? null : const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    final p = _p;
    final mini = st.profile;
    final name = (p?.name.isNotEmpty ?? false) ? p!.name : mini.name;
    final phone = (p?.phone.isNotEmpty ?? false) ? p!.phone : mini.phone;
    final vehicle = p?.vehicle ?? mini.vehicle;

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(12),
        children: [
          if (_error != null) ...[
            NoticeCard(level: NoticeLevel.error, icon: Icons.cloud_off, text: _error!),
            const SizedBox(height: 10),
          ],
          // ---- Header ----
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 30,
                        backgroundColor: kGreen.withValues(alpha: 0.13),
                        child: const Icon(Icons.person, size: 32, color: kGreen),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(name.isEmpty ? 'Rider' : name,
                                style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
                            if (phone.isNotEmpty) Text(phone),
                            Text(vehicle.isEmpty ? 'Vehicle likha nahi' : vehicle,
                                style: const TextStyle(color: Colors.black54)),
                          ],
                        ),
                      ),
                      IconButton.filledTonal(
                        onPressed: p == null ? null : _edit,
                        icon: const Icon(Icons.edit_rounded),
                        tooltip: 'Naam / vehicle badlein',
                      ),
                    ],
                  ),
                  if (p != null) ...[
                    const Divider(height: 24),
                    Row(
                      children: [
                        Expanded(child: _mini('Deliveries', numText(p.totalDeliveries))),
                        Expanded(child: _mini('Fee / delivery', rs(p.fee))),
                        Expanded(child: _mini('Shamil hue', p.joined.isEmpty ? '-' : fmtDate(DateTime.tryParse(p.joined)?.toLocal() ?? DateTime.now()))),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (p == null && _loading) const Padding(padding: EdgeInsets.only(top: 12), child: SkeletonList(count: 2)),
          // ---- Rating + reviews ----
          if (p != null) ...[
            const SectionTitle('Rating aur reviews'),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: p.ratingAvg == null || p.ratingCount == 0
                    ? const Text('Abhi tak koi rating nahi mili.', style: TextStyle(color: Colors.black54))
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(p.ratingAvg!.toStringAsFixed(1),
                                  style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w900)),
                              const SizedBox(width: 10),
                              _stars(p.ratingAvg!, size: 22),
                              const SizedBox(width: 8),
                              Text('(${p.ratingCount})', style: const TextStyle(color: Colors.black54)),
                            ],
                          ),
                          for (final r in p.reviews) ...[
                            const Divider(height: 20),
                            Row(
                              children: [
                                _stars(r.stars.toDouble(), size: 16),
                                const Spacer(),
                                Text('#${r.orderNo}  •  ${fmtDateTime(r.at)}',
                                    style: const TextStyle(fontSize: 12, color: Colors.black54)),
                              ],
                            ),
                            if (r.comment.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(r.comment),
                              ),
                          ],
                        ],
                      ),
              ),
            ),
          ],
          // ---- Settings ----
          const SectionTitle('Settings'),
          _tile(Icons.lock_outline, 'Password badlein', onTap: () {
            Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => AppScope(state: st, child: const ChangePasswordScreen()),
            ));
          }),
          const SizedBox(height: 8),
          _tile(Icons.shield_outlined, 'Permissions madad',
              subtitle: 'Allow all the time, Battery unrestricted', onTap: () {
            Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => const PermissionsHelpScreen(),
            ));
          }),
          const SizedBox(height: 8),
          _tile(Icons.info_outline, 'About', subtitle: 'Version $kAppVersion', onTap: _about),
          const SectionTitle('Account'),
          _tile(Icons.delete_outline, 'Account delete karein',
              subtitle: 'Website par tasdeeq ke saath', color: Colors.red.shade700, onTap: _deleteAccount),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _logout,
            icon: const Icon(Icons.logout),
            label: const Text('Logout'),
          ),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _mini(String label, String value) => Column(
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(value, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
          ),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(fontSize: 11, color: Colors.black54)),
        ],
      );
}

/// Naam / vehicle badalne ka dialog. Phone login ID hai - nahi badalta.
class _EditDialog extends StatefulWidget {
  final String name;
  final String vehicle;
  final AppState st;
  const _EditDialog({required this.name, required this.vehicle, required this.st});

  @override
  State<_EditDialog> createState() => _EditDialogState();
}

class _EditDialogState extends State<_EditDialog> {
  late final TextEditingController _name = TextEditingController(text: widget.name);
  late final TextEditingController _vehicle = TextEditingController(text: widget.vehicle);
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _vehicle.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_busy) return;
    final name = _name.text.trim();
    if (name.length < 2) {
      setState(() => _error = 'Naam kam az kam 2 harf ka likhein.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Api.updateProfile(name: name, vehicle: _vehicle.text.trim());
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (e.authExpired) {
        await widget.st.onLogout();
        return;
      }
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Profile badlein'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              enabled: !_busy,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Naam'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _vehicle,
              enabled: !_busy,
              decoration: const InputDecoration(labelText: 'Vehicle (e.g. Honda 70, 2 wheeler)'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: TextStyle(color: Colors.red.shade700)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: const Text('Nahi')),
        FilledButton(onPressed: _busy ? null : _save, child: Text(_busy ? '...' : 'Save')),
      ],
    );
  }
}
