import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'screens/shell.dart';
import 'services/app_state.dart';
import 'theme.dart';
import 'utils.dart' show kAppName;
import 'widgets/crash_view.dart';

Future<void> main() async {
  // Crash safety: koi bhi ghair-mutawaqqa galti app ko band na kare (log hoti hai, app chalti rehti hai)
  runZonedGuarded<Future<void>>(() async {
    WidgetsFlutterBinding.ensureInitialized();
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      debugPrint('FlutterError: ${details.exceptionAsString()}');
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      debugPrint('Uncaught: $error');
      return true; // sambhal liya - app band nahi hogi
    };
    ErrorWidget.builder = (details) => kDebugMode ? ErrorWidget(details.exception) : const CrashView();
    final state = AppState();
    unawaited(state.init()); // token / save kiya hua customer padhna (splash tab tak dikhta hai)
    runApp(CustomerApp(state: state));
  }, (error, stack) => debugPrint('Zone error: $error'));
}

class CustomerApp extends StatelessWidget {
  final AppState state;
  const CustomerApp({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: state,
      child: MaterialApp(
        title: kAppName,
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        // Phone ka text size bohat bara ho tab bhi layout na toote (1.3 se zyada nahi barhta)
        builder: (context, child) => MediaQuery.withClampedTextScaling(
          minScaleFactor: 0.9,
          maxScaleFactor: 1.3,
          child: child ?? const SizedBox.shrink(),
        ),
        home: const _Gate(),
      ),
    );
  }
}

/// Phone se token padhne tak splash, phir shell (guest ho ya login, shell hi khulta hai).
class _Gate extends StatelessWidget {
  const _Gate();

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      child: state.booting ? const _Splash(key: ValueKey('splash')) : const CustomerShell(key: ValueKey('shell')),
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kOrange,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 108,
              height: 108,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(30),
              ),
              child: const Icon(Icons.shopping_bag_rounded, size: 60, color: Colors.white),
            ),
            const SizedBox(height: 18),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 24),
              child: Text(kAppName,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: Colors.white)),
            ),
            const SizedBox(height: 22),
            const SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white)),
          ],
        ),
      ),
    );
  }
}
