import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../services/api.dart';
import '../theme.dart';

/// Server ki tasveer (cache ke sath). Link na ho / load na ho to naram sa icon wala dibba - kabhi crash ya laal screen nahi.
/// `path` server ka relative (/media/...) ya poora link ho sakta hai.
class NetImage extends StatelessWidget {
  final String path;
  final double? width;
  final double? height;
  final BoxFit fit;
  final double radius;
  final IconData fallbackIcon;

  const NetImage({
    super.key,
    required this.path,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.radius = 0,
    this.fallbackIcon = Icons.image_outlined,
  });

  Widget _box(Widget? child) => Container(
        width: width,
        height: height,
        color: kOrangeSoft,
        alignment: Alignment.center,
        child: child,
      );

  @override
  Widget build(BuildContext context) {
    final Widget inner;
    if (path.isEmpty) {
      inner = _box(Icon(fallbackIcon, color: kOrange.withValues(alpha: 0.5)));
    } else {
      inner = CachedNetworkImage(
        imageUrl: Api.absUrl(path),
        width: width,
        height: height,
        fit: fit,
        fadeInDuration: const Duration(milliseconds: 150),
        placeholder: (_, __) => _box(null),
        errorWidget: (_, __, ___) => _box(Icon(fallbackIcon, color: kOrange.withValues(alpha: 0.5))),
      );
    }
    if (radius <= 0) return inner;
    return ClipRRect(borderRadius: BorderRadius.circular(radius), child: inner);
  }
}
