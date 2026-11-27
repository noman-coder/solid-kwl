import 'package:flutter/material.dart';

/// Loading ke waqt dhundle (pulse karte) card - spinner se behtar lagta hai.
class SkeletonList extends StatefulWidget {
  final int count;
  final double height;
  const SkeletonList({super.key, this.count = 4, this.height = 92});

  @override
  State<SkeletonList> createState() => _SkeletonListState();
}

class _SkeletonListState extends State<SkeletonList> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final shade = Color.lerp(const Color(0xFFE5E7EB), const Color(0xFFF3F4F6), _c.value)!;
        return Column(
          children: [
            for (var i = 0; i < widget.count; i++)
              Container(
                height: i == 0 ? widget.height + 30 : widget.height,
                margin: const EdgeInsets.only(bottom: 10),
                decoration: BoxDecoration(color: shade, borderRadius: BorderRadius.circular(16)),
              ),
          ],
        );
      },
    );
  }
}
