import 'dart:async';
import 'dart:io' show HttpOverrides;
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'screens/login.dart';
import 'screens/shell.dart';
import 'services/api.dart';
import 'services/app_state.dart';
import 'services/prefs.dart';
import 'services/push.dart';
import 'services/net_fix.dart';
import 'theme.dart';
import 'utils.dart' show kAppName;
import 'widgets/crash_view.dart';

Future<void> main() async {
  // Phase V17 crash safety: koi bhi ghair-mutawaqqa galti app ko band na kare (log hoti hai, app chalti rehti hai)
  runZonedGuarded<Future<void>>(() async {
    WidgetsFlutterBinding.ensureInitialized();
    HttpOverrides.global = DnsFallbackOverrides(); // ISP DNS kharab ho to DoH se chale
    await DnsFallbackOverrides.start(); // local HTTPS tunnel (DoH ke liye)
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      debugPrint('FlutterError: ${details.exceptionAsString()}');
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      debugPrint('Uncaught: $error');
      return true; // sambhal liya - app band nahi hogi
    };
    ErrorWidget.builder = (details) => kDebugMode ? ErrorWidget(details.exception) : const CrashView();
    await Prefs.load(); // alert pasand (banner / awaaz / vibration)
    await Push.init(); // Firebase config na ho to khamoshi se band
    runApp(const VendorApp());
  }, (error, stack) => debugPrint('Zone error: $error'));
}

class VendorApp extends StatefulWidget {
  const VendorApp({super.key});
  @override
  State<VendorApp> createState() => _VendorAppState();
}

class _VendorAppState extends State<VendorApp> {
  bool _ready = false;
  bool _loggedIn = false;
  LoginResult? _fresh; // login se abhi mila vendor (shell ko seedha milta hai)
  int _session = 0; // har login par naya (Phase V16: password badalne par token badalta hai, shell dobara na bane)

  @override
  void initState() {
    super.initState();
    Api.load().then((_) {
      if (mounted) {
        setState(() {
          _ready = true;
          _loggedIn = Api.token != null;
        });
      }
    });
  }

  Future<void> _logout() async {
    // Is phone ka push band + token server se hatao: logout ke baad is phone par alert nahi aayega
    final pushToken = Push.token;
    await Push.stop();
    await Api.logout(pushToken: pushToken);
    if (mounted) {
      setState(() {
        _loggedIn = false;
        _fresh = null;
        _session++;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget body;
    if (!_ready) {
      body = const _Splash();
    } else if (_loggedIn) {
      body = VendorShell(key: ValueKey(_session), initial: _fresh, onLogout: _logout);
    } else {
      body = LoginScreen(onDone: (r) => setState(() {
            _fresh = r;
            _loggedIn = true;
            _session++;
          }));
    }
    return MaterialApp(
      title: kAppName,
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: body,
    );
  }
}

class _Splash extends StatelessWidget {
  const _Splash();
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: Image.asset('assets/icon/app_icon.png', width: 130, height: 130),
            ),
            const SizedBox(height: 18),
            const Text(kAppName,
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: kTeal)),
            const SizedBox(height: 22),
            const SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 3)),
          ],
        ),
      ),
    );
  }
}
