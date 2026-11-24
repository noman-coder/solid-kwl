import 'package:flutter/material.dart';

import '../models/order.dart';
import '../services/app_state.dart';
import '../theme.dart';
import '../utils.dart';

/// Aik order ka card: store, customer, items, COD/Paid chip aur action button.
/// offer = true to "Accept", warna status ke hisaab se "Maal le liya" ya "Deliver".
class OrderCard extends StatelessWidget {
  final RiderOrder order;
  final bool offer;
  final bool busy;
  final VoidCallback? onAccept;
  final VoidCallback? onPickup;
  final VoidCallback? onDeliver;
  final VoidCallback? onTap; // card dabane par detail

  const OrderCard({
    super.key,
    required this.order,
    required this.offer,
    this.busy = false,
    this.onAccept,
    this.onPickup,
    this.onDeliver,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final o = order;
    Widget action;
    if (offer) {
      action = FilledButton(
        onPressed: busy ? null : onAccept,
        child: Text('Accept  (${rs(o.fee)})'),
      );
    } else if (o.isAssigned) {
      action = FilledButton(
        onPressed: busy ? null : onPickup,
        child: const Text('📦 Maal le liya'),
      );
    } else {
      action = FilledButton(
        style: FilledButton.styleFrom(backgroundColor: Colors.green.shade700),
        onPressed: busy ? null : onDeliver,
        child: const Text('🎉 Deliver kar diya'),
      );
    }

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('#${o.orderNo}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                const Spacer(),
                Chip(
                  label: Text(o.isCod ? 'COD ${rs(o.total)}' : 'Paid'),
                  backgroundColor: o.isCod ? Colors.amber.shade100 : Colors.green.shade100,
                  side: BorderSide.none,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            if (!offer)
              Text(o.isAssigned ? 'Maal uthana hai' : 'Customer ko dena hai',
                  style: const TextStyle(color: Colors.black54)),
            const SizedBox(height: 8),
            _PlaceRow(icon: Icons.store, place: o.store),
            const SizedBox(height: 6),
            _PlaceRow(icon: Icons.home, place: o.customer),
            if (o.items.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(o.items.map((i) => '${numText(i.qty)} × ${i.name}').join('\n'),
                  style: const TextStyle(fontSize: 12.5, color: Colors.black87)),
            ],
            const SizedBox(height: 12),
            SizedBox(width: double.infinity, child: action),
          ],
        ),
      ),
      ),
    );
  }
}

class _PlaceRow extends StatelessWidget {
  final IconData icon;
  final Place place;
  const _PlaceRow({required this.icon, required this.place});

  Future<void> _open(BuildContext context, String url) async {
    final st = AppScope.of(context);
    if (!await openUrl(url)) st.toast('Ye link khul nahi saka');
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: Colors.black54),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (place.name.isNotEmpty)
                Text(place.name, style: const TextStyle(fontWeight: FontWeight.w700)),
              Text(place.address.isEmpty ? '—' : place.address, style: const TextStyle(fontSize: 12.5)),
            ],
          ),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.navigation, color: Colors.blue),
          tooltip: 'Map',
          onPressed: () => _open(context, place.mapUrl),
        ),
        if (place.phone.isNotEmpty)
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.call, color: kGreen),
            tooltip: 'Call',
            onPressed: () => _open(context, 'tel:${place.phone}'),
          ),
      ],
    );
  }
}
