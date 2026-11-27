import 'dart:async';

import 'package:flutter/material.dart';

import '../models/home.dart';
import '../theme.dart';
import 'net_image.dart';

/// Offers / banners ka carousel (3:1 tasveer, khud aage barhta hai, dots). Ek hi banner ho to scroll / timer nahi.
class BannerCarousel extends StatefulWidget {
  final List<BannerItem> banners;
  final void Function(BannerItem) onTap;
  const BannerCarousel({super.key, required this.banners, required this.onTap});

  @override
  State<BannerCarousel> createState() => _BannerCarouselState();
}

class _BannerCarouselState extends State<BannerCarousel> {
  final PageController _pc = PageController(viewportFraction: 0.92);
  Timer? _timer;
  int _page = 0;

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  @override
  void didUpdateWidget(covariant BannerCarousel old) {
    super.didUpdateWidget(old);
    if (old.banners.length != widget.banners.length) {
      _page = 0;
      _startTimer();
    }
  }

  void _startTimer() {
    _timer?.cancel();
    if (widget.banners.length < 2) return;
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted || !_pc.hasClients) return;
      final next = (_page + 1) % widget.banners.length;
      _pc.animateToPage(next, duration: const Duration(milliseconds: 350), curve: Curves.easeOut);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.banners;
    if (items.isEmpty) return const SizedBox.shrink();
    return Column(
      children: [
        LayoutBuilder(
          builder: (context, box) {
            final h = (box.maxWidth * 0.92 / 3).clamp(104.0, 210.0).toDouble();
            return SizedBox(
              height: h,
              child: PageView.builder(
                controller: _pc,
                itemCount: items.length,
                onPageChanged: (i) => setState(() => _page = i),
                itemBuilder: (context, i) {
                  final b = items[i];
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: GestureDetector(
                      onTap: () => widget.onTap(b),
                      child: Semantics(
                        label: b.title,
                        image: true,
                        child: NetImage(path: b.image, radius: 16, fit: BoxFit.cover),
                      ),
                    ),
                  );
                },
              ),
            );
          },
        ),
        if (items.length > 1)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < items.length; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: i == _page ? 18 : 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: i == _page ? kOrange : kBorder,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
