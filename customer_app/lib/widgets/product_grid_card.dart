import 'package:flutter/material.dart';

import '../models/products.dart';
import '../theme.dart';
import '../utils.dart';
import 'net_image.dart';

/// Grid ke columns aur har card ki unchai (chhote / bare phone aur text scale ke hisab se, taake kabhi overflow na ho).
class GridMetrics {
  final int columns;
  final double tileWidth;
  final double imageHeight;
  final double extent;
  const GridMetrics(this.columns, this.tileWidth, this.imageHeight, this.extent);
}

/// Search / list ka product card (tasveer, offer badge, naam, unit, qeemat, store). "Add" gol button tasveer ke kone par.
/// Khatam stock / band store par button ki jagah saaf nishan - customer us par order nahi kar sakta.
class ProductGridCard extends StatelessWidget {
  final ProductItem item;
  final VoidCallback? onTap;
  final VoidCallback? onAdd;
  const ProductGridCard({super.key, required this.item, this.onTap, this.onAdd});

  static const double spacing = 10;

  /// `width`: grid ke liye dastiyab chaurai (padding ke baad). Do column kam az kam, bare screen par zyada.
  static GridMetrics metrics(BuildContext context, double width) {
    final cols = (width / 180).floor().clamp(2, 5).toInt();
    final tile = (width - spacing * (cols - 1)) / cols;
    final scale = MediaQuery.textScalerOf(context).scale(1.0).clamp(1.0, 1.3).toDouble();
    final image = tile * 0.82;
    // naam (2 lines) + unit + qeemat + store ka naam + padding / faasle
    final extent = image + 18 + 84 * scale;
    return GridMetrics(cols, tile, image, extent);
  }

  @override
  Widget build(BuildContext context) {
    final p = item.card;
    final unavailable = !item.canAdd;
    final badge = !p.storeOpen ? 'Store band' : (!p.inStock ? 'Khatam' : '');
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 1 / 0.82,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Opacity(
                    opacity: unavailable ? 0.5 : 1,
                    child: NetImage(path: p.image, fallbackIcon: Icons.fastfood_outlined),
                  ),
                  if (p.discountPercent != null)
                    Positioned(
                      top: 8,
                      left: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(color: kGreen, borderRadius: BorderRadius.circular(8)),
                        child: Text('${p.discountPercent}% off',
                            style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w800)),
                      ),
                    ),
                  if (badge.isNotEmpty)
                    Positioned(
                      bottom: 6,
                      left: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
                        child: Text(badge,
                            style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
                      ),
                    ),
                  if (!unavailable)
                    Positioned(
                      bottom: 6,
                      right: 6,
                      child: SizedBox(
                        width: 36,
                        height: 36,
                        child: IconButton.filled(
                          onPressed: onAdd,
                          tooltip: 'Cart mein dalein',
                          padding: EdgeInsets.zero,
                          style: IconButton.styleFrom(backgroundColor: kOrange, foregroundColor: Colors.white),
                          icon: const Icon(Icons.add_rounded, size: 22),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(p.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          height: 1.2,
                          color: unavailable ? kMuted : kInk)),
                  if (p.unit.isNotEmpty)
                    Text(p.unit, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, color: kMuted)),
                  const SizedBox(height: 2),
                  Text.rich(
                    TextSpan(children: [
                      TextSpan(
                          text: rs(p.price),
                          style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w900, color: kOrangeDark)),
                      if (p.oldPrice != null)
                        TextSpan(
                            text: '  ${rs(p.oldPrice)}',
                            style: const TextStyle(
                                fontSize: 11.5, color: kMuted, decoration: TextDecoration.lineThrough)),
                    ]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (p.storeName.isNotEmpty)
                    Text(p.storeName,
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5, color: kMuted)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
