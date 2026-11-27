import 'package:flutter/material.dart';

import '../models/profile.dart';
import '../services/api.dart';
import '../services/app_state.dart';
import '../services/push.dart';
import '../theme.dart';
import '../utils.dart';
import '../widgets/empty_state.dart';
import '../widgets/notice_card.dart';
import '../widgets/section_title.dart';
import '../widgets/skeleton.dart';

/// Phase V16: Profile (naam / email / city / address badlein), Password badlein, Account delete.
/// Validation server par hai (web jaisi); yahan sirf saaf message dikhte hain. Skeleton, error + retry, net band par purani copy.

Future<void> openProfileScreen(BuildContext context) {
  final state = AppScope.read(context);
  return Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => AppScope(state: state, child: const ProfileScreen()),
  ));
}

Future<void> openChangePasswordScreen(BuildContext context) {
  final state = AppScope.read(context);
  return Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => AppScope(state: state, child: const ChangePasswordScreen()),
  ));
}

Future<void> openDeleteAccountScreen(BuildContext context) {
  final state = AppScope.read(context);
  return Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => AppScope(state: state, child: const DeleteAccountScreen()),
  ));
}

mixin _ProfileUi<T extends StatefulWidget> on State<T> {
  void snack(String msg) {
    if (!mounted || msg.isEmpty) return;
    final m = ScaffoldMessenger.of(context);
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(content: Text(msg)));
  }

  /// Session khatam / approval hat gayi: app sambhal leti hai (true = screen kuch na kare).
  Future<bool> handled(ApiException e) async {
    final done = await AppScope.read(context).handleApiError(e);
    if (done && mounted) Navigator.of(context).popUntil((r) => r.isFirst);
    return done;
  }
}

// =====================================================================
// Profile
// =====================================================================

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> with _ProfileUi {
  final _owner = TextEditingController();
  final _email = TextEditingController();
  final _city = TextEditingController();
  final _address = TextEditingController();

  ProfilePage? _page;
  bool _loading = true;
  bool _stale = false; // taza load nakam, purani copy dikh rahi hai
  bool _saving = false;
  bool _filled = false;
  String? _error;
  List<String> _errors = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _owner.dispose();
    _email.dispose();
    _city.dispose();
    _address.dispose();
    super.dispose();
  }

  void _fill(VendorProfileData p) {
    _owner.text = p.ownerName;
    _email.text = p.email;
    _city.text = p.city;
    _address.text = p.address;
    _filled = true;
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      if (_page == null) _loading = true;
    });
    if (_page == null) {
      final cached = await Api.cachedProfile();
      if (!mounted) return;
      if (cached != null) {
        setState(() {
          _page = cached;
          if (!_filled) _fill(cached.profile);
          _stale = true;
          _loading = false;
        });
      }
    }
    try {
      final p = await Api.profile();
      if (!mounted) return;
      setState(() {
        _page = p;
        if (!_filled || !_dirty(p.profile)) _fill(p.profile);
        _stale = false;
        _loading = false;
        _error = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      if (await handled(e)) return;
      setState(() {
        _loading = false;
        if (_page == null) {
          _error = e.message;
        } else {
          _stale = true;
        }
      });
    }
  }

  /// Vendor ne kuch likh rakha hai jo abhi save nahi hua?
  bool _dirty(VendorProfileData p) =>
      _owner.text.trim() != p.ownerName ||
      _email.text.trim() != p.email ||
      _city.text.trim() != p.city ||
      _address.text.trim() != p.address;

  Future<void> _save() async {
    final page = _page;
    if (page == null || _saving) return;
    final p = page.profile;
    // Sirf badle hue fields bhejo (purana adhoora address jaisa kuch na atke)
    final fields = <String, dynamic>{
      if (_owner.text.trim() != p.ownerName) 'owner_name': _owner.text.trim(),
      if (_email.text.trim() != p.email) 'email': _email.text.trim(),
      if (_city.text.trim() != p.city) 'city': _city.text.trim(),
      if (_address.text.trim() != p.address) 'address': _address.text.trim(),
    };
    if (fields.isEmpty) {
      snack('Kuch badla nahi.');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _saving = true;
      _errors = const [];
    });
    try {
      final r = await Api.saveProfile(fields);
      if (!mounted) return;
      AppScope.read(context).applyProfileChange(r.vendor);
      setState(() {
        _page = r.page;
        _fill(r.page.profile);
        _saving = false;
        _stale = false;
      });
      snack(r.page.message.isEmpty ? 'Profile update ho gaya.' : r.page.message);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (await handled(e)) return;
      setState(() {
        _saving = false;
        _errors = e.errors.isNotEmpty ? e.errors : [e.message];
      });
    }
  }

  Widget _readOnly(IconData icon, String label, String value) => ListTile(
        dense: true,
        leading: Icon(icon, color: Colors.black45),
        title: Text(label, style: const TextStyle(fontSize: 12.5, color: Colors.black54)),
        subtitle: Text(value.isEmpty ? '-' : value,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.black87)),
      );

  Widget _field(TextEditingController c, String label,
      {TextInputType? type, int maxLines = 1, int? maxLength, TextInputAction? action}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c,
        enabled: !_saving,
        keyboardType: type,
        maxLines: maxLines,
        maxLength: maxLength,
        textInputAction: action ?? (maxLines > 1 ? TextInputAction.newline : TextInputAction.next),
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), counterText: ''),
      ),
    );
  }

  Widget _body(ProfilePage page) {
    final p = page.profile;
    final joined = dateText(p.joined);
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(16),
      children: [
        if (_stale)
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: NoticeCard(
                level: NoticeLevel.warn, text: 'Offline: purani maloomat dikh rahi hain. Net aane par khud taza hongi.'),
          ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundColor: kTeal.withValues(alpha: 0.12),
                  child: Text(
                    p.storeName.trim().isEmpty ? 'S' : p.storeName.trim().substring(0, 1).toUpperCase(),
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: kTeal),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(p.storeName,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 2),
                      Text(joined.isEmpty ? 'Vendor' : 'Vendor  •  $joined se',
                          style: const TextStyle(color: Colors.black54, fontSize: 13)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SectionTitle('Aap ki maloomat'),
        Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 16, 14, 4),
            child: Column(
              children: [
                _field(_owner, 'Aap ka poora naam', maxLength: 100),
                _field(_email, 'Email', type: TextInputType.emailAddress, maxLength: 100),
                _field(_city, 'City', maxLength: 100),
                _field(_address, 'Poora address', type: TextInputType.multiline, maxLines: 3, maxLength: 500),
              ],
            ),
          ),
        ),
        if (_errors.isNotEmpty) ...[
          const SizedBox(height: 12),
          NoticeCard(level: NoticeLevel.error, text: _errors.join('\n')),
        ],
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _saving ? null : _save,
          icon: _saving
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.check),
          label: Text(_saving ? 'Save ho raha hai...' : 'Save karein'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        ),
        const SectionTitle('Jo yahan se nahi badalta'),
        Card(
          child: Column(
            children: [
              _readOnly(Icons.storefront_outlined, 'Store ka naam', p.storeName),
              const Divider(height: 1),
              _readOnly(Icons.phone_outlined, 'Phone (login ID)', p.phone),
              const Divider(height: 1),
              _readOnly(Icons.pie_chart_outline, 'Commission', '${numText(p.commissionPercent)}%'),
            ],
          ),
        ),
        const SizedBox(height: 8),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            'Store ka naam aur phone hisaab ke records se jude hain. Inhein badalna ho to Madad & support se rabta karein.',
            style: TextStyle(color: Colors.black54, fontSize: 12.5),
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final page = _page;
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: page != null
          ? RefreshIndicator(onRefresh: _load, child: _body(page))
          : (_error != null
              ? ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    const SizedBox(height: 80),
                    EmptyState(
                      icon: Icons.cloud_off_outlined,
                      title: 'Profile nahi aa saka',
                      message: _error,
                      action: FilledButton(onPressed: _load, child: const Text('Dobara koshish')),
                    ),
                  ],
                )
              : const Padding(padding: EdgeInsets.all(16), child: SkeletonList(count: 4, height: 90))),
    );
  }
}

// =====================================================================
// Password badlein
// =====================================================================

class ChangePasswordScreen extends StatefulWidget {
  const ChangePasswordScreen({super.key});

  @override
  State<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends State<ChangePasswordScreen> with _ProfileUi {
  final _old = TextEditingController();
  final _new = TextEditingController();
  final _again = TextEditingController();
  bool _showOld = false;
  bool _showNew = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _old.dispose();
    _new.dispose();
    _again.dispose();
    super.dispose();
  }

  String? _check() {
    final o = _old.text, n = _new.text, a = _again.text;
    if (o.isEmpty) return 'Purana password likhein.';
    if (n.length < 6) return 'Naya password kam az kam 6 harf ka ho.';
    if (n.length > 128) return 'Naya password bohat lamba hai.';
    if (n == o) return 'Naya password purane se alag ho.';
    if (n != a) return 'Dono naye password barabar nahi hain.';
    return null;
  }

  Future<void> _submit() async {
    if (_busy) return;
    final problem = _check();
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    final m = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    try {
      final msg = await Api.changePassword(_old.text, _new.text, pushToken: Push.token);
      m.hideCurrentSnackBar();
      m.showSnackBar(SnackBar(content: Text(msg.isEmpty ? 'Password badal gaya.' : msg)));
      if (mounted) nav.pop();
    } on ApiException catch (e) {
      if (!mounted) return;
      if (await handled(e)) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
    }
  }

  Widget _pw(TextEditingController c, String label, bool show, VoidCallback? toggle, {TextInputAction? action}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c,
        enabled: !_busy,
        obscureText: !show,
        autocorrect: false,
        enableSuggestions: false,
        textInputAction: action ?? TextInputAction.next,
        onSubmitted: action == TextInputAction.done ? (_) => _submit() : null,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          suffixIcon: toggle == null
              ? null
              : IconButton(
                  icon: Icon(show ? Icons.visibility_off_outlined : Icons.visibility_outlined), onPressed: toggle),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Password badlein')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const NoticeCard(
            level: NoticeLevel.info,
            icon: Icons.lock_outline,
            text: 'Password badalne par is phone par login rahega, doosre phones par dobara login karna hoga.',
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 16, 14, 4),
              child: Column(
                children: [
                  _pw(_old, 'Purana password', _showOld, () => setState(() => _showOld = !_showOld)),
                  _pw(_new, 'Naya password (kam az kam 6 harf)', _showNew, () => setState(() => _showNew = !_showNew)),
                  _pw(_again, 'Naya password dobara', _showNew, null, action: TextInputAction.done),
                ],
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            NoticeCard(level: NoticeLevel.error, text: _error!),
          ],
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _busy ? null : _submit,
            icon: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.key_outlined),
            label: Text(_busy ? 'Badal raha hai...' : 'Password badlein'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          ),
        ],
      ),
    );
  }
}

// =====================================================================
// Account delete
// =====================================================================

class DeleteAccountScreen extends StatefulWidget {
  const DeleteAccountScreen({super.key});

  @override
  State<DeleteAccountScreen> createState() => _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends State<DeleteAccountScreen> with _ProfileUi {
  final _password = TextEditingController();
  bool _agree = false;
  bool _show = false;
  bool _busy = false;
  bool _loading = true;
  int _openOrders = 0; // server batata hai (na mile to 0 - delete par server phir bhi rokta hai)
  String? _error;

  @override
  void initState() {
    super.initState();
    _password.addListener(() => setState(() {}));
    _loadInfo();
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _loadInfo() async {
    try {
      final p = await Api.profile();
      if (!mounted) return;
      setState(() {
        _openOrders = p.profile.openOrders;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      if (await handled(e)) return;
      setState(() => _loading = false); // net nahi: phir bhi delete ki koshish ho sakti hai, server khud rokta hai
    }
  }

  bool get _blocked => _openOrders > 0;
  bool get _ready => _agree && _password.text.isNotEmpty && !_blocked && !_busy;

  Future<void> _delete() async {
    if (!_ready) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Akhri tasdeeq'),
        content: const Text('Aap ka vendor account aur store ka data hamesha ke liye hat jayega. Ye wapas nahi hoga. Kya aap pakka delete karna chahte hain?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Nahi')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700, minimumSize: const Size(100, 44)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Haan, delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    final state = AppScope.read(context);
    final m = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    try {
      final msg = await Api.deleteAccount(_password.text);
      m.hideCurrentSnackBar();
      m.showSnackBar(SnackBar(content: Text(msg.isEmpty ? 'Aap ka account delete ho gaya.' : msg)));
      await state.accountDeleted(); // token + local data saaf, login screen
      if (mounted) nav.popUntil((r) => r.isFirst);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (await handled(e)) return;
      setState(() {
        _busy = false;
        _error = e.message;
        if (e.code == 'open_orders') _openOrders = _openOrders > 0 ? _openOrders : 1;
      });
    }
  }

  Widget _point(IconData icon, String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: Colors.red.shade700),
            const SizedBox(width: 10),
            Expanded(child: Text(text, style: const TextStyle(fontSize: 13.5))),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final cashPending = state.dashboard?.riderCash.count ?? 0;
    return Scaffold(
      appBar: AppBar(title: const Text('Account delete')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            color: Colors.red.shade50,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Icon(Icons.warning_amber_rounded, color: Colors.red.shade700),
                    const SizedBox(width: 8),
                    Text('Ye wapas nahi hota',
                        style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: Colors.red.shade800)),
                  ]),
                  const SizedBox(height: 8),
                  _point(Icons.storefront_outlined, 'Store band ho jayega aur saari products customers se chhup jayengi.'),
                  _point(Icons.person_off_outlined, 'Aap ka naam, email, address, logo / banner hat jayenge.'),
                  _point(Icons.login_outlined, 'Login hamesha ke liye band; is phone par alert nahi aayenge.'),
                  _point(Icons.receipt_long_outlined,
                      'Purane orders aur hisaab ke records (bina aap ki zaati maloomat ke) system mein rehte hain.'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (_loading)
            const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: LinearProgressIndicator()),
          if (_blocked) ...[
            NoticeCard(
              level: NoticeLevel.error,
              icon: Icons.shopping_bag_outlined,
              text: _openOrders > 1
                  ? '$_openOrders orders abhi chal rahe hain. Pehle unhein mukammal ya reject karein, phir account delete karein.'
                  : 'Ek order abhi chal raha hai. Pehle usay mukammal ya reject karein, phir account delete karein.',
            ),
            const SizedBox(height: 12),
          ],
          if (cashPending > 0) ...[
            NoticeCard(
              level: NoticeLevel.warn,
              icon: Icons.payments_outlined,
              text: 'Rider se $cashPending cash confirm baqi hai. Delete se pehle More > Rider se cash mein confirm / reject kar lein.',
            ),
            const SizedBox(height: 12),
          ],
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
              child: Column(
                children: [
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: _agree,
                    onChanged: _busy ? null : (v) => setState(() => _agree = v == true),
                    title: const Text('Main samajhta hoon ke account delete hone ke baad wapas nahi aayega.',
                        style: TextStyle(fontSize: 14)),
                  ),
                  const SizedBox(height: 4),
                  TextField(
                    controller: _password,
                    enabled: !_busy,
                    obscureText: !_show,
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.done,
                    decoration: InputDecoration(
                      labelText: 'Apna password',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(_show ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                        onPressed: () => setState(() => _show = !_show),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            NoticeCard(level: NoticeLevel.error, text: _error!),
          ],
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _ready ? _delete : null,
            icon: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.delete_forever_outlined),
            label: Text(_busy ? 'Delete ho raha hai...' : 'Account hamesha ke liye delete karein'),
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700, minimumSize: const Size.fromHeight(50)),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
