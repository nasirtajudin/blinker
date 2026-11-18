import 'package:flutter/material.dart';
import 'theme.dart';

/// bLinker navigation: FAST horizontal slides between screens
/// (190 ms in / 150 ms out) - no fades, no slow zooms.
class BlPageRoute<T> extends PageRouteBuilder<T> {
  BlPageRoute({required WidgetBuilder builder})
      : super(
          pageBuilder: (context, animation, secondaryAnimation) =>
              builder(context),
          transitionDuration: const Duration(milliseconds: 190),
          reverseTransitionDuration: const Duration(milliseconds: 150),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            final curved = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
            );
            return SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(1, 0),
                end: Offset.zero,
              ).animate(curved),
              child: child,
            );
          },
        );
}

Future<T?> blPush<T>(BuildContext context, Widget page) =>
    Navigator.of(context).push<T>(BlPageRoute<T>(builder: (_) => page));

/// Full-screen wrapper for pushed screens: keeps the bLinker background and
/// handles the status-bar inset so the screens themselves stay simple.
class BlScreen extends StatelessWidget {
  final Widget child;
  const BlScreen({super.key, required this.child});

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: BlColors.bg,
        body: SafeArea(
          bottom: false,
          child: child,
        ),
      );
}
