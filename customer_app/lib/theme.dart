import 'package:flutter/material.dart';

/// Customer app ke rang: garam narangi (asli action) + hara (faida / free delivery / kamyabi).
/// Poore app mein yahi rang use hote hain - screens mein koi alag hex na likhein.
const Color kOrange = Color(0xFFE8590C);
const Color kOrangeDark = Color(0xFFC2410C);
const Color kOrangeSoft = Color(0xFFFFF1E8);
const Color kGreen = Color(0xFF16A34A);
const Color kGreenSoft = Color(0xFFE8F7EE);
const Color kInk = Color(0xFF1F2937);
const Color kMuted = Color(0xFF6B7280);
const Color kBg = Color(0xFFFAF7F4);
const Color kBorder = Color(0xFFEBE3DC);

/// Card ka halka saya (zyada gehra nahi, taake kam RAM wale phone par bhi smooth rahe).
const List<BoxShadow> kSoftShadow = [
  BoxShadow(color: Color(0x14000000), blurRadius: 12, offset: Offset(0, 4)),
];

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(seedColor: kOrange, brightness: Brightness.light).copyWith(
    primary: kOrange,
    onPrimary: Colors.white,
    secondary: kGreen,
    onSecondary: Colors.white,
    surface: Colors.white,
  );
  OutlineInputBorder border(Color c, [double w = 1]) =>
      OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: c, width: w));
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: kBg,
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.white,
      foregroundColor: kInk,
      elevation: 0,
      scrolledUnderElevation: 1,
      centerTitle: false,
      titleTextStyle: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: kInk),
    ),
    cardTheme: CardThemeData(
      color: Colors.white,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: kBorder),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: kOrange,
        foregroundColor: Colors.white,
        minimumSize: const Size(64, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: kOrangeDark,
        side: const BorderSide(color: kOrange),
        minimumSize: const Size(64, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: kOrangeDark,
        textStyle: const TextStyle(fontWeight: FontWeight.w700),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: border(kBorder),
      enabledBorder: border(kBorder),
      focusedBorder: border(kOrange, 1.6),
      errorBorder: border(Colors.red.shade400),
      focusedErrorBorder: border(Colors.red.shade600, 1.6),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 68,
      backgroundColor: Colors.white,
      indicatorColor: kOrange.withValues(alpha: 0.15),
      labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
            fontSize: 12,
            fontWeight: states.contains(WidgetState.selected) ? FontWeight.w800 : FontWeight.w500,
            color: states.contains(WidgetState.selected) ? kOrangeDark : kMuted,
          )),
      iconTheme: WidgetStateProperty.resolveWith((states) =>
          IconThemeData(color: states.contains(WidgetState.selected) ? kOrangeDark : kMuted)),
    ),
    // Sab screens par ek jaisi halki transition
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
    }),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: kOrange),
  );
}
