import 'package:flutter/material.dart';

import '../models/home.dart';
import '../theme.dart';
import '../utils.dart';
import 'net_image.dart';

/// Store ka card (logo, naam, rating, time, fee, faasla). Band store dhundla + 'abhi band hai' paigham.
class StoreCardTile extends StatelessWidget {
  final StoreCard store;
  final VoidCallback? onTap;
  const StoreCardTile({super.key, required this.store, this.onTap});

  @override
  Widget build(BuildContext context) {
    final st = store;
    final closed = !st.isOpen;
    final sub = [st.type, st.city].where((e) => e.isNotEmpty).join(' - ');
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Opacity(
                opacity: closed ? 0.5 : 1,
                child: NetImage(
                    path: st.logo, width: 64, height: 64, radius: 14, fallbackIcon: Icons.storefront_rounded),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(st.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 16, fontWeight: FontWeight.w800, color: closed ? kMuted : kInk)),
                        ),
                        if (st.verified) ...[
                          const SizedBox(width: 4),
                          const Icon(Icons.verified_rounded, size: 16, color: Color(0xFF2563EB)),
                        ],
                        if (st.isNew) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(color: kOrangeSoft, borderRadius: BorderRadius.circular(6)),
                            child: const Text('Naya',
                                style: TextStyle(color: kOrangeDark, fontSize: 11, fontWeight: FontWeight.w900)),
                          ),
                        ],
                      ],
                    ),
                    if (sub.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(sub,
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: kMuted, fontSize: 13)),
                      ),
                    if (st.tags.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(st.tags.join(', '),
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: kMuted, fontSize: 12.5)),
                      ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        if (st.rating != null) _Chip(icon: Icons.star_rounded, text: '${st.rating} (${st.ratingCount})', color: const Color(0xFFB45309)),
                        if (st.timeText.isNotEmpty) _Chip(icon: Icons.schedule_rounded, text: st.timeText),
                        st.freeDelivery
                            ? const _Chip(icon: Icons.delivery_dining_rounded, text: 'Delivery free', color: kGreen)
                            : _Chip(icon: Icons.delivery_dining_rounded, text: rs(st.deliveryFee)),
                        if (st.distanceText.isNotEmpty) _Chip(icon: Icons.near_me_rounded, text: st.distanceText),
                      ],
                    ),
                    if (closed || st.status == 'busy')
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          closed
                              ? (st.closedMessage.isNotEmpty ? st.closedMessage : 'Abhi band hai')
                              : 'Abhi busy hai - delivery mein der ho sakti hai',
                          style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                              color: closed ? Colors.red.shade700 : const Color(0xFFB45309)),
                        ),
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

class _Chip extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color color;
  const _Chip({required this.icon, required this.text, this.color = kMuted});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 3),
        Text(text, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: color)),
      ],
    );
  }
}
