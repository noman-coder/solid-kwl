import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../models/offers.dart';
import '../services/api.dart';
import '../services/app_state.dart';
import '../theme.dart';
import '../utils.dart';
import '../widgets/empty_state.dart';
import '../widgets/notice_card.dart';
import '../widgets/skeleton.dart';

/// Phase V13-B: Offers. Vendor kisi product par waqt-wala discount (start - end tareekh) lagata hai.
/// Product ki asli price kabhi nahi badalti: customer ko offer sirf us dauran dikhta hai, khatam hote hi price pehli jaisi.
/// Do discount jama nahi hote: customer ko product ka apna discount ya offer, jo bara ho.
/// Pull-to-refresh, skeleton, empty, error + retry, net band ho to purani list, double-tap lock.
class OffersScreen extends StatefulWidget {
  const OffersScreen({super.key});

  @override
  State<OffersScreen> createState() => _OffersScreenState();
}

/// More tab se Offers screen kholo.
Future<void> openOffersScreen(BuildContext context) {
  final state = AppScope.read(context);
  return Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => AppScope(state: state, child: const OffersScreen()),
  ));
}

String _newKey() {
  const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  final r = math.Random.secure();
  return List.generate(20, (_) => chars[r.nextInt(chars.length)]).join();
}

Color _stateColor(String st) {
  switch (st) {
    case 'live':
      return kTeal;
    case 'scheduled':
      return Colors.blue.shade700;
    case 'paused':
      return Colors.amber.shade900;
    default:
      return Colors.grey.shade600;
  }
}

Widget _thumb(String? url, {double size = 54}) {
  final ph = Container(
    width: size,
    height: size,
    color: const Color(0xFFEFF3F2),
    child: const Icon(Icons.fastfood_outlined, color: Colors.black38),
  );
  return ClipRRect(
    borderRadius: BorderRadius.circular(10),
    child: url == null
        ? ph
        : Image.network(Api.absUrl(url), width: size, height: size, fit: BoxFit.cover, errorBuilder: (_, __, ___) => ph),
  );
}

class _OffersScreenState extends State<OffersScreen> {
  OffersPage? _page;
  bool _loading = false;
  bool _stale = false; // purani (phone mein save) list dikh rahi hai
  String? _error;
  String _filter = 'all'; // all | live | scheduled | ended
  final Set<int> _busy = <int>{};
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final cached = await Api.cachedOffers();
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
      final p = await Api.offers();
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

  bool _matches(Offer o) {
    switch (_filter) {
      case 'live':
        return o.state == 'live' || o.state == 'paused';
      case 'scheduled':
        return o.state == 'scheduled';
      case 'ended':
        return o.isEnded;
      default:
        return true;
    }
  }

  int _count(String f) {
    final list = _page?.offers ?? const <Offer>[];
    return list.where((o) {
      switch (f) {
        case 'live':
          return o.state == 'live' || o.state == 'paused';
        case 'scheduled':
          return o.state == 'scheduled';
        case 'ended':
          return o.isEnded;
        default:
          return true;
      }
    }).length;
  }

  // ------------------------------------------------------------------ actions

  Future<void> _openForm([Offer? o]) async {
    final page = _page;
    if (o == null && page != null && page.offers.length >= page.summary.max) {
      _snack('Zyada se zyada ${page.summary.max} offers ho sakte hain. Purane delete karein.');
      return;
    }
    final state = AppScope.read(context);
    final r = await Navigator.of(context).push<OfferActionResult>(MaterialPageRoute(
      builder: (_) => AppScope(state: state, child: OfferFormScreen(offer: o, limits: page)),
    ));
    if (r == null || !mounted) return;
    setState(() {
      _page = r.page;
      _stale = false;
    });
    _snack(r.message.isEmpty ? 'Offer save ho gaya.' : r.message);
  }

  Future<void> _run(Offer o, Future<OfferActionResult> Function() action) async {
    if (!_busy.add(o.id)) return;
    setState(() {});
    try {
      final r = await action();
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
      if (e.code == 'not_found' || e.code == 'ended') _load();
    } catch (_) {
      if (mounted) _snack('Kuch masla aa gaya. Dobara koshish karein.');
    } finally {
      _busy.remove(o.id);
      if (mounted) setState(() {});
    }
  }

  Future<void> _toggle(Offer o, bool on) => _run(o, () => Api.setOfferActive(o.id, on));

  Future<void> _delete(Offer o) async {
    if (_busy.contains(o.id)) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${o.product.name} ka offer delete karein?'),
        content: const Text('Offer hat jayega aur price foran pehli jaisi ho jayegi. Purane orders ka hisaab wahi rahega.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Nahi')),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(100, 44), backgroundColor: Colors.red.shade700),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _run(o, () => Api.deleteOffer(o.id));
  }

  Future<void> _whatsapp(Offer o) async {
    final text = o.shareText.isEmpty ? '${o.product.name} par offer' : o.shareText;
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
      ['scheduled', 'Jald shuru'],
      ['ended', 'Khatam'],
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

  List<Widget> _content(OffersPage page) {
    final out = <Widget>[];
    if (_error != null) {
      out
        ..add(NoticeCard(
          level: NoticeLevel.warn,
          icon: Icons.cloud_off_outlined,
          text: _stale ? 'Net nahi chal raha. Purani list dikh rahi hai.' : 'Taza data nahi aaya. Purana data dikh raha hai.',
          actionLabel: 'Dobara',
          onAction: _load,
        ))
        ..add(const SizedBox(height: 10));
    }
    out
      ..add(Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: kTeal.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(14)),
        child: Row(
          children: [
            const Icon(Icons.bolt, color: kTeal),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '${page.summary.live} offer chalu  -  ${page.summary.scheduled} jald shuru\n${page.summary.total} / ${page.summary.max} bane hain',
                style: const TextStyle(fontWeight: FontWeight.w700, height: 1.35),
              ),
            ),
          ],
        ),
      ))
      ..add(const SizedBox(height: 8))
      ..add(const Text(
        'Offer sirf chune hue din tak chalta hai. Product ki asli price nahi badalti. Product ka apna discount bhi ho to customer ko jo bara ho wohi milta hai.',
        style: TextStyle(color: Colors.black54, fontSize: 12.5),
      ))
      ..add(const SizedBox(height: 12))
      ..add(_chips())
      ..add(const SizedBox(height: 10));

    final shown = page.offers.where(_matches).toList();
    if (shown.isEmpty) {
      out.add(const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: Text('Is filter mein koi offer nahi.', style: TextStyle(color: Colors.black54))),
      ));
    }
    for (final o in shown) {
      out
        ..add(_OfferCard(
          offer: o,
          busy: _busy.contains(o.id),
          onEdit: o.isEnded ? null : () => _openForm(o),
          onToggle: (v) => _toggle(o, v),
          onDelete: () => _delete(o),
          onShare: () => _whatsapp(o),
        ))
        ..add(const SizedBox(height: 10));
    }
    out.add(const SizedBox(height: 80));
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final page = _page;
    Widget body;
    if (page == null && _loading) {
      body = const Padding(padding: EdgeInsets.all(16), child: SkeletonList(count: 4, height: 120));
    } else if (page == null) {
      body = ListView(children: [
        const SizedBox(height: 60),
        EmptyState(
          icon: Icons.cloud_off_outlined,
          title: 'Offers nahi khul sake',
          message: _error ?? 'Dobara koshish karein.',
          action: FilledButton(onPressed: _load, child: const Text('Dobara koshish')),
        ),
      ]);
    } else if (page.offers.isEmpty) {
      body = ListView(children: [
        const SizedBox(height: 60),
        EmptyState(
          icon: Icons.bolt_outlined,
          title: 'Abhi koi offer nahi',
          message: 'Kisi product par kuch din ka discount lagayein - customer ko "OFF" badge ke saath dikhega.',
          action: FilledButton.icon(onPressed: () => _openForm(), icon: const Icon(Icons.add), label: const Text('Pehla offer banayein')),
        ),
      ]);
    } else {
      body = ListView(padding: const EdgeInsets.all(16), children: _content(page));
    }
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(title: const Text('Offers')),
      floatingActionButton: (page == null || page.offers.isEmpty)
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _openForm(),
              icon: const Icon(Icons.add),
              label: const Text('Naya offer'),
            ),
      body: RefreshIndicator(onRefresh: _load, child: body),
    );
  }
}

class _OfferCard extends StatelessWidget {
  final Offer offer;
  final bool busy;
  final VoidCallback? onEdit;
  final ValueChanged<bool> onToggle;
  final VoidCallback onDelete;
  final VoidCallback onShare;

  const _OfferCard({
    required this.offer,
    required this.busy,
    required this.onEdit,
    required this.onToggle,
    required this.onDelete,
    required this.onShare,
  });

  @override
  Widget build(BuildContext context) {
    final o = offer;
    final color = _stateColor(o.state);
    final when = o.state == 'scheduled'
        ? '${dateText(o.startsOn)} se ${dateText(o.endsOn)} tak'
        : '${dateText(o.endsOn)} tak${o.daysLeft != null ? '  (${o.daysLeft} din baqi)' : ''}';
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: busy ? null : onEdit,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _thumb(o.product.image),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(o.product.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800)),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Text(rs(o.offerPrice), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: kTeal)),
                            const SizedBox(width: 8),
                            Text(rs(o.regularPrice),
                                style: const TextStyle(decoration: TextDecoration.lineThrough, color: Colors.black45, fontSize: 13)),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
                    child: Text('${numText(o.discountPercent)}% OFF', style: TextStyle(color: color, fontWeight: FontWeight.w800)),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(8)),
                    child: Text(offerStateText(o.state), style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700)),
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(when, style: const TextStyle(color: Colors.black54, fontSize: 12.5))),
                ],
              ),
              if (!o.effective && !o.isEnded) ...[
                const SizedBox(height: 6),
                Text('Product ka apna ${numText(o.productDiscount)}% discount bara hai, isliye offer ka asar nahi.',
                    style: TextStyle(color: Colors.amber.shade900, fontSize: 12)),
              ],
              const SizedBox(height: 4),
              Row(
                children: [
                  if (!o.isEnded) ...[
                    Switch(value: o.isActive, onChanged: busy ? null : onToggle),
                    Text(o.isActive ? 'Chalu' : 'Band', style: const TextStyle(fontSize: 12.5)),
                  ],
                  const Spacer(),
                  if (busy)
                    const Padding(padding: EdgeInsets.all(10), child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
                  else ...[
                    if (!o.isEnded) IconButton(tooltip: 'WhatsApp par share', onPressed: onShare, icon: const Icon(Icons.share_outlined)),
                    IconButton(tooltip: 'Delete', onPressed: onDelete, icon: Icon(Icons.delete_outline, color: Colors.red.shade700)),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ====================================================================== form

/// Naya offer ([offer] null) ya purana edit (product nahi badalta). Kamyab hone par [OfferActionResult] ke saath wapas.
class OfferFormScreen extends StatefulWidget {
  final Offer? offer;
  final OffersPage? limits;
  const OfferFormScreen({super.key, this.offer, this.limits});

  @override
  State<OfferFormScreen> createState() => _OfferFormScreenState();
}

class _OfferFormScreenState extends State<OfferFormScreen> {
  final _pct = TextEditingController();
  OfferPick? _pick;
  DateTime _start = DateTime.now();
  late DateTime _end = DateTime.now().add(const Duration(days: 6));
  bool _saving = false;
  String? _error;
  String _key = _newKey(); // retry par wohi key: offer dohra nahi banta

  Offer? get _edit => widget.offer;
  bool get _liveEdit => _edit != null && (_edit!.state == 'live' || _edit!.state == 'paused') && _startedAlready;
  bool get _startedAlready {
    final d = DateTime.tryParse(_edit?.startsOn ?? '');
    if (d == null) return false;
    final n = DateTime.now();
    return !d.isAfter(DateTime(n.year, n.month, n.day));
  }

  double get _maxPct => _edit?.maxPercent ?? _pick?.maxPercent ?? (widget.limits?.maxPercent ?? 70);
  double get _value => double.tryParse(_pct.text.trim()) ?? 0;

  @override
  void initState() {
    super.initState();
    final o = _edit;
    if (o != null) {
      _pct.text = numText(o.discountPercent);
      _start = DateTime.tryParse(o.startsOn) ?? _start;
      _end = DateTime.tryParse(o.endsOn) ?? _end;
    }
  }

  @override
  void dispose() {
    _pct.dispose();
    super.dispose();
  }

  Future<void> _choose() async {
    final p = await showModalBottomSheet<OfferPick>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _ProductPickSheet(),
    );
    if (p == null || !mounted) return;
    setState(() {
      _pick = p;
      _error = null;
      if (_value > p.maxPercent) _pct.text = numText(p.maxPercent);
    });
  }

  Future<void> _pickDate(bool start) async {
    final today = DateTime.now();
    final first = DateTime(today.year, today.month, today.day);
    final init = start ? _start : _end;
    final d = await showDatePicker(
      context: context,
      initialDate: init.isBefore(first) ? first : init,
      firstDate: start && _edit != null ? (init.isBefore(first) ? init : first) : first,
      lastDate: first.add(const Duration(days: 365)),
    );
    if (d == null || !mounted) return;
    setState(() {
      if (start) {
        _start = d;
        if (_end.isBefore(d)) _end = d;
      } else {
        _end = d;
        if (_start.isAfter(d)) _start = d;
      }
      _error = null;
    });
  }

  String? _validate() {
    if (_edit == null && _pick == null) return 'Pehle product chunein.';
    final v = _value;
    if (v <= 0) return 'Discount % likhein (maslan 15).';
    if (v < (widget.limits?.minPercent ?? 1)) return 'Discount kam az kam ${numText(widget.limits?.minPercent ?? 1)}% hona chahiye.';
    if (v > _maxPct) return 'Is product par zyada se zyada ${numText(_maxPct)}% offer ho sakta hai.';
    final days = _end.difference(_start).inDays + 1;
    if (days < 1) return 'Khatam ki tareekh shuru se pehle nahi ho sakti.';
    if (days > (widget.limits?.maxDays ?? 90)) return 'Offer zyada se zyada ${widget.limits?.maxDays ?? 90} din ka ho sakta hai.';
    return null;
  }

  Future<void> _save() async {
    if (_saving) return;
    final bad = _validate();
    if (bad != null) {
      setState(() => _error = bad);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final fields = <String, dynamic>{
        if (_edit == null) 'product_id': _pick!.id,
        'discount_percent': _value,
        'starts_on': ymdOf(_start),
        'ends_on': ymdOf(_end),
      };
      final r = await Api.saveOffer(id: _edit?.id, fields: fields, requestKey: _key);
      if (!mounted) return;
      Navigator.of(context).pop(r);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.authExpired) {
        await AppScope.read(context).handleAuthExpired();
        if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
        return;
      }
      setState(() {
        _saving = false;
        _error = e.errors.isNotEmpty ? e.errors.join('\n') : e.message;
        // server ne saaf jawab diya (ghalti) -> nayi key; net ka masla ho to wohi key (offer dohra nahi banega)
        if (e.code != 'network') _key = _newKey();
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Kuch masla aa gaya. Dobara koshish karein.';
      });
    }
  }

  Widget _preview() {
    final name = _edit?.product.name ?? _pick?.name ?? 'Product';
    final img = _edit?.product.image ?? _pick?.image;
    final base = _edit?.basePrice ?? _pick?.basePrice ?? 0;
    final own = _edit?.productDiscount ?? _pick?.productDiscount ?? 0;
    final v = _value.clamp(0, 100).toDouble();
    final eff = v > own ? v : own;
    final price = base * (100 - eff) / 100;
    final regular = base * (100 - own) / 100;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: kBorder),
      ),
      child: Row(
        children: [
          _thumb(img, size: 64),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text(rs(price.round()), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17, color: kTeal)),
                    if (price < regular) ...[
                      const SizedBox(width: 8),
                      Text(rs(regular.round()),
                          style: const TextStyle(decoration: TextDecoration.lineThrough, color: Colors.black45)),
                    ],
                  ],
                ),
              ],
            ),
          ),
          if (eff > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
              decoration: BoxDecoration(color: Colors.red.shade600, borderRadius: BorderRadius.circular(8)),
              child: Text('${numText(eff)}% OFF', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12)),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final editing = _edit != null;
    final prod = _edit?.product.name ?? _pick?.name;
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(title: Text(editing ? 'Offer badlein' : 'Naya offer')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Product', style: TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              onTap: editing || _saving ? null : _choose,
              leading: const Icon(Icons.inventory_2_outlined, color: kTeal),
              title: Text(prod ?? 'Product chunein', style: TextStyle(fontWeight: FontWeight.w700, color: prod == null ? Colors.black54 : null)),
              subtitle: _pick != null ? Text('Asli rate ${rs(_pick!.basePrice)}  -  zyada se zyada ${numText(_pick!.maxPercent)}% offer') : null,
              trailing: editing ? null : const Icon(Icons.chevron_right),
            ),
          ),
          const SizedBox(height: 16),
          const Text('Discount %', style: TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          TextField(
            controller: _pct,
            enabled: !_saving,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              hintText: 'maslan 15',
              suffixText: '%',
              helperText: 'Zyada se zyada ${numText(_maxPct)}% (commission ki hadd)',
            ),
            onChanged: (_) => setState(() => _error = null),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final c in const [5, 10, 15, 20, 25, 30])
                if (c <= _maxPct)
                  ActionChip(label: Text('$c%'), onPressed: _saving ? null : () => setState(() => _pct.text = '$c')),
            ],
          ),
          const SizedBox(height: 16),
          const Text('Kab se kab tak', style: TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _saving || _liveEdit ? null : () => _pickDate(true),
                  icon: const Icon(Icons.event),
                  label: Text(dateText(ymdOf(_start))),
                ),
              ),
              const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Text('se')),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _saving ? null : () => _pickDate(false),
                  icon: const Icon(Icons.event_available),
                  label: Text(dateText(ymdOf(_end))),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            _liveEdit
                ? 'Chalu offer ki shuruaat nahi badal sakte. Khatam ki tareekh (shamil) badal sakte hain.'
                : 'Offer aakhri tareekh ke din raat tak chalta hai.',
            style: const TextStyle(color: Colors.black54, fontSize: 12.5),
          ),
          const SizedBox(height: 18),
          const Text('Customer ko aise dikhega', style: TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          _preview(),
          if (_error != null) ...[
            const SizedBox(height: 14),
            NoticeCard(level: NoticeLevel.error, text: _error!),
          ],
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _saving ? null : _save,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
            child: _saving
                ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))
                : Text(editing ? 'Save karein' : 'Offer lagayein'),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

// ====================================================================== product picker

class _ProductPickSheet extends StatefulWidget {
  const _ProductPickSheet();

  @override
  State<_ProductPickSheet> createState() => _ProductPickSheetState();
}

class _ProductPickSheetState extends State<_ProductPickSheet> {
  final _q = TextEditingController();
  List<OfferPick>? _items;
  String? _error;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final seq = ++_seq;
    setState(() => _error = null);
    try {
      final list = await Api.offerProducts(q: _q.text);
      if (!mounted || seq != _seq) return;
      setState(() => _items = list);
    } on ApiException catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() => _error = e.message);
    } catch (_) {
      if (!mounted || seq != _seq) return;
      setState(() => _error = 'Products nahi aaye. Dobara koshish karein.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.75,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                controller: _q,
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Product ka naam'),
                onSubmitted: (_) => _load(),
              ),
            ),
            Expanded(
              child: _error != null
                  ? EmptyState(
                      icon: Icons.cloud_off_outlined,
                      title: 'Masla aa gaya',
                      message: _error,
                      action: FilledButton(onPressed: _load, child: const Text('Dobara koshish')),
                    )
                  : items == null
                      ? const Padding(padding: EdgeInsets.all(16), child: SkeletonList(count: 5, height: 64))
                      : items.isEmpty
                          ? const EmptyState(
                              icon: Icons.inventory_2_outlined,
                              title: 'Koi product nahi mila',
                              message: 'Offer sirf approved aur chalu products par lagta hai.',
                            )
                          : ListView.separated(
                              itemCount: items.length,
                              separatorBuilder: (_, __) => const Divider(height: 1),
                              itemBuilder: (_, i) {
                                final p = items[i];
                                return ListTile(
                                  leading: _thumb(p.image, size: 44),
                                  title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                                  subtitle: Text(
                                    p.hasOffer ? '${rs(p.regularPrice)}  -  offer pehle se hai' : rs(p.regularPrice),
                                    style: TextStyle(color: p.hasOffer ? Colors.amber.shade900 : Colors.black54, fontSize: 12.5),
                                  ),
                                  onTap: p.maxPercent < 1
                                      ? null
                                      : () => Navigator.pop(context, p),
                                  trailing: p.maxPercent < 1
                                      ? const Text('Hadd nahi', style: TextStyle(fontSize: 11, color: Colors.black45))
                                      : null,
                                );
                              },
                            ),
            ),
          ],
        ),
      ),
    );
  }
}
