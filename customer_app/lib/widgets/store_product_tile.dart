import 'package:flutter/material.dart';

import '../models/stores.dart';
import '../theme.dart';
import '../utils.dart';
import 'net_image.dart';

/// Store detail ki list ka product (tasveer, naam, unit, qeemat, offer badge, "Add" button).
/// Band store / khatam stock par "Add" ki jagah saaf nishan (button band) - customer us par order nahi kar sakta.
class StoreProductTile extends StatelessWidget {
  final StoreProduct product;
  final VoidCallback? onTap;
  final VoidCallback? onAdd;
  const StoreProductTile({super.key, required this.product, this.onTap, this.onAdd});

  @override
  Widget build(BuildContext context) {
    final sp = product;
    final p = sp.card;
    final unavailable = !sp.canAdd;
    final note = !p.storeOpen ? 'Store band hai' : (!p.inStock ? 'Abhi available nahi' : '');
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                children: [
                  Opacity(
                    opacity: unavailable ? 0.5 : 1,
                    child: NetImage(
                        path: p.image, width: 88, height: 88, radius: 12, fallbackIcon: Icons.fastfood_outlined),
                  ),
                  if (p.discountPercent != null)
                    Positioned(
                      top: 4,
                      left: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(color: kGreen, borderRadius: BorderRadius.circular(6)),
                        child: Text('${p.discountPercent}% off',
                            style: const TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.w800)),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(p.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w800, height: 1.2, color: unavailable ? kMuted : kInk)),
                    if (p.unit.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(p.unit, style: const TextStyle(fontSize: 12.5, color: kMuted)),
                      ),
                    if (sp.description.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(sp.description,
                            maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, color: kMuted)),
                      ),
                    const SizedBox(height: 6),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: Wrap(
                            crossAxisAlignment: WrapCrossAlignment.end,
                            spacing: 6,
                            children: [
                              Text(rs(p.price),
                                  style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w900, color: kOrangeDark)),
                              if (p.oldPrice != null)
                                Text(rs(p.oldPrice),
                                    style: const TextStyle(
                                        fontSize: 12, color: kMuted, decoration: TextDecoration.lineThrough)),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        if (unavailable)
                          const SizedBox(width: 40, height: 40, child: Icon(Icons.block_rounded, color: kMuted, size: 22))
                        else
                          IconButton.filled(
                            onPressed: onAdd,
                            tooltip: 'Cart mein dalein',
                            style: IconButton.styleFrom(
                              backgroundColor: kOrange,
                              foregroundColor: Colors.white,
                              minimumSize: const Size(40, 40),
                            ),
                            icon: const Icon(Icons.add_rounded),
                          ),
                      ],
                    ),
                    if (note.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(note,
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.red.shade700)),
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
}
