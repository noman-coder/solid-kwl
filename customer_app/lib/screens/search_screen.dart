import 'dart:async';

import 'package:flutter/material.dart';

import '../models/products.dart';
import '../models/stores.dart';
import '../services/api.dart';
import '../theme.dart';
import '../utils.dart';
import '../widgets/cart_actions.dart';
import '../widgets/content_width.dart';
import '../widgets/empty_state.dart';
import '../widgets/net_image.dart';
import '../widgets/notice_card.dart';
import '../widgets/product_grid_card.dart';
import '../widgets/skeleton.dart';
import 'product_detail.dart';
import 'store_detail.dart';

/// Search screen kholo (Home ki search bar se). `initial` mein lafz / filter ho to seedha nateeje khulte hain.
Future<void> openSearch(BuildContext context, {ProductQuery initial = const ProductQuery()}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(builder: (_) => SearchScreen(initial: initial)),
  );
}

enum _Mode { idle, suggest, results }

/// Phase C6: products ki talash. Likhte waqt suggestions (products / stores / categories + "kya aap ye dhoondh rahe the"),
/// pehle ki talashein, nateeje grid mein (filter + tarteeb sheet), galat spelling par bhi sahi nateeje.
class SearchScreen extends StatefulWidget {
  final ProductQuery initial;
  const SearchScreen({super.key, this.initial = const ProductQuery()});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _ctl = TextEditingController();
  final FocusNode _focus = FocusNode();
  final ScrollController _scroll = ScrollController();
  Timer? _debounce;

  _Mode _mode = _Mode.idle;
  List<String> _recent = [];

  // suggestions
  SuggestData? _suggest;
  bool _suggestLoading = false;
  int _suggestSeq = 0;

  // nateeje
  ProductQuery _query = const ProductQuery();
  ProductListData? _meta;
  List<ProductItem> _items = [];
  List<CategoryRef> _categories = [];
  int _page = 1;
  bool _hasMore = false;
  bool _loading = false;
  bool _loadingMore = false;
  bool _moreFailed = false;
  ApiException? _error;
  int _seq = 0;

  static const List<SortOption> _fallbackSorts = [
    SortOption(key: 'newest', label: 'Naye pehle'),
    SortOption(key: 'price_low', label: 'Qeemat: kam se zyada'),
    SortOption(key: 'price_high', label: 'Qeemat: zyada se kam'),
    SortOption(key: 'name', label: 'Naam (A-Z)'),
  ];

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _loadRecent();
    _query = widget.initial;
    _ctl.text = widget.initial.q;
    if (widget.initial.q.isNotEmpty || widget.initial.hasFilters) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _runQuery();
      });
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _ctl.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _loadRecent() async {
    final list = await Api.recentSearches();
    if (mounted) setState(() => _recent = list);
  }

  void _onScroll() {
    if (!_scroll.hasClients || _mode != _Mode.results) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 420) _loadMore();
  }

  // ---------------------------------------------------------------- likhna / suggestions

  void _onChanged(String text) {
    _debounce?.cancel();
    final t = text.trim();
    if (t.isEmpty) {
      _suggestSeq++;
      setState(() {
        _mode = _Mode.idle;
        _suggest = null;
        _suggestLoading = false;
      });
      return;
    }
    setState(() => _mode = _Mode.suggest);
    if (t.length < 2) {
      setState(() {
        _suggest = null;
        _suggestLoading = false;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () => _fetchSuggest(t));
  }

  Future<void> _fetchSuggest(String t) async {
    final my = ++_suggestSeq;
    setState(() => _suggestLoading = true);
    try {
      final d = await Api.suggest(t);
      if (!mounted || my != _suggestSeq) return;
      setState(() {
        _suggest = d;
        _suggestLoading = false;
      });
    } catch (_) {
      // suggestions na aayen to bhi customer "dhoondhein" dabakar nateeje dekh sakta hai
      if (!mounted || my != _suggestSeq) return;
      setState(() {
        _suggest = null;
        _suggestLoading = false;
      });
    }
  }

  // ---------------------------------------------------------------- nateeje

  void _submit(String text) {
    final t = text.trim();
    if (t.isEmpty) return;
    _debounce?.cancel();
    _suggestSeq++;
    _ctl.value = TextEditingValue(text: t, selection: TextSelection.collapsed(offset: t.length));
    _focus.unfocus();
    Api.addRecentSearch(t).then((list) {
      if (mounted) setState(() => _recent = list);
    });
    _query = _query.copyWith(q: t, sort: '');
    _runQuery();
  }

  /// Category dabane par: lafz hatao, sirf wo category dikhao.
  void _openCategory(CategoryRef c) {
    _debounce?.cancel();
    _suggestSeq++;
    _ctl.clear();
    _focus.unfocus();
    _query = ProductQuery(category: c.id);
    _runQuery();
  }

  Future<void> _runQuery() async {
    final my = ++_seq;
    setState(() {
      _mode = _Mode.results;
      _loading = true;
      _error = null;
      _items = [];
      _page = 1;
      _hasMore = false;
      _moreFailed = false;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    try {
      final d = await Api.products(_query, page: 1);
      if (!mounted || my != _seq) return;
      setState(() {
        _meta = d;
        _items = d.products;
        _page = 1;
        _hasMore = d.hasMore;
        if (d.categories.isNotEmpty) _categories = d.categories;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted || my != _seq) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || my != _seq) return;
      setState(() {
        _error = ApiException('Kuch masla aa gaya. Dobara koshish karein.', 0);
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _loading || !_hasMore) return;
    final my = _seq;
    setState(() {
      _loadingMore = true;
      _moreFailed = false;
    });
    try {
      final d = await Api.products(_query, page: _page + 1);
      if (!mounted || my != _seq) return;
      final seen = _items.map((e) => e.card.id).toSet();
      setState(() {
        _items = [..._items, ...d.products.where((e) => !seen.contains(e.card.id))];
        _page = d.page;
        _hasMore = d.hasMore;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted || my != _seq) return;
      setState(() {
        _loadingMore = false;
        _moreFailed = true;
      });
    }
  }

  // ---------------------------------------------------------------- sort / filter

  String get _sortLabel {
    final meta = _meta;
    final key = _query.sort.isNotEmpty ? _query.sort : (meta?.sort ?? '');
    final list = (meta != null && meta.sorts.isNotEmpty) ? meta.sorts : _fallbackSorts;
    for (final o in list) {
      if (o.key == key) return o.label;
    }
    return 'Tarteeb';
  }

  Future<void> _pickSort() async {
    final meta = _meta;
    final options = (meta != null && meta.sorts.isNotEmpty) ? meta.sorts : _fallbackSorts;
    final current = _query.sort.isNotEmpty ? _query.sort : (meta?.sort ?? '');
    final chosen = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      backgroundColor: Colors.white,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('Tarteeb', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: kInk)),
            ),
            for (final o in options)
              ListTile(
                title: Text(o.label, style: TextStyle(fontWeight: o.key == current ? FontWeight.w800 : FontWeight.w500)),
                trailing: o.key == current ? const Icon(Icons.check_rounded, color: kOrange) : null,
                onTap: () => Navigator.of(ctx).pop(o.key),
              ),
          ],
        ),
      ),
    );
    if (chosen == null || chosen == current) return;
    _query = _query.copyWith(sort: chosen);
    _runQuery();
  }

  Future<void> _openFilters() async {
    final result = await showModalBottomSheet<ProductQuery>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      backgroundColor: Colors.white,
      builder: (_) => _FilterSheet(query: _query, categories: _categories),
    );
    if (result == null) return;
    _query = result;
    _runQuery();
  }

  void _clearFilters() {
    _query = _query.copyWith(clearCategory: true, clearStore: true, clearPrice: true, inStock: false);
    if (_query.q.isEmpty) {
      // na lafz na filter: wapas khali talash
      setState(() {
        _mode = _Mode.idle;
        _items = [];
        _meta = null;
      });
      return;
    }
    _runQuery();
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          controller: _ctl,
          focusNode: _focus,
          textInputAction: TextInputAction.search,
          onChanged: _onChanged,
          onSubmitted: _submit,
          decoration: InputDecoration(
            hintText: 'Product, store ya category dhoondhein',
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            filled: false,
            suffixIcon: _ctl.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.close_rounded),
                    tooltip: 'Saaf karein',
                    onPressed: () {
                      _ctl.clear();
                      _onChanged('');
                      _focus.requestFocus();
                    },
                  ),
          ),
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: kInk),
        ),
      ),
      body: ContentWidth(maxWidth: 900, child: _body()),
    );
  }

  Widget _body() {
    switch (_mode) {
      case _Mode.idle:
        return _idleView();
      case _Mode.suggest:
        return _suggestView();
      case _Mode.results:
        return _resultsView();
    }
  }

  // ---- khali: pehle ki talashein

  Widget _idleView() {
    if (_recent.isEmpty) {
      return const EmptyState(
        icon: Icons.search_rounded,
        title: 'Kuch bhi dhoondhein',
        message: 'Product, store ya category ka naam likhein. Spelling galat ho to bhi mil jata hai.',
      );
    }
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 0),
          child: Row(
            children: [
              const Expanded(
                child: Text('Haal ki talashein',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: kInk)),
              ),
              TextButton(
                onPressed: () async {
                  await Api.clearRecentSearches();
                  if (mounted) setState(() => _recent = []);
                },
                child: const Text('Saaf karein'),
              ),
            ],
          ),
        ),
        for (final t in _recent)
          ListTile(
            leading: const Icon(Icons.history_rounded, color: kMuted),
            title: Text(t, maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: IconButton(
              icon: const Icon(Icons.close_rounded, size: 20, color: kMuted),
              tooltip: 'Hatayein',
              onPressed: () async {
                await Api.removeRecentSearch(t);
                await _loadRecent();
              },
            ),
            onTap: () {
              _ctl.text = t;
              _submit(t);
            },
          ),
      ],
    );
  }

  // ---- likhte waqt: suggestions

  Widget _suggestView() {
    final text = _ctl.text.trim();
    final d = _suggest;
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        if (_suggestLoading) const LinearProgressIndicator(minHeight: 2, color: kOrange),
        ListTile(
          leading: const Icon(Icons.search_rounded, color: kOrange),
          title: Text('"$text" dhoondhein', style: const TextStyle(fontWeight: FontWeight.w800)),
          onTap: () => _submit(text),
        ),
        if (d != null && d.didYouMean.isNotEmpty)
          ListTile(
            leading: const Icon(Icons.auto_fix_high_rounded, color: kGreen),
            title: Text('Kya aap ye dhoondh rahe the: ${d.didYouMean}?',
                style: const TextStyle(fontWeight: FontWeight.w700)),
            onTap: () => _submit(d.didYouMean),
          ),
        if (d != null && d.categories.isNotEmpty) ...[
          const _SuggestHeader('Categories'),
          for (final c in d.categories)
            ListTile(
              leading: const Icon(Icons.category_outlined, color: kMuted),
              title: Text(c.name),
              onTap: () => _openCategory(c),
            ),
        ],
        if (d != null && d.stores.isNotEmpty) ...[
          const _SuggestHeader('Stores'),
          for (final st in d.stores)
            ListTile(
              leading: NetImage(
                  path: st.logo, width: 44, height: 44, radius: 22, fallbackIcon: Icons.storefront_outlined),
              title: Text(st.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: st.city.isEmpty ? null : Text(st.city),
              onTap: () => openStore(context, st.id),
            ),
        ],
        if (d != null && d.products.isNotEmpty) ...[
          const _SuggestHeader('Products'),
          for (final p in d.products)
            ListTile(
              leading: NetImage(path: p.image, width: 44, height: 44, radius: 10, fallbackIcon: Icons.fastfood_outlined),
              title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text([p.unit, p.storeName].where((e) => e.isNotEmpty).join(' - '),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => openProduct(context, p.id),
            ),
        ],
        if (d != null && d.isEmpty && d.didYouMean.isEmpty && !_suggestLoading)
          const Padding(
            padding: EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Text('Koi suggestion nahi mila. "Dhoondhein" dabakar poori talash karein.',
                style: TextStyle(color: kMuted)),
          ),
      ],
    );
  }

  // ---- nateeje

  Widget _resultsView() {
    final meta = _meta;
    return RefreshIndicator(
      onRefresh: _runQuery,
      color: kOrange,
      child: CustomScrollView(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        slivers: [
          SliverToBoxAdapter(child: _resultsHeader(meta)),
          ..._resultSlivers(),
        ],
      ),
    );
  }

  Widget _resultsHeader(ProductListData? meta) {
    final chips = <Widget>[];
    if (_query.category != null) {
      var name = 'Category';
      for (final c in _categories) {
        if (c.id == _query.category) name = c.name;
      }
      chips.add(_FilterChipTag(
          label: name,
          onRemove: () {
            _query = _query.copyWith(clearCategory: true);
            _afterFilterRemoved();
          }));
    }
    if (_query.priceMin != null || _query.priceMax != null) {
      final lo = _query.priceMin;
      final hi = _query.priceMax;
      final label = lo != null && hi != null
          ? '${rs(lo)} - ${rs(hi)}'
          : (lo != null ? '${rs(lo)} se upar' : '${rs(hi)} tak');
      chips.add(_FilterChipTag(
          label: label,
          onRemove: () {
            _query = _query.copyWith(clearPrice: true);
            _afterFilterRemoved();
          }));
    }
    if (_query.inStock) {
      chips.add(_FilterChipTag(
          label: 'Sirf stock mein',
          onRemove: () {
            _query = _query.copyWith(inStock: false);
            _afterFilterRemoved();
          }));
    }
    final count = _query.filterCount;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (meta != null && meta.didYouMean.isNotEmpty && !_loading)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: NoticeCard(
                level: NoticeLevel.info,
                icon: Icons.auto_fix_high_rounded,
                text: '"${meta.q}" ke liye kuch nahi mila. "${meta.didYouMean}" ke nateeje dikha rahe hain.',
              ),
            ),
          Row(
            children: [
              Expanded(
                child: Text(
                  _loading || meta == null ? ' ' : '${meta.total} product${meta.total == 1 ? '' : 's'}',
                  style: const TextStyle(fontWeight: FontWeight.w800, color: kInk),
                ),
              ),
              TextButton.icon(
                onPressed: meta == null ? null : _pickSort,
                icon: const Icon(Icons.swap_vert_rounded, size: 20),
                label: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 140),
                  child: Text(_sortLabel, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ),
              TextButton.icon(
                onPressed: meta == null ? null : _openFilters,
                icon: Badge(
                  isLabelVisible: count > 0,
                  label: Text('$count'),
                  backgroundColor: kOrange,
                  child: const Icon(Icons.tune_rounded, size: 20),
                ),
                label: const Text('Filter'),
              ),
            ],
          ),
          if (chips.isNotEmpty) Wrap(spacing: 8, runSpacing: 4, children: chips),
        ],
      ),
    );
  }

  void _afterFilterRemoved() {
    if (_query.q.isEmpty && !_query.hasFilters) {
      _clearFilters();
    } else {
      _runQuery();
    }
  }

  List<Widget> _resultSlivers() {
    if (_loading) {
      return [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
          sliver: SliverLayoutBuilder(builder: (context, c) {
            final m = ProductGridCard.metrics(context, c.crossAxisExtent);
            return SliverToBoxAdapter(
              child: SkeletonScope(
                child: Wrap(
                  spacing: ProductGridCard.spacing,
                  runSpacing: ProductGridCard.spacing,
                  children: [
                    for (var i = 0; i < m.columns * 3; i++)
                      SkeletonBox(width: m.tileWidth, height: m.extent, radius: 16),
                  ],
                ),
              ),
            );
          }),
        ),
      ];
    }
    if (_error != null && _items.isEmpty) {
      final e = _error!;
      return [
        SliverToBoxAdapter(
          child: SizedBox(
            height: 320,
            child: EmptyState(
              icon: e.isNetwork ? Icons.wifi_off_rounded : Icons.error_outline_rounded,
              title: 'Products nahi aa sake',
              message: e.message,
              action: FilledButton(onPressed: _runQuery, child: const Text('Dobara koshish karein')),
            ),
          ),
        ),
      ];
    }
    if (_items.isEmpty) {
      final hasText = _query.q.isNotEmpty;
      return [
        SliverToBoxAdapter(
          child: SizedBox(
            height: 320,
            child: EmptyState(
              icon: Icons.search_off_rounded,
              title: 'Koi product nahi mila',
              message: hasText
                  ? '"${_query.q}" se milta koi product is area mein nahi. Doosra lafz try karein.'
                  : 'Is category / filter mein abhi koi product nahi.',
              action: _query.hasFilters
                  ? OutlinedButton(onPressed: _clearFilters, child: const Text('Filters hatayein'))
                  : null,
            ),
          ),
        ),
      ];
    }
    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
        sliver: SliverLayoutBuilder(builder: (context, c) {
          final m = ProductGridCard.metrics(context, c.crossAxisExtent);
          return SliverGrid.builder(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: m.columns,
              mainAxisSpacing: ProductGridCard.spacing,
              crossAxisSpacing: ProductGridCard.spacing,
              mainAxisExtent: m.extent,
            ),
            itemCount: _items.length,
            itemBuilder: (_, i) {
              final it = _items[i];
              return ProductGridCard(
                item: it,
                onTap: () => openProduct(context, it.card.id, preview: it.card),
                onAdd: () => addProductToCart(context, card: it.card, stock: it.stock),
              );
            },
          );
        }),
      ),
      SliverToBoxAdapter(child: _footer()),
    ];
  }

  Widget _footer() {
    if (_loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 18),
        child: Center(child: SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 3))),
      );
    }
    if (_moreFailed) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Center(
          child: TextButton.icon(
            onPressed: _loadMore,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Aur products nahi aa sake - dobara'),
          ),
        ),
      );
    }
    return const SizedBox(height: 28);
  }
}

// ---------------------------------------------------------------- chhote widgets

class _SuggestHeader extends StatelessWidget {
  final String text;
  const _SuggestHeader(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 2),
      child: Text(text, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w900, color: kMuted)),
    );
  }
}

class _FilterChipTag extends StatelessWidget {
  final String label;
  final VoidCallback onRemove;
  const _FilterChipTag({required this.label, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return InputChip(
      label: Text(label),
      onDeleted: onRemove,
      deleteIcon: const Icon(Icons.close_rounded, size: 18),
      backgroundColor: kOrangeSoft,
      side: const BorderSide(color: kBorder),
      visualDensity: VisualDensity.compact,
    );
  }
}

/// Filter sheet: category, qeemat ki hadd, sirf stock mein. "Lagayein" par naya ProductQuery wapas.
class _FilterSheet extends StatefulWidget {
  final ProductQuery query;
  final List<CategoryRef> categories;
  const _FilterSheet({required this.query, required this.categories});

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late int? _category = widget.query.category;
  late bool _inStock = widget.query.inStock;
  late final TextEditingController _min = TextEditingController(text: _fmt(widget.query.priceMin));
  late final TextEditingController _max = TextEditingController(text: _fmt(widget.query.priceMax));

  static String _fmt(double? v) => v == null ? '' : (v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString());

  @override
  void dispose() {
    _min.dispose();
    _max.dispose();
    super.dispose();
  }

  double? _num(TextEditingController c) {
    final v = double.tryParse(c.text.trim());
    return (v == null || v < 0) ? null : v;
  }

  void _apply() {
    final lo = _num(_min);
    final hi = _num(_max);
    final base = widget.query.copyWith(clearCategory: true, clearPrice: true, inStock: _inStock);
    Navigator.of(context).pop(ProductQuery(
      q: base.q,
      sort: base.sort,
      category: _category,
      store: base.store,
      priceMin: lo,
      priceMax: hi,
      inStock: _inStock,
    ));
  }

  void _reset() {
    setState(() {
      _category = null;
      _inStock = false;
      _min.clear();
      _max.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Filter', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: kInk)),
              const SizedBox(height: 14),
              if (widget.categories.isNotEmpty) ...[
                const Text('Category', style: TextStyle(fontWeight: FontWeight.w800, color: kInk)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final c in widget.categories)
                      ChoiceChip(
                        label: Text(c.name),
                        selected: _category == c.id,
                        selectedColor: kOrangeSoft,
                        onSelected: (v) => setState(() => _category = v ? c.id : null),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
              ],
              const Text('Qeemat (Rs)', style: TextStyle(fontWeight: FontWeight.w800, color: kInk)),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _min,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Kam az kam'),
                    ),
                  ),
                  const Padding(padding: EdgeInsets.symmetric(horizontal: 10), child: Text('-')),
                  Expanded(
                    child: TextField(
                      controller: _max,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Zyada se zyada'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _inStock,
                activeColor: kOrange,
                title: const Text('Sirf stock mein', style: TextStyle(fontWeight: FontWeight.w700)),
                onChanged: (v) => setState(() => _inStock = v),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(child: OutlinedButton(onPressed: _reset, child: const Text('Reset'))),
                  const SizedBox(width: 12),
                  Expanded(flex: 2, child: FilledButton(onPressed: _apply, child: const Text('Lagayein'))),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
