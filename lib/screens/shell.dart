import 'package:flutter/material.dart';
import '../core/theme.dart';
import '../core/routes.dart';
import '../data/store.dart';
import '../widgets/dock.dart';
import '../widgets/toast.dart';
import '../widgets/topbar.dart';
import 'detail_screen.dart';
import 'diagnostics_screen.dart';
import 'home_screen.dart';
import 'settings_screen.dart';

/// The home shell: top bar + radar screen + Send/Receive dock.
/// Settings, Diagnostics and Transfer details are REAL routes now - the
/// Android back button pops them back here instead of exiting the app.
class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  bool _historyAll = false;

  void _openSettings({bool autoFocusName = false}) {
    blPush(
      context,
      BlScreen(
        child: SettingsScreen(
          onBack: () => Navigator.of(context).pop(),
          onDiagnostics: () => blPush(
            context,
            BlScreen(
              child: DiagnosticsScreen(
                onBack: () => Navigator.of(context).pop(),
              ),
            ),
          ),
          autoFocusName: autoFocusName,
        ),
      ),
    );
  }

  void _onMode(String mode) {
    BlToast.show(context,
        'Send & Receive go live with the transfer engine — next build.');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BlColors.bg,
      body: Column(
        children: [
          BlTopBar(
            name: BlStore.name,
            method: (BlStore.prefs['method'] ?? 'fast') as String,
            onName: () => _openSettings(autoFocusName: true),
            onMethod: () => _openSettings(),
            onSettings: () => _openSettings(),
          ),
          Expanded(
            child: Stack(
              children: [
                HomeScreen(
                  historyAll: _historyAll,
                  onHistoryAll: () =>
                      setState(() => _historyAll = !_historyAll),
                  onDetail: (id) => blPush(
                    context,
                    BlScreen(
                      child: DetailScreen(
                        id: id,
                        onBack: () => Navigator.of(context).pop(),
                      ),
                    ),
                  ),
                ),
                BlDock(mode: null, onMode: _onMode),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
