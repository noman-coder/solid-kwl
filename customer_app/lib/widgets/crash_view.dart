import 'package:flutter/material.dart';

/// Koi widget build mein toot jaye to red/kali screen ke bajaye saaf, chhota message
/// (release mein Flutter ka default kharab dikhta hai). Poori app tab bhi chalti rehti hai.
class CrashView extends StatelessWidget {
  const CrashView({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: Alignment.center,
      color: const Color(0xFFFAF7F4),
      padding: const EdgeInsets.all(20),
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline_rounded, size: 40, color: Colors.black38),
          SizedBox(height: 8),
          Text('Yeh hissa nahi khul saka',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w800, color: Colors.black87, decoration: TextDecoration.none)),
          SizedBox(height: 4),
          Text('Peeche ja kar dobara koshish karein.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.black54, decoration: TextDecoration.none)),
        ],
      ),
    );
  }
}
