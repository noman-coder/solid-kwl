import 'package:flutter/material.dart';

import '../models/order_detail.dart';
import '../theme.dart';
import '../utils.dart';

/// Order ka safar: Naya > Qubool > Tayyar > Raste mein > Deliver (reject par: Naya > Reject).
/// Server ke `steps` se banta hai; mukammal qadam teal, baqi dhundle.
class StatusStepper extends StatelessWidget {
  final List<StepInfo> steps;
  const StatusStepper({super.key, required this.steps});

  @override
  Widget build(BuildContext context) {
    if (steps.isEmpty) return const SizedBox.shrink();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < steps.length; i++)
          Expanded(
            child: _Step(
              info: steps[i],
              first: i == 0,
              last: i == steps.length - 1,
              nextDone: i + 1 < steps.length && steps[i + 1].done,
            ),
          ),
      ],
    );
  }
}

class _Step extends StatelessWidget {
  final StepInfo info;
  final bool first;
  final bool last;
  final bool nextDone;
  const _Step({required this.info, required this.first, required this.last, required this.nextDone});

  @override
  Widget build(BuildContext context) {
    final done = info.done;
    final color = info.failed ? Colors.red.shade700 : kTeal;
    final off = Colors.grey.shade300;
    final at = info.at.isEmpty ? '' : dateTimeText(info.at);
    return Column(
      children: [
        Row(
          children: [
            Expanded(child: Container(height: 3, color: first ? Colors.transparent : (done ? color : off))),
            CircleAvatar(
              radius: 14,
              backgroundColor: done ? color : off,
              child: Icon(
                done ? (info.failed ? Icons.close : Icons.check) : Icons.circle,
                size: done ? 16 : 8,
                color: Colors.white,
              ),
            ),
            Expanded(child: Container(height: 3, color: last ? Colors.transparent : (nextDone ? color : off))),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          info.label,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, fontWeight: done ? FontWeight.w800 : FontWeight.w500),
        ),
        if (at.isNotEmpty)
          Text(at, textAlign: TextAlign.center, style: const TextStyle(fontSize: 10, color: Colors.black54)),
      ],
    );
  }
}
