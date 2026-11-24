import 'package:flutter/material.dart';

import 'screens/login.dart';
import 'screens/shell.dart';
import 'services/api.dart';
import 'services/app_state.dart';
import 'services/push.dart';
import 'theme.dart';
import 'utils.dart' show kAppName;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Push.init(); // Firebase config na ho to khamoshi se band
  runApp(const VendorApp());
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
    await Api.logout();
    if (mounted) {
      setState(() {
        _loggedIn = false;
        _fresh = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget body;
    if (!_ready) {
      body = const _Splash();
    } else if (_loggedIn) {
      body = VendorShell(key: ValueKey(Api.token), initial: _fresh, onLogout: _logout);
    } else {
      body = LoginScreen(onDone: (r) => setState(() {
            _fresh = r;
            _loggedIn = true;
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
