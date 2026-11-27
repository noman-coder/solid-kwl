import 'package:flutter/material.dart';

import '../theme.dart';

/// Home ke hisse ka sar-nama (+ optional 'Sab dekhein' jaisa button).
class SectionHeader extends StatelessWidget {
  final String title;
  final String? action;
  final VoidCallback? onAction;
  const SectionHeader({super.key, required this.title, this.action, this.onAction});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: kInk)),
          ),
          if (action != null && onAction != null)
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(minimumSize: const Size(48, 36), padding: const EdgeInsets.symmetric(horizontal: 10)),
              child: Text(action!),
            ),
        ],
      ),
    );
  }
}
