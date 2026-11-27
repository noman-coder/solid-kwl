import 'package:flutter/material.dart';

import 'screens/login.dart';
import 'screens/shell.dart';
import 'services/api.dart';
import 'services/push.dart';
import 'services/tracker.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Push.init(); // Firebase (push notification). Config na ho to khamoshi se band.
  runApp(const RiderApp());
}

class RiderApp extends StatefulWidget {
  const RiderApp({super.key});
  @override
  State<RiderApp> createState() => _RiderAppState();
}

class _RiderAppState extends State<RiderApp> {
  bool _ready = false;
  bool _loggedIn = false;

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
    await Tracker.stop();
    final pushToken = Push.token;
    await Push.stop();
    await Api.logout(pushToken: pushToken);
    if (mounted) setState(() => _loggedIn = false);
  }

  @override
  Widget build(BuildContext context) {
    Widget body;
    if (!_ready) {
      body = Scaffold(
        backgroundColor: Colors.white,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(28),
                child: Image.asset('assets/icon/app_icon.png', width: 150, height: 150),
              ),
              const SizedBox(height: 18),
              const Text('88 Riders',
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: kGreen)),
              const SizedBox(height: 22),
              const SizedBox(width: 26, height: 26, child: CircularProgressIndicator(strokeWidth: 3)),
            ],
          ),
        ),
      );
    } else if (_loggedIn) {
      body = RiderShell(onLogout: _logout);
    } else {
      body = LoginScreen(onDone: () => setState(() => _loggedIn = true));
    }
    return MaterialApp(
      title: '88 Riders',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: body,
    );
  }
}
