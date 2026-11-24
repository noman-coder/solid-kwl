import 'package:flutter/material.dart';

import '../models/vendor.dart';
import '../services/app_state.dart';
import '../theme.dart';
import '../utils.dart';
import '../widgets/section_title.dart';

/// More tab: store ka chhota card, aglay phases ki list (jald), logout, version.
class MoreScreen extends StatelessWidget {
  final VoidCallback onLogout;
  const MoreScreen({super.key, required this.onLogout});

  Future<void> _confirmLogout(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Logout'),
        content: const Text('Kya aap logout karna chahte hain?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Nahi')),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(80, 44)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Logout'),
          ),
        ],
      ),
    );
    if (ok == true) onLogout();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final v = state.vendor;
    return RefreshIndicator(
      onRefresh: state.refresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          if (v != null) _StoreCard(v: v),
          const SectionTitle('Jald aa raha hai'),
          const Card(
            child: Column(
              children: [
                _SoonTile(icon: Icons.local_offer_outlined, title: 'Coupons & offers'),
                Divider(height: 1),
                _SoonTile(icon: Icons.star_outline, title: 'Reviews'),
                Divider(height: 1),
                _SoonTile(icon: Icons.payments_outlined, title: 'Rider cash'),
                Divider(height: 1),
                _SoonTile(icon: Icons.storefront_outlined, title: 'Store settings'),
                Divider(height: 1),
                _SoonTile(icon: Icons.person_outline, title: 'Profile & help'),
              ],
            ),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: () => _confirmLogout(context),
            icon: const Icon(Icons.logout),
            label: const Text('Logout'),
            style: OutlinedButton.styleFrom(foregroundColor: Colors.red.shade700),
          ),
          const SizedBox(height: 16),
          const Center(
            child: Text('Version $kAppVersion', style: TextStyle(color: Colors.black45, fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

class _StoreCard extends StatelessWidget {
  final Vendor v;
  const _StoreCard({required this.v});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            CircleAvatar(
              radius: 28,
              backgroundColor: kTeal.withValues(alpha: 0.12),
              child: Text(v.initial,
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: kTeal)),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(v.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 2),
                  Text([v.phone, v.city].where((e) => e.isNotEmpty).join('  •  '),
                      style: const TextStyle(color: Colors.black54)),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      const Icon(Icons.star_rounded, size: 18, color: Colors.amber),
                      const SizedBox(width: 3),
                      Text(v.ratingCount > 0 ? '${v.rating.toStringAsFixed(1)} (${v.ratingCount})' : 'Abhi rating nahi',
                          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                      const SizedBox(width: 12),
                      Text('Commission ${numText(v.commissionPercent)}%',
                          style: const TextStyle(color: Colors.black54, fontSize: 13)),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SoonTile extends StatelessWidget {
  final IconData icon;
  final String title;
  const _SoonTile({required this.icon, required this.title});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: Colors.black45),
      title: Text(title, style: const TextStyle(color: Colors.black54, fontWeight: FontWeight.w600)),
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: kBg, borderRadius: BorderRadius.circular(10)),
        child: const Text('Jald', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.black45)),
      ),
    );
  }
}
