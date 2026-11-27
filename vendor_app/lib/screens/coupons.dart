import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../models/coupons.dart';
import '../services/api.dart';
import '../services/app_state.dart';
import '../theme.dart';
import '../utils.dart';
import '../widgets/empty_state.dart';
import '../widgets/notice_card.dart';
import '../widgets/skeleton.dart';

/// Phase V13: Coupons. Vendor apne coupons banata / badalta / chalu-band / delete karta hai. Validation server wali hi hai
/// (web portal jaisi); customer checkout par coupon wahi engine chalata hai.
/// Pull-to-refresh, skeleton, empty, error + retry, net band ho to purani list, double-tap lock.
class CouponsScreen extends StatefulWidget {
  const CouponsScreen({super.key});

  @override
  State<CouponsScreen> createState() => _CouponsScreenState();
}

/// More tab se Coupons screen kholo.
Future<void> openCouponsScreen(BuildContext context) {
  final state = AppScope.read(context);
  return Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => AppScope(state: state, child: const CouponsScreen()),
  ));
}

String _newKey() {
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  final r = math.Random.secure();
  return List.generate(20, (_) => chars[r.nextInt(chars.length)]).join();
}

class _CouponsScreenState extends State<CouponsScreen> {
  CouponsPage? _page;
  bool _loading = false;
  bool _stale = false; // purani (phone mein save) list dikh rahi hai
  String? _error;
  String _filter = 'all'; // all | live | expired | paused
  final Set<int> _busy = <int>{};
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final cached = await Api.cachedCoupons();
    if (mounted && cached != null && _page == null) {
      setState(() {
        _page = cached;
        _stale = true;
      });
    }
    if (!mounted) return;
    await _load();
  }

  void _snack(String msg) {
    if (!mounted) return;
    final m = ScaffoldMessenger.of(context);
    m.hideCurrentSnackBar();
    m.showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _expired() async {
    await AppScope.read(context).handleAuthExpired();
    if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
  }

  Future<void> _load() async {
    final seq = ++_seq;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final p = await Api.coupons();
      if (!mounted || seq != _seq) return;
      setState(() {
        _page = p;
        _stale = false;
        _loading = false;
        _error = null;
      });
    } on ApiException catch (e) {
      if (!mounted || seq != _seq) return;
      if (e.authExpired) {
        await _expired();
        return;
      }
      setState(() {
        _loading = false;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _loading = false;
        _error = 'Kuch masla aa gaya. Dobara koshish karein.';
      });
    }
  }

  bool _matches(Coupon c) {
    switch (_filter) {
      case 'live':
        return c.status == 'active' || c.status == 'scheduled';
      case 'expired':
        return c.isFinished;
      case 'paused':
        return c.status == 'paused';
      default:
        return true;
    }
  }

  int _count(String f) {
    final list = _page?.coupons ?? const <Coupon>[];
    switch (f) {
      case 'live':
        return list.where((c) => c.status == 'active' || c.status == 'scheduled').length;
      case 'expired':
        return list.where((c) => c.isFinished).length;
      case 'paused':
        return list.where((c) => c.status == 'paused').length;
      default:
        return list.length;
    }
  }

  // ------------------------------------------------------------------ actions

  Future<void> _openForm([Coupon? c]) async {
    final page = _page;
    if (c == null && page != null && page.coupons.length >= page.summary.max) {
      _snack('Zyada se zyada ${page.summary.max} coupons ho sakte hain. Purane delete karein.');
      return;
    }
    final state = AppScope.read(context);
    final r = await Navigator.of(context).push<CouponActionResult>(MaterialPageRoute(
      builder: (_) => AppScope(state: state, child: CouponFormScreen(coupon: c)),
    ));
    if (r == null || !mounted) return;
    setState(() {
      _page = r.page;
      _stale = false;
    });
    _snack(r.message.isEmpty ? 'Coupon save ho gaya.' : r.message);
  }

  Future<void> _toggle(Coupon c, bool on) async {
    if (!_busy.add(c.id)) return;
    setState(() {});
    try {
      final r = await Api.setCouponActive(c.id, on);
      if (!mounted) return;
      setState(() {
        _page = r.page;
        _stale = false;
      });
      _snack(r.message);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.authExpired) {
        await _expired();
        return;
      }
      _snack(e.message);
      if (e.code == 'not_found') _load();
    } catch (_) {
      if (mounted) _snack('Kuch masla aa gaya. Dobara koshish karein.');
    } finally {
      _busy.remove(c.id);
      if (mounted) setState(() {});
    }
  }

  Future<void> _delete(Coupon c) async {
    if (_busy.contains(c.id)) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${c.code} delete karein?'),
        content: Text(c.used > 0
            ? 'Yeh coupon ${c.used} dafa istemal ho chuka hai, is liye delete nahi hoga - sirf band ho jayega. Purane orders ka hisaab wahi rahega.'
            : 'Yeh coupon hamesha ke liye hat jayega.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Nahi')),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(100, 44), backgroundColor: Colors.red.shade700),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(c.used > 0 ? 'Band karein' : 'Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    if (!_busy.add(c.id)) return;
    setState(() {});
    try {
      final r = await Api.deleteCoupon(c.id);
      if (!mounted) return;
      setState(() {
        _page = r.page;
        _stale = false;
      });
      _snack(r.message);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.authExpired) {
        await _expired();
        return;
      }
      _snack(e.message);
      if (e.code == 'not_found') _load();
    } catch (_) {
      if (mounted) _snack('Kuch masla aa gaya. Dobara koshish karein.');
    } finally {
      _busy.remove(c.id);
      if (mounted) setState(() {});
    }
  }

  Future<void> _copy(Coupon c) async {
    await Clipboard.setData(ClipboardData(text: c.code));
    _snack('Code ${c.code} copy ho gaya.');
  }

  Future<void> _whatsapp(Coupon c) async {
    final text = c.shareText.isEmpty ? 'Coupon: ${c.code}' : c.shareText;
    final opened = await openUrl('https://wa.me/?text=${Uri.encodeComponent(text)}');
    if (!opened) {
      try {
        await Share.share(text);
      } catch (_) {
        _snack('Share nahi ho saka.');
      }
    }
  }

  // ------------------------------------------------------------------ build

  Widget _chips() {
    const items = <List<String>>[
      ['all', 'Sab'],
      ['live', 'Chalu'],
      ['expired', 'Expire'],
      ['paused', 'Band'],
    ];
    return SizedBox(
      height: 42,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          for (final it in items)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text('${it[1]} (${_count(it[0])})'),
                selected: _filter == it[0],
                onSelected: (_) => setState(() => _filter = it[0]),
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _content(CouponsPage page) {
    final out = <Widget>[];
    if (_error != null) {
      out
        ..add(NoticeCard(
          level: NoticeLevel.warn,
          icon: Icons.cloud_off_outlined,
          text: _stale
              ? 'Net nahi chal raha. Purani list dikh rahi hai.'
              : 'Taza data nahi aaya. Purana data dikh raha hai.',
          actionLabel: 'Dobara',
          onAction: _load,
        ))
        ..add(const SizedBox(height: 10));
    }
    out.add(Row(
      children: [
        Expanded(
          child: _SumCard(
            label: 'Chalu coupons',
            value: '${page.summary.active}',
            sub: '${page.summary.total} / ${page.summary.max} bane hain',
            color: kTeal,
            bg: kTeal.withValues(alpha: 0.08),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _SumCard(
            label: 'Ab tak chhoot di',
            value: rs(page.summary.givenTotal),
            sub: '${page.summary.usedTotal} dafa istemal',
            color: Colors.amber.shade900,
            bg: Colors.amber.shade50,
          ),
        ),
      ],
    ));
    out
      ..add(const SizedBox(height: 14))
      ..add(_chips())
      ..add(const SizedBox(height: 10));

    final shown = page.coupons.where(_matches).toList();
    if (shown.isEmpty) {
      out.add(const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: Text('Is filter mein koi coupon nahi.', style: TextStyle(color: Colors.black54))),
      ));
    }
    for (final c in shown) {
      out
        ..add(_CouponCard(
          c: c,
          busy: _busy.contains(c.id),
          onToggle: (v) => _toggle(c, v),
          onCopy: () => _copy(c),
          onShare: () => _whatsapp(c),
          onEdit: () => _openForm(c),
          onDelete: () => _delete(c),
        ))
        ..add(const SizedBox(height: 10));
    }
    out.add(const SizedBox(height: 80)); // FAB ke neeche jagah
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final page = _page;
    Widget body;
    if (page == null && _loading) {
      body = const Padding(padding: EdgeInsets.all(16), child: SkeletonList(count: 4, height: 120));
    } else if (page == null) {
      body = EmptyState(
        icon: Icons.wifi_off_rounded,
        title: 'Load nahi ho saka',
        message: _error ?? 'Internet / VPN check karein.',
        action: FilledButton.icon(
          onPressed: _load,
          icon: const Icon(Icons.refresh),
          label: const Text('Dobara koshish karein'),
        ),
      );
    } else if (page.coupons.isEmpty && _error == null) {
      body = RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            const SizedBox(height: 80),
            EmptyState(
              icon: Icons.local_offer_outlined,
              title: 'Abhi koi coupon nahi',
              message: 'Pehla coupon banayein - customers ko chhoot dein aur orders barhayein.',
              action: FilledButton.icon(
                onPressed: () => _openForm(),
                icon: const Icon(Icons.add),
                label: const Text('Naya coupon'),
              ),
            ),
          ],
        ),
      );
    } else {
      body = RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: _content(page),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Coupons')),
      floatingActionButton: page == null
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _openForm(),
              icon: const Icon(Icons.add),
              label: const Text('Naya coupon'),
            ),
      body: body,
    );
  }
}

class _SumCard extends StatelessWidget {
  final String label;
  final String value;
  final String sub;
  final Color color;
  final Color bg;
  const _SumCard({required this.label, required this.value, required this.sub, required this.color, required this.bg});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12.5)),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value, style: TextStyle(color: color, fontWeight: FontWeight.w900, fontSize: 24)),
          ),
          const SizedBox(height: 2),
          Text(sub, style: TextStyle(color: color.withValues(alpha: 0.8), fontSize: 12)),
        ],
      ),
    );
  }
}

Color _statusColor(String status) {
  switch (status) {
    case 'active':
      return kTeal;
    case 'scheduled':
      return Colors.blue.shade700;
    case 'paused':
      return Colors.blueGrey.shade600;
    default:
      return Colors.red.shade700; // expired / used_up
  }
}

/// "5 Dec 2026 tak (3 din baqi)" / "5 Dec 2026 ko expire hua" / "1 Dec 2026 se shuru".
String _validityText(Coupon c) {
  if (c.status == 'scheduled' && c.validFrom.isNotEmpty) return '${dateText(c.validFrom)} se shuru';
  if (c.validUntil.isEmpty) return c.validFrom.isEmpty ? 'Koi tareekh ki hadd nahi' : '${dateText(c.validFrom)} se';
  final until = DateTime.tryParse(c.validUntil);
  if (until == null) return '';
  if (c.status == 'expired') return '${dateText(c.validUntil)} ko expire hua';
  final now = DateTime.now();
  final left = DateTime(until.year, until.month, until.day).difference(DateTime(now.year, now.month, now.day)).inDays;
  final tail = left <= 0 ? 'aaj aakhri din' : '$left din baqi';
  return '${dateText(c.validUntil)} tak ($tail)';
}

class _CouponCard extends StatelessWidget {
  final Coupon c;
  final bool busy;
  final ValueChanged<bool> onToggle;
  final VoidCallback onCopy;
  final VoidCallback onShare;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _CouponCard({
    required this.c,
    required this.busy,
    required this.onToggle,
    required this.onCopy,
    required this.onShare,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(c.status);
    final frac = c.usageFraction;
    final rules = <String>[
      if (c.minOrder > 0) 'Kam az kam ${rs(c.minOrder)}',
      if (c.firstOrderOnly) 'Sirf pehla order',
      if (c.perCustomerLimit == 0) 'Customer be-had' else 'Har customer ${c.perCustomerLimit} dafa',
    ];
    return Opacity(
      opacity: c.isFinished ? 0.75 : 1,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 6, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: kTeal.withValues(alpha: 0.08),
                      border: Border.all(color: kTeal.withValues(alpha: 0.4)),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(c.code,
                        style: const TextStyle(
                            fontWeight: FontWeight.w900, letterSpacing: 1.2, color: kTealDark, fontSize: 15)),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
                    child: Text(couponStatusText(c.status),
                        style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 11.5)),
                  ),
                  const Spacer(),
                  PopupMenuButton<String>(
                    enabled: !busy,
                    onSelected: (v) => v == 'edit' ? onEdit() : onDelete(),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'edit', child: Text('Badlein')),
                      PopupMenuItem(value: 'delete', child: Text('Delete')),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(c.label, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900)),
              if (c.title.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(c.title, style: const TextStyle(color: Colors.black54)),
                ),
              const SizedBox(height: 6),
              Text(rules.join('  •  '), style: const TextStyle(color: Colors.black54, fontSize: 12.5)),
              const SizedBox(height: 2),
              Text(_validityText(c), style: const TextStyle(color: Colors.black54, fontSize: 12.5)),
              const SizedBox(height: 10),
              if (frac != null) ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: frac,
                    minHeight: 8,
                    backgroundColor: kBg,
                    color: frac >= 1 ? Colors.red.shade600 : kTeal,
                  ),
                ),
                const SizedBox(height: 4),
                Text('${c.used} / ${c.usageLimit} istemal  •  ${c.remaining ?? 0} baqi',
                    style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
              ] else
                Text('${c.used} dafa istemal  •  be-had', style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
              if (c.given > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text('Ab tak ${rs(c.given)} ki chhoot di',
                      style: TextStyle(fontSize: 12.5, color: Colors.amber.shade900, fontWeight: FontWeight.w700)),
                ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Switch(value: c.isActive, onChanged: busy ? null : onToggle),
                  Text(c.isActive ? 'Chalu' : 'Band',
                      style: TextStyle(fontWeight: FontWeight.w700, color: c.isActive ? kTeal : Colors.black54)),
                  const Spacer(),
                  IconButton(tooltip: 'Code copy', onPressed: onCopy, icon: const Icon(Icons.copy_rounded)),
                  IconButton(
                      tooltip: 'WhatsApp par bhejein',
                      onPressed: onShare,
                      icon: const Icon(Icons.share_rounded, color: Color(0xFF25D366))),
                  if (busy)
                    const Padding(
                      padding: EdgeInsets.only(right: 10),
                      child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.2)),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ======================================================================================================
// Naya coupon / coupon badlein
// ======================================================================================================

class _UpperFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) =>
      newValue.copyWith(text: newValue.text.toUpperCase());
}

String _plain(double v) {
  if (v == v.roundToDouble()) return v.toStringAsFixed(0);
  return v.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
}

class CouponFormScreen extends StatefulWidget {
  /// Null ho to naya coupon.
  final Coupon? coupon;
  const CouponFormScreen({super.key, this.coupon});

  @override
  State<CouponFormScreen> createState() => _CouponFormScreenState();
}

class _CouponFormScreenState extends State<CouponFormScreen> {
  static const double _maxPercent = 70; // server ki hadd (vendor coupon)
  static const double _maxMoney = 100000;

  final _scroll = ScrollController();
  final _code = TextEditingController();
  final _title = TextEditingController();
  final _value = TextEditingController();
  final _maxDiscount = TextEditingController();
  final _minOrder = TextEditingController();
  final _usage = TextEditingController();
  final _perCustomer = TextEditingController(text: '1');
  String _type = kCouponPercent;
  bool _firstOrder = false;
  DateTime? _from;
  DateTime? _until;
  bool _saving = false;
  List<String> _errors = const [];
  final String _key = _newKey();

  bool get _editing => widget.coupon != null;
  bool get _locked => widget.coupon?.coreLocked ?? false;

  @override
  void initState() {
    super.initState();
    final c = widget.coupon;
    if (c != null) {
      _code.text = c.code;
      _title.text = c.title;
      _type = c.discountType;
      if (c.discountType != kCouponFreeDelivery) _value.text = _plain(c.value);
      if (c.maxDiscount != null) _maxDiscount.text = _plain(c.maxDiscount!);
      if (c.minOrder > 0) _minOrder.text = _plain(c.minOrder);
      if (c.usageLimit != null) _usage.text = '${c.usageLimit}';
      _perCustomer.text = '${c.perCustomerLimit}';
      _firstOrder = c.firstOrderOnly;
      _from = DateTime.tryParse(c.validFrom);
      _until = DateTime.tryParse(c.validUntil);
    }
    for (final t in [_code, _title, _value, _maxDiscount, _minOrder, _usage, _perCustomer]) {
      t.addListener(_refresh);
    }
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    for (final t in [_code, _title, _value, _maxDiscount, _minOrder, _usage, _perCustomer]) {
      t.removeListener(_refresh);
      t.dispose();
    }
    _scroll.dispose();
    super.dispose();
  }

  double? _num(TextEditingController t) => double.tryParse(t.text.trim().replaceAll(',', ''));

  List<String> _validate() {
    final errs = <String>[];
    final code = _code.text.trim().toUpperCase();
    if (!_editing && !RegExp(r'^[A-Z0-9]{3,20}$').hasMatch(code)) {
      errs.add('Code 3 se 20 harf/number ka ho (jaise WELCOME50), koi space ya nishan nahi');
    }
    if (_type != kCouponFreeDelivery && !_locked) {
      final v = _num(_value);
      if (v == null || v <= 0) {
        errs.add('Discount ki miqdar likhein');
      } else if (_type == kCouponPercent && v > _maxPercent) {
        errs.add('Percent 1 se ${_maxPercent.toInt()} ke beech hona chahiye');
      } else if (_type == kCouponFixed && v > _maxMoney) {
        errs.add('Rs. discount ${rs(_maxMoney)} se zyada nahi ho sakta');
      }
      if (_type == kCouponPercent && _maxDiscount.text.trim().isNotEmpty) {
        final m = _num(_maxDiscount);
        if (m == null || m < 1 || m > _maxMoney) errs.add('Max discount sahi likhein');
      }
    }
    if (_minOrder.text.trim().isNotEmpty) {
      final m = _num(_minOrder);
      if (m == null || m < 0) errs.add('Minimum order sahi likhein');
    }
    if (_usage.text.trim().isNotEmpty) {
      final u = int.tryParse(_usage.text.trim());
      if (u == null || u < 1) errs.add('Kul istemal kam az kam 1 ho (ya khali chhorein)');
    }
    if (_perCustomer.text.trim().isNotEmpty) {
      final p = int.tryParse(_perCustomer.text.trim());
      if (p == null || p < 0 || p > 100) errs.add('Har customer ki hadd 0 se 100 ke beech ho (0 = be-had)');
    }
    if (_from != null && _until != null && _until!.isBefore(_from!)) {
      errs.add('Khatam ki tareekh shuru se pehle nahi ho sakti');
    }
    return errs;
  }

  Map<String, dynamic> _body() {
    String t(TextEditingController c) => c.text.trim().replaceAll(',', '');
    return {
      'code': _code.text.trim().toUpperCase(),
      'title': _title.text.trim(),
      'discount_type': _type,
      if (_type != kCouponFreeDelivery) 'value': t(_value),
      if (_type == kCouponPercent) 'max_discount': t(_maxDiscount),
      'min_order': t(_minOrder),
      'usage_limit': t(_usage),
      'per_customer_limit': t(_perCustomer).isEmpty ? '1' : t(_perCustomer),
      'first_order_only': _firstOrder,
      'valid_from': _from == null ? '' : ymdOf(_from!),
      'valid_until': _until == null ? '' : ymdOf(_until!),
    };
  }

  void _toTop() {
    if (_scroll.hasClients) {
      _scroll.animateTo(0, duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    FocusScope.of(context).unfocus();
    final errs = _validate();
    if (errs.isNotEmpty) {
      setState(() => _errors = errs);
      _toTop();
      return;
    }
    setState(() {
      _saving = true;
      _errors = const [];
    });
    try {
      final r = await Api.saveCoupon(id: widget.coupon?.id, fields: _body(), requestKey: _key);
      if (!mounted) return;
      Navigator.of(context).pop(r);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.authExpired) {
        await AppScope.read(context).handleAuthExpired();
        if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
        return;
      }
      setState(() => _errors = e.errors.isNotEmpty ? e.errors : [e.message]);
      _toTop();
    } catch (_) {
      if (!mounted) return;
      setState(() => _errors = const ['Kuch masla aa gaya. Dobara koshish karein.']);
      _toTop();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pickDate(bool isFrom) async {
    final now = DateTime.now();
    final init = (isFrom ? _from : _until) ?? now;
    final floor = DateTime(now.year - 1);
    final d = await showDatePicker(
      context: context,
      initialDate: init,
      firstDate: init.isBefore(floor) ? init : floor,
      lastDate: DateTime(now.year + 5, 12, 31),
    );
    if (d == null || !mounted) return;
    setState(() {
      if (isFrom) {
        _from = d;
      } else {
        _until = d;
      }
    });
  }

  // ------------------------------------------------------------------ build

  Widget _preview() {
    final v = _num(_value) ?? 0;
    final mx = _num(_maxDiscount);
    String label;
    if (_type == kCouponFreeDelivery) {
      label = 'Free delivery';
    } else if (v <= 0) {
      label = 'Discount likhein';
    } else {
      label = couponLabel(type: _type, value: v, maxDiscount: mx);
    }
    final code = _code.text.trim().isEmpty ? 'CODE' : _code.text.trim().toUpperCase();
    final min = _num(_minOrder) ?? 0;
    final lines = <String>[
      if (min > 0) 'Kam az kam ${rs(min)} ka order',
      if (_firstOrder) 'Sirf pehle order par',
      if (_until != null) '${dateText(ymdOf(_until!))} tak',
    ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [kTeal, kTealDark], begin: Alignment.topLeft, end: Alignment.bottomRight),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w900)),
          if (_title.text.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(_title.text.trim(), style: const TextStyle(color: Colors.white70, fontSize: 14)),
            ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.16),
              border: Border.all(color: Colors.white54),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text('Code: $code',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, letterSpacing: 1.3)),
          ),
          if (lines.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(lines.join('  •  '), style: const TextStyle(color: Colors.white70, fontSize: 12.5)),
          ],
        ],
      ),
    );
  }

  Widget _dateTile(String label, DateTime? d, bool isFrom) {
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: _saving ? null : () => _pickDate(isFrom),
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: label,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            suffixIcon: d == null
                ? const Icon(Icons.calendar_month_outlined)
                : IconButton(
                    tooltip: 'Hataein',
                    icon: const Icon(Icons.close),
                    onPressed: _saving
                        ? null
                        : () => setState(() {
                              if (isFrom) {
                                _from = null;
                              } else {
                                _until = null;
                              }
                            }),
                  ),
          ),
          child: Text(d == null ? 'Koi hadd nahi' : dateText(ymdOf(d)),
              style: TextStyle(color: d == null ? Colors.black45 : Colors.black87)),
        ),
      ),
    );
  }

  InputDecoration _dec(String label, {String? hint, String? helper, String? prefix, String? suffix}) => InputDecoration(
        labelText: label,
        hintText: hint,
        helperText: helper,
        helperMaxLines: 2,
        prefixText: prefix,
        suffixText: suffix,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      );

  @override
  Widget build(BuildContext context) {
    final free = _type == kCouponFreeDelivery;
    final decimal = const TextInputType.numberWithOptions(decimal: true);
    final decFmt = [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))];
    return Scaffold(
      appBar: AppBar(title: Text(_editing ? 'Coupon badlein' : 'Naya coupon')),
      body: ListView(
        controller: _scroll,
        padding: const EdgeInsets.all(16),
        children: [
          for (final e in _errors) ...[
            NoticeCard(level: NoticeLevel.error, text: e),
            const SizedBox(height: 8),
          ],
          if (_locked) ...[
            const NoticeCard(
              icon: Icons.lock_outline,
              text: 'Yeh coupon istemal ho chuka hai - code, qism aur discount badal nahi sakte. Baqi cheezein badal sakte hain.',
            ),
            const SizedBox(height: 12),
          ],
          const Text('Customer ko aise dikhega', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
          const SizedBox(height: 8),
          _preview(),
          const SizedBox(height: 18),
          TextField(
            controller: _code,
            enabled: !_editing && !_saving,
            maxLength: 20,
            textCapitalization: TextCapitalization.characters,
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9]')), _UpperFormatter()],
            decoration: _dec('Coupon code', hint: 'jaise WELCOME50', helper: _editing ? 'Code badal nahi sakta' : '3 se 20 harf / number'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _title,
            enabled: !_saving,
            maxLength: 80,
            decoration: _dec('Title (optional)', hint: 'jaise Pehle order par 20% off'),
          ),
          const SizedBox(height: 8),
          const Text('Qism', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: kCouponPercent, label: Text('Percent %')),
              ButtonSegment(value: kCouponFixed, label: Text('Rs. off')),
              ButtonSegment(value: kCouponFreeDelivery, label: Text('Free delivery')),
            ],
            selected: {_type},
            onSelectionChanged: (_saving || _locked) ? null : (sel) => setState(() => _type = sel.first),
          ),
          const SizedBox(height: 14),
          if (!free)
            TextField(
              controller: _value,
              enabled: !_saving && !_locked,
              keyboardType: decimal,
              inputFormatters: decFmt,
              decoration: _dec(
                _type == kCouponPercent ? 'Kitne percent' : 'Kitne rupay',
                helper: _type == kCouponPercent ? 'Zyada se zyada ${_maxPercent.toInt()}%' : null,
                suffix: _type == kCouponPercent ? '%' : null,
                prefix: _type == kCouponFixed ? 'Rs ' : null,
              ),
            ),
          if (_type == kCouponPercent) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _maxDiscount,
              enabled: !_saving && !_locked,
              keyboardType: decimal,
              inputFormatters: decFmt,
              decoration: _dec('Zyada se zyada discount (optional)', prefix: 'Rs ', helper: 'Khali = koi hadd nahi'),
            ),
          ],
          if (free)
            const Padding(
              padding: EdgeInsets.only(bottom: 4),
              child: Text('Delivery ka kharcha maaf ho jayega (jab order par delivery fee ho).',
                  style: TextStyle(color: Colors.black54)),
            ),
          const SizedBox(height: 12),
          TextField(
            controller: _minOrder,
            enabled: !_saving,
            keyboardType: decimal,
            inputFormatters: decFmt,
            decoration: _dec('Kam az kam order (optional)', prefix: 'Rs ', helper: 'Delivery ke baghair items ka total'),
          ),
          const SizedBox(height: 18),
          const Text('Hadood', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: _usage,
                  enabled: !_saving,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: _dec('Kul istemal', helper: 'Khali = be-had'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _perCustomer,
                  enabled: !_saving,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: _dec('Har customer', helper: '0 = be-had'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _firstOrder,
            onChanged: _saving ? null : (v) => setState(() => _firstOrder = v),
            title: const Text('Sirf pehle order ke liye', style: TextStyle(fontWeight: FontWeight.w700)),
            subtitle: const Text('Naye customer ke pehle order par hi chalega'),
          ),
          const SizedBox(height: 8),
          const Text('Tareekh', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
          const SizedBox(height: 8),
          Row(children: [_dateTile('Shuru', _from, true), const SizedBox(width: 10), _dateTile('Khatam', _until, false)]),
          const SizedBox(height: 22),
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))
                : const Icon(Icons.check),
            label: Text(_saving ? 'Save ho raha hai...' : (_editing ? 'Badlav save karein' : 'Coupon banayein')),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
