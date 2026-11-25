import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/sales.dart';
import '../theme.dart';
import '../utils.dart';

/// Din wise bikri ka line + area chart (koi extra package nahi). 1 se 366 din tak chalta hai.
/// Neeche kuch tareekhein, upar sab se zyada bikri ka number. 1 din ho to ek bar jaisa nishan.
class SalesLineChart extends StatelessWidget {
  final List<SalesDay> days;
  final double height;
  const SalesLineChart({super.key, required this.days, this.height = 170});

  @override
  Widget build(BuildContext context) {
    if (days.isEmpty) {
      return SizedBox(
        height: height,
        child: const Center(child: Text('Abhi data nahi.', style: TextStyle(color: Colors.black54))),
      );
    }
    final maxV = days.map((d) => d.sales).fold<double>(0, math.max);
    return Column(
      children: [
        SizedBox(
          height: height,
          width: double.infinity,
          child: CustomPaint(painter: _LinePainter(days, maxV)),
        ),
        const SizedBox(height: 6),
        _XLabels(days: days),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(maxV > 0 ? 'Sab se zyada: ${rs(maxV)}' : 'Is muddat mein koi bikri nahi.',
              style: const TextStyle(fontSize: 11, color: Colors.black54)),
        ),
      ],
    );
  }
}

class _XLabels extends StatelessWidget {
  final List<SalesDay> days;
  const _XLabels({required this.days});

  @override
  Widget build(BuildContext context) {
    final n = days.length;
    final picks = <int>{0, n - 1};
    if (n > 4) {
      picks.add((n - 1) ~/ 2);
    }
    if (n > 10) {
      picks.add((n - 1) ~/ 4);
      picks.add(((n - 1) * 3) ~/ 4);
    }
    final idx = picks.toList()..sort();
    return Row(
      mainAxisAlignment: idx.length == 1 ? MainAxisAlignment.center : MainAxisAlignment.spaceBetween,
      children: [
        for (final i in idx)
          Text(days[i].label, style: const TextStyle(fontSize: 10, color: Colors.black54)),
      ],
    );
  }
}

class _LinePainter extends CustomPainter {
  final List<SalesDay> days;
  final double maxV;
  _LinePainter(this.days, this.maxV);

  @override
  void paint(Canvas canvas, Size size) {
    const padTop = 10.0;
    const padBottom = 6.0;
    final w = size.width;
    final h = size.height - padTop - padBottom;

    final grid = Paint()
      ..color = kBorder
      ..strokeWidth = 1;
    for (var i = 0; i <= 3; i++) {
      final y = padTop + h * i / 3;
      canvas.drawLine(Offset(0, y), Offset(w, y), grid);
    }

    final n = days.length;
    Offset pt(int i) {
      final x = n == 1 ? w / 2 : w * i / (n - 1);
      final v = maxV <= 0 ? 0.0 : days[i].sales / maxV;
      return Offset(x, padTop + h * (1 - v));
    }

    if (n == 1) {
      final p = pt(0);
      final bar = Paint()..color = kTeal.withValues(alpha: 0.85);
      final top = days[0].sales > 0 ? p.dy : padTop + h - 4;
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTRB(w / 2 - 18, top, w / 2 + 18, padTop + h), const Radius.circular(8)),
        bar,
      );
      return;
    }

    final line = Path()..moveTo(pt(0).dx, pt(0).dy);
    for (var i = 1; i < n; i++) {
      line.lineTo(pt(i).dx, pt(i).dy);
    }
    final area = Path.from(line)
      ..lineTo(pt(n - 1).dx, padTop + h)
      ..lineTo(pt(0).dx, padTop + h)
      ..close();
    canvas.drawPath(area, Paint()..color = kTeal.withValues(alpha: 0.14));
    canvas.drawPath(
      line,
      Paint()
        ..color = kTeal
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
    // Thore din hon to har din par dot; warna sirf aakhri din par
    final dot = Paint()..color = kTeal;
    if (n <= 14) {
      for (var i = 0; i < n; i++) {
        canvas.drawCircle(pt(i), 3.5, dot);
      }
    } else {
      canvas.drawCircle(pt(n - 1), 4, dot);
    }
  }

  @override
  bool shouldRepaint(covariant _LinePainter old) => old.days != days || old.maxV != maxV;
}

/// Cash (COD) vs Online ka donut. Dono 0 ho to khali ring.
class PayDonut extends StatelessWidget {
  final double cod;
  final double online;
  final double size;
  const PayDonut({super.key, required this.cod, required this.online, this.size = 112});

  static final Color codColor = Colors.orange.shade700;
  static final Color onlineColor = Colors.green.shade600;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _DonutPainter(cod, online, codColor, onlineColor)),
    );
  }
}

class _DonutPainter extends CustomPainter {
  final double cod;
  final double online;
  final Color codColor;
  final Color onlineColor;
  _DonutPainter(this.cod, this.online, this.codColor, this.onlineColor);

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 16.0;
    final rect = Rect.fromLTWH(stroke / 2, stroke / 2, size.width - stroke, size.height - stroke);
    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = const Color(0xFFE5E7EB);
    canvas.drawArc(rect, 0, math.pi * 2, false, base);
    final total = cod + online;
    if (total <= 0) return;
    final codSweep = math.pi * 2 * (cod / total);
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.butt;
    if (cod > 0) {
      canvas.drawArc(rect, -math.pi / 2, online <= 0 ? math.pi * 2 : codSweep, false, p..color = codColor);
    }
    if (online > 0) {
      canvas.drawArc(rect, -math.pi / 2 + (cod > 0 ? codSweep : 0),
          cod <= 0 ? math.pi * 2 : math.pi * 2 - codSweep, false, p..color = onlineColor);
    }
  }

  @override
  bool shouldRepaint(covariant _DonutPainter old) => old.cod != cod || old.online != online;
}
