import 'package:flutter/material.dart';

import '../services/api.dart';

/// Internet / server se rabta na ho to screen ke upar patti (purana data dikhta rehta hai).
/// `Api.offline` kisi bhi kamyab request par khud band ho jata hai; 'Dobara' dabane par [onRetry] chalta hai.
class OfflineBanner extends StatelessWidget {
  final VoidCallback? onRetry;
  const OfflineBanner({super.key, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: Api.offline,
      builder: (context, off, _) {
        if (!off) return const SizedBox.shrink();
        return Material(
          color: const Color(0xFFFEF3C7),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: Row(
              children: [
                const Icon(Icons.wifi_off_rounded, size: 18, color: Color(0xFF92400E)),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('Internet nahi hai - purana data dikh raha hai',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF92400E))),
                ),
                if (onRetry != null)
                  TextButton(
                    onPressed: onRetry,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(48, 32),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      foregroundColor: const Color(0xFF92400E),
                    ),
                    child: const Text('Dobara', style: TextStyle(fontWeight: FontWeight.w800)),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
