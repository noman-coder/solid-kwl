import 'package:flutter/material.dart';

/// Bara action button: kaam chal raha ho to spinner + dabne se band (double tap se do dafa kaam nahi hota).
class BusyButton extends StatelessWidget {
  final String label;
  final bool busy;
  final VoidCallback? onPressed;
  final IconData? icon;

  const BusyButton({super.key, required this.label, required this.busy, required this.onPressed, this.icon});

  @override
  Widget build(BuildContext context) {
    final child = busy
        ? const SizedBox(
            height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white))
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[Icon(icon, size: 20), const SizedBox(width: 8)],
              Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis)),
            ],
          );
    return FilledButton(onPressed: busy ? null : onPressed, child: child);
  }
}
