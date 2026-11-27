import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/home.dart';
import '../services/api.dart';
import '../services/app_state.dart';
import '../theme.dart';
import '../utils.dart';
import '../widgets/banner_carousel.dart';
import '../widgets/content_width.dart';
import '../widgets/empty_state.dart';
import '../widgets/product_mini.dart';
import '../widgets/section_header.dart';
import '../widgets/skeleton.dart';
import '../widgets/store_card.dart';
import 'area_picker.dart';

/// Home tab (Phase C4): area, search, offers carousel, store types, categories, coupons, offers, stores, recently viewed.
///
/// - Pull-to-refresh, skeleton loader, error + retry.
/// - Net band ho to phone mein save kiya hua aakhri Home (shell ki patti 'Internet nahi hai' batati hai).
/// - Area / login badalne par khud dobara load hota hai (AppState.areaVersion).
class HomeTab extends StatefulWidget {
  const HomeTab({super.key});

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> {
  HomeData? _data;
  ApiException? _error;
  bool _loading = true; // pehli dafa (data nahi) - skeleton
  bool _refreshing = false; // data ke upar patli patti
  int? _master; // bari category khuli ho to uski id
  String _key = '';
  int _seq = 0; // purane (der se aaye) jawab ignore karne ke liye
  bool _promptChecked = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final st = AppScope.of(context);
    final key = '${st.customer?.id}|${st.areaVersion}';
    if (key != _key) {
      _key = key;
      _master = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    }
  }

  Future<void> _load() async {
    final seq = ++_seq;
    setState(() {
      _error = null;
      if (_data == null) {
        _loading = true;
      } else {
        _refreshing = true;
      }
    });
    HomeData? fresh;
    ApiException? err;
    try {
      fresh = await Api.home(master: _master);
    } on ApiException catch (e) {
      err = e;
    } catch (_) {
      err = ApiException('Kuch masla aa gaya. Dobara koshish karein.', 0);
    }
    if (!mounted || seq != _seq) return;
    HomeData? shown = fresh ?? _data;
    if (fresh == null && err != null && err.isNetwork && shown == null) {
      shown = await Api.cachedHome(); // net band + app naya khula: aakhri save kiya hua Home
      if (!mounted || seq != _seq) return;
    }
    setState(() {
      _loading = false;
      _refreshing = false;
      _data = shown;
      _error = (fresh == null && shown == null) ? err : null;
    });
    if (fresh == null && shown != null && err != null && !err.isNetwork) {
      AppScope.read(context).say(err.message);
    }
    if (fresh != null) _maybePromptArea(fresh);
  }

  /// Pehli dafa (aur area na ho) to area picker khud khul jaye; dobara zabardasti nahi.
  void _maybePromptArea(HomeData d) {
    if (_promptChecked) return;
    _promptChecked = true;
    if (Api.areaPrompted || Api.areaChosen || d.area.isNotEmpty) return;
    Api.markAreaPrompted();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) showAreaPicker(context);
    });
  }

  void _soon() => AppScope.read(context).say('Yeh hissa jald aa raha hai.');

  void _openBanner(BannerItem b) {
    final a = b.action;
    if (a.type == 'url' && a.url.isNotEmpty) {
      openUrl(a.relative ? Api.absUrl(a.url) : a.url);
    } else if (a.type == 'store' || a.type == 'stores') {
      _soon();
    }
  }

  void _openMaster(int? id) {
    _master = id;
    _load();
  }

  Future<void> _copy(String code) async {
    await Clipboard.setData(ClipboardData(text: code));
    if (mounted) AppScope.read(context).say('Code "$code" copy ho gaya.');
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final d = _data;
    Widget body;
    if (_loading && d == null) {
      body = const _HomeSkeleton();
    } else if (d == null) {
      body = EmptyState(
        icon: _error != null && _error!.isNetwork ? Icons.wifi_off_rounded : Icons.error_outline_rounded,
        title: 'Home nahi khul saka',
        message: _error?.message ?? 'Dobara koshish karein.',
        action: FilledButton(onPressed: _load, child: const Text('Dobara koshish karein')),
      );
    } else {
      body = _content(context, state, d);
    }
    return Stack(
      children: [
        RefreshIndicator(onRefresh: _load, color: kOrange, child: body),
        if (_refreshing) const Positioned(top: 0, left: 0, right: 0, child: LinearProgressIndicator(minHeight: 3)),
      ],
    );
  }

  Widget _content(BuildContext context, AppState state, HomeData d) {
    final scale = MediaQuery.textScalerOf(context).scale(1.0).clamp(1.0, 1.3).toDouble();
    final name = state.customer?.firstName;
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 28),
      children: [
        ContentWidth(
          maxWidth: 720,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _LocationHeader(
                area: d.area,
                chosen: Api.areaChosen,
                hasLocation: d.hasLocation,
                greeting: name == null ? 'Assalam o Alaikum!' : 'Assalam o Alaikum, $name!',
                onTap: () => showAreaPicker(context),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: _SearchBar(onTap: () => state.say('Search jald aa raha hai.')),
              ),
              if (d.delivery.freeEnabled && d.delivery.freeThreshold > 0)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: _FreeDeliveryStrip(threshold: d.delivery.freeThreshold),
                ),
              if (d.banners.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: BannerCarousel(banners: d.banners, onTap: _openBanner),
                ),
              if (d.storeTypes.isNotEmpty) ...[
                const SectionHeader(title: 'Dukan ki qism'),
                SizedBox(
                  height: 44 * scale,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: d.storeTypes.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (_, i) {
                      final t = d.storeTypes[i];
                      return ActionChip(
                        label: Text('${t.icon} ${t.name}'.trim()),
                        backgroundColor: Colors.white,
                        side: const BorderSide(color: kBorder),
                        labelStyle: const TextStyle(fontWeight: FontWeight.w700, color: kInk),
                        onPressed: _soon,
                      );
                    },
                  ),
                ),
              ],
              if (d.categories.isNotEmpty) ...[
                if (d.selectedMaster != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 12, 16, 0),
                    child: Row(
                      children: [
                        TextButton.icon(
                          onPressed: () => _openMaster(null),
                          icon: const Icon(Icons.arrow_back_rounded, size: 18),
                          label: const Text('Sab categories'),
                        ),
                        Expanded(
                          child: Text(d.selectedMasterName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.end,
                              style: const TextStyle(fontWeight: FontWeight.w900, color: kInk)),
                        ),
                      ],
                    ),
                  )
                else
                  const SectionHeader(title: 'Categories'),
                SizedBox(
                  height: 100 * scale,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: d.categories.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 10),
                    itemBuilder: (_, i) => _CategoryTileView(
                      tile: d.categories[i],
                      onTap: () => d.categories[i].isMaster ? _openMaster(d.categories[i].id) : _soon(),
                    ),
                  ),
                ),
              ],
              if (d.coupons.isNotEmpty) ...[
                const SectionHeader(title: 'Aap ke liye coupons'),
                SizedBox(
                  height: 104 * scale,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: d.coupons.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 10),
                    itemBuilder: (_, i) => _CouponCard(coupon: d.coupons[i], onCopy: _copy),
                  ),
                ),
              ],
              if (d.offers.isNotEmpty) ...[
                const SectionHeader(title: 'Aaj ke offers'),
                _ProductRow(items: d.offers, onTap: (_) => _soon()),
              ],
              SectionHeader(title: d.hasLocation ? 'Aap ke nazdeek stores' : 'Stores'),
              if (d.stores.isEmpty)
                _NoStores(data: d, onChangeArea: () => showAreaPicker(context))
              else
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    children: [
                      for (final st in d.stores)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: StoreCardTile(store: st, onTap: _soon),
                        ),
                      if (d.storesOutsideCount > 0)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            '${d.storesOutsideCount} aur stores doosre areas mein hain.',
                            style: const TextStyle(color: kMuted, fontSize: 13),
                          ),
                        ),
                    ],
                  ),
                ),
              if (d.recentlyViewed.isNotEmpty) ...[
                const SectionHeader(title: 'Haal hi mein dekhe'),
                _ProductRow(items: d.recentlyViewed, onTap: (_) => _soon()),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- chhote hisse

class _LocationHeader extends StatelessWidget {
  final String area;
  final bool chosen;
  final bool hasLocation;
  final String greeting;
  final VoidCallback onTap;
  const _LocationHeader(
      {required this.area, required this.chosen, required this.hasLocation, required this.greeting, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final label = area.isNotEmpty ? area : (chosen ? 'Sab areas' : 'Area chunein');
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(greeting,
              maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: kMuted, fontSize: 13.5)),
          const SizedBox(height: 2),
          InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  const Icon(Icons.location_on_rounded, color: kOrange, size: 22),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900, color: kInk)),
                  ),
                  const Icon(Icons.keyboard_arrow_down_rounded, color: kOrangeDark),
                  if (hasLocation) ...[
                    const SizedBox(width: 6),
                    const Icon(Icons.my_location_rounded, size: 16, color: kGreen),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchBar extends StatelessWidget {
  final VoidCallback onTap;
  const _SearchBar({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          height: 50,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: kBorder),
          ),
          child: const Row(
            children: [
              Icon(Icons.search_rounded, color: kMuted),
              SizedBox(width: 10),
              Expanded(
                child: Text('Dukan ya cheez dhoondhein',
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: kMuted, fontSize: 15)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FreeDeliveryStrip extends StatelessWidget {
  final double threshold;
  const _FreeDeliveryStrip({required this.threshold});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(color: kGreenSoft, borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          const Icon(Icons.delivery_dining_rounded, color: kGreen),
          const SizedBox(width: 8),
          Expanded(
            child: Text('${rs(threshold)} se upar order par delivery free',
                style: const TextStyle(color: kGreen, fontWeight: FontWeight.w800, fontSize: 13.5)),
          ),
        ],
      ),
    );
  }
}

class _CategoryTileView extends StatelessWidget {
  final CategoryTile tile;
  final VoidCallback onTap;
  const _CategoryTileView({required this.tile, required this.onTap});

  static const _tones = [
    Color(0xFFFFF1E8),
    Color(0xFFE8F7EE),
    Color(0xFFEAF2FF),
    Color(0xFFFFF4D6),
    Color(0xFFFCE8F1),
    Color(0xFFEFE9FF),
    Color(0xFFE4F6F8),
    Color(0xFFF1F1EA),
  ];

  @override
  Widget build(BuildContext context) {
    final bg = _tones[(tile.tone - 1).clamp(0, _tones.length - 1).toInt()];
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        width: 76,
        child: Column(
          children: [
            Container(
              width: 62,
              height: 62,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(18)),
              child: Text(tile.icon.isEmpty ? '🛍️' : tile.icon, style: const TextStyle(fontSize: 28)),
            ),
            const SizedBox(height: 6),
            Text(tile.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: kInk, height: 1.15)),
          ],
        ),
      ),
    );
  }
}

class _CouponCard extends StatelessWidget {
  final CouponItem coupon;
  final Future<void> Function(String) onCopy;
  const _CouponCard({required this.coupon, required this.onCopy});

  @override
  Widget build(BuildContext context) {
    final c = coupon;
    final until = c.validUntil.length >= 10 ? dateText(c.validUntil.substring(0, 10)) : '';
    final rule = [
      if (c.minOrder > 0) '${rs(c.minOrder)} se upar',
      if (c.firstOrderOnly) 'pehle order par',
      if (c.storeName.isNotEmpty) c.storeName,
      if (until.isNotEmpty) '$until tak',
    ].join(' - ');
    return Container(
      width: 232,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kGreen.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(c.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w900, color: kGreen, fontSize: 16)),
          if (rule.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(rule,
                  maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: kMuted, fontSize: 12)),
            ),
          const Spacer(),
          InkWell(
            onTap: () => onCopy(c.code),
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(color: kGreenSoft, borderRadius: BorderRadius.circular(8)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(c.code,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w900, letterSpacing: 0.6, color: kInk)),
                  ),
                  const SizedBox(width: 6),
                  const Icon(Icons.copy_rounded, size: 15, color: kGreen),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProductRow extends StatelessWidget {
  final List<ProductCard> items;
  final void Function(ProductCard) onTap;
  const _ProductRow({required this.items, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: ProductMiniCard.heightFor(context),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (_, i) => ProductMiniCard(product: items[i], onTap: () => onTap(items[i])),
      ),
    );
  }
}

class _NoStores extends StatelessWidget {
  final HomeData data;
  final VoidCallback onChangeArea;
  const _NoStores({required this.data, required this.onChangeArea});

  @override
  Widget build(BuildContext context) {
    final hasArea = data.area.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: kBorder),
        ),
        child: Column(
          children: [
            const CircleAvatar(
                radius: 30,
                backgroundColor: kOrangeSoft,
                child: Icon(Icons.storefront_outlined, size: 30, color: kOrange)),
            const SizedBox(height: 12),
            Text(hasArea ? 'Is area mein abhi koi store nahi' : 'Abhi koi store nahi',
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: kInk)),
            const SizedBox(height: 4),
            Text(
              data.storesOutsideCount > 0
                  ? 'Doosre areas mein ${data.storesOutsideCount} stores hain. Area badal kar dekhein.'
                  : 'Thori der baad dobara dekhein.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: kMuted),
            ),
            const SizedBox(height: 14),
            OutlinedButton(onPressed: onChangeArea, child: const Text('Area badlein')),
          ],
        ),
      ),
    );
  }
}

/// Home ka dhundla (loading) roop - asli layout jaisa.
class _HomeSkeleton extends StatelessWidget {
  const _HomeSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.all(16),
      children: const [
        ContentWidth(
          maxWidth: 720,
          child: SkeletonScope(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SkeletonBox(width: 120, height: 14),
                SizedBox(height: 8),
                SkeletonBox(width: 200, height: 24),
                SizedBox(height: 14),
                SkeletonBox(width: double.infinity, height: 50, radius: 14),
                SizedBox(height: 16),
                SkeletonBox(width: double.infinity, height: 120, radius: 16),
                SizedBox(height: 18),
                Row(
                  children: [
                    SkeletonBox(width: 62, height: 62, radius: 18),
                    SizedBox(width: 14),
                    SkeletonBox(width: 62, height: 62, radius: 18),
                    SizedBox(width: 14),
                    SkeletonBox(width: 62, height: 62, radius: 18),
                    SizedBox(width: 14),
                    SkeletonBox(width: 62, height: 62, radius: 18),
                  ],
                ),
                SizedBox(height: 20),
                SkeletonBox(width: double.infinity, height: 92, radius: 16),
                SizedBox(height: 10),
                SkeletonBox(width: double.infinity, height: 92, radius: 16),
                SizedBox(height: 10),
                SkeletonBox(width: double.infinity, height: 92, radius: 16),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
