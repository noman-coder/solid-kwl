import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';

import '../models/store_settings.dart';
import '../services/api.dart';
import '../services/app_state.dart';
import '../services/photo.dart';
import '../theme.dart';
import '../utils.dart';
import '../widgets/empty_state.dart';
import '../widgets/notice_card.dart';
import '../widgets/skeleton.dart';

/// Phase V15: Store settings. Hub screen (summary + 5 hisse) aur har hissa alag screen / alag save:
/// Basic (status, tafseel, category), Timing, Delivery (fee, min order, waqt, areas), Branding (logo / banner),
/// Location verify (GPS, blue tick). Validation server par web jaisi hai; yahan sirf saaf message dikhte hain.
/// Pull-to-refresh, skeleton, error + retry, net band ho to purani settings + message.

/// More tab se Store settings kholo.
Future<void> openStoreSettingsScreen(BuildContext context) {
  final state = AppScope.read(context);
  return Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => AppScope(state: state, child: const StoreSettingsScreen()),
  ));
}

/// Dashboard ki "location verify nahi" warning se seedha Location screen kholo.
Future<void> openStoreLocationScreen(BuildContext context) {
  final state = AppScope.read(context);
  return Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => AppScope(state: state, child: const StoreLocationScreen()),
  ));
}

String statusLabel(String status) => status == 'closed' ? 'Band' : (status == 'busy' ? 'Busy' : 'Khula');

mixin _StoreUi<T extends StatefulWidget> on State<T> {
  void snack(String msg) {
    if (!mounted || msg.isEmpty) return;
    final m = ScaffoldMessenger.of(context);
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> expired() async {
    await AppScope.read(context).handleAuthExpired();
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  /// Kamyab save ke baad: app ka vendor / dashboard taza, message dikhao, screen band.
  Future<void> saved(StoreSaveResult r) async {
    final state = AppScope.read(context);
    final nav = Navigator.of(context);
    final m = ScaffoldMessenger.of(context);
    state.applyStoreChange(r.vendor);
    m.hideCurrentSnackBar();
    if (r.message.isNotEmpty) m.showSnackBar(SnackBar(content: Text(r.message)));
    nav.pop(true);
  }

  Widget? errorsCard(List<String> errors) {
    if (errors.isEmpty) return null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: NoticeCard(level: NoticeLevel.error, text: errors.join('\n')),
    );
  }
}

Future<bool> _confirm(BuildContext context, String title, String text, String okLabel) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(text),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Nahi')),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size(80, 44)),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(okLabel),
        ),
      ],
    ),
  );
  return ok == true;
}

Future<void> _pushSection(BuildContext context, Widget child, VoidCallback onChanged) async {
  final state = AppScope.read(context);
  final changed = await Navigator.of(context).push<bool>(MaterialPageRoute<bool>(
    builder: (_) => AppScope(state: state, child: child),
  ));
  if (changed == true) onChanged();
}

// ===========================================================================
// Hub
// ===========================================================================

class StoreSettingsScreen extends StatefulWidget {
  const StoreSettingsScreen({super.key});

  @override
  State<StoreSettingsScreen> createState() => _StoreSettingsScreenState();
}

class _StoreSettingsScreenState extends State<StoreSettingsScreen> with _StoreUi {
  StorePage? _page;
  bool _loading = true;
  bool _stale = false;
  String? _error;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final cached = await Api.cachedStoreSettings();
    if (mounted && cached != null && _page == null) {
      setState(() {
        _page = cached;
        _stale = true;
      });
    }
    await _load();
  }

  Future<void> _load() async {
    final seq = ++_seq;
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final p = await Api.storeSettings();
      if (!mounted || seq != _seq) return;
      setState(() {
        _page = p;
        _loading = false;
        _stale = false;
      });
    } on ApiException catch (e) {
      if (!mounted || seq != _seq) return;
      if (e.authExpired) {
        await expired();
        return;
      }
      setState(() {
        _loading = false;
        if (_page == null) {
          _error = e.message;
        } else {
          _stale = true;
        }
      });
      if (_page != null) snack(e.message);
    } catch (_) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _loading = false;
        if (_page == null) _error = 'Kuch masla aa gaya. Dobara koshish karein.';
      });
    }
  }

  void _open(Widget Function(StorePage) build) {
    final p = _page;
    if (p == null) return;
    _pushSection(context, build(p), _load);
  }

  @override
  Widget build(BuildContext context) {
    final p = _page;
    return Scaffold(
      appBar: AppBar(title: const Text('Store settings')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: p == null
            ? (_error != null
                ? ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    children: [
                      const SizedBox(height: 80),
                      EmptyState(
                        icon: Icons.cloud_off_outlined,
                        title: 'Settings nahi aa sakin',
                        message: _error,
                        action: FilledButton(onPressed: _load, child: const Text('Dobara koshish')),
                      ),
                    ],
                  )
                : const Padding(padding: EdgeInsets.all(16), child: SkeletonList(count: 5, height: 84)))
            : _content(p),
      ),
    );
  }

  Widget _content(StorePage p) {
    final st = p.settings;
    final loc = st.location;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(16),
      children: [
        if (_stale)
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: NoticeCard(level: NoticeLevel.warn, text: 'Net nahi hai - purani settings dikh rahi hain.'),
          ),
        _Header(page: p),
        const SizedBox(height: 12),
        _SectionTile(
          icon: Icons.storefront_outlined,
          title: 'Basic',
          subtitle: [
            statusLabel(st.status),
            if (st.category != null) st.category!.name,
            if (st.description.isNotEmpty) 'tafseel likhi hai',
          ].join('  •  '),
          onTap: () => _open((p) => _BasicScreen(page: p)),
        ),
        _SectionTile(
          icon: Icons.schedule_outlined,
          title: 'Timing',
          subtitle: st.hasHours ? '${st.opensAt} - ${st.closesAt}' : 'Hamesha khula (timing nahi lagi)',
          onTap: () => _open((p) => _TimingScreen(page: p)),
        ),
        _SectionTile(
          icon: Icons.delivery_dining_outlined,
          title: 'Delivery',
          subtitle: 'Min order ${rs(st.minOrder)}  •  Fee ${rs(st.deliveryFee)}  •  ${st.timeMin}-${st.timeMax} min'
              '  •  ${st.areas.length} areas',
          onTap: () => _open((p) => _DeliveryScreen(page: p)),
        ),
        _SectionTile(
          icon: Icons.image_outlined,
          title: 'Branding (logo / banner)',
          subtitle: '${st.logo != null ? 'Logo lagi hai' : 'Logo nahi'}  •  ${st.cover != null ? 'Banner laga hai' : 'Banner nahi'}',
          onTap: () => _open((p) => _BrandingScreen(page: p)),
        ),
        _SectionTile(
          icon: loc.verified ? Icons.verified : Icons.my_location_outlined,
          iconColor: loc.verified ? Colors.blue.shade600 : null,
          title: 'Location verify',
          subtitle: loc.verified ? 'Verify ho chuki - blue tick laga hai' : 'Verify nahi hui - blue tick nahi',
          onTap: () => _open((p) => StoreLocationScreen(initial: p.settings.location)),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  final StorePage page;
  const _Header({required this.page});

  @override
  Widget build(BuildContext context) {
    final st = page.settings;
    final open = page.isOpen;
    final color = open ? Colors.green.shade700 : Colors.red.shade700;
    final why = open
        ? 'Customer abhi order de sakte hain'
        : (st.status == 'closed' ? 'Store band hai (switch)' : (!page.withinHours ? 'Timing se bahar hai' : 'Abhi band dikh raha hai'));
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (st.cover != null)
            SizedBox(
              height: 110,
              width: double.infinity,
              child: Image.network(Api.absUrl(st.cover!), fit: BoxFit.cover, errorBuilder: (_, __, ___) => const SizedBox()),
            ),
          Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 26,
                  backgroundColor: kTeal.withValues(alpha: 0.12),
                  backgroundImage: st.logo != null ? NetworkImage(Api.absUrl(st.logo!)) : null,
                  child: st.logo == null
                      ? Text(st.name.isEmpty ? 'S' : st.name.substring(0, 1).toUpperCase(),
                          style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: kTeal))
                      : null,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(st.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                          ),
                          if (st.location.verified) ...[
                            const SizedBox(width: 4),
                            Icon(Icons.verified, size: 18, color: Colors.blue.shade600),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          Icon(Icons.circle, size: 10, color: color),
                          const SizedBox(width: 5),
                          Flexible(
                            child: Text('${open ? 'Khula' : 'Band'} - $why',
                                style: TextStyle(color: color, fontSize: 12.5, fontWeight: FontWeight.w700)),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTile extends StatelessWidget {
  final IconData icon;
  final Color? iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  const _SectionTile({
    required this.icon,
    this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        child: ListTile(
          onTap: onTap,
          leading: Icon(icon, color: iconColor ?? kTeal),
          title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Text(subtitle, style: const TextStyle(color: Colors.black54, fontSize: 12.5)),
          trailing: const Icon(Icons.chevron_right),
        ),
      ),
    );
  }
}

/// Section screens ka common dhancha: scroll hone wala form + neeche Save button (loading lock).
class _SectionScaffold extends StatelessWidget {
  final String title;
  final List<Widget> children;
  final bool saving;
  final VoidCallback? onSave;
  final String saveLabel;
  final double? progress;

  const _SectionScaffold({
    required this.title,
    required this.children,
    required this.saving,
    required this.onSave,
    this.saveLabel = 'Save karein',
    this.progress,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.all(16),
                children: children,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (saving && progress != null) ...[
                    LinearProgressIndicator(value: progress, minHeight: 6, borderRadius: BorderRadius.circular(3)),
                    const SizedBox(height: 8),
                  ],
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: saving ? null : onSave,
                      child: saving
                          ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                          : Text(saveLabel),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ===========================================================================
// Basic
// ===========================================================================

class _BasicScreen extends StatefulWidget {
  final StorePage page;
  const _BasicScreen({required this.page});

  @override
  State<_BasicScreen> createState() => _BasicScreenState();
}

class _BasicScreenState extends State<_BasicScreen> with _StoreUi {
  late String _status = widget.page.settings.status;
  late int? _cat = widget.page.settings.category?.id;
  late final TextEditingController _desc = TextEditingController(text: widget.page.settings.description);
  bool _saving = false;
  List<String> _errors = [];

  @override
  void dispose() {
    _desc.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final cur = widget.page.settings.status;
    if (_status == 'closed' && cur != 'closed') {
      final ok = await _confirm(context, 'Store band karein?',
          'Band karne par customer is store se order nahi de sakega. Kya aap store band karna chahte hain?', 'Band karein');
      if (!ok || !mounted) return;
    }
    setState(() {
      _saving = true;
      _errors = [];
    });
    try {
      final r = await Api.saveStoreSection('basic', {
        'status': _status,
        'description': _desc.text.trim(),
        'store_category': _cat ?? '',
      });
      if (!mounted) return;
      await saved(r);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.authExpired) {
        await expired();
        return;
      }
      setState(() {
        _saving = false;
        _errors = e.errors.isNotEmpty ? e.errors : [e.message];
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _errors = ['Kuch masla aa gaya. Dobara koshish karein.'];
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final lim = widget.page.limits;
    final cats = widget.page.categories;
    final catValid = _cat != null && cats.any((c) => c.id == _cat);
    return _SectionScaffold(
      title: 'Basic',
      saving: _saving,
      onSave: _save,
      children: [
        if (errorsCard(_errors) != null) errorsCard(_errors)!,
        const Text('Store ki halat', style: TextStyle(fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: 'open', label: Text('Khula')),
            ButtonSegment(value: 'busy', label: Text('Busy')),
            ButtonSegment(value: 'closed', label: Text('Band')),
          ],
          selected: {_status},
          onSelectionChanged: (v) => setState(() => _status = v.first),
        ),
        const SizedBox(height: 6),
        Text(
          _status == 'closed'
              ? 'Band: customer is store se order nahi de sakta.'
              : (_status == 'busy'
                  ? 'Busy: orders milte hain, par customer ko der ka bataya jata hai.'
                  : 'Khula: customer order de sakte hain (timing ke andar).'),
          style: const TextStyle(color: Colors.black54, fontSize: 12.5),
        ),
        const SizedBox(height: 18),
        const Text('Store ki category', style: TextStyle(fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        DropdownButtonFormField<int?>(
          value: catValid ? _cat : null,
          isExpanded: true,
          decoration: const InputDecoration(hintText: 'Category chunein'),
          items: [
            const DropdownMenuItem<int?>(value: null, child: Text('Koi nahi')),
            ...cats.map((c) => DropdownMenuItem<int?>(value: c.id, child: Text(c.name))),
          ],
          onChanged: (v) => setState(() => _cat = v),
        ),
        const SizedBox(height: 18),
        const Text('Store ki tafseel', style: TextStyle(fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        TextField(
          controller: _desc,
          maxLines: 5,
          minLines: 3,
          maxLength: lim.descriptionMax,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(hintText: 'Aap ka store kya bechta hai, khaas baatein...'),
        ),
      ],
    );
  }
}

// ===========================================================================
// Timing
// ===========================================================================

class _TimingScreen extends StatefulWidget {
  final StorePage page;
  const _TimingScreen({required this.page});

  @override
  State<_TimingScreen> createState() => _TimingScreenState();
}

TimeOfDay? _parseHm(String v) {
  final p = v.split(':');
  if (p.length < 2) return null;
  final h = int.tryParse(p[0]);
  final m = int.tryParse(p[1]);
  if (h == null || m == null || h < 0 || h > 23 || m < 0 || m > 59) return null;
  return TimeOfDay(hour: h, minute: m);
}

String _hm(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

class _TimingScreenState extends State<_TimingScreen> with _StoreUi {
  late bool _always = !widget.page.settings.hasHours;
  late TimeOfDay _open = _parseHm(widget.page.settings.opensAt) ?? const TimeOfDay(hour: 9, minute: 0);
  late TimeOfDay _close = _parseHm(widget.page.settings.closesAt) ?? const TimeOfDay(hour: 22, minute: 0);
  bool _saving = false;
  List<String> _errors = [];

  Future<void> _pick(bool opening) async {
    final t = await showTimePicker(
      context: context,
      initialTime: opening ? _open : _close,
      helpText: opening ? 'Store kab khulta hai' : 'Store kab band hota hai',
    );
    if (t == null || !mounted) return;
    setState(() {
      if (opening) {
        _open = t;
      } else {
        _close = t;
      }
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _errors = [];
    });
    try {
      final r = await Api.saveStoreSection('timing', {
        'opens_at': _always ? '' : _hm(_open),
        'closes_at': _always ? '' : _hm(_close),
      });
      if (!mounted) return;
      await saved(r);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.authExpired) {
        await expired();
        return;
      }
      setState(() {
        _saving = false;
        _errors = e.errors.isNotEmpty ? e.errors : [e.message];
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _errors = ['Kuch masla aa gaya. Dobara koshish karein.'];
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final overnight = !_always && (_close.hour * 60 + _close.minute) <= (_open.hour * 60 + _open.minute);
    return _SectionScaffold(
      title: 'Timing',
      saving: _saving,
      onSave: _save,
      children: [
        if (errorsCard(_errors) != null) errorsCard(_errors)!,
        Card(
          child: SwitchListTile(
            value: _always,
            onChanged: (v) => setState(() => _always = v),
            title: const Text('Hamesha khula (timing nahi)', style: TextStyle(fontWeight: FontWeight.w700)),
            subtitle: const Text('Sirf Khula / Band switch se chale', style: TextStyle(fontSize: 12.5)),
          ),
        ),
        if (!_always) ...[
          const SizedBox(height: 12),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.wb_sunny_outlined, color: kTeal),
                  title: const Text('Store khulne ka waqt'),
                  trailing: Text(_open.format(context), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                  onTap: () => _pick(true),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.nightlight_outlined, color: kTeal),
                  title: const Text('Store band hone ka waqt'),
                  trailing: Text(_close.format(context), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                  onTap: () => _pick(false),
                ),
              ],
            ),
          ),
          if (overnight)
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: NoticeCard(text: 'Band hone ka waqt agle din ka hoga (raat ko paar hone wala waqt, jaise 18:00 se 02:00).'),
            ),
        ],
        const SizedBox(height: 12),
        const Text(
          'Yeh waqt har din ke liye hai. Timing ke bahar customer ko store band dikhta hai aur naye orders nahi milte.',
          style: TextStyle(color: Colors.black54, fontSize: 12.5),
        ),
      ],
    );
  }
}

// ===========================================================================
// Delivery
// ===========================================================================

class _DeliveryScreen extends StatefulWidget {
  final StorePage page;
  const _DeliveryScreen({required this.page});

  @override
  State<_DeliveryScreen> createState() => _DeliveryScreenState();
}

class _DeliveryScreenState extends State<_DeliveryScreen> with _StoreUi {
  late final TextEditingController _min = TextEditingController(text: _num(widget.page.settings.minOrder));
  late final TextEditingController _fee = TextEditingController(text: _num(widget.page.settings.deliveryFee));
  late final TextEditingController _tMin = TextEditingController(text: '${widget.page.settings.timeMin}');
  late final TextEditingController _tMax = TextEditingController(text: '${widget.page.settings.timeMax}');
  late final TextEditingController _extra = TextEditingController(text: widget.page.settings.areasExtra);
  late final Set<String> _sel = {
    for (final g in widget.page.settings.areaGroups)
      for (final a in g.areas)
        if (a.selected) a.label,
  };
  bool _saving = false;
  List<String> _errors = [];

  static String _num(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  @override
  void dispose() {
    for (final c in [_min, _fee, _tMin, _tMax, _extra]) {
      c.dispose();
    }
    super.dispose();
  }

  int get _extraCount => _extra.text.split(RegExp(r'[,;\n]+')).where((e) => e.trim().isNotEmpty).length;

  String? _check() {
    final lim = widget.page.limits;
    final mn = double.tryParse(_min.text.trim().isEmpty ? '0' : _min.text.trim());
    final fee = double.tryParse(_fee.text.trim().isEmpty ? '0' : _fee.text.trim());
    if (mn == null || mn < 0 || mn > lim.moneyMax) return 'Minimum order sahi likhein.';
    if (fee == null || fee < 0 || fee > lim.moneyMax) return 'Delivery fee sahi likhein.';
    final a = int.tryParse(_tMin.text.trim());
    final b = int.tryParse(_tMax.text.trim());
    if (a == null || b == null || a < lim.minutesMin || b < lim.minutesMin || a > lim.minutesMax || b > lim.minutesMax) {
      return 'Delivery time ${lim.minutesMin} se ${lim.minutesMax} minute ke beech likhein.';
    }
    if (a > b) return 'Delivery time: kam se kam, zyada se zyada se chhota hona chahiye.';
    if (_sel.length + _extraCount > lim.maxAreas) return 'Zyada se zyada ${lim.maxAreas} areas chun sakte hain.';
    return null;
  }

  Future<void> _save() async {
    if (_saving) return;
    final bad = _check();
    if (bad != null) {
      setState(() => _errors = [bad]);
      return;
    }
    setState(() {
      _saving = true;
      _errors = [];
    });
    try {
      final r = await Api.saveStoreSection('delivery', {
        'min_order_amount': _min.text.trim().isEmpty ? '0' : _min.text.trim(),
        'delivery_fee': _fee.text.trim().isEmpty ? '0' : _fee.text.trim(),
        'delivery_time_min': int.parse(_tMin.text.trim()),
        'delivery_time_max': int.parse(_tMax.text.trim()),
        'areas': _sel.toList(),
        'areas_extra': _extra.text.trim(),
      });
      if (!mounted) return;
      await saved(r);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.authExpired) {
        await expired();
        return;
      }
      setState(() {
        _saving = false;
        _errors = e.errors.isNotEmpty ? e.errors : [e.message];
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _errors = ['Kuch masla aa gaya. Dobara koshish karein.'];
        });
      }
    }
  }

  Widget _field(TextEditingController c, String label, {String? prefix, String? suffix}) => TextField(
        controller: c,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: label, prefixText: prefix, suffixText: suffix),
      );

  @override
  Widget build(BuildContext context) {
    final lim = widget.page.limits;
    final groups = widget.page.settings.areaGroups;
    final total = _sel.length + _extraCount;
    return _SectionScaffold(
      title: 'Delivery',
      saving: _saving,
      onSave: _save,
      children: [
        if (errorsCard(_errors) != null) errorsCard(_errors)!,
        Row(
          children: [
            Expanded(child: _field(_min, 'Minimum order', prefix: 'Rs ')),
            const SizedBox(width: 12),
            Expanded(child: _field(_fee, 'Delivery fee', prefix: 'Rs ')),
          ],
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _tMin,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Delivery time (kam se kam)', suffixText: 'min'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _tMax,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Delivery time (zyada se zyada)', suffixText: 'min'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: Text('Fee 0 ho to delivery free dikhegi. Customer ko "30-45 min" jaisa waqt dikhta hai.',
              style: TextStyle(color: Colors.black54, fontSize: 12.5)),
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            const Expanded(child: Text('Delivery ke areas', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(color: kTeal.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
              child: Text('$total / ${lim.maxAreas}', style: const TextStyle(fontWeight: FontWeight.w800, color: kTeal)),
            ),
          ],
        ),
        const SizedBox(height: 4),
        const Text('Khali chhodein to sirf store ke shehar mein delivery.', style: TextStyle(color: Colors.black54, fontSize: 12.5)),
        const SizedBox(height: 8),
        for (final g in groups)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Card(
              clipBehavior: Clip.antiAlias,
              child: ExpansionTile(
                initiallyExpanded: g.areas.any((a) => _sel.contains(a.label)),
                shape: const Border(),
                collapsedShape: const Border(),
                title: Text(g.city, style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text('${g.areas.where((a) => _sel.contains(a.label)).length} / ${g.areas.length} chune',
                    style: const TextStyle(fontSize: 12)),
                children: [
                  for (final a in g.areas)
                    CheckboxListTile(
                      dense: true,
                      value: _sel.contains(a.label),
                      title: Text(a.label),
                      onChanged: (v) => setState(() => v == true ? _sel.add(a.label) : _sel.remove(a.label)),
                    ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 6),
        TextField(
          controller: _extra,
          maxLines: 3,
          minLines: 2,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            labelText: groups.isEmpty ? 'Areas (comma se alag)' : 'Aur areas (list mein na hon to, comma se alag)',
            hintText: 'jaise: Gulberg, DHA',
          ),
        ),
      ],
    );
  }
}

// ===========================================================================
// Branding (logo / banner)
// ===========================================================================

class _BrandingScreen extends StatefulWidget {
  final StorePage page;
  const _BrandingScreen({required this.page});

  @override
  State<_BrandingScreen> createState() => _BrandingScreenState();
}

class _BrandingScreenState extends State<_BrandingScreen> with _StoreUi {
  File? _logo;
  File? _cover;
  bool _rmLogo = false;
  bool _rmCover = false;
  bool _saving = false;
  bool _picking = false;
  double? _progress;
  List<String> _errors = [];

  bool get _dirty => _logo != null || _cover != null || _rmLogo || _rmCover;

  Future<void> _choose(bool isLogo) async {
    if (_picking || _saving) return;
    final src = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Camera se photo lein'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Gallery se chunein'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (src == null || !mounted) return;
    setState(() => _picking = true);
    try {
      final path = await PhotoService.pick(src);
      if (path == null || !mounted) return;
      final cropped = await PhotoService.crop(path);
      if (cropped == null || !mounted) return;
      final res = await PhotoService.compress(cropped, maxMb: widget.page.limits.imageMaxMb);
      if (!mounted) return;
      setState(() {
        if (isLogo) {
          _logo = res.file;
          _rmLogo = false;
        } else {
          _cover = res.file;
          _rmCover = false;
        }
        _errors = [];
      });
    } on PhotoException catch (e) {
      snack(e.message);
    } catch (_) {
      snack('Photo nahi chuni ja saki. Dobara koshish karein.');
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _remove(bool isLogo) async {
    final ok = await _confirm(context, isLogo ? 'Logo hatayein?' : 'Banner hatayein?',
        'Save karne par ${isLogo ? 'logo' : 'banner'} store se hat jayega.', 'Hatayein');
    if (!ok || !mounted) return;
    setState(() {
      if (isLogo) {
        _logo = null;
        _rmLogo = true;
      } else {
        _cover = null;
        _rmCover = true;
      }
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    if (!_dirty) {
      setState(() => _errors = ['Pehle koi nayi photo chunein ya hatane ka nishan lagayein.']);
      return;
    }
    setState(() {
      _saving = true;
      _progress = 0;
      _errors = [];
    });
    try {
      final r = await Api.saveStoreBranding(
        logo: _logo,
        cover: _cover,
        removeLogo: _rmLogo,
        removeCover: _rmCover,
        onProgress: (v) {
          if (mounted) setState(() => _progress = v);
        },
      );
      await PhotoService.deleteIfOurs(_logo?.path);
      await PhotoService.deleteIfOurs(_cover?.path);
      if (!mounted) return;
      await saved(r);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.authExpired) {
        await expired();
        return;
      }
      setState(() {
        _saving = false;
        _progress = null;
        _errors = e.errors.isNotEmpty ? e.errors : [e.message];
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _progress = null;
          _errors = ['Kuch masla aa gaya. Dobara koshish karein.'];
        });
      }
    }
  }

  Widget _preview({required bool isLogo, required File? file, required bool removed, required String? url}) {
    final has = file != null || (!removed && url != null);
    final Widget img;
    if (file != null) {
      img = Image.file(file, fit: BoxFit.cover);
    } else if (!removed && url != null) {
      img = Image.network(Api.absUrl(url), fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_outlined));
    } else {
      img = Icon(isLogo ? Icons.storefront_outlined : Icons.landscape_outlined, size: 40, color: Colors.black38);
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(isLogo ? 'Logo' : 'Banner (upar ki badi tasveer)', style: const TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            Center(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(isLogo ? 60 : 14),
                child: Container(
                  width: isLogo ? 110 : double.infinity,
                  height: isLogo ? 110 : 130,
                  color: kBg,
                  alignment: Alignment.center,
                  child: SizedBox.expand(child: has ? img : Center(child: img)),
                ),
              ),
            ),
            if (file != null)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('Nayi photo - Save karne par lagegi.', style: TextStyle(color: Colors.black54, fontSize: 12.5)),
              ),
            if (removed)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('Save karne par hat jayegi.', style: TextStyle(color: Colors.black54, fontSize: 12.5)),
              ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: (_saving || _picking) ? null : () => _choose(isLogo),
                    icon: const Icon(Icons.add_a_photo_outlined),
                    label: Text(has ? 'Badlein' : 'Photo lagayein'),
                  ),
                ),
                if (has) ...[
                  const SizedBox(width: 10),
                  OutlinedButton(
                    onPressed: _saving
                        ? null
                        : () {
                            if (file != null) {
                              setState(() {
                                if (isLogo) {
                                  _logo = null;
                                } else {
                                  _cover = null;
                                }
                              });
                            } else {
                              _remove(isLogo);
                            }
                          },
                    style: OutlinedButton.styleFrom(foregroundColor: Colors.red.shade700),
                    child: Text(file != null ? 'Radd' : 'Hatayein'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final st = widget.page.settings;
    return _SectionScaffold(
      title: 'Branding',
      saving: _saving,
      progress: _progress,
      onSave: _save,
      saveLabel: 'Save karein',
      children: [
        if (errorsCard(_errors) != null) errorsCard(_errors)!,
        _preview(isLogo: true, file: _logo, removed: _rmLogo, url: st.logo),
        const SizedBox(height: 12),
        _preview(isLogo: false, file: _cover, removed: _rmCover, url: st.cover),
        const SizedBox(height: 12),
        Text('Photo upload se pehle chhoti (compress) ho jati hai. Zyada se zyada ${widget.page.limits.imageMaxMb} MB, JPG / PNG / WEBP.',
            style: const TextStyle(color: Colors.black54, fontSize: 12.5)),
      ],
    );
  }
}

// ===========================================================================
// Location verify (GPS + map pin, blue tick)
// ===========================================================================

class StoreLocationScreen extends StatefulWidget {
  /// Hub se aayein to maujooda location; Dashboard warning se aayein to null (khud load hoti hai).
  final StoreLocation? initial;
  const StoreLocationScreen({super.key, this.initial});

  @override
  State<StoreLocationScreen> createState() => _StoreLocationScreenState();
}

class _Fix {
  final double lat;
  final double lng;
  final double accuracy;
  const _Fix(this.lat, this.lng, this.accuracy);
}

class _StoreLocationScreenState extends State<StoreLocationScreen> with _StoreUi {
  StoreLocation? _loc;
  bool _consent = false;
  bool _locating = false;
  bool _saving = false;
  bool _loadingInit = false;
  _Fix? _fix;
  String? _gpsError;
  bool _needSettings = false; // ijazat hamesha ke liye band
  bool _needGps = false; // phone ka location (GPS) band
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _loc = widget.initial;
    if (_loc == null) _loadInit();
  }

  Future<void> _loadInit() async {
    setState(() {
      _loadingInit = true;
      _loadError = null;
    });
    try {
      final p = await Api.storeSettings();
      if (!mounted) return;
      setState(() {
        _loc = p.settings.location;
        _loadingInit = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.authExpired) {
        await expired();
        return;
      }
      setState(() {
        _loadingInit = false;
        _loadError = e.message;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loadingInit = false;
          _loadError = 'Kuch masla aa gaya. Dobara koshish karein.';
        });
      }
    }
  }

  int get _maxAcc => _loc?.maxAccuracyM ?? 500;
  bool get _accOk => _fix != null && _fix!.accuracy <= _maxAcc;

  Future<void> _locate() async {
    if (_locating || _saving) return;
    setState(() {
      _locating = true;
      _gpsError = null;
      _needSettings = false;
      _needGps = false;
    });
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        if (mounted) {
          setState(() {
            _gpsError = 'Phone ki Location (GPS) band hai. Usay on karke dobara koshish karein.';
            _needGps = true;
          });
        }
        return;
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied) {
        if (mounted) setState(() => _gpsError = 'Location ki ijazat nahi mili. Ijazat dein to hi store ki location le sakte hain.');
        return;
      }
      if (perm == LocationPermission.deniedForever) {
        if (mounted) {
          setState(() {
            _gpsError = 'Location ki ijazat band hai. Phone ki Settings mein Location ki ijazat dein.';
            _needSettings = true;
          });
        }
        return;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.best, timeLimit: Duration(seconds: 25)),
      );
      if (!mounted) return;
      setState(() => _fix = _Fix(pos.latitude, pos.longitude, pos.accuracy));
    } catch (_) {
      if (mounted) {
        setState(() => _gpsError = 'Location nahi mil saki. Khuli jagah ya store ke andar GPS on karke dobara koshish karein.');
      }
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _verify() async {
    final f = _fix;
    if (f == null || _saving || !_consent) return;
    if (_loc?.verified == true) {
      final ok = await _confirm(context, 'Location badlein?',
          'Store ki purani verified location is nayi location se badal jayegi.', 'Badlein');
      if (!ok || !mounted) return;
    }
    setState(() => _saving = true);
    try {
      final r = await Api.verifyStoreLocation(f.lat, f.lng, f.accuracy);
      if (!mounted) return;
      await saved(r);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.authExpired) {
        await expired();
        return;
      }
      setState(() {
        _saving = false;
        _gpsError = e.message;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _gpsError = 'Kuch masla aa gaya. Dobara koshish karein.';
        });
      }
    }
  }

  Widget _map(LatLng p, {double? accuracy}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        height: 230,
        child: FlutterMap(
          key: ValueKey('${p.latitude},${p.longitude}'),
          options: MapOptions(
            initialCenter: p,
            initialZoom: 17,
            minZoom: 3,
            maxZoom: 19,
            interactionOptions: const InteractionOptions(flags: InteractiveFlag.pinchZoom | InteractiveFlag.drag),
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.khanewal.vendor.app',
            ),
            if (accuracy != null && accuracy > 0)
              CircleLayer(circles: [
                CircleMarker(
                  point: p,
                  radius: accuracy,
                  useRadiusInMeter: true,
                  color: kTeal.withValues(alpha: 0.15),
                  borderColor: kTeal,
                  borderStrokeWidth: 1,
                ),
              ]),
            MarkerLayer(markers: [
              Marker(
                point: p,
                width: 44,
                height: 44,
                alignment: Alignment.topCenter,
                child: const Icon(Icons.location_on, size: 44, color: Color(0xFFD32F2F)),
              ),
            ]),
            RichAttributionWidget(
              alignment: AttributionAlignment.bottomLeft,
              attributions: [TextSourceAttribution('© OpenStreetMap contributors')],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = _loc;
    return Scaffold(
      appBar: AppBar(title: const Text('Location verify')),
      body: loc == null
          ? (_loadingInit
              ? const Padding(padding: EdgeInsets.all(16), child: SkeletonList(count: 3, height: 110))
              : EmptyState(
                  icon: Icons.cloud_off_outlined,
                  title: 'Location nahi aa saki',
                  message: _loadError,
                  action: FilledButton(onPressed: _loadInit, child: const Text('Dobara koshish')),
                ))
          : SafeArea(child: _body(loc)),
    );
  }

  Widget _body(StoreLocation loc) {
    final f = _fix;
    final savedPt = loc.hasLocation ? LatLng(loc.latitude!, loc.longitude!) : null;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          color: loc.verified ? Colors.blue.shade50 : Colors.amber.shade50,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Icon(loc.verified ? Icons.verified : Icons.info_outline,
                    color: loc.verified ? Colors.blue.shade700 : Colors.amber.shade900, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    loc.verified
                        ? 'Aap ke store ki location verify hai. Store naam ke saath blue tick nazar aata hai.'
                            '${loc.verifiedAt.isNotEmpty ? '\nVerify: ${dateTimeText(loc.verifiedAt)}' : ''}'
                        : 'Location verify nahi hui. Verify karne par store naam ke saath blue tick aata hai aur '
                            'customer ko paas ka store aur doori dikhti hai.',
                    style: const TextStyle(fontSize: 13.5),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (f != null) ...[
          _map(LatLng(f.lat, f.lng), accuracy: f.accuracy),
          const SizedBox(height: 8),
          Text('Nayi location: GPS ki ghalti ${f.accuracy.round()} meter',
              style: TextStyle(fontWeight: FontWeight.w700, color: _accOk ? Colors.green.shade800 : Colors.red.shade700)),
          if (!_accOk)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: NoticeCard(
                level: NoticeLevel.warn,
                text: 'GPS ki ghalti $_maxAcc meter se zyada hai. Store ke andar / khuli jagah par GPS on karke dobara location lein.',
              ),
            ),
        ] else if (savedPt != null) ...[
          _map(savedPt, accuracy: loc.accuracyM),
          const SizedBox(height: 8),
          const Text('Abhi ki verified location', style: TextStyle(color: Colors.black54, fontSize: 12.5)),
        ],
        const SizedBox(height: 14),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Hum location kyun lete hain?', style: TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 6),
                const Text(
                  'Store ki location sirf customer ko paas ka store dikhane aur doori batane ke liye li jati hai. '
                  'Yeh sirf aap ke ittefaq se, aur sirf tab li jati hai jab aap button dabate hain. '
                  'Location lete waqt aap store ke andar hon. Jab chahein dobara verify kar sakte hain.',
                  style: TextStyle(fontSize: 13, color: Colors.black87),
                ),
                const SizedBox(height: 6),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _consent,
                  onChanged: (_saving || _locating) ? null : (v) => setState(() => _consent = v == true),
                  title: const Text('Main ittefaq karta hun ke mere store ki location li jaye.',
                      style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5)),
                ),
              ],
            ),
          ),
        ),
        if (_gpsError != null) ...[
          const SizedBox(height: 12),
          NoticeCard(
            level: NoticeLevel.error,
            text: _gpsError!,
            actionLabel: _needSettings ? 'Settings kholein' : (_needGps ? 'Location on karein' : null),
            onAction: _needSettings
                ? () => Geolocator.openAppSettings()
                : (_needGps ? () => Geolocator.openLocationSettings() : null),
          ),
        ],
        const SizedBox(height: 14),
        OutlinedButton.icon(
          onPressed: (!_consent || _locating || _saving) ? null : _locate,
          icon: _locating
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.my_location),
          label: Text(_locating ? 'Location dhoondh rahe hain...' : (f == null ? 'Meri abhi ki location lein' : 'Dobara location lein')),
        ),
        const SizedBox(height: 10),
        FilledButton.icon(
          onPressed: (_fix == null || !_accOk || !_consent || _saving || _locating) ? null : _verify,
          icon: _saving
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
              : const Icon(Icons.verified_outlined),
          label: Text(loc.verified ? 'Nayi location verify karein' : 'Verify karein'),
        ),
      ],
    );
  }
}
