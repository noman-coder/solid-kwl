import 'package:flutter/material.dart';

/// Loading ke waqt dhundla (pulse karta) dibba - spinner se behtar lagta hai.
/// Ek [SkeletonScope] ke andar sab dibbe ek saath pulse karte hain (ek hi animation, kam RAM).
class SkeletonScope extends StatefulWidget {
  final Widget child;
  const SkeletonScope({super.key, required this.child});

  @override
  State<SkeletonScope> createState() => _SkeletonScopeState();
}

class _SkeletonScopeState extends State<SkeletonScope> with SingleTickerProviderStateMixin {
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
      builder: (context, child) => _SkeletonShade(
        shade: Color.lerp(const Color(0xFFEDE6DF), const Color(0xFFF7F2EC), _c.value)!,
        child: child!,
      ),
      child: widget.child,
    );
  }
}

class _SkeletonShade extends InheritedWidget {
  final Color shade;
  const _SkeletonShade({required this.shade, required super.child});

  @override
  bool updateShouldNotify(_SkeletonShade old) => old.shade != shade;
}

/// Dhundla dibba (SkeletonScope ke andar rakhein).
class SkeletonBox extends StatelessWidget {
  final double? width;
  final double height;
  final double radius;
  const SkeletonBox({super.key, this.width, this.height = 16, this.radius = 10});

  @override
  Widget build(BuildContext context) {
    final inherited = context.dependOnInheritedWidgetOfExactType<_SkeletonShade>();
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: inherited?.shade ?? const Color(0xFFEDE6DF),
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

/// Card jaisi dhundli list (pehla card thoda bara).
class SkeletonList extends StatelessWidget {
  final int count;
  final double height;
  const SkeletonList({super.key, this.count = 4, this.height = 92});

  @override
  Widget build(BuildContext context) {
    return SkeletonScope(
      child: Column(
        children: [
          for (var i = 0; i < count; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: SkeletonBox(
                  height: i == 0 ? height + 30 : height, radius: 16, width: double.infinity),
            ),
        ],
      ),
    );
  }
}
