import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/products.dart';
import '../services/api.dart';
import '../services/app_state.dart';
import '../theme.dart';
import '../utils.dart';
import '../widgets/empty_state.dart';
import '../widgets/notice_card.dart';
import '../widgets/skeleton.dart';

/// Products tab: search + filter chips (Sab / Approved / Pending / Rejected / Kam stock / Khatam), list ya grid,
/// har product par shop show/hide switch, card par tap = quick edit (rate, discount, naya stock).
/// Pull-to-refresh, neeche scroll par agla page, skeleton, empty, error + retry, offline par purana data.
class ProductsScreen extends StatefulWidget {
  const ProductsScreen({super.key});

  @override
  State<ProductsScreen> createState() => _ProductsScreenState();
}

class _ProductsScreenState extends State<ProductsScreen> {
  final TextEditingController _search = TextEditingController();
  final ScrollController _sc = ScrollController();
  Timer? _debounce;
  bool _grid = false;

  @override
  void initState() {
    super.initState();
    _sc.addListener(_onScroll);
    _loadPref();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _sc.removeListener(_onScroll);
    _sc.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _loadPref() async {
    try {
      final p = await SharedPreferences.getInstance();
      final g = p.getBool('products_grid') ?? false;
      if (mounted && g != _grid) setState(() => _grid = g);
    } catch (_) {}
  }

  Future<void> _setGrid(bool v) async {
    setState(() => _grid = v);
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool('products_grid', v);
    } catch (_) {}
  }

  void _onScroll() {
    if (!_sc.hasClients || !mounted) return;
    if (_sc.position.pixels > _sc.position.maxScrollExtent - 300) {
      AppScope.read(context).loadMoreProducts();
    }
  }

  void _onSearch(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () {
      if (!mounted) return;
      AppScope.read(context).setProductsQuery(v);
    });
    setState(() {}); // clear (X) button
  }

  void _clearSearch() {
    _search.clear();
    _debounce?.cancel();
    AppScope.read(context).setProductsQuery('');
    setState(() {});
  }

  void _pickFilter(String f) {
    if (_sc.hasClients) _sc.jumpTo(0);
    AppScope.read(context).setProductFilter(f);
  }

  Future<void> _toggle(VendorProduct p, bool v) async {
    HapticFeedback.selectionClick();
    await AppScope.read(context).toggleProduct(p, active: v);
  }

  ({String title, String message, IconData icon}) _emptyText(String filter, bool searching) {
    if (searching) {
      return (title: 'Koi product nahi mila', message: 'Doosra naam ya barcode try karein.', icon: Icons.search_off);
    }
    switch (filter) {
      case 'approved':
        return (title: 'Koi approved product nahi', message: 'Admin approve karega to yahan nazar aayega.', icon: Icons.verified_outlined);
      case 'pending':
        return (title: 'Koi product approval ka muntazir nahi', message: 'Naya product bhejne par yahan dikhega.', icon: Icons.hourglass_empty);
      case 'rejected':
        return (title: 'Koi product reject nahi hua', message: 'Reject hone par wajah yahan nazar aayegi.', icon: Icons.thumb_up_alt_outlined);
      case 'low':
        return (title: 'Kisi ka stock kam nahi', message: 'Stock kam hone par yahan dikhega.', icon: Icons.inventory_2_outlined);
      case 'out':
        return (title: 'Kisi ka stock khatam nahi', message: 'Shabash! Sab products ka stock maujood hai.', icon: Icons.check_circle_outline);
      default:
        return (
          title: 'Abhi koi product nahi',
          message: 'Pehla product add karein. App se add karna jald aa raha hai - tab tak web portal use karein.',
          icon: Icons.inventory_2_outlined
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    final filter = st.productFilter;
    final l = st.productList(filter);

    // Tab khulte hi (ya list purani ho to) load - sirf jab ye tab saamne ho.
    if (st.tab == 2 && !l.loading && ((!l.loaded && l.error == null) || l.stale)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) AppScope.read(context).ensureProducts();
      });
    }

    const physics = AlwaysScrollableScrollPhysics();
    Widget content;
    if (!l.loaded && l.error != null) {
      content = ListView(
        physics: physics,
        padding: const EdgeInsets.all(12),
        children: [
          NoticeCard(
            level: NoticeLevel.error,
            icon: Icons.cloud_off,
            text: l.error!,
            actionLabel: 'Dobara',
            onAction: () => st.loadProducts(),
          ),
        ],
      );
    } else if (!l.loaded) {
      content = ListView(
        physics: physics,
        padding: const EdgeInsets.all(12),
        children: const [SkeletonList(count: 5, height: 96)],
      );
    } else if (l.products.isEmpty) {
      final e = _emptyText(filter, st.productsQuery.isNotEmpty);
      content = ListView(
        physics: physics,
        children: [
          SizedBox(height: 380, child: EmptyState(icon: e.icon, title: e.title, message: e.message)),
        ],
      );
    } else {
      content = CustomScrollView(
        controller: _sc,
        physics: physics,
        slivers: [
          if (l.error != null)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              sliver: SliverToBoxAdapter(
                child: NoticeCard(
                  level: NoticeLevel.warn,
                  icon: Icons.wifi_off,
                  text: 'Offline - purana data dikh raha hai.',
                  actionLabel: 'Dobara',
                  onAction: () => st.loadProducts(),
                ),
              ),
            ),
          SliverPadding(
            padding: const EdgeInsets.all(12),
            sliver: _grid
                ? SliverGrid(
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      mainAxisSpacing: 10,
                      crossAxisSpacing: 10,
                      mainAxisExtent: 300,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (ctx, i) => _ProductGridCard(product: l.products[i], onToggle: _toggle),
                      childCount: l.products.length,
                    ),
                  )
                : SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (ctx, i) => Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _ProductListCard(product: l.products[i], onToggle: _toggle),
                      ),
                      childCount: l.products.length,
                    ),
                  ),
          ),
          SliverToBoxAdapter(
            child: l.loadingMore
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Center(
                        child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5))),
                  )
                : l.hasMore
                    ? TextButton(onPressed: () => st.loadMoreProducts(), child: const Text('Aur products dikhayein'))
                    : const SizedBox(height: 40),
          ),
        ],
      );
    }

    return Column(
      children: [
        Container(
          color: Colors.white,
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 6),
          child: Row(
            children: [
              Expanded(
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
              IconButton(
                tooltip: _grid ? 'List dekhein' : 'Grid dekhein',
                onPressed: () => _setGrid(!_grid),
                icon: Icon(_grid ? Icons.view_list_rounded : Icons.grid_view_rounded),
              ),
            ],
          ),
        ),
        Container(
          color: Colors.white,
          height: 48,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            itemCount: kProductFilters.length,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (ctx, i) {
              final f = kProductFilters[i];
              final c = st.productCounts?[f];
              final sel = f == filter;
              final warn = f == 'low' || f == 'out';
              final accent = f == 'out' ? Colors.red.shade700 : (warn ? Colors.orange.shade800 : kTeal);
              final label = (kProductFilterLabels[f] ?? f) + (c == null ? '' : ' ($c)');
              return ChoiceChip(
                label: Text(label),
                selected: sel,
                showCheckmark: false,
                onSelected: (_) => _pickFilter(f),
                selectedColor: accent.withValues(alpha: 0.14),
                labelStyle: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  color: sel ? accent : Colors.black87,
                ),
                side: BorderSide(color: sel ? accent : kBorder),
                visualDensity: VisualDensity.compact,
              );
            },
          ),
        ),
        const Divider(height: 1),
        Expanded(child: RefreshIndicator(onRefresh: st.refreshProducts, child: content)),
      ],
    );
  }
}

// ---------------------------------------------------------------- pieces

Color _stockColor(String state) {
  switch (state) {
    case 'out':
      return Colors.red.shade700;
    case 'low':
      return Colors.orange.shade800;
    default:
      return Colors.green.shade700;
  }
}

String _stockLabel(VendorProduct p) {
  switch (p.stockState) {
    case 'out':
      return 'Stock khatam';
    case 'low':
      return 'Kam: ${numText(p.stock)}';
    default:
      return 'Stock: ${numText(p.stock)}';
  }
}

class _Pill extends StatelessWidget {
  final String text;
  final Color color;
  final IconData? icon;
  const _Pill({required this.text, required this.color, this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 12, color: color), const SizedBox(width: 3)],
          Text(text, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: color)),
        ],
      ),
    );
  }
}

/// Product ki tasveer (na ho ya na khule to icon).
class _Thumb extends StatelessWidget {
  final String? path;
  final double size;
  final double? height;
  const _Thumb({required this.path, required this.size, this.height});

  @override
  Widget build(BuildContext context) {
    final h = height ?? size;
    final box = BoxDecoration(color: kBg, borderRadius: BorderRadius.circular(12));
    final fallback = Container(
      width: size,
      height: h,
      decoration: box,
      child: const Icon(Icons.inventory_2_outlined, color: Colors.black38),
    );
    if (path == null) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Image.network(
        Api.absUrl(path!),
        width: size,
        height: h,
        fit: BoxFit.cover,
        cacheWidth: 360,
        errorBuilder: (_, __, ___) => fallback,
      ),
    );
  }
}

class _PriceLine extends StatelessWidget {
  final VendorProduct p;
  const _PriceLine({required this.p});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(rs(p.price), style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w900, color: kTealDark)),
        if (p.hasDiscount) ...[
          Text(rs(p.originalPrice),
              style: const TextStyle(
                  fontSize: 12, color: Colors.black45, decoration: TextDecoration.lineThrough)),
          Text('-${numText(p.discountPercent)}%',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Colors.green.shade700)),
        ],
        if (p.unit.isNotEmpty) Text('/ ${p.unit}', style: const TextStyle(fontSize: 12, color: Colors.black54)),
      ],
    );
  }
}

class _Badges extends StatelessWidget {
  final VendorProduct p;
  const _Badges({required this.p});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        _Pill(text: _stockLabel(p), color: _stockColor(p.stockState), icon: Icons.inventory_2_outlined),
        if (p.isPending) _Pill(text: 'Approval baqi', color: Colors.blue.shade700, icon: Icons.hourglass_top),
        if (p.isRejected) _Pill(text: 'Reject', color: Colors.red.shade700, icon: Icons.block),
        if (p.isApproved && !p.isActive) _Pill(text: 'Shop se chhupa', color: Colors.grey.shade700, icon: Icons.visibility_off),
      ],
    );
  }
}

class _ReasonBox extends StatelessWidget {
  final VendorProduct p;
  const _ReasonBox({required this.p});

  @override
  Widget build(BuildContext context) {
    if (!p.isRejected) return const SizedBox.shrink();
    final text = p.rejectionReason.isEmpty ? 'Admin ne is product ko reject kiya hai.' : p.rejectionReason;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(8),
      width: double.infinity,
      decoration: BoxDecoration(color: Colors.red.shade50, borderRadius: BorderRadius.circular(10)),
      child: Text('Wajah: $text', style: TextStyle(fontSize: 12.5, color: Colors.red.shade900)),
    );
  }
}

/// Shop par show/hide switch. Approved na ho to switch nahi. Chalte waqt chhota spinner (double tap lock).
class _VisibilitySwitch extends StatelessWidget {
  final VendorProduct p;
  final Future<void> Function(VendorProduct p, bool v) onToggle;
  const _VisibilitySwitch({required this.p, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    if (!p.canToggle) return const SizedBox(width: 8);
    final busy = AppScope.of(context).productBusy.contains(p.id);
    if (busy) {
      return const SizedBox(
        width: 48,
        height: 32,
        child: Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5))),
      );
    }
    return Switch(value: p.isActive, onChanged: (v) => onToggle(p, v));
  }
}

class _ProductListCard extends StatelessWidget {
  final VendorProduct product;
  final Future<void> Function(VendorProduct p, bool v) onToggle;
  const _ProductListCard({required this.product, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final p = product;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => showQuickEdit(context, p),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Opacity(opacity: p.visible || !p.isApproved ? 1 : 0.55, child: _Thumb(path: p.image, size: 68)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(p.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                        if (p.category.isNotEmpty)
                          Text(p.category,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12, color: Colors.black54)),
                        const SizedBox(height: 3),
                        _PriceLine(p: p),
                      ],
                    ),
                  ),
                  _VisibilitySwitch(p: p, onToggle: onToggle),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(child: _Badges(p: p)),
                  const Icon(Icons.edit_outlined, size: 18, color: Colors.black45),
                ],
              ),
              _ReasonBox(p: p),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProductGridCard extends StatelessWidget {
  final VendorProduct product;
  final Future<void> Function(VendorProduct p, bool v) onToggle;
  const _ProductGridCard({required this.product, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final p = product;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => showQuickEdit(context, p),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LayoutBuilder(
                builder: (ctx, c) => Opacity(
                  opacity: p.visible || !p.isApproved ? 1 : 0.55,
                  child: _Thumb(path: p.image, size: c.maxWidth, height: 104),
                ),
              ),
              const SizedBox(height: 6),
              Text(p.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              _PriceLine(p: p),
              const SizedBox(height: 4),
              _Badges(p: p),
              const Spacer(),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (p.isRejected)
                    Expanded(
                      child: Text(p.rejectionReason.isEmpty ? 'Reject hua' : p.rejectionReason,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11.5, color: Colors.red.shade800)),
                    ),
                  _VisibilitySwitch(p: p, onToggle: onToggle),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- quick edit

Future<void> showQuickEdit(BuildContext context, VendorProduct p) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: Colors.white,
    builder: (_) => AppScope(state: AppScope.read(context), child: _QuickEditSheet(product: p)),
  );
}

String _plain(double v) {
  if (v == v.roundToDouble()) return v.toStringAsFixed(0);
  return v.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
}

class _QuickEditSheet extends StatefulWidget {
  final VendorProduct product;
  const _QuickEditSheet({required this.product});

  @override
  State<_QuickEditSheet> createState() => _QuickEditSheetState();
}

class _QuickEditSheetState extends State<_QuickEditSheet> {
  late final TextEditingController _price = TextEditingController(text: _plain(widget.product.originalPrice));
  late final TextEditingController _discount =
      TextEditingController(text: widget.product.hasDiscount ? _plain(widget.product.discountPercent) : '');
  final TextEditingController _add = TextEditingController();
  bool _saving = false;
  String? _error;

  static const List<int> _addChips = [5, 10, 25, 50];

  @override
  void dispose() {
    _price.dispose();
    _discount.dispose();
    _add.dispose();
    super.dispose();
  }

  double? _num(TextEditingController c) {
    final t = c.text.trim();
    if (t.isEmpty) return 0;
    return double.tryParse(t);
  }

  /// Customer ko jo rate dikhega (discount ke baad).
  double? get _preview {
    final pr = double.tryParse(_price.text.trim());
    final d = _num(_discount);
    if (pr == null || pr <= 0 || d == null || d < 0 || d > 90) return null;
    return pr - pr * d / 100;
  }

  void _addChip(int n) {
    final cur = _num(_add) ?? 0;
    _add.text = _plain(cur + n);
    _add.selection = TextSelection.collapsed(offset: _add.text.length);
    setState(() => _error = null);
  }

  Future<void> _save() async {
    final p = widget.product;
    final price = double.tryParse(_price.text.trim());
    final discount = _num(_discount);
    final add = _num(_add);
    if (price == null || price <= 0) {
      setState(() => _error = 'Sahi rate likhein (0 se zyada).');
      return;
    }
    if (discount == null || discount < 0 || discount > 90) {
      setState(() => _error = 'Discount 0 se 90 ke darmiyan hona chahiye.');
      return;
    }
    if (add == null || add < 0 || add > 1000000) {
      setState(() => _error = 'Naya stock sahi likhein (0 ya zyada).');
      return;
    }
    final samePrice = (price - p.originalPrice).abs() < 0.005;
    final sameDiscount = (discount - p.discountPercent).abs() < 0.005;
    if (samePrice && sameDiscount && add == 0) {
      Navigator.of(context).pop();
      AppScope.read(context).toast('Koi tabdeeli nahi mili.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final err = await AppScope.read(context).quickUpdateProduct(
      p,
      price: price,
      discount: discount,
      addStock: add > 0 ? add : null,
    );
    if (!mounted) return;
    if (err == null) {
      HapticFeedback.lightImpact();
      Navigator.of(context).pop();
    } else {
      setState(() {
        _saving = false;
        _error = err;
      });
    }
  }

  InputDecoration _dec(String label, {String? hint, String? prefix, String? suffix}) => InputDecoration(
        labelText: label,
        hintText: hint,
        prefixText: prefix,
        suffixText: suffix,
        isDense: true,
      );

  @override
  Widget build(BuildContext context) {
    final p = widget.product;
    final preview = _preview;
    final nf = FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'));
    const kb = TextInputType.numberWithOptions(decimal: true);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _Thumb(path: p.image, size: 52),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(p.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
                      const SizedBox(height: 4),
                      _Badges(p: p),
                    ],
                  ),
                ),
              ],
            ),
            _ReasonBox(p: p),
            const SizedBox(height: 16),
            TextField(
              controller: _price,
              keyboardType: kb,
              inputFormatters: [nf],
              onChanged: (_) => setState(() => _error = null),
              decoration: _dec('Rate (discount se pehle)', prefix: 'Rs '),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _discount,
              keyboardType: kb,
              inputFormatters: [nf],
              onChanged: (_) => setState(() => _error = null),
              decoration: _dec('Discount (0 - 90)', hint: '0', suffix: '%'),
            ),
            if (preview != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('Customer ko rate: ${rs(double.parse(preview.toStringAsFixed(2)))}',
                    style: const TextStyle(fontWeight: FontWeight.w800, color: kTealDark)),
              ),
            const SizedBox(height: 16),
            Text('Abhi stock: ${numText(p.stock)}${p.unit.isEmpty ? '' : ' ${p.unit}'}',
                style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            TextField(
              controller: _add,
              keyboardType: kb,
              inputFormatters: [nf],
              onChanged: (_) => setState(() => _error = null),
              decoration: _dec('Naya stock jama karein', hint: '0'),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final n in _addChips)
                  ActionChip(label: Text('+$n'), onPressed: _saving ? null : () => _addChip(n), visualDensity: VisualDensity.compact),
              ],
            ),
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('Ye stock mein jama hoga (purana stock kam nahi hota).',
                  style: TextStyle(fontSize: 12, color: Colors.black54)),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: Colors.red.shade50, borderRadius: BorderRadius.circular(10)),
                child: Text(_error!, style: TextStyle(color: Colors.red.shade900, fontWeight: FontWeight.w600)),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _saving ? null : () => Navigator.of(context).pop(),
                    child: const Text('Band karein'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: FilledButton(
                    onPressed: _saving ? null : _save,
                    child: _saving
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                        : const Text('Save karein'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
