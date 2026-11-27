import 'package:flutter/material.dart';

enum NoticeLevel { info, warn, error, success }

/// Error / warning / info / kamyabi ka rangeen card (ghalat password, net masla, code bhej diya...).
class NoticeCard extends StatelessWidget {
  final NoticeLevel level;
  final String text;
  final IconData? icon;
  final String? actionLabel;
  final VoidCallback? onAction;

  const NoticeCard({
    super.key,
    required this.text,
    this.level = NoticeLevel.info,
    this.icon,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final Color bg;
    final Color fg;
    final IconData defIcon;
    switch (level) {
      case NoticeLevel.error:
        bg = Colors.red.shade50;
        fg = Colors.red.shade800;
        defIcon = Icons.error_outline;
        break;
      case NoticeLevel.warn:
        bg = Colors.amber.shade50;
        fg = Colors.amber.shade900;
        defIcon = Icons.warning_amber_rounded;
        break;
      case NoticeLevel.success:
        bg = Colors.green.shade50;
        fg = Colors.green.shade800;
        defIcon = Icons.check_circle_outline;
        break;
      case NoticeLevel.info:
        bg = Colors.blue.shade50;
        fg = Colors.blue.shade800;
        defIcon = Icons.info_outline;
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14)),
      child: Row(
        children: [
          Icon(icon ?? defIcon, color: fg),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: TextStyle(color: fg, fontWeight: FontWeight.w600))),
          if (actionLabel != null && onAction != null)
            TextButton(onPressed: onAction, child: Text(actionLabel!)),
        ],
      ),
    );
  }
}
