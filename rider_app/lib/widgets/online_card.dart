import 'package:flutter/material.dart';

import '../services/app_state.dart';
import '../services/tracker.dart';
import '../theme.dart';
import '../utils.dart';

/// Online / Offline ka bara switch + aaj ke numbers. (Phase 5 mein dashboard isi ko use karega.)
class OnlineCard extends StatelessWidget {
  const OnlineCard({super.key});

  @override
  Widget build(BuildContext context) {
    final st = AppScope.of(context);
    final p = st.profile;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            Row(
              children: [
                Icon(Icons.circle, size: 14, color: st.online ? kGreen : Colors.grey),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(st.online ? 'Online' : 'Offline',
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                ),
                Switch(value: st.online, onChanged: st.busy ? null : st.toggleOnline),
              ],
            ),
            const Divider(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _Stat('Aaj deliveries', numText(p.todayDeliveries)),
                _Stat('Aaj kamai', rs(p.todayEarned)),
                _Stat('Cash paas', rs(p.cashInHand)),
              ],
            ),
            if (Tracker.running)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.my_location, size: 16, color: kGreen),
                    SizedBox(width: 6),
                    Text('Live location ON', style: TextStyle(color: kGreen, fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  const _Stat(this.label, this.value);

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(fontSize: 11, color: Colors.black54)),
        ],
      );
}
