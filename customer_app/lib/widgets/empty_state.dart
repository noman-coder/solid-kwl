import 'package:flutter/material.dart';

import '../theme.dart';

/// Khali list / "jald aa raha hai" / error jaisi screens ke liye (icon + title + message + button).
/// Chhoti screen / bare text size par scroll ho jata hai, overflow nahi hota.
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  const EmptyState({super.key, required this.icon, required this.title, this.message, this.action});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: box.hasBoundedHeight ? box.maxHeight : 0),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircleAvatar(
                    radius: 38,
                    backgroundColor: kOrangeSoft,
                    child: Icon(icon, size: 38, color: kOrange),
                  ),
                  const SizedBox(height: 16),
                  Text(title,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: kInk)),
                  if (message != null) ...[
                    const SizedBox(height: 6),
                    Text(message!, textAlign: TextAlign.center, style: const TextStyle(color: kMuted)),
                  ],
                  if (action != null) ...[const SizedBox(height: 18), action!],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
