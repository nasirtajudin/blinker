import 'package:flutter/material.dart';
import 'core/theme.dart';
import 'data/store.dart';
import 'services/engine.dart';
import 'screens/onboarding_screen.dart';
import 'screens/shell.dart';

class BlinkerApp extends StatefulWidget {
  const BlinkerApp({super.key});
  @override
  State<BlinkerApp> createState() => _BlinkerAppState();
}

class _BlinkerAppState extends State<BlinkerApp> {
  late final Future<void> _boot = () async {
    await BlStore.load();
    await BlEngine.warm();
    if (!BlEngine.supports5GHz && BlStore.prefs['method'] == 'fast') {
      BlStore.set('method', 'normal');
    }
  }();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'bLinker',
      debugShowCheckedModeBanner: false,
      theme: buildBlTheme(),
      home: FutureBuilder<void>(
        future: _boot,
        builder: (_, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Scaffold(
              backgroundColor: BlColors.bg,
              body: SizedBox.expand(),
            );
          }
          return BlStore.prefs['onboard'] == true
              ? const Shell()
              : const OnboardingScreen();
        },
      ),
    );
  }
}
