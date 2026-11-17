import 'package:flutter/material.dart';
import '../core/theme.dart';
import '../data/store.dart';
import '../widgets/dock.dart';
import '../widgets/toast.dart';
import '../widgets/topbar.dart';
import 'detail_screen.dart';
import 'diagnostics_screen.dart';
import 'home_screen.dart';
import 'settings_screen.dart';

class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  String _view = 'home';
  bool _historyAll = false;
  String? _detailId;
  bool _autoFocusName = false;

  void _go(String v) => setState(() => _view = v);

  void _onMode(String mode) {
    BlToast.show(context,
        'Send & Receive go live with the transfer engine — next build.');
  }

  @override
  Widget build(BuildContext context) {
    final isHome = _view == 'home';
    return Scaffold(
      backgroundColor: BlColors.bg,
      body: Column(
        children: [
          BlTopBar(
            name: BlStore.name,
            method: (BlStore.prefs['method'] ?? 'fast') as String,
            onName: () => setState(() {
              _autoFocusName = true;
              _view = 'settings';
            }),
            onMethod: () => _go('settings'),
            onSettings: () => _go('settings'),
          ),
          Expanded(
            child: Stack(
              children: [
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 450),
                  switchInCurve: const Cubic(0.22, 1, 0.36, 1),
                  transitionBuilder: (child, anim) => FadeTransition(
                    opacity: anim,
                    child: SlideTransition(
                      position: Tween(
                              begin: const Offset(0, 0.02),
                              end: Offset.zero)
                          .animate(anim),
                      child: child,
                    ),
                  ),
                  child: KeyedSubtree(key: ValueKey(_view), child: _body()),
                ),
                if (isHome) BlDock(mode: null, onMode: _onMode),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    switch (_view) {
      case 'settings':
        return SettingsScreen(
          onBack: () => setState(() {
            _autoFocusName = false;
            _view = 'home';
          }),
          onDiagnostics: () => _go('diagnostics'),
          autoFocusName: _autoFocusName,
        );
      case 'diagnostics':
        return DiagnosticsScreen(onBack: () => _go('settings'));
      case 'detail':
        return DetailScreen(id: _detailId, onBack: () => _go('home'));
      default:
        return HomeScreen(
          historyAll: _historyAll,
          onHistoryAll: () => setState(() => _historyAll = !_historyAll),
          onDetail: (id) => setState(() {
            _detailId = id;
            _view = 'detail';
          }),
        );
    }
  }
}
