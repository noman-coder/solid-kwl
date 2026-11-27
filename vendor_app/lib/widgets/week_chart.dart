import 'package:flutter/material.dart';

import '../models/dashboard.dart';
import '../theme.dart';
import '../utils.dart';

/// 7 din ka simple bar chart (koi extra package nahi). Bar = bikri, neeche orders ki ginti.
class WeekChart extends StatelessWidget {
  final List<ChartDay> days;
  const WeekChart({super.key, required this.days});

  @override
  Widget build(BuildContext context) {
    if (days.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Text('Abhi data nahi.', style: TextStyle(color: Colors.black54)),
      );
    }
    final maxV = days.map((d) => d.sales).fold<double>(0, (a, b) => b > a ? b : a);
    const barArea = 110.0;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        for (var i = 0; i < days.length; i++)
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: 16,
                  child: days[i].sales > 0
                      ? FittedBox(
                          child: Text(numText(days[i].sales),
                              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700)),
                        )
                      : null,
                ),
                const SizedBox(height: 2),
                SizedBox(
                  height: barArea,
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: Container(
                      width: 22,
                      height: maxV <= 0 ? 4 : (days[i].sales / maxV * barArea).clamp(4.0, barArea),
                      decoration: BoxDecoration(
                        color: i == days.length - 1 ? kTeal : kTeal.withValues(alpha: 0.35),
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(days[i].label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600)),
                Text('${days[i].orders} ord',
                    style: const TextStyle(fontSize: 10, color: Colors.black54)),
              ],
            ),
          ),
      ],
    );
  }
}
