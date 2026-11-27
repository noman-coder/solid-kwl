import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/products.dart';
import '../models/stock.dart';
import '../services/api.dart';
import '../services/app_state.dart';
import '../theme.dart';
import '../utils.dart';
import '../widgets/empty_state.dart';
import '../widgets/notice_card.dart';
import '../widgets/skeleton.dart';

/// Phase V10: Stock section (Products tab se). Kam / Khatam list, ek tap par "Stock add", stock kam karna (wajah ke saath),
/// kai products ka stock ek screen par (Bulk), kam-stock ki hadd badalna aur stock ki history.
/// Pull-to-refresh, skeleton, empty, error + retry, offline par purana data. Negative stock server hone nahi deta.
class StockScreen extends StatefulWidget {
  final String initialFilter;
  const StockScreen({super.key, this.initialFilter = 'need'});

  @override
  State<StockScreen> createState() => _StockScreenState();
}

/// Products tab se Stock screen kholo.
Future<void> openStockScreen(BuildContext context, {String filter = 'need'}) {
  final state = AppScope.read(context);
  return Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => AppScope(state: state, child: StockScreen(initialFilter: filter)),
  ));
}

String _newKey() => 'k${DateTime.now().microsecondsSinceEpoch}${Random().nextInt(1 << 30)}';

/// 12 -> "12", 2.5 -> "2.5", 0.125 -> "0.125"
String _fmt(double v) {
  if (v == v.roundToDouble()) return v.toStringAsFixed(0);
  return v.toStringAsFixed(3).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
}

Color _stateColor(String state) {
  switch (state) {
    case 'out':
      return Colors.red.shade700;
    case 'low':
      return Colors.orange.shade800;
    default:
      return Colors.green.shade700;
  }
}

class _StockScreenState extends State<StockScreen> {
  final TextEditingController _search = TextEditingController();
  final ScrollController _sc = ScrollController();
  Timer? _debounce;

  String _filter = 'need';
  String _q = '';
  List<StockItem> _items = [];
  StockSummary _summary = const StockSummary();
  StockReasons _reasons = StockReasons.fallback;
  bool _loaded = false;
  bool _loading = false;
  bool _loadingMore = false;
  bool _hasMore = false;
  String? _error;
  int _page = 1;
  int _seq = 0;

  // Bulk (kai products ka stock add ek saath)
  bool _bulk = false;
  bool _bulkBusy = false;
  String _bulkKey = _newKey();
  final Map<int, TextEditingController> _bulkCtl = {};

  @override
  void initState() {
    super.initState();
    _filter = kStockFilters.contains(widget.initialFilter) ? widget.initialFilter : 'need';
    _sc.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _sc.removeListener(_onScroll);
    _sc.dispose();
    _search.dispose();
    for (final c in _bulkCtl.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _onScroll() {
    if (!_sc.hasClients || !mounted) return;
    if (_sc.position.pixels > _sc.position.maxScrollExtent - 300) _loadMore();
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
      final p = await Api.stock(_filter, q: _q);
      if (!mounted || seq != _seq) return;
      setState(() {
        _items = p.items;
        _summary = p.summary;
        _reasons = p.reasons;
        _page = p.page;
        _hasMore = p.hasMore;
        _loaded = true;
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

  Future<void> _loadMore() async {
    if (_loading || _loadingMore || !_hasMore || !_loaded) return;
    final seq = _seq;
    setState(() => _loadingMore = true);
    try {
      final p = await Api.stock(_filter, page: _page + 1, q: _q);
      if (!mounted || seq != _seq) return;
      final have = _items.map((e) => e.id).toSet();
      setState(() {
        _items = [..._items, ...p.items.where((e) => !have.contains(e.id))];
        _page = p.page;
        _hasMore = p.hasMore;
        _loadingMore = false;
      });
    } on ApiException catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() => _loadingMore = false);
      if (e.authExpired) {
        await _expired();
        return;
      }
      _snack(e.message);
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  void _onSearch(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () {
      if (!mounted) return;
      _q = v.trim();
      _load();
    });
    setState(() {});
  }

  void _clearSearch() {
    _search.clear();
    _debounce?.cancel();
    _q = '';
    setState(() {});
    _load();
  }

  void _pickFilter(String f) {
    if (f == _filter) return;
    if (_sc.hasClients) _sc.jumpTo(0);
    setState(() => _filter = f);
    _load();
  }

  bool _matches(VendorProduct p) {
    switch (_filter) {
      case 'low':
        return p.stockState == 'low';
      case 'out':
        return p.stockState == 'out';
      case 'need':
        return p.stockState != 'ok';
      default:
        return true;
    }
  }

  /// Server se aaye taza items list mein lagao (jo ab filter mein nahi banta use hata do).
  void _applyItems(Iterable<StockItem> fresh, StockSummary summary) {
    final map = {for (final i in fresh) i.id: i};
    setState(() {
      _summary = summary;
      _items = [
        for (final i in _items)
          if (map.containsKey(i.id)) ...[if (_matches(map[i.id]!.product)) map[i.id]!] else i
      ];
    });
    AppScope.read(context).stockChanged();
  }

  // ---------------------------------------------------------------- actions

  Future<void> _openAdjust(StockItem item, String mode) async {
    HapticFeedback.selectionClick();
    final res = await showModalBottomSheet<StockAdjustResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: Colors.white,
      builder: (_) => AppScope(state: AppScope.read(context), child: _AdjustSheet(item: item, mode: mode, reasons: _reasons)),
    );
    if (res == null || !mounted) return;
    final fresh = res.rows.where((r) => r.item != null).map((r) => r.item!);
    _applyItems(fresh, res.summary);
    final row = res.rows.isEmpty ? null : res.rows.first;
    if (row != null && row.item != null && !_matches(row.item!.product) && _filter != 'all') {
      _snack('${row.item!.product.name}: stock theek hai, list se hat gaya.');
    } else {
      _snack(res.message.isEmpty ? 'Stock update ho gaya.' : res.message);
    }
  }

  Future<void> _openThreshold(StockItem item) async {
    final updated = await showModalBottomSheet<StockItem>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: Colors.white,
      builder: (_) => AppScope(
        state: AppScope.read(context),
        child: _ThresholdSheet(item: item, defaultThreshold: _summary.defaultThreshold),
      ),
    );
    if (updated == null || !mounted) return;
    _snack('Kam stock ki hadd badal gayi.');
    // Hadd badli to kam/khatam ki list badal sakti hai: taza load.
    AppScope.read(context).stockChanged();
    _load();
  }

  Future<void> _openHistory({StockItem? item}) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: Colors.white,
      builder: (_) => AppScope(
        state: AppScope.read(context),
        child: _HistorySheet(productId: item?.id, title: item == null ? 'Stock ki history' : item.product.name),
      ),
    );
  }

  void _toggleBulk() {
    HapticFeedback.selectionClick();
    setState(() {
      _bulk = !_bulk;
      for (final c in _bulkCtl.values) {
        c.clear();
      }
      _bulkKey = _newKey();
    });
  }

  TextEditingController _ctl(int id) => _bulkCtl.putIfAbsent(id, () => TextEditingController());

  List<Map<String, dynamic>> _bulkItems() {
    final out = <Map<String, dynamic>>[];
    for (final i in _items) {
      final c = _bulkCtl[i.id];
      final q = c == null ? null : double.tryParse(c.text.trim().replaceAll(',', '.'));
      if (q != null && q > 0) out.add({'id': i.id, 'mode': 'add', 'qty': q, 'reason': 'purchase'});
    }
    return out;
  }

  Future<void> _submitBulk() async {
    final items = _bulkItems();
    if (items.isEmpty || _bulkBusy) return;
    FocusScope.of(context).unfocus();
    setState(() => _bulkBusy = true);
    try {
      final res = await Api.adjustStock(items, requestKey: _bulkKey);
      if (!mounted) return;
      final okIds = res.rows.where((r) => r.ok).map((r) => r.id).toSet();
      for (final id in okIds) {
        _bulkCtl[id]?.clear();
      }
      _bulkKey = _newKey(); // agli dafa naya kaam
      setState(() => _bulkBusy = false);
      _applyItems(res.rows.where((r) => r.item != null).map((r) => r.item!), res.summary);
      final bad = res.failed;
      _snack(bad.isEmpty ? res.message : '${res.doneCount} update hue. ${bad.first.error}');
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _bulkBusy = false);
      if (e.authExpired) {
        await _expired();
        return;
      }
      _snack(e.message); // _bulkKey wahi: dobara dabane par double stock nahi lagega
    } catch (_) {
      if (mounted) {
        setState(() => _bulkBusy = false);
        _snack('Kuch masla aa gaya. Dobara koshish karein.');
      }
    }
  }

  // ---------------------------------------------------------------- build

  ({String title, String message, IconData icon}) _emptyText() {
    if (_q.isNotEmpty) {
      return (title: 'Koi product nahi mila', message: 'Doosra naam ya barcode try karein.', icon: Icons.search_off);
    }
    switch (_filter) {
      case 'out':
        return (title: 'Kisi ka stock khatam nahi', message: 'Shabash! Sab products ka stock maujood hai.', icon: Icons.check_circle_outline);
      case 'low':
        return (title: 'Kisi ka stock kam nahi', message: 'Stock kam hone par yahan dikhega.', icon: Icons.inventory_2_outlined);
      case 'all':
        return (title: 'Abhi koi approved product nahi', message: 'Product approve hone par yahan stock nazar aayega.', icon: Icons.inventory_2_outlined);
      default:
        return (title: 'Sab ka stock theek hai', message: 'Kam ya khatam hone par yahan dikhega.', icon: Icons.check_circle_outline);
    }
  }

  @override
  Widget build(BuildContext context) {
    const physics = AlwaysScrollableScrollPhysics();
    Widget content;
    if (!_loaded && _error != null) {
      content = ListView(
        physics: physics,
        padding: const EdgeInsets.all(12),
        children: [
          NoticeCard(
            level: NoticeLevel.error,
            icon: Icons.cloud_off,
            text: _error!,
            actionLabel: 'Dobara',
            onAction: _load,
          ),
        ],
      );
    } else if (!_loaded) {
      content = ListView(
        physics: physics,
        padding: const EdgeInsets.all(12),
        children: const [SkeletonList(count: 5, height: 110)],
      );
    } else if (_items.isEmpty) {
      final e = _emptyText();
      content = ListView(
        physics: physics,
        children: [SizedBox(height: 380, child: EmptyState(icon: e.icon, title: e.title, message: e.message))],
      );
    } else {
      content = ListView.builder(
        controller: _sc,
        physics: physics,
        padding: EdgeInsets.fromLTRB(12, 12, 12, _bulk ? 100 : 40),
        itemCount: _items.length + 2,
        itemBuilder: (ctx, i) {
          if (i == 0) {
            return _error == null
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: NoticeCard(
                      level: NoticeLevel.warn,
                      icon: Icons.wifi_off,
                      text: 'Offline - purana data dikh raha hai.',
                      actionLabel: 'Dobara',
                      onAction: _load,
                    ),
                  );
          }
          if (i == _items.length + 1) {
            return _loadingMore
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5))),
                  )
                : _hasMore
                    ? TextButton(onPressed: _loadMore, child: const Text('Aur products dikhayein'))
                    : const SizedBox.shrink();
          }
          final item = _items[i - 1];
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _StockCard(
              item: item,
              bulk: _bulk,
              controller: _bulk ? _ctl(item.id) : null,
              onAdd: () => _openAdjust(item, 'add'),
              onMinus: () => _openAdjust(item, 'minus'),
              onThreshold: () => _openThreshold(item),
              onHistory: () => _openHistory(item: item),
              onBulkChanged: () => setState(() {}),
            ),
          );
        },
      );
    }

    final bulkCount = _bulk ? _bulkItems().length : 0;
    return Scaffold(
      appBar: AppBar(
        title: Text(_bulk ? 'Kai products ka stock' : 'Stock'),
        actions: [
          IconButton(
            tooltip: _bulk ? 'Bulk band karein' : 'Kai products ka stock ek saath',
            onPressed: _loaded && _items.isNotEmpty ? _toggleBulk : null,
            icon: Icon(_bulk ? Icons.close : Icons.playlist_add_rounded),
          ),
          if (!_bulk)
            IconButton(
              tooltip: 'Stock ki history',
              onPressed: () => _openHistory(),
              icon: const Icon(Icons.history_rounded),
            ),
        ],
      ),
      body: Column(
        children: [
          Container(
            color: Colors.white,
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
            child: TextField(
              controller: _search,
              onChanged: _onSearch,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Product ka naam ya barcode',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(icon: const Icon(Icons.close), onPressed: _clearSearch),
                isDense: true,
                filled: true,
                fillColor: kBg,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
              ),
            ),
          ),
          Container(
            color: Colors.white,
            height: 48,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              itemCount: kStockFilters.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (ctx, i) {
                final f = kStockFilters[i];
                final sel = f == _filter;
                final int? c = f == 'need'
                    ? _summary.need
                    : f == 'low'
                        ? _summary.low
                        : f == 'out'
                            ? _summary.out
                            : _summary.approved;
                final accent = f == 'out' ? Colors.red.shade700 : (f == 'all' ? kTeal : Colors.orange.shade800);
                return ChoiceChip(
                  label: Text('${kStockFilterLabels[f]} ($c)'),
                  selected: sel,
                  showCheckmark: false,
                  onSelected: (_) => _pickFilter(f),
                  selectedColor: accent.withValues(alpha: 0.14),
                  labelStyle: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: sel ? accent : Colors.black87),
                  side: BorderSide(color: sel ? accent : kBorder),
                  visualDensity: VisualDensity.compact,
                );
              },
            ),
          ),
          const Divider(height: 1),
          Expanded(child: RefreshIndicator(onRefresh: _load, child: content)),
        ],
      ),
      bottomNavigationBar: _bulk
          ? SafeArea(
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                decoration: const BoxDecoration(color: Colors.white, border: Border(top: BorderSide(color: kBorder))),
                child: FilledButton.icon(
                  onPressed: bulkCount == 0 || _bulkBusy ? null : _submitBulk,
                  icon: _bulkBusy
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                      : const Icon(Icons.add_task_rounded),
                  label: Text(bulkCount == 0 ? 'Jis ka stock dalna hai uska number likhein' : '$bulkCount products mein stock add karein'),
                ),
              ),
            )
          : null,
    );
  }
}

// ---------------------------------------------------------------- card

class _StockCard extends StatelessWidget {
  final StockItem item;
  final bool bulk;
  final TextEditingController? controller;
  final VoidCallback onAdd;
  final VoidCallback onMinus;
  final VoidCallback onThreshold;
  final VoidCallback onHistory;
  final VoidCallback onBulkChanged;

  const _StockCard({
    required this.item,
    required this.bulk,
    required this.controller,
    required this.onAdd,
    required this.onMinus,
    required this.onThreshold,
    required this.onHistory,
    required this.onBulkChanged,
  });

  @override
  Widget build(BuildContext context) {
    final p = item.product;
    final color = _stateColor(p.stockState);
    final unit = p.unit.isEmpty ? '' : ' ${p.unit}';
    final label = p.stockState == 'out' ? 'Khatam' : (p.stockState == 'low' ? 'Kam' : 'Theek');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Thumb(path: p.image),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(p.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
                            child: Text(label, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: color)),
                          ),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text('${_fmt(p.stock)}$unit',
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: color)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Kam ki hadd: ${_fmt(p.lowThreshold)}${item.reserved > 0 ? '  •  Orders ke liye roka: ${_fmt(item.reserved)}' : ''}',
                        style: const TextStyle(fontSize: 12, color: Colors.black54),
                      ),
                    ],
                  ),
                ),
                if (!bulk)
                  PopupMenuButton<String>(
                    tooltip: 'Aur',
                    onSelected: (v) => v == 'thr' ? onThreshold() : onHistory(),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'thr', child: Text('Kam stock ki hadd badlein')),
                      PopupMenuItem(value: 'hist', child: Text('Is ki history')),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 10),
            if (bulk)
              TextField(
                controller: controller,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
                onChanged: (_) => onBulkChanged(),
                decoration: InputDecoration(
                  labelText: 'Kitna stock add karna hai',
                  suffixText: p.unit,
                  isDense: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              )
            else
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: onAdd,
                      style: FilledButton.styleFrom(minimumSize: const Size(64, 44)),
                      icon: const Icon(Icons.add, size: 20),
                      label: const Text('Stock add', style: TextStyle(fontSize: 15)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton.icon(
                    onPressed: p.stock > 0 ? onMinus : null,
                    style: OutlinedButton.styleFrom(minimumSize: const Size(64, 44)),
                    icon: const Icon(Icons.remove, size: 20),
                    label: const Text('Kam karein', style: TextStyle(fontSize: 14)),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _Thumb extends StatelessWidget {
  final String? path;
  const _Thumb({required this.path});

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      width: 64,
      height: 64,
      decoration: BoxDecoration(color: kBg, borderRadius: BorderRadius.circular(12)),
      child: const Icon(Icons.inventory_2_outlined, color: Colors.black38),
    );
    if (path == null) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Image.network(
        Api.absUrl(path!),
        width: 64,
        height: 64,
        fit: BoxFit.cover,
        cacheWidth: 200,
        errorBuilder: (_, __, ___) => fallback,
      ),
    );
  }
}

// ---------------------------------------------------------------- stock add / kam sheet

class _AdjustSheet extends StatefulWidget {
  final StockItem item;
  final String mode;
  final StockReasons reasons;
  const _AdjustSheet({required this.item, required this.mode, required this.reasons});

  @override
  State<_AdjustSheet> createState() => _AdjustSheetState();
}

class _AdjustSheetState extends State<_AdjustSheet> {
  final TextEditingController _qty = TextEditingController();
  final TextEditingController _note = TextEditingController();
  late String _mode = widget.mode;
  String _reason = '';
  String _key = _newKey(); // input badle to naya; fail ke baad bina badle dobara = wahi (double stock nahi)
  bool _busy = false;
  String? _error;

  List<StockReason> get _reasonList => _mode == 'add' ? widget.reasons.add : widget.reasons.minus;

  @override
  void initState() {
    super.initState();
    _reason = _reasonList.first.code;
  }

  @override
  void dispose() {
    _qty.dispose();
    _note.dispose();
    super.dispose();
  }

  double? get _q {
    final v = double.tryParse(_qty.text.trim().replaceAll(',', '.'));
    return (v == null || v <= 0) ? null : v;
  }

  double get _available => widget.item.available;

  String? get _problem {
    final q = _q;
    if (q == null) return null;
    if (q > 1000000) return 'Itna zyada quantity nahi (10 lakh tak).';
    if (_mode == 'minus' && q > _available + 1e-9) return 'Itna stock nahi hai. Maujooda: ${_fmt(_available)}';
    return null;
  }

  void _edited() => setState(() {
        _key = _newKey();
        _error = null;
      });

  void _setMode(String m) {
    if (m == _mode) return;
    setState(() {
      _mode = m;
      _reason = _reasonList.first.code;
      _key = _newKey();
      _error = null;
    });
  }

  void _addQty(double v) {
    final cur = _q ?? 0;
    _qty.text = _fmt(cur + v);
    _qty.selection = TextSelection.collapsed(offset: _qty.text.length);
    _edited();
  }

  Future<void> _submit() async {
    final q = _q;
    if (q == null || _problem != null || _busy) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await Api.adjustStock([
        {'id': widget.item.id, 'mode': _mode, 'qty': q, 'reason': _reason, if (_note.text.trim().isNotEmpty) 'note': _note.text.trim()}
      ], requestKey: _key);
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      Navigator.of(context).pop(res);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.authExpired) {
        await AppScope.read(context).handleAuthExpired();
        if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
        return;
      }
      setState(() {
        _busy = false;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Kuch masla aa gaya. Dobara koshish karein.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.item.product;
    final q = _q;
    final after = q == null ? null : (_mode == 'add' ? p.stock + q : p.stock - q);
    final problem = _problem;
    final unit = p.unit.isEmpty ? '' : ' ${p.unit}';
    final quick = _mode == 'add' ? const [5.0, 10.0, 20.0, 50.0] : const <double>[];
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(p.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
            const SizedBox(height: 2),
            Text('Abhi stock: ${_fmt(p.stock)}$unit', style: const TextStyle(color: Colors.black54)),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'add', icon: Icon(Icons.add), label: Text('Stock add')),
                ButtonSegment(value: 'minus', icon: Icon(Icons.remove), label: Text('Stock kam')),
              ],
              selected: {_mode},
              onSelectionChanged: _busy ? null : (picked) => _setMode(picked.first),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _qty,
              autofocus: true,
              enabled: !_busy,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
              onChanged: (_) => _edited(),
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
              decoration: InputDecoration(
                labelText: _mode == 'add' ? 'Kitna stock add karna hai' : 'Kitna stock kam karna hai',
                suffixText: p.unit,
                errorText: problem,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            if (quick.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (final v in quick) ActionChip(label: Text('+${_fmt(v)}'), onPressed: _busy ? null : () => _addQty(v)),
                ],
              ),
            ] else if (_available > 0) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  ActionChip(
                    label: Text('Sab (${_fmt(_available)})'),
                    onPressed: _busy
                        ? null
                        : () {
                            _qty.text = _fmt(_available);
                            _edited();
                          },
                  ),
                ],
              ),
            ],
            if (widget.item.reserved > 0 && _mode == 'minus')
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('${_fmt(widget.item.reserved)}$unit orders ke liye roka hua hai, wo kam nahi ho sakta.',
                    style: const TextStyle(fontSize: 12, color: Colors.black54)),
              ),
            const SizedBox(height: 14),
            const Text('Wajah', style: TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final r in _reasonList)
                  ChoiceChip(
                    label: Text(r.label),
                    selected: _reason == r.code,
                    showCheckmark: false,
                    onSelected: _busy
                        ? null
                        : (_) => setState(() {
                              _reason = r.code;
                              _key = _newKey();
                              _error = null;
                            }),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _note,
              enabled: !_busy,
              maxLength: 200,
              onChanged: (_) => _edited(),
              decoration: InputDecoration(
                labelText: 'Note (zaroori nahi)',
                isDense: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            if (after != null && problem == null)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: kBg, borderRadius: BorderRadius.circular(12)),
                child: Text('Stock: ${_fmt(p.stock)} → ${_fmt(after)}$unit',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: NoticeCard(level: NoticeLevel.error, text: _error!),
              ),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: (q == null || problem != null || _busy) ? null : _submit,
                child: _busy
                    ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                    : Text(_mode == 'add' ? 'Stock add karein' : 'Stock kam karein'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- kam stock ki hadd

class _ThresholdSheet extends StatefulWidget {
  final StockItem item;
  final double defaultThreshold;
  const _ThresholdSheet({required this.item, required this.defaultThreshold});

  @override
  State<_ThresholdSheet> createState() => _ThresholdSheetState();
}

class _ThresholdSheetState extends State<_ThresholdSheet> {
  late final TextEditingController _c = TextEditingController(text: _fmt(widget.item.product.lowThreshold));
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  double? get _v {
    final v = double.tryParse(_c.text.trim().replaceAll(',', '.'));
    return (v == null || v < 1 || v > 1000000) ? null : v;
  }

  Future<void> _save() async {
    final v = _v;
    if (v == null || _busy) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final item = await Api.setStockThreshold(widget.item.id, v);
      if (!mounted) return;
      Navigator.of(context).pop(item);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.authExpired) {
        await AppScope.read(context).handleAuthExpired();
        if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
        return;
      }
      setState(() {
        _busy = false;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Kuch masla aa gaya. Dobara koshish karein.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.item.product;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(p.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
            const SizedBox(height: 4),
            const Text(
              'Stock is hadd se kam ya barabar ho to product "Kam" dikhega aur aap ko alert aayega.',
              style: TextStyle(color: Colors.black54),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _c,
              autofocus: true,
              enabled: !_busy,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
              onChanged: (_) => setState(() => _error = null),
              decoration: InputDecoration(
                labelText: 'Kam stock ki hadd',
                suffixText: p.unit,
                helperText: 'Aam taur par ${_fmt(widget.defaultThreshold)}',
                errorText: _c.text.trim().isNotEmpty && _v == null ? '1 se 10,00,000 ke beech likhein' : null,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 12),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: NoticeCard(level: NoticeLevel.error, text: _error!),
              ),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: (_v == null || _busy) ? null : _save,
                child: _busy
                    ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                    : const Text('Save karein'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- history

class _HistorySheet extends StatefulWidget {
  final int? productId;
  final String title;
  const _HistorySheet({required this.productId, required this.title});

  @override
  State<_HistorySheet> createState() => _HistorySheetState();
}

class _HistorySheetState extends State<_HistorySheet> {
  final List<StockLog> _logs = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  int _page = 1;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool more = false}) async {
    setState(() {
      if (more) {
        _loadingMore = true;
      } else {
        _loading = true;
        _error = null;
      }
    });
    try {
      final p = await Api.stockHistory(productId: widget.productId, page: more ? _page + 1 : 1);
      if (!mounted) return;
      setState(() {
        if (!more) _logs.clear();
        _logs.addAll(p.logs);
        _page = p.page;
        _hasMore = p.hasMore;
        _loading = false;
        _loadingMore = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.authExpired) {
        await AppScope.read(context).handleAuthExpired();
        if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
        return;
      }
      setState(() {
        _loading = false;
        _loadingMore = false;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        _error = 'Kuch masla aa gaya. Dobara koshish karein.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height * 0.75;
    Widget body;
    if (_loading) {
      body = const Padding(padding: EdgeInsets.all(12), child: SkeletonList(count: 4, height: 70));
    } else if (_error != null && _logs.isEmpty) {
      body = Padding(
        padding: const EdgeInsets.all(12),
        child: NoticeCard(level: NoticeLevel.error, icon: Icons.cloud_off, text: _error!, actionLabel: 'Dobara', onAction: _load),
      );
    } else if (_logs.isEmpty) {
      body = const EmptyState(
        icon: Icons.history_rounded,
        title: 'Abhi koi record nahi',
        message: 'Stock add ya kam karne par yahan record bante jayenge.',
      );
    } else {
      body = ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
        itemCount: _logs.length + 1,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (ctx, i) {
          if (i == _logs.length) {
            return _loadingMore
                ? const Padding(padding: EdgeInsets.all(12), child: Center(child: CircularProgressIndicator(strokeWidth: 2.5)))
                : _hasMore
                    ? TextButton(onPressed: () => _load(more: true), child: const Text('Aur dikhayein'))
                    : const SizedBox.shrink();
          }
          final l = _logs[i];
          final color = l.isAdd ? Colors.green.shade700 : Colors.red.shade700;
          final parts = <String>[
            if (l.reasonLabel.isNotEmpty) l.reasonLabel,
            if (l.source == 'quick_update') 'Quick update',
            if (l.note.isNotEmpty) l.note,
          ];
          return ListTile(
            contentPadding: EdgeInsets.zero,
            leading: CircleAvatar(
              backgroundColor: color.withValues(alpha: 0.12),
              child: Icon(l.isAdd ? Icons.add : Icons.remove, color: color),
            ),
            title: Text(widget.productId == null ? l.product : '${l.isAdd ? '+' : '-'}${_fmt(l.qty)}',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800)),
            subtitle: Text([
              if (widget.productId == null) '${l.isAdd ? '+' : '-'}${_fmt(l.qty)}',
              '${_fmt(l.before)} → ${_fmt(l.after)}',
              ...parts,
              agoText(l.at),
            ].where((e) => e.isNotEmpty).join('  •  ')),
          );
        },
      );
    }
    return SizedBox(
      height: h,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(widget.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
          ),
          Expanded(child: body),
        ],
      ),
    );
  }
}
