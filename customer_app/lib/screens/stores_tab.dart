import 'dart:async';

import 'package:flutter/material.dart';

import '../models/home.dart';
import '../models/stores.dart';
import '../services/api.dart';
import '../services/app_state.dart';
import '../theme.dart';
import '../widgets/content_width.dart';
import '../widgets/empty_state.dart';
import '../widgets/skeleton.dart';
import '../widgets/store_card.dart';
import 'area_picker.dart';
import 'store_detail.dart';

/// Stores tab (Phase C5): search, filter chips (Khula / Top rated / Free delivery / Naye), dukan ki qism, category, sort,
/// store card, aur neeche scroll karne par agla page.
///
/// - Area / login badalne par khud dobara load (AppState.areaVersion). Home ke banner / dukan ki qism / search bar se
///   filter ke saath khulta hai (AppState.openStores).
/// - Pull-to-refresh, skeleton, error + retry, net band par save kiya hua aakhri (bina filter) pehla page.
class StoresTab extends StatefulWidget {
  const StoresTab({super.key});

  @override
  State<StoresTab> createState() => _StoresTabState();
}

class _StoresTabState extends State<StoresTab> {
  final TextEditingController _searchCtl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final ScrollController _scroll = ScrollController();
  Timer? _debounce;

  StoreQuery _query = const StoreQuery();
  StoreListData? _meta; // aakhri jawab (types, sorts, categories, total...)
  List<StoreCard> _items = [];
  int _page = 1;
  bool _hasMore = false;
  bool _loading = true; // pehla page aa raha hai (list ki jagah skeleton)
  bool _refreshing = false;
  bool _loadingMore = false;
  bool _moreFailed = false;
  ApiException? _error;
  int _seq = 0; // purane (der se aaye) jawab ignore karne ke liye
  String _key = '';
  int _requestSeen = 0;
  bool _stale = true; // list dobara mangwani hai
  bool _visibleOnce = false; // tab kabhi khula?

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final st = AppScope.of(context);
    final key = '${st.customer?.id}|${st.areaVersion}';
    if (key != _key) {
      _key = key;
      _stale = true;
      _items = []; // doosre area / customer ki purani list na dikhe
      _hasMore = false;
      _page = 1;
      _loading = true;
    }
    if (st.storesRequestVersion != _requestSeen) {
      _requestSeen = st.storesRequestVersion;
      final params = st.storesRequest;
      _query = StoreQuery.fromParams(params);
      _searchCtl.text = _query.q;
      _items = [];
      _hasMore = false;
      _page = 1;
      _loading = true;
      _stale = true;
      if (params['focus'] == '1') {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _searchFocus.requestFocus();
        });
      }
    }
    if (st.tab == 1) _visibleOnce = true;
    // Tab pehli dafa khulne par hi load (app khulte hi bekar request nahi); baad mein area / filter badalne par dobara.
    if (_stale && _visibleOnce) {
      _stale = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtl.dispose();
    _searchFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 420) _loadMore();
  }

  /// Pehla page (filter / area / sort badalne ya pull-to-refresh par).
  Future<void> _load() async {
    final seq = ++_seq;
    final query = _query;
    setState(() {
      _error = null;
      _moreFailed = false;
      _loadingMore = false;
      if (_items.isEmpty) {
        _loading = true;
      } else {
        _refreshing = true;
      }
    });
    StoreListData? fresh;
    ApiException? err;
    try {
      fresh = await Api.stores(query);
    } on ApiException catch (e) {
      err = e;
    } catch (_) {
      err = ApiException('Kuch masla aa gaya. Dobara koshish karein.', 0);
    }
    if (!mounted || seq != _seq) return;
    StoreListData? shown = fresh;
    if (fresh == null && err != null && err.isNetwork && _items.isEmpty && !query.hasFilters && query.sort.isEmpty) {
      shown = await Api.cachedStores(); // net band: aakhri save kiya hua pehla page
      if (!mounted || seq != _seq) return;
    }
    setState(() {
      _loading = false;
      _refreshing = false;
      if (shown != null) {
        _meta = shown;
        _items = List<StoreCard>.of(shown.stores);
        _page = shown.page;
        _hasMore = fresh != null && shown.hasMore;
        _error = null;
      } else if (_items.isNotEmpty) {
        _error = null; // purani list dikhti rahe
      } else {
        _error = err;
      }
    });
    if (fresh == null && shown != null && err != null && !err.isNetwork) {
      AppScope.read(context).say(err.message);
    }
  }

  /// Agla page (neeche scroll karne par). Fail ho to 'Dobara' ka button.
  Future<void> _loadMore() async {
    if (!_hasMore || _loadingMore || _loading || _refreshing) return;
    final seq = _seq;
    final query = _query;
    setState(() {
      _loadingMore = true;
      _moreFailed = false;
    });
    try {
      final next = await Api.stores(query, page: _page + 1);
      if (!mounted || seq != _seq) return;
      setState(() {
        final seen = _items.map((e) => e.id).toSet();
        _items = [..._items, ...next.stores.where((e) => !seen.contains(e.id))];
        _page = next.page;
        _hasMore = next.hasMore;
        _meta = next;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _loadingMore = false;
        _moreFailed = true;
      });
    }
  }

  /// Filter / sort / search badla: list saaf, naya pehla page.
  void _apply(StoreQuery q) {
    _debounce?.cancel();
    setState(() {
      _query = q;
      _items = [];
      _hasMore = false;
      _page = 1;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _load();
  }

  void _onSearchChanged(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () {
      final t = text.trim();
      if (mounted && t != _query.q) _apply(_query.copyWith(q: t));
    });
  }

  void _submitSearch(String text) {
    _debounce?.cancel();
    final t = text.trim();
    if (t != _query.q) _apply(_query.copyWith(q: t));
  }

  void _clearAll() {
    _searchCtl.clear();
    _apply(const StoreQuery());
  }

  Future<void> _pickSort() async {
    final meta = _meta;
    if (meta == null || meta.sorts.isEmpty) return;
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
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final o in meta.sorts)
                    ListTile(
                      title: Text(o.label, style: const TextStyle(fontWeight: FontWeight.w700)),
                      trailing: o.key == meta.sort
                          ? const Icon(Icons.check_circle_rounded, color: kOrange)
                          : const Icon(Icons.circle_outlined, color: kBorder),
                      onTap: () => Navigator.pop(ctx, o.key),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (chosen != null && chosen != meta.sort && mounted) _apply(_query.copyWith(sort: chosen));
  }

  Future<void> _pickCategory() async {
    final meta = _meta;
    if (meta == null || meta.categories.isEmpty) return;
    final chosen = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
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
              child: Text('Category', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: kInk)),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  ListTile(
                    title: const Text('Sab categories', style: TextStyle(fontWeight: FontWeight.w700)),
                    trailing: _query.category == null ? const Icon(Icons.check_circle_rounded, color: kOrange) : null,
                    onTap: () => Navigator.pop(ctx, -1),
                  ),
                  for (final c in meta.categories)
                    ListTile(
                      title: Text(c.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                      trailing: c.id == _query.category ? const Icon(Icons.check_circle_rounded, color: kOrange) : null,
                      onTap: () => Navigator.pop(ctx, c.id),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    if (chosen < 0) {
      if (_query.category != null) _apply(_query.copyWith(clearCategory: true));
    } else if (chosen != _query.category) {
      _apply(_query.copyWith(category: chosen));
    }
  }

  String _sortLabel() {
    final meta = _meta;
    if (meta == null) return 'Tarteeb';
    for (final o in meta.sorts) {
      if (o.key == meta.sort) return o.label;
    }
    return 'Tarteeb';
  }

  String _categoryLabel() {
    final meta = _meta;
    final id = _query.category;
    if (id == null) return 'Category';
    if (meta != null) {
      for (final c in meta.categories) {
        if (c.id == id) return c.name;
      }
    }
    return 'Category';
  }

  @override
  Widget build(BuildContext context) {
    // Header (search + chips) list ka pehla item hai: scroll par upar chala jata hai, chhote phone par jagah bachti hai.
    final itemsCount = _items.length;
    final showSkeleton = _loading && _items.isEmpty;
    final showEmpty = !_loading && _items.isEmpty && _error == null;
    final showError = !_loading && _items.isEmpty && _error != null;
    final footer = _loadingMore || _moreFailed || (!_hasMore && _items.isNotEmpty);

    return Stack(
      children: [
        RefreshIndicator(
          onRefresh: _load,
          color: kOrange,
          child: ListView.builder(
            controller: _scroll,
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.only(bottom: 28),
            itemCount: 2 + (showSkeleton || showEmpty || showError ? 1 : itemsCount) + (footer ? 1 : 0),
            itemBuilder: (context, i) {
              if (i == 0) return ContentWidth(maxWidth: 720, child: _header(context));
              if (i == 1) return ContentWidth(maxWidth: 720, child: _summary(context));
              final j = i - 2;
              if (showSkeleton) {
                return const ContentWidth(
                  maxWidth: 720,
                  child: Padding(padding: EdgeInsets.fromLTRB(16, 4, 16, 0), child: SkeletonList(count: 5, height: 104)),
                );
              }
              if (showError) return ContentWidth(maxWidth: 720, child: _errorView());
              if (showEmpty) return ContentWidth(maxWidth: 720, child: _emptyView());
              if (j < itemsCount) {
                final st = _items[j];
                return ContentWidth(
                  maxWidth: 720,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                    child: StoreCardTile(store: st, onTap: () => openStore(context, st.id, preview: st)),
                  ),
                );
              }
              return ContentWidth(maxWidth: 720, child: _footer());
            },
          ),
        ),
        if (_refreshing) const Positioned(top: 0, left: 0, right: 0, child: LinearProgressIndicator(minHeight: 3)),
      ],
    );
  }

  Widget _header(BuildContext context) {
    final state = AppScope.of(context);
    final meta = _meta;
    final area = meta?.area.isNotEmpty == true ? meta!.area : state.area;
    final areaLabel = area.isNotEmpty ? area : (state.areaChosen ? 'Sab areas' : 'Area chunein');
    final scale = MediaQuery.textScalerOf(context).scale(1.0).clamp(1.0, 1.3).toDouble();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => showAreaPicker(context),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 2),
            child: Row(
              children: [
                const Icon(Icons.location_on_rounded, size: 18, color: kOrange),
                const SizedBox(width: 6),
                const Text('Deliver to: ', style: TextStyle(color: kMuted, fontSize: 13)),
                Expanded(
                  child: Text(areaLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w900, color: kInk, fontSize: 14)),
                ),
                const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: Text('Badlein', style: TextStyle(color: kOrangeDark, fontWeight: FontWeight.w800, fontSize: 13)),
                ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
          child: TextField(
            controller: _searchCtl,
            focusNode: _searchFocus,
            textInputAction: TextInputAction.search,
            onChanged: (v) {
              setState(() {}); // clear button ke liye
              _onSearchChanged(v);
            },
            onSubmitted: _submitSearch,
            decoration: InputDecoration(
              hintText: 'Dukan ya cheez dhoondhein',
              prefixIcon: const Icon(Icons.search_rounded, color: kMuted),
              suffixIcon: _searchCtl.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close_rounded),
                      tooltip: 'Saaf karein',
                      onPressed: () {
                        _searchCtl.clear();
                        _submitSearch('');
                        setState(() {});
                      },
                    ),
            ),
          ),
        ),
        SizedBox(
          height: 52 * scale,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            children: [
              _filterChip('Khula hai', _query.open, () => _apply(_query.copyWith(open: !_query.open))),
              _filterChip('Top rated', _query.top, () => _apply(_query.copyWith(top: !_query.top))),
              _filterChip('Free delivery', _query.free, () => _apply(_query.copyWith(free: !_query.free))),
              _filterChip('Naye', _query.isNew, () => _apply(_query.copyWith(isNew: !_query.isNew))),
              if (meta != null && meta.categories.isNotEmpty)
                _filterChip(_categoryLabel(), _query.category != null, _pickCategory, icon: Icons.arrow_drop_down_rounded),
              if (meta != null && meta.sorts.isNotEmpty)
                _filterChip(_sortLabel(), false, _pickSort, icon: Icons.sort_rounded),
            ],
          ),
        ),
        if (meta != null && meta.storeTypes.isNotEmpty)
          SizedBox(
            height: 44 * scale,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                _typeChip('Sab', _query.type == null, () {
                  if (_query.type != null) _apply(_query.copyWith(clearType: true));
                }),
                for (final t in meta.storeTypes)
                  _typeChip('${t.icon} ${t.name}'.trim(), _query.type == t.id, () {
                    if (_query.type != t.id) _apply(_query.copyWith(type: t.id));
                  }),
              ],
            ),
          ),
      ],
    );
  }

  Widget _filterChip(String label, bool selected, VoidCallback onTap, {IconData? icon}) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        selected: selected,
        showCheckmark: false,
        avatar: icon == null ? null : Icon(icon, size: 18, color: selected ? kOrangeDark : kMuted),
        label: Text(label),
        onSelected: (_) => onTap(),
        backgroundColor: Colors.white,
        selectedColor: kOrangeSoft,
        side: BorderSide(color: selected ? kOrange : kBorder),
        labelStyle: TextStyle(fontWeight: FontWeight.w700, color: selected ? kOrangeDark : kInk),
      ),
    );
  }

  Widget _typeChip(String label, bool selected, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        selected: selected,
        showCheckmark: false,
        label: Text(label),
        onSelected: (_) => onTap(),
        backgroundColor: Colors.white,
        selectedColor: kOrange,
        side: BorderSide(color: selected ? kOrange : kBorder),
        labelStyle: TextStyle(fontWeight: FontWeight.w700, color: selected ? Colors.white : kInk),
      ),
    );
  }

  /// "12 stores" + doosre areas ke stores ka zikr.
  Widget _summary(BuildContext context) {
    final meta = _meta;
    if (meta == null || _loading && _items.isEmpty) return const SizedBox(height: 6);
    final parts = <String>[
      if (_items.isNotEmpty || meta.total > 0) '${meta.total} store${meta.total == 1 ? '' : 's'}',
      if (meta.outsideCount > 0) '${meta.outsideCount} aur doosre areas mein',
    ];
    if (parts.isEmpty) return const SizedBox(height: 6);
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 4, 16, 10),
      child: Text(parts.join(' - '), style: const TextStyle(color: kMuted, fontSize: 13, fontWeight: FontWeight.w600)),
    );
  }

  Widget _errorView() {
    final e = _error;
    return SizedBox(
      height: 320,
      child: EmptyState(
        icon: e != null && e.isNetwork ? Icons.wifi_off_rounded : Icons.error_outline_rounded,
        title: 'Stores nahi khul sake',
        message: e?.message ?? 'Dobara koshish karein.',
        action: FilledButton(onPressed: _load, child: const Text('Dobara koshish karein')),
      ),
    );
  }

  Widget _emptyView() {
    final filtered = _query.hasFilters;
    final meta = _meta;
    final area = meta?.area ?? '';
    return SizedBox(
      height: 340,
      child: EmptyState(
        icon: filtered ? Icons.search_off_rounded : Icons.storefront_outlined,
        title: filtered ? 'Koi store nahi mila' : 'Is area mein abhi koi store nahi',
        message: filtered
            ? 'Search ya filters badal kar dekhein.'
            : (area.isNotEmpty ? '$area mein abhi koi store deliver nahi karta. Doosra area chun kar dekhein.' : 'Thori dair baad dobara dekhein.'),
        action: filtered
            ? OutlinedButton(onPressed: _clearAll, child: const Text('Filters hatayein'))
            : OutlinedButton(onPressed: () => showAreaPicker(context), child: const Text('Area badlein')),
      ),
    );
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
            label: const Text('Aur stores nahi aa sake - dobara'),
          ),
        ),
      );
    }
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 16),
      child: Center(child: Text('Sab stores dikha diye', style: TextStyle(color: kMuted, fontSize: 13))),
    );
  }
}
