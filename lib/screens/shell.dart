import 'package:flutter/material.dart';
import '../core/routes.dart';
import '../core/theme.dart';
import '../data/store.dart';
import '../services/session.dart';
import '../widgets/buttons.dart';
import '../widgets/dock.dart';
import '../widgets/modal.dart';
import '../widgets/session_flow.dart';
import '../widgets/toast.dart';
import '../widgets/topbar.dart';
import 'detail_screen.dart';
import 'diagnostics_screen.dart';
import 'home_screen.dart';
import 'settings_screen.dart';

/// The home shell: top bar + radar screen + Send/Receive dock.
/// Settings, Diagnostics and Transfer details are REAL routes now - the
/// Android back button pops them back here instead of exiting the app.
///
/// PHASE 4: the dock runs the real session flow. This state also shows the
/// decision cards the session raises (invite, accept, join, band, perms)
/// and its toasts - always in bLinker's own design language.
class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  bool _historyAll = false;
  bool _cardOpen = false;
  int _lastToast = 0;

  @override
  void initState() {
    super.initState();
    BlSession.I.addListener(_onSession);
    // A session might already be live (e.g. process restart edge).
    WidgetsBinding.instance.addPostFrameCallback((_) => _drainCards());
  }

  @override
  void dispose() {
    BlSession.I.removeListener(_onSession);
    super.dispose();
  }

  void _onSession() {
    final s = BlSession.I;
    if (s.toastSeq != _lastToast && s.toast != null) {
      _lastToast = s.toastSeq;
      BlToast.show(context, s.toast!);
    }
    _drainCards();
  }

  /// One decision card at a time, in arrival order. Stale queue entries
  /// (their state was cleared by stop()) are skipped.
  void _drainCards() {
    if (!mounted || _cardOpen) return;
    final s = BlSession.I;
    while (s.cardQueue.isNotEmpty) {
      final id = s.cardQueue.first;
      final valid = switch (id) {
        'invite' => s.invite != null,
        'accept' => s.manifest != null,
        'join' => s.manualExpected || s.joinFallback != null,
        'joinTimeout' => s.joinTimedOut != null,
        'perm' => s.permMissing.isNotEmpty,
        'band' => s.bandIssue != null,
        _ => false,
      };
      if (valid) {
        s.cardQueue.removeAt(0);
        _cardOpen = true;
        Future<void> f;
        switch (id) {
          case 'invite':
            f = showInviteModal(context);
            break;
          case 'accept':
            f = showAcceptModal(context);
            break;
          case 'join':
            f = showJoinModal(context);
            break;
          case 'joinTimeout':
            f = showJoinTimeoutModal(context);
            break;
          case 'perm':
            f = showPermModal(context);
            break;
          default:
            f = showBandModal(context);
            break;
        }
        f.whenComplete(() {
          _cardOpen = false;
          if (mounted) _drainCards();
        });
        return;
      }
      s.cardQueue.removeAt(0);
    }
  }

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
    final s = BlSession.I;
    if (s.role == mode) {
      // Same role tapped again: pick more files over the live link.
      if (mode == 'send' && s.linkUp) {
        s.sendMore();
      } else if (mode == 'send' &&
          (s.phase == 'p2p_search' || s.phase == 'mdns_search')) {
        BlToast.show(context, 'Pick a device on the radar below.');
      } else if (mode == 'receive') {
        BlToast.show(context, 'Already visible — waiting for a sender.');
      }
      return;
    }
    if (s.active) {
      _confirmSwitch(mode);
      return;
    }
    mode == 'send' ? s.startSend() : s.startReceive();
  }

  void _confirmSwitch(String mode) {
    final s = BlSession.I;
    showBlModal(
      context,
      (ctx) => BlModalCard(
        pillIcon: 'refresh',
        pillLabel: 'Switch',
        title: 'End this session?',
        body: mode == 'send'
            ? 'Receiving stops and you start picking files to send instead.'
            : 'The send stops and you become visible to nearby devices.',
        actions: [
          BlButton('Stay',
              primary: false, onTap: () => Navigator.of(ctx).pop()),
          BlButton('Switch', onTap: () {
            Navigator.of(ctx).pop();
            s.stop();
            mode == 'send' ? s.startSend() : s.startReceive();
          }),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = BlSession.I;
    return AnimatedBuilder(
      animation: s,
      builder: (context, _) => Scaffold(
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
                  BlDock(
                    mode: s.failure == null && s.role != 'none' ? s.role : null,
                    onMode: _onMode,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
