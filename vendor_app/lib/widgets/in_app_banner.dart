import 'dart:async';

import 'package:flutter/material.dart';

import '../theme.dart';

/// App khuli ho aur push aaye: upar se utarta hua chhota banner (tap par kaam khulta hai, upar swipe / X se band).
/// 8 sec mein khud hat jata hai. Ek waqt mein ek hi banner (naya aaye to purana badal jata hai).
class InAppBanner {
  static OverlayEntry? _entry;
  static Timer? _timer;

  static void show(
    BuildContext context, {
    required String title,
    required String body,
    required bool highlight,
    required VoidCallback onTap,
  }) {
    hide();
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _BannerView(
        title: title,
        body: body,
        highlight: highlight,
        onTap: () {
          hide();
          onTap();
        },
        onClose: hide,
      ),
    );
    _entry = entry;
    overlay.insert(entry);
    _timer = Timer(const Duration(seconds: 8), hide);
  }

  static void hide() {
    _timer?.cancel();
    _timer = null;
    final e = _entry;
    _entry = null;
    if (e != null) {
      try {
        e.remove();
      } catch (_) {}
    }
  }
}

class _BannerView extends StatelessWidget {
  final String title;
  final String body;
  final bool highlight;
  final VoidCallback onTap;
  final VoidCallback onClose;

  const _BannerView({
    required this.title,
    required this.body,
    required this.highlight,
    required this.onTap,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final bg = highlight ? kTeal : Colors.white;
    final fg = highlight ? Colors.white : Colors.black87;
    final sub = highlight ? Colors.white70 : Colors.black54;
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
            builder: (context, t, child) => Opacity(
              opacity: t,
              child: Transform.translate(offset: Offset(0, -30 * (1 - t)), child: child),
            ),
            child: Dismissible(
              key: ValueKey('banner-$title-$body'),
              direction: DismissDirection.up,
              onDismissed: (_) => onClose(),
              child: Material(
                color: bg,
                elevation: 8,
                shadowColor: Colors.black38,
                borderRadius: BorderRadius.circular(16),
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: onTap,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
                    child: Row(
                      children: [
                        Icon(highlight ? Icons.notifications_active : Icons.notifications_none,
                            color: highlight ? Colors.white : kTeal, size: 28),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(color: fg, fontWeight: FontWeight.w800, fontSize: 15)),
                              if (body.isNotEmpty) ...[
                                const SizedBox(height: 2),
                                Text(body,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(color: sub, fontSize: 13)),
                              ],
                              const SizedBox(height: 4),
                              Text('Kholne ke liye tap karein',
                                  style: TextStyle(color: sub, fontSize: 11, fontWeight: FontWeight.w600)),
                            ],
                          ),
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          tooltip: 'Band karein',
                          icon: Icon(Icons.close, color: sub, size: 20),
                          onPressed: onClose,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
