import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../models/home.dart';
import '../models/stores.dart';
import '../services/api.dart';
import '../services/app_state.dart';
import '../theme.dart';
import '../utils.dart';
import '../widgets/content_width.dart';
import '../widgets/empty_state.dart';
import '../widgets/net_image.dart';
import '../widgets/notice_card.dart';
import '../widgets/skeleton.dart';
import '../widgets/store_product_tile.dart';

/// Kisi bhi jagah se store ka page kholo (Home, Stores tab, banner...). `preview` ho to load hote waqt naam dikhta hai.
Future<void> openStore(BuildContext context, int storeId, {StoreCard? preview}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(builder: (_) => StoreDetailScreen(storeId: storeId, preview: preview)),
  );
}

/// Store ka poora page (Phase C5): cover, info card, coupons, sticky category tabs, products (agla page neeche scroll par),
/// 'store band hai' patti, search, share.
///
/// Band store / khatam stock ke products par 'Add' band. Cart ka kaam Phase C7 mein judega (abhi 'Add' par paigham).
class StoreDetailScreen extends StatefulWidget {
  final int storeId;
  final StoreCard? preview;
  const StoreDetailScreen({super.key, required this.storeId, this.preview});

  @override
  State<StoreDetailScreen> createState() => _StoreDetailScreenState();
}

class _StoreDetailScreenState extends State<StoreDetailScreen> {
  final ScrollController _scroll = ScrollController();
  final TextEditingController _searchCtl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  Timer? _debounce;

  StoreDetailData? _data; // pehla jawab (store info + menu); baad mein refresh par badalta hai
  List<StoreProduct> _products = [];
  int _page = 1;
  bool _hasMore = false;
  bool _loading = true; // pehli dafa poora page
  bool _productsLoading = false; // category / search badli: sirf products dobara
  bool _loadingMore = false;
  bool _moreFailed = false;
  bool _searching = false;
  ApiException? _error; // pehla load fail (poori screen)
  ApiException? _productsError; // category / search ka load fail (sirf products ki jagah)
  int? _category; // null = sab, 0 = bina category wale
  String _q = '';
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scroll.dispose();
    _searchCtl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 500) _loadMore();
  }

  /// `full` true: poora page (pehli dafa / pull-to-refresh); false: sirf products (category / search badli).
  Future<void> _load({bool full = true}) async {
    final seq = ++_seq;
    setState(() {
      _error = null;
      _productsError = null;
      _moreFailed = false;
      _loadingMore = false;
      if (full && _data == null) {
        _loading = true;
      } else {
        _productsLoading = !full;
      }
    });
    StoreDetailData? fresh;
    ApiException? err;
    try {
      fresh = await Api.storeDetail(widget.storeId, category: _category, q: _q);
    } on ApiException catch (e) {
      err = e;
    } catch (_) {
      err = ApiException('Kuch masla aa gaya. Dobara koshish karein.', 0);
    }
    if (!mounted || seq != _seq) return;
    setState(() {
      _loading = false;
      _productsLoading = false;
      if (fresh != null) {
        _data = fresh;
        _products = List<StoreProduct>.of(fresh.products);
        _page = fresh.page;
        _hasMore = fresh.hasMore;
        _error = null;
      } else if (_data == null) {
        _error = err; // pehla load fail: poori screen par error
      } else if (!full) {
        _productsError = err; // category / search fail: products ki jagah error + retry
        _products = [];
        _hasMore = false;
      }
      // pull-to-refresh fail: purane products dikhte rahen
    });
    if (fresh == null && _data != null && full && err != null) AppScope.read(context).say(err.message);
  }

  Future<void> _loadMore() async {
    if (!_hasMore || _loadingMore || _loading || _productsLoading) return;
    final seq = _seq;
    setState(() {
      _loadingMore = true;
      _moreFailed = false;
    });
    try {
      final next = await Api.storeDetail(widget.storeId, category: _category, q: _q, page: _page + 1);
      if (!mounted || seq != _seq) return;
      setState(() {
        final seen = _products.map((e) => e.card.id).toSet();
        _products = [..._products, ...next.products.where((e) => !seen.contains(e.card.id))];
        _page = next.page;
        _hasMore = next.hasMore;
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

  void _pickCategory(int? id) {
    if (id == _category) return;
    setState(() {
      _category = id;
      _products = [];
      _hasMore = false;
    });
    _load(full: false);
  }

  void _onSearchChanged(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () {
      final t = text.trim();
      if (mounted && t != _q) _applySearch(t);
    });
  }

  void _applySearch(String t) {
    _debounce?.cancel();
    if (t == _q) return;
    setState(() {
      _q = t;
      _products = [];
      _hasMore = false;
    });
    _load(full: false);
  }

  void _toggleSearch() {
    setState(() => _searching = !_searching);
    if (_searching) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _searchFocus.requestFocus();
      });
    } else if (_q.isNotEmpty || _searchCtl.text.isNotEmpty) {
      _searchCtl.clear();
      _applySearch('');
    }
  }

  Future<void> _share() async {
    final info = _data?.store;
    final name = info?.card.name ?? widget.preview?.name ?? 'Store';
    final path = info?.sharePath ?? '';
    final text = [
      info != null && info.shareText.isNotEmpty ? info.shareText : name,
      if (path.isNotEmpty) Api.absUrl(path),
    ].join('\n');
    try {
      await Share.share(text, subject: name);
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) AppScope.read(context).say('Link copy ho gaya.');
    }
  }

  Future<void> _copy(String code) async {
    await Clipboard.setData(ClipboardData(text: code));
    if (mounted) AppScope.read(context).say('Code "$code" copy ho gaya.');
  }

  void _soon(String msg) => AppScope.read(context).say(msg);

  void _showRatings(StoreInfo info) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      backgroundColor: Colors.white,
      builder: (_) => _RatingSheet(info: info),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    if (d == null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.preview?.name ?? 'Store')),
        body: _loading
            ? const ContentWidth(
                maxWidth: 720,
                child: Padding(padding: EdgeInsets.all(16), child: SingleChildScrollView(child: _DetailSkeleton())),
              )
            : EmptyState(
                icon: _error != null && _error!.isNetwork ? Icons.wifi_off_rounded : Icons.storefront_outlined,
                title: _error != null && _error!.status == 404 ? 'Yeh store nahi mila' : 'Store nahi khul saka',
                message: _error?.message ?? 'Dobara koshish karein.',
                action: _error != null && _error!.status == 404
                    ? OutlinedButton(onPressed: () => Navigator.of(context).maybePop(), child: const Text('Wapas'))
                    : FilledButton(onPressed: _load, child: const Text('Dobara koshish karein')),
              ),
      );
    }
    final info = d.store;
    return Scaffold(
      body: ContentWidth(
        maxWidth: 720,
        child: RefreshIndicator(
          onRefresh: _load,
          color: kOrange,
          edgeOffset: 90,
          child: CustomScrollView(
            controller: _scroll,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              _appBar(info),
              SliverToBoxAdapter(child: _infoCard(info, d)),
              if (!info.card.isOpen)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: NoticeCard(
                      level: NoticeLevel.error,
                      icon: Icons.storefront_outlined,
                      text: info.card.closedMessage.isNotEmpty
                          ? '${info.card.closedMessage} Abhi order nahi ho sakta.'
                          : 'Yeh store abhi band hai. Abhi order nahi ho sakta.',
                    ),
                  ),
                )
              else if (info.card.status == 'busy')
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: NoticeCard(
                      level: NoticeLevel.warn,
                      text: 'Store abhi busy hai - order lete hain, magar delivery mein der ho sakti hai.',
                    ),
                  ),
                ),
              if (!info.servesArea)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: NoticeCard(
                      level: NoticeLevel.warn,
                      icon: Icons.location_off_outlined,
                      text: info.areaMessage.isNotEmpty ? info.areaMessage : 'Yeh store aap ke area mein deliver nahi karta.',
                    ),
                  ),
                ),
              if (info.coupons.isNotEmpty)
                SliverToBoxAdapter(child: _couponsStrip(info.coupons)),
              if (d.menu.isNotEmpty)
                SliverPersistentHeader(
                  pinned: true,
                  delegate: _MenuTabsDelegate(
                    menu: d.menu,
                    total: d.menuTotal,
                    selected: _category,
                    onPick: _pickCategory,
                    extent: 58 * MediaQuery.textScalerOf(context).scale(1.0).clamp(1.0, 1.3).toDouble(),
                  ),
                ),
              if (_searching)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
                    child: TextField(
                      controller: _searchCtl,
                      focusNode: _searchFocus,
                      textInputAction: TextInputAction.search,
                      onChanged: _onSearchChanged,
                      onSubmitted: (v) => _applySearch(v.trim()),
                      decoration: InputDecoration(
                        hintText: '${info.card.name} mein dhoondhein',
                        prefixIcon: const Icon(Icons.search_rounded, color: kMuted),
                        suffixIcon: IconButton(
                            icon: const Icon(Icons.close_rounded), tooltip: 'Band karein', onPressed: _toggleSearch),
                      ),
                    ),
                  ),
                ),
              ..._productSlivers(),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- hisse

  Widget _appBar(StoreInfo info) {
    final card = info.card;
    return SliverAppBar(
      pinned: true,
      expandedHeight: 170,
      backgroundColor: Colors.white,
      foregroundColor: kInk,
      automaticallyImplyLeading: false,
      leading: Padding(
        padding: const EdgeInsets.all(6),
        child: _RoundButton(icon: Icons.arrow_back_rounded, tooltip: 'Wapas', onTap: () => Navigator.of(context).maybePop()),
      ),
      actions: [
        _RoundButton(
            icon: _searching ? Icons.search_off_rounded : Icons.search_rounded,
            tooltip: 'Store mein dhoondhein',
            onTap: _toggleSearch),
        const SizedBox(width: 6),
        _RoundButton(icon: Icons.share_rounded, tooltip: 'Share karein', onTap: _share),
        const SizedBox(width: 10),
      ],
      flexibleSpace: LayoutBuilder(
        builder: (context, box) {
          final top = MediaQuery.paddingOf(context).top;
          final collapsed = box.maxHeight <= kToolbarHeight + top + 12;
          return Stack(
            fit: StackFit.expand,
            children: [
              if (!collapsed)
                NetImage(path: card.cover.isNotEmpty ? card.cover : card.logo, fit: BoxFit.cover, fallbackIcon: Icons.storefront_rounded),
              if (!collapsed)
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0x33000000), Color(0x00000000)],
                    ),
                  ),
                ),
              if (collapsed)
                Positioned(
                  left: 56,
                  right: 120,
                  bottom: 0,
                  height: kToolbarHeight,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(card.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: kInk)),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _infoCard(StoreInfo info, StoreDetailData d) {
    final c = info.card;
    final sub = [c.type, c.city].where((e) => e.isNotEmpty).join(' - ');
    final freeLine = c.freeDelivery
        ? 'Is store ki delivery free hai'
        : (d.delivery.freeEnabled && d.delivery.freeThreshold > 0
            ? '${rs(d.delivery.freeThreshold)} se upar order par delivery free'
            : '');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  NetImage(path: c.logo, width: 64, height: 64, radius: 14, fallbackIcon: Icons.storefront_rounded),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(c.name,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900, color: kInk)),
                            ),
                            if (c.verified) ...[
                              const SizedBox(width: 4),
                              const Icon(Icons.verified_rounded, size: 18, color: Color(0xFF2563EB)),
                            ],
                          ],
                        ),
                        if (sub.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(sub, style: const TextStyle(color: kMuted, fontSize: 13.5)),
                          ),
                        const SizedBox(height: 6),
                        _StatusPill(status: c.status, text: c.statusText),
                      ],
                    ),
                  ),
                ],
              ),
              if (info.description.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(info.description, style: const TextStyle(color: kInk, fontSize: 14, height: 1.35)),
                ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 14,
                runSpacing: 8,
                children: [
                  if (c.rating != null)
                    InkWell(
                      onTap: () => _showRatings(info),
                      borderRadius: BorderRadius.circular(8),
                      child: _Fact(
                          icon: Icons.star_rounded,
                          text: '${c.rating} (${c.ratingCount})',
                          color: const Color(0xFFB45309)),
                    )
                  else
                    const _Fact(icon: Icons.star_outline_rounded, text: 'Abhi rating nahi'),
                  if (c.timeText.isNotEmpty) _Fact(icon: Icons.schedule_rounded, text: c.timeText),
                  c.freeDelivery
                      ? const _Fact(icon: Icons.delivery_dining_rounded, text: 'Delivery free', color: kGreen)
                      : _Fact(icon: Icons.delivery_dining_rounded, text: 'Delivery ${rs(c.deliveryFee)}'),
                  if (c.minOrder > 0) _Fact(icon: Icons.shopping_bag_outlined, text: 'Kam az kam ${rs(c.minOrder)}'),
                  if (c.distanceText.isNotEmpty) _Fact(icon: Icons.near_me_rounded, text: c.distanceText),
                  if (info.hoursText.isNotEmpty) _Fact(icon: Icons.access_time_rounded, text: info.hoursText),
                ],
              ),
              if (freeLine.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(color: kGreenSoft, borderRadius: BorderRadius.circular(10)),
                    child: Text(freeLine,
                        style: const TextStyle(color: kGreen, fontWeight: FontWeight.w800, fontSize: 13)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _couponsStrip(List<CouponItem> coupons) {
    final scale = MediaQuery.textScalerOf(context).scale(1.0).clamp(1.0, 1.3).toDouble();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: SizedBox(
        height: 70 * scale,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: coupons.length,
          separatorBuilder: (_, __) => const SizedBox(width: 10),
          itemBuilder: (_, i) {
            final c = coupons[i];
            final rule = [
              if (c.minOrder > 0) '${rs(c.minOrder)} se upar',
              if (c.firstOrderOnly) 'pehle order par',
            ].join(' - ');
            return InkWell(
              onTap: () => _copy(c.code),
              borderRadius: BorderRadius.circular(14),
              child: Container(
                width: 210,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: kGreen.withValues(alpha: 0.35)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.local_offer_rounded, color: kGreen),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(c.label.isNotEmpty ? c.label : c.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w900, color: kInk, fontSize: 14)),
                          Text('Code: ${c.code}${rule.isEmpty ? '' : ' - $rule'}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: kMuted, fontSize: 12)),
                        ],
                      ),
                    ),
                    const Icon(Icons.copy_rounded, size: 18, color: kMuted),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  List<Widget> _productSlivers() {
    if (_productsLoading) {
      return const [
        SliverToBoxAdapter(
          child: Padding(padding: EdgeInsets.fromLTRB(16, 10, 16, 0), child: SkeletonList(count: 4, height: 100)),
        ),
      ];
    }
    if (_products.isEmpty && _productsError != null) {
      final e = _productsError!;
      return [
        SliverToBoxAdapter(
          child: SizedBox(
            height: 280,
            child: EmptyState(
              icon: e.isNetwork ? Icons.wifi_off_rounded : Icons.error_outline_rounded,
              title: 'Products nahi aa sake',
              message: e.message,
              action: FilledButton(onPressed: () => _load(full: false), child: const Text('Dobara koshish karein')),
            ),
          ),
        ),
      ];
    }
    if (_products.isEmpty) {
      final searching = _q.isNotEmpty;
      return [
        SliverToBoxAdapter(
          child: SizedBox(
            height: 280,
            child: EmptyState(
              icon: searching ? Icons.search_off_rounded : Icons.inventory_2_outlined,
              title: searching ? 'Koi product nahi mila' : 'Abhi koi product nahi',
              message: searching
                  ? '"$_q" se milta koi product is store mein nahi.'
                  : (_category != null ? 'Is category mein abhi koi product nahi.' : 'Is store ne abhi products nahi lagaye.'),
            ),
          ),
        ),
      ];
    }
    final showHeaders = _category == null && _q.isEmpty;
    return [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
        sliver: SliverList.builder(
          itemCount: _products.length,
          itemBuilder: (context, i) {
            final sp = _products[i];
            final newGroup = showHeaders && (i == 0 || _products[i - 1].categoryId != sp.categoryId);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (newGroup)
                  Padding(
                    padding: EdgeInsets.fromLTRB(2, i == 0 ? 8 : 18, 0, 8),
                    child: Text(sp.categoryName.isEmpty ? 'Doosra' : sp.categoryName,
                        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: kInk)),
                  ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: StoreProductTile(
                    product: sp,
                    onTap: () => _soon('Product ka page jald aa raha hai.'),
                    onAdd: () => _soon('Cart ka hissa jald aa raha hai.'),
                  ),
                ),
              ],
            );
          },
        ),
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

class _RoundButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _RoundButton({required this.icon, required this.tooltip, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.92),
      shape: const CircleBorder(side: BorderSide(color: kBorder)),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Tooltip(
          message: tooltip,
          child: SizedBox(width: 40, height: 40, child: Icon(icon, size: 22, color: kInk)),
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final String status;
  final String text;
  const _StatusPill({required this.status, required this.text});

  @override
  Widget build(BuildContext context) {
    final Color fg;
    final Color bg;
    switch (status) {
      case 'closed':
        fg = Colors.red.shade700;
        bg = Colors.red.shade50;
        break;
      case 'busy':
        fg = const Color(0xFFB45309);
        bg = const Color(0xFFFEF3C7);
        break;
      default:
        fg = kGreen;
        bg = kGreenSoft;
    }
    final label = text.isNotEmpty ? text : (status == 'closed' ? 'Abhi band hai' : 'Khula hai');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
      child: Text(label, style: TextStyle(color: fg, fontWeight: FontWeight.w800, fontSize: 12.5)),
    );
  }
}

class _Fact extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color color;
  const _Fact({required this.icon, required this.text, this.color = kMuted});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 17, color: color),
        const SizedBox(width: 4),
        Flexible(child: Text(text, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: color))),
      ],
    );
  }
}

/// Sticky category tabs: "Sab (n)" + store ki categories.
class _MenuTabsDelegate extends SliverPersistentHeaderDelegate {
  final List<StoreMenuItem> menu;
  final int total;
  final int? selected;
  final ValueChanged<int?> onPick;
  final double extent;

  _MenuTabsDelegate(
      {required this.menu, required this.total, required this.selected, required this.onPick, required this.extent});

  @override
  double get minExtent => extent;

  @override
  double get maxExtent => extent;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Material(
      color: kBg,
      elevation: overlapsContent ? 1.5 : 0,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        children: [
          _tab('Sab ($total)', selected == null, () => onPick(null)),
          for (final m in menu) _tab('${m.name} (${m.count})', selected == m.id, () => onPick(m.id)),
        ],
      ),
    );
  }

  Widget _tab(String label, bool on, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        selected: on,
        showCheckmark: false,
        label: Text(label),
        onSelected: (_) => onTap(),
        backgroundColor: Colors.white,
        selectedColor: kOrange,
        side: BorderSide(color: on ? kOrange : kBorder),
        labelStyle: TextStyle(fontWeight: FontWeight.w700, color: on ? Colors.white : kInk),
      ),
    );
  }

  @override
  bool shouldRebuild(_MenuTabsDelegate old) =>
      old.selected != selected || old.menu != menu || old.total != total || old.extent != extent;
}

class _RatingSheet extends StatelessWidget {
  final StoreInfo info;
  const _RatingSheet({required this.info});

  @override
  Widget build(BuildContext context) {
    final c = info.card;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.star_rounded, color: Color(0xFFB45309), size: 30),
                const SizedBox(width: 6),
                Text('${c.rating ?? '-'}',
                    style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: kInk)),
                const SizedBox(width: 8),
                Text('${c.ratingCount} ratings', style: const TextStyle(color: kMuted)),
              ],
            ),
            const SizedBox(height: 12),
            for (final b in info.ratingBars)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    SizedBox(width: 30, child: Text('${b.stars} *', style: const TextStyle(fontWeight: FontWeight.w700))),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: LinearProgressIndicator(
                          value: (b.pct.clamp(0, 100)) / 100,
                          minHeight: 9,
                          backgroundColor: kOrangeSoft,
                          color: const Color(0xFFF59E0B),
                        ),
                      ),
                    ),
                    SizedBox(width: 38, child: Text('${b.count}', textAlign: TextAlign.end, style: const TextStyle(color: kMuted))),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _DetailSkeleton extends StatelessWidget {
  const _DetailSkeleton();

  @override
  Widget build(BuildContext context) {
    return const SkeletonScope(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SkeletonBox(height: 140, radius: 18, width: double.infinity),
          SizedBox(height: 12),
          SkeletonBox(height: 120, radius: 16, width: double.infinity),
          SizedBox(height: 14),
          SkeletonBox(height: 40, radius: 20, width: 260),
          SizedBox(height: 14),
          SkeletonBox(height: 100, radius: 16, width: double.infinity),
          SizedBox(height: 10),
          SkeletonBox(height: 100, radius: 16, width: double.infinity),
          SizedBox(height: 10),
          SkeletonBox(height: 100, radius: 16, width: double.infinity),
        ],
      ),
    );
  }
}
