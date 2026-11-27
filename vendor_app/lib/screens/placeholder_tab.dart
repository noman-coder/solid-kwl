import 'package:flutter/material.dart';

import '../widgets/empty_state.dart';

/// Jis tab ka kaam abhi baqi hai: "Jald aa raha hai" (aglay phases mein asli screen se badal jayega).
class PlaceholderTab extends StatelessWidget {
  final IconData icon;
  final String title;
  const PlaceholderTab({super.key, required this.icon, required this.title});

  @override
  Widget build(BuildContext context) {
    return EmptyState(icon: icon, title: title, message: 'Yeh hissa jald aa raha hai.');
  }
}
