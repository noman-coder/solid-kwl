import 'package:flutter/material.dart';

/// Chhota number card: icon + bara number + label (dashboard mein). `onTap` ho to dabane par khulta hai.
class StatCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final String? hint; // value ke neeche chhoti line (jaise "3 orders")
  final Color? color;
  final VoidCallback? onTap;

  const StatCard({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.hint,
    this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.primary;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: c.withValues(alpha: 0.13),
                child: Icon(icon, size: 18, color: c),
              ),
              const SizedBox(height: 10),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
              ),
              const SizedBox(height: 2),
              Text(label, style: const TextStyle(fontSize: 12, color: Colors.black54)),
              if (hint != null) ...[
                const SizedBox(height: 2),
                Text(hint!,
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: c)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
