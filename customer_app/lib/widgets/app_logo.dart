import 'package:flutter/material.dart';

/// App ka icon (gol kone), login / splash par.
class AppLogo extends StatelessWidget {
  final double size;
  const AppLogo({super.key, this.size = 96});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.23),
      child: Image.asset('assets/icon/app_icon.png', width: size, height: size, fit: BoxFit.cover),
    );
  }
}
