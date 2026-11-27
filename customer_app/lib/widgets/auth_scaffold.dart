import 'package:flutter/material.dart';

import '../theme.dart';
import 'app_logo.dart';
import 'content_width.dart';

/// Login / register / forgot / OTP ka ek jaisa dhancha: upar logo + title, neeche form.
/// Keyboard khulne par scroll hota hai; bare screen par beech mein; screen par kahin tap karne se keyboard band.
class AuthScaffold extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<Widget> children;
  final bool showLogo;
  final String? appBarTitle; // diya ho to upar back wali AppBar

  const AuthScaffold({
    super.key,
    required this.title,
    required this.children,
    this.subtitle,
    this.showLogo = true,
    this.appBarTitle,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: appBarTitle == null ? null : AppBar(title: Text(appBarTitle!)),
      body: SafeArea(
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
          child: Center(
            child: SingleChildScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
              child: ContentWidth(
                maxWidth: 460,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (showLogo) ...[
                      const Center(child: AppLogo(size: 88)),
                      const SizedBox(height: 14),
                    ],
                    Text(title,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: kOrangeDark)),
                    if (subtitle != null) ...[
                      const SizedBox(height: 6),
                      Text(subtitle!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 15, color: kMuted, fontWeight: FontWeight.w500)),
                    ],
                    const SizedBox(height: 24),
                    ...children,
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
