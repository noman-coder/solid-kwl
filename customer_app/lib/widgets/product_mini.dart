import 'package:flutter/material.dart';

import '../models/home.dart';
import '../theme.dart';
import '../utils.dart';
import 'net_image.dart';

/// Home ke horizontal list ka chhota product card (offer badge, band store / khatam stock ka nishan).
class ProductMiniCard extends StatelessWidget {
  final ProductCard product;
  final VoidCallback? onTap;
  const ProductMiniCard({super.key, required this.product, this.onTap});

  /// Is card ki kul unchai (text bara ho to barhti hai, taake overflow na ho).
  static double heightFor(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(1.0).clamp(1.0, 1.3).toDouble();
    return 146 + 92 * scale;
  }

  @override
  Widget build(BuildContext context) {
    final p = product;
    final unavailable = !p.storeOpen || !p.inStock;
    return SizedBox(
      width: 144,
      child: Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                children: [
                  Opacity(
                    opacity: unavailable ? 0.5 : 1,
                    child: NetImage(path: p.image, width: 144, height: 112, fallbackIcon: Icons.fastfood_outlined),
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
                  if (unavailable)
                    Positioned(
                      bottom: 6,
                      left: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
                        child: Text(!p.storeOpen ? 'Store band' : 'Khatam',
                            style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
                      ),
                    ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(p.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: kInk, height: 1.2)),
                    const SizedBox(height: 4),
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.end,
                      spacing: 6,
                      children: [
                        Text(rs(p.price),
                            style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w900, color: kOrangeDark)),
                        if (p.oldPrice != null)
                          Text(rs(p.oldPrice),
                              style: const TextStyle(
                                  fontSize: 11.5, color: kMuted, decoration: TextDecoration.lineThrough)),
                      ],
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
      ),
    );
  }
}
