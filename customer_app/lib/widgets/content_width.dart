import 'package:flutter/material.dart';

/// Bare phone / tablet par content ko beech mein ek munasib chaurai tak rakhta hai
/// (chhote phone par poori chaurai). Har form / list screen isi mein lapete.
class ContentWidth extends StatelessWidget {
  final Widget child;
  final double maxWidth;
  const ContentWidth({super.key, required this.child, this.maxWidth = 560});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(constraints: BoxConstraints(maxWidth: maxWidth), child: child),
    );
  }
}
