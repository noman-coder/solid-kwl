import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../models/home.dart';
import '../models/products.dart';
import '../services/api.dart';
import '../services/app_state.dart';
import '../theme.dart';
import '../utils.dart';
import '../widgets/cart_actions.dart';
import '../widgets/content_width.dart';
import '../widgets/empty_state.dart';
import '../widgets/net_image.dart';
import '../widgets/notice_card.dart';
import '../widgets/product_mini.dart';
import '../widgets/skeleton.dart';
import 'store_detail.dart';

/// Kisi bhi jagah se product ka page kholo (Search, Store page, Home...). `preview` ho to load hote waqt naam / qeemat dikhti hai.
Future<void> openProduct(BuildContext context, int productId, {ProductCard? preview}) {
  return Navigator.of(context).push<void>(
    MaterialPageRoute<void>(builder: (_) => ProductDetailScreen(productId: productId, preview: preview)),
  );
}

const int _kMaxQty = 99;

/// Phase C6: product ka poora page - tasveeren (zoom), offer badge + countdown, qeemat, stock badge, store, milte julte,
/// qty stepper aur "Cart mein dalein" (Phase C7: cart mein jata hai, guest ke liye phone mein).
class ProductDetailScreen extends StatefulWidget {
  final int productId;
  final ProductCard? preview;
  const ProductDetailScreen({super.key, required this.productId, this.preview});

  @override
  State<ProductDetailScreen> createState() => _ProductDetailScreenState();
}

class _ProductDetailScreenState extends State<ProductDetailScreen> {
  final PageController _pages = PageController();
  ProductDetailData? _data;
  bool _loading = true;
  ApiException? _error;
  int _qty = 1;
  bool _adding = false;
  int _imageIndex = 0;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final my = ++_seq;
    setState(() {
      _loading = _data == null;
      _error = null;
    });
    try {
      final d = await Api.productDetail(widget.productId);
      if (!mounted || my != _seq) return;
      setState(() {
        _data = d;
        _loading = false;
        if (_qty > _maxFor(d)) _qty = _maxFor(d);
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

  int _maxFor(ProductDetailData d) => d.maxQty <= 0 ? 1 : (d.maxQty > _kMaxQty ? _kMaxQty : d.maxQty);

  void _say(String msg) => AppScope.read(context).say(msg);

  Future<void> _share(ProductDetailData d) async {
    final path = d.sharePath;
    final text = [
      d.shareText.isNotEmpty ? d.shareText : d.item.card.name,
      if (path.isNotEmpty) Api.absUrl(path),
    ].join('\n');
    try {
      await Share.share(text, subject: d.item.card.name);
    } catch (_) {
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) _say('Link copy ho gaya.');
    }
  }

  Future<void> _addToCart(ProductDetailData d) async {
    if (_adding) return;                       // double tap par ek hi dafa
    setState(() => _adding = true);
    try {
      final ok = await addProductToCart(context, card: d.item.card, qty: _qty, stock: d.maxQty);
      if (ok && mounted) setState(() => _qty = 1);
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  void _openImage(ProductDetailData d, int index) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => _ImageViewer(images: d.images, start: index),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    if (d == null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.preview?.name ?? 'Product', maxLines: 1, overflow: TextOverflow.ellipsis)),
        body: _loading
            ? const ContentWidth(maxWidth: 720, child: SingleChildScrollView(child: _DetailSkeleton()))
            : EmptyState(
                icon: _error != null && _error!.isNetwork ? Icons.wifi_off_rounded : Icons.inventory_2_outlined,
                title: _error != null && _error!.status == 404 ? 'Yeh product nahi mila' : 'Product nahi khul saka',
                message: _error?.message ?? 'Dobara koshish karein.',
                action: _error != null && _error!.status == 404
                    ? OutlinedButton(onPressed: () => Navigator.of(context).maybePop(), child: const Text('Wapas'))
                    : FilledButton(onPressed: _load, child: const Text('Dobara koshish karein')),
              ),
      );
    }
    final p = d.item.card;
    return Scaffold(
      appBar: AppBar(
        title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17)),
        actions: [
          IconButton(icon: const Icon(Icons.share_rounded), tooltip: 'Share karein', onPressed: () => _share(d)),
        ],
      ),
      body: ContentWidth(
        maxWidth: 720,
        child: RefreshIndicator(
          onRefresh: _load,
          color: kOrange,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.only(bottom: 24),
            children: [
              _gallery(d),
              _info(d),
              if (d.related.isNotEmpty) _relatedRow(d),
            ],
          ),
        ),
      ),
      bottomNavigationBar: _bottomBar(d),
    );
  }

  // ---------------------------------------------------------------- tasveeren

  Widget _gallery(ProductDetailData d) {
    final p = d.item.card;
    final unavailable = !d.item.canAdd;
    final images = d.images;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: AspectRatio(
          aspectRatio: 1.15,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Container(color: Colors.white),
              if (images.isEmpty)
                const NetImage(path: '', fallbackIcon: Icons.fastfood_outlined)
              else
                PageView.builder(
                  controller: _pages,
                  itemCount: images.length,
                  onPageChanged: (i) => setState(() => _imageIndex = i),
                  itemBuilder: (_, i) => GestureDetector(
                    onTap: () => _openImage(d, i),
                    child: Opacity(
                      opacity: unavailable ? 0.55 : 1,
                      child: NetImage(path: images[i].thumb, fit: BoxFit.contain, fallbackIcon: Icons.fastfood_outlined),
                    ),
                  ),
                ),
              if (p.discountPercent != null)
                Positioned(
                  top: 12,
                  left: 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(color: kGreen, borderRadius: BorderRadius.circular(10)),
                    child: Text('${p.discountPercent}% off',
                        style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w900)),
                  ),
                ),
              if (images.isNotEmpty)
                Positioned(
                  top: 10,
                  right: 10,
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(color: Colors.black38, borderRadius: BorderRadius.circular(20)),
                    child: const Icon(Icons.zoom_out_map_rounded, size: 18, color: Colors.white),
                  ),
                ),
              if (images.length > 1)
                Positioned(
                  bottom: 10,
                  left: 0,
                  right: 0,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (var i = 0; i < images.length; i++)
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          margin: const EdgeInsets.symmetric(horizontal: 3),
                          width: i == _imageIndex ? 18 : 7,
                          height: 7,
                          decoration: BoxDecoration(
                              color: i == _imageIndex ? kOrange : Colors.black26, borderRadius: BorderRadius.circular(4)),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- tafseel

  String _offerLeft(DateTime? ends) {
    if (ends == null) return '';
    final left = ends.difference(DateTime.now());
    if (left.isNegative) return '';
    if (left.inDays >= 1) return 'Offer ${left.inDays} din ${left.inHours % 24} ghante mein khatam';
    if (left.inHours >= 1) return 'Offer ${left.inHours} ghante ${left.inMinutes % 60} minute mein khatam';
    return 'Offer ${left.inMinutes.clamp(1, 59)} minute mein khatam';
  }

  Widget _info(ProductDetailData d) {
    final p = d.item.card;
    final saved = p.oldPrice != null ? (p.oldPrice! - p.price) : 0.0;
    final offerLeft = d.hasOffer ? _offerLeft(p.offerEndsAt) : '';
    final Color stockFg;
    final Color stockBg;
    if (!d.item.card.inStock) {
      stockFg = Colors.red.shade700;
      stockBg = Colors.red.shade50;
    } else if (d.lowStock) {
      stockFg = const Color(0xFFB45309);
      stockBg = const Color(0xFFFEF3C7);
    } else {
      stockFg = kGreen;
      stockBg = kGreenSoft;
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(p.name, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w900, color: kInk, height: 1.2)),
          if (p.unit.isNotEmpty || d.item.categoryName.isNotEmpty || d.item.brand.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  if (p.unit.isNotEmpty) _Tag(p.unit),
                  if (d.item.categoryName.isNotEmpty) _Tag(d.item.categoryName),
                  if (d.item.brand.isNotEmpty) _Tag(d.item.brand),
                ],
              ),
            ),
          const SizedBox(height: 12),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.end,
            spacing: 10,
            runSpacing: 4,
            children: [
              Text(rs(p.price), style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: kOrangeDark)),
              if (p.oldPrice != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(rs(p.oldPrice),
                      style: const TextStyle(fontSize: 16, color: kMuted, decoration: TextDecoration.lineThrough)),
                ),
              if (saved > 0)
                Container(
                  margin: const EdgeInsets.only(bottom: 4),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(color: kGreenSoft, borderRadius: BorderRadius.circular(8)),
                  child: Text('${rs(saved)} bachat',
                      style: const TextStyle(color: kGreen, fontSize: 12.5, fontWeight: FontWeight.w800)),
                ),
            ],
          ),
          if (offerLeft.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  const Icon(Icons.timer_outlined, size: 16, color: kGreen),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(offerLeft,
                        style: const TextStyle(color: kGreen, fontSize: 13, fontWeight: FontWeight.w700)),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(color: stockBg, borderRadius: BorderRadius.circular(10)),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(d.item.card.inStock ? Icons.check_circle_outline_rounded : Icons.block_rounded,
                    size: 16, color: stockFg),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(d.stockText.isEmpty ? (d.item.card.inStock ? 'Stock mein hai' : 'Abhi available nahi') : d.stockText,
                      style: TextStyle(color: stockFg, fontSize: 13, fontWeight: FontWeight.w800)),
                ),
              ],
            ),
          ),
          if (!d.store.isOpen)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: NoticeCard(
                level: NoticeLevel.warn,
                icon: Icons.storefront_outlined,
                text: d.store.closedMessage.isEmpty ? '${d.store.name} abhi band hai.' : d.store.closedMessage,
              ),
            ),
          if (!d.servesArea && d.areaMessage.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: NoticeCard(level: NoticeLevel.warn, icon: Icons.location_off_outlined, text: d.areaMessage),
            ),
          if (d.description.isNotEmpty) ...[
            const SizedBox(height: 18),
            const Text('Tafseel', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: kInk)),
            const SizedBox(height: 6),
            Text(d.description, style: const TextStyle(fontSize: 14.5, color: kInk, height: 1.45)),
          ],
          const SizedBox(height: 18),
          _storeCard(d.store),
        ],
      ),
    );
  }

  Widget _storeCard(ProductStoreBox st) {
    final meta = <String>[
      if (st.rating != null) '${st.rating!.toStringAsFixed(1)} (${st.ratingCount})',
      st.freeDelivery ? 'Free delivery' : 'Delivery ${rs(st.deliveryFee)}',
      if (st.deliveryTimeMax > 0) '${st.deliveryTimeMin}-${st.deliveryTimeMax} min',
    ];
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: st.id > 0 ? () => openStore(context, st.id) : null,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              NetImage(path: st.logo, width: 52, height: 52, radius: 26, fallbackIcon: Icons.storefront_outlined),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(st.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w900, color: kInk)),
                    const SizedBox(height: 2),
                    Text(
                      st.statusText.isEmpty ? meta.join('  •  ') : '${st.statusText}  •  ${meta.join('  •  ')}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.5, color: st.isOpen ? kMuted : Colors.red.shade700),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: kMuted),
            ],
          ),
        ),
      ),
    );
  }

  Widget _relatedRow(ProductDetailData d) {
    return Padding(
      padding: const EdgeInsets.only(top: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text('Milte julte products', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: kInk)),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: ProductMiniCard.heightFor(context),
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: d.related.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (_, i) {
                final it = d.related[i];
                return ProductMiniCard(
                  product: it.card,
                  onTap: () => openProduct(context, it.card.id, preview: it.card),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- neeche ki patti: qty + Add

  Widget? _bottomBar(ProductDetailData d) {
    final p = d.item.card;
    final can = d.item.canAdd && d.servesArea;
    final max = _maxFor(d);
    final String label;
    if (can) {
      label = 'Cart mein dalein  •  ${rs(p.price * _qty)}';
    } else if (!d.store.isOpen) {
      label = 'Store abhi band hai';
    } else if (!d.servesArea) {
      label = 'Is area mein deliver nahi';
    } else {
      label = 'Abhi available nahi';
    }
    return Material(
      color: Colors.white,
      elevation: 8,
      child: SafeArea(
        top: false,
        child: ContentWidth(
          maxWidth: 720,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Row(
              children: [
                if (can) ...[
                  Container(
                    decoration: BoxDecoration(
                        color: kOrangeSoft, borderRadius: BorderRadius.circular(14), border: Border.all(color: kBorder)),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'Kam karein',
                          onPressed: _qty > 1 ? () => setState(() => _qty--) : null,
                          icon: const Icon(Icons.remove_rounded),
                        ),
                        SizedBox(
                          width: 28,
                          child: Text('$_qty',
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: kInk)),
                        ),
                        IconButton(
                          tooltip: 'Zyada karein',
                          onPressed: () {
                            if (_qty < max) {
                              setState(() => _qty++);
                            } else {
                              _say(d.maxQty > 0 && d.maxQty < _kMaxQty
                                  ? 'Itna hi stock hai (${d.maxQty}).'
                                  : 'Ek dafa mein itna hi mangwa sakte hain.');
                            }
                          },
                          icon: const Icon(Icons.add_rounded),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: FilledButton(
                    onPressed: can && !_adding ? () => _addToCart(d) : null,
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                    child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- chhote widgets

class _Tag extends StatelessWidget {
  final String text;
  const _Tag(this.text);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(color: kOrangeSoft, borderRadius: BorderRadius.circular(8)),
      child: Text(text, style: const TextStyle(fontSize: 12.5, color: kOrangeDark, fontWeight: FontWeight.w700)),
    );
  }
}

class _DetailSkeleton extends StatelessWidget {
  const _DetailSkeleton();

  @override
  Widget build(BuildContext context) {
    return const SkeletonScope(
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SkeletonBox(height: 250, radius: 20, width: double.infinity),
            SizedBox(height: 16),
            SkeletonBox(height: 24, width: 230),
            SizedBox(height: 10),
            SkeletonBox(height: 30, width: 150),
            SizedBox(height: 16),
            SkeletonBox(height: 70, radius: 16, width: double.infinity),
          ],
        ),
      ),
    );
  }
}

/// Poori screen par tasveer: ungli se zoom (pinch), swipe se agli tasveer.
class _ImageViewer extends StatelessWidget {
  final List<ProductImage> images;
  final int start;
  const _ImageViewer({required this.images, required this.start});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text('Tasveer', style: TextStyle(color: Colors.white, fontSize: 16)),
      ),
      body: PageView.builder(
        controller: PageController(initialPage: start),
        itemCount: images.length,
        itemBuilder: (_, i) => InteractiveViewer(
          minScale: 1,
          maxScale: 4,
          child: Center(child: NetImage(path: images[i].full, fit: BoxFit.contain)),
        ),
      ),
    );
  }
}
