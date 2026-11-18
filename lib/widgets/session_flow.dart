import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/format.dart';
import '../core/icons.dart';
import '../core/theme.dart';
import '../data/store.dart';
import '../engine/engine_bridge.dart' as bridge;
import '../services/session.dart';
import 'buttons.dart';
import 'modal.dart';
import 'pressable.dart';
import 'radar.dart';
import 'toast.dart';

/// PHASE 4 - the live session HUD that replaces the home hero while a
/// Send/Receive session runs, plus every bLinker card the flow raises.
///
/// UI RULE (locked): system prompts (permission card, Wi-Fi suggestion
/// consent, "Add network" panel, the document picker) are Android's own;
/// every card bLinker itself shows uses this design language only.
class BlSessionPanel extends StatelessWidget {
  const BlSessionPanel({super.key});

  BlSession get _s => BlSession.I;

  String get _eyebrow {
    if (_s.failure != null) return 'SESSION ENDED';
    if (_s.progress != null) return 'TRANSFERRING';
    if (_s.result != null) return 'TRANSFER DONE';
    switch (_s.phase) {
      case 'p2p_search':
      case 'mdns_search':
        return 'LOOKING NEARBY';
      case 'inviting':
        return 'INVITING';
      case 'exchanging':
        return 'HANDSHAKE';
      case 'hotspot_starting':
        return 'HOTSPOT';
      case 'waiting_receiver':
        return 'YOUR CODE';
      case 'standby':
        return 'VISIBLE';
      case 'joining':
        return 'JOINING';
      case 'link_connecting':
        return 'CONNECTING';
      case 'link_connected':
        return 'LINK READY';
      case 'failed':
        return 'FAILED';
      default:
        return _s.role == 'send' ? 'PICK FILES' : 'READY';
    }
  }

  String get _headline {
    if (_s.failure != null) return 'That didn’t work.';
    if (_s.result != null) {
      if (_s.result!['cancelled'] == true) return 'Cancelled.';
      return _s.result!['direction'] == 'receive' ? 'Received.' : 'Sent.';
    }
    if (_s.progress != null) return 'On its way.';
    switch (_s.phase) {
      case 'p2p_search':
      case 'mdns_search':
        return 'Pick a device.';
      case 'inviting':
        return 'Inviting ${_s.peerName}…';
      case 'exchanging':
        return 'Almost there.';
      case 'hotspot_starting':
        return 'Starting up.';
      case 'waiting_receiver':
        return 'Share this code.';
      case 'standby':
        return 'You’re visible.';
      case 'joining':
        return 'Joining the sender…';
      case 'link_connecting':
        return 'Connecting…';
      case 'link_connected':
        return 'Linked up.';
      default:
        return _s.role == 'send' ? 'Choose files.' : 'Ready.';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 25),
        Text(_eyebrow,
            style: ts(9, w: 650, ls: 2.2, color: const Color(0xFFDC8B9B))),
        const SizedBox(height: 13),
        _radar(),
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: Text.rich(
            TextSpan(
              text: _headline,
              style: ts(32, w: 650, ls: -1.55, h: 1.12),
              children: [
                TextSpan(
                    text: '.',
                    style: ts(32,
                        w: 650, ls: -1.55, h: 1.12, color: BlColors.red)),
              ],
            ),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 14),
        _bodyCard(),
        const SizedBox(height: 10),
        _bandRow(),
      ],
    );
  }

  Widget _radar() {
    final s = _s;
    final searching = s.role == 'send' &&
        (s.phase == 'p2p_search' || s.phase == 'mdns_search');
    return BlRadar(
      symbol: s.role == 'send' ? 'send' : 'receive',
      scale: 0.66,
      peers: searching ? s.peers : const <BlPeer>[],
      onPeerTap: searching ? s.pickPeer : null,
    );
  }

  Widget _bodyCard() {
    final s = _s;
    if (s.failure != null) return const _FailureCard();
    if (s.result != null) return const _ResultCard();
    if (s.progress != null) return const _ProgressCard();
    if (s.manualCode != null && s.phase == 'waiting_receiver') {
      return _ManualCodeCard(s.manualCode!);
    }
    if (s.phase == 'p2p_search' || s.phase == 'mdns_search') {
      return const _SearchCard();
    }
    if (s.phase == 'standby') return const _StandbyCard();
    if (s.phase == 'link_connected') return const _DoneActions();
    return const _PhaseCard();
  }

  Widget _bandRow() {
    final s = _s.wifiStats;
    if (s == null) return const SizedBox(height: 16);
    final band = (s['band'] as String?) ?? '—';
    final mbps = (s['linkMbps'] as num?) ?? 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const BlDot(color: Color(0xFFF17B8D)),
          const SizedBox(width: 7),
          Text('Measured $band · $mbps Mb/s',
              style: ts(10, color: const Color(0xFFA6939C))),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- states ---

/// Sender, searching: staged files summary + peer hint.
class _SearchCard extends StatelessWidget {
  const _SearchCard();

  @override
  Widget build(BuildContext context) {
    final s = BlSession.I;
    final total =
        s.staged.fold<double>(0, (a, f) => a + ((f['size'] as num?) ?? 0));
    final count = s.staged.length;
    return _card(
      icon: 'folder',
      title: count > 0
          ? '$count file${count == 1 ? '' : 's'} · ${fmtBytes(total)} staged'
          : 'No files staged',
      body: s.peers.isEmpty
          ? 'Looking for bLinker receivers nearby. Devices on your router appear too.'
          : 'Tap a device on the radar to connect.',
      actions: [
        BlButton('Stop', primary: false, onTap: s.stop),
      ],
    );
  }
}

/// Receiver, standby.
class _StandbyCard extends StatelessWidget {
  const _StandbyCard();

  @override
  Widget build(BuildContext context) {
    final s = BlSession.I;
    return _card(
      icon: 'receive',
      title: 'Visible as ${BlStore.name}',
      body: 'Senders nearby can invite you. Keep bLinker open while you wait.',
      actions: [
        BlButton('Stop', primary: false, onTap: s.stop),
      ],
    );
  }
}

/// In-between phases (inviting / handshake / hotspot / joining / connecting).
class _PhaseCard extends StatelessWidget {
  const _PhaseCard();

  @override
  Widget build(BuildContext context) {
    final s = BlSession.I;
    final String body;
    switch (s.phase) {
      case 'inviting':
        body = 'Waiting for the other side to answer.';
        break;
      case 'exchanging':
        body = 'Agreeing on the fastest connection.';
        break;
      case 'hotspot_starting':
        body = 'Your code appears here in a moment.';
        break;
      case 'joining':
        body = s.manualExpected
            ? 'Type the code from the sender’s screen to join.'
            : 'Using the code from the sender’s screen.';
        break;
      case 'link_connecting':
        body = 'Setting up the direct link.';
        break;
      default:
        body = 'Hold tight.';
    }
    final joinActions = <Widget>[
      if (s.manualExpected)
        BlTextButton('Type the code', icon: 'lock', onTap: s.reopenJoinCard),
      if (s.joinTimedOut != null) ...[
        BlTextButton('Try the join again', icon: 'refresh', onTap: s.retryJoin),
        BlTextButton('Open system panel',
            icon: 'chevron', onTap: s.openJoinPanel),
      ],
    ];
    return _card(
      icon: 'link',
      title: 'Working on it.',
      body: body,
      actions: joinActions.isEmpty
          ? [BlButton('Stop', primary: false, onTap: s.stop)]
          : joinActions,
    );
  }
}

/// Sender: the system-generated hotspot credentials, big and copyable.
class _ManualCodeCard extends StatelessWidget {
  final Map<String, dynamic> code;
  const _ManualCodeCard(this.code);

  void _copy(BuildContext context, String label, String value) {
    Clipboard.setData(ClipboardData(text: value));
    BlToast.show(context, '$label copied');
  }

  @override
  Widget build(BuildContext context) {
    final ssid = (code['ssid'] as String?) ?? '';
    final pass = (code['pass'] as String?) ?? '';
    return _card(
      icon: 'lock',
      title: 'Let them type it once.',
      body:
          'Android generated this hotspot for you. The receiver enters it once, then the system takes over.',
      extra: Column(
        children: [
          const SizedBox(height: 15),
          _codeRow(
              context, 'NETWORK', ssid, () => _copy(context, 'Network', ssid)),
          const SizedBox(height: 8),
          _codeRow(context, 'PASSWORD', pass,
              () => _copy(context, 'Password', pass)),
        ],
      ),
      actions: [
        BlButton('End session', primary: false, onTap: BlSession.I.stop),
      ],
    );
  }

  Widget _codeRow(
      BuildContext context, String label, String value, VoidCallback onCopy) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: const Color(0x77100D0F),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: const Color(0x16FFFFFF)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: ts(8, w: 650, ls: 1.2, color: BlColors.muted)),
                const SizedBox(height: 3),
                Text(value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ts(13, w: 550, h: 1.3)),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Pressable(
            onTap: onCopy,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child:
                  Text('COPY', style: ts(9, w: 650, color: BlColors.pinkDeep)),
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------- transfer ---

class _ProgressCard extends StatelessWidget {
  const _ProgressCard();

  @override
  Widget build(BuildContext context) {
    final s = BlSession.I;
    final p = s.progress!;
    final bytes = ((p['bytes'] as num?) ?? 0).toDouble();
    final total = ((p['totalBytes'] as num?) ?? 0).toDouble();
    final done = (p['filesDone'] as num?) ?? 0;
    final count = (p['fileCount'] as num?) ?? 0;
    final index = ((p['index'] as num?) ?? 0) + 1;
    final name = (p['name'] as String?) ?? '';
    final bps = ((p['bps'] as num?) ?? 0).toDouble();
    final eta = (p['etaSec'] as num?) ?? -1;
    final frac = total > 0 ? (bytes / total).clamp(0.0, 1.0) : 0.0;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(19),
      decoration: _box(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              BlIcon('file', size: 15, color: BlColors.pink),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  name.isEmpty ? 'Preparing…' : name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ts(11, w: 550),
                ),
              ),
              Text('File $index of ${count == 0 ? '?' : count}',
                  style: ts(10, color: BlColors.muted)),
            ],
          ),
          const SizedBox(height: 15),
          ClipRRect(
            borderRadius: BorderRadius.circular(7),
            child: SizedBox(
              height: 8,
              child: Stack(
                children: [
                  Container(color: const Color(0x14FFFFFF)),
                  FractionallySizedBox(
                    widthFactor: frac,
                    child: Container(
                        decoration: const BoxDecoration(
                            gradient: blDockActiveGradient)),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('${fmtBytes(bytes)} / ${fmtBytes(total)}',
                  style: ts(10, color: BlColors.muted)),
              Text(
                  bps > 0
                      ? '${fmtBytes(bps)}/s · ${eta >= 0 ? fmtDuration(eta) : '—'}'
                      : 'Starting…',
                  style: ts(10, color: BlColors.muted)),
            ],
          ),
          if (count > 0) ...[
            const SizedBox(height: 6),
            Text('$done of $count files done',
                style: ts(9, color: const Color(0xFF8A7881))),
          ],
          const SizedBox(height: 16),
          BlButton('Cancel',
              primary: false, full: true, onTap: s.cancelTransfer),
        ],
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard();

  @override
  Widget build(BuildContext context) {
    final s = BlSession.I;
    final r = s.result!;
    final recv = r['direction'] == 'receive';
    final cancelled = r['cancelled'] == true;
    final files = ((r['files'] as List?) ?? []).length;
    final total = ((r['totalBytes'] as num?) ?? 0).toDouble();
    final bytes = ((r['bytes'] as num?) ?? 0).toDouble();
    final avg = ((r['avgBps'] as num?) ?? 0) / 1048576;
    final secs = ((r['durationMs'] as num?) ?? 0) / 1000;
    final band = (r['band'] as String?) ?? '—';
    final dir = (r['dir'] as String?) ?? '';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(21),
      decoration: _box(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              BlIcon(recv ? 'arrowdown' : 'arrowup',
                  size: 15, color: BlColors.pink),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                    cancelled
                        ? 'Cancelled mid-transfer'
                        : recv
                            ? 'Received from ${r['peer'] ?? 'them'}'
                            : 'Sent to ${r['peer'] ?? 'them'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ts(12, w: 550)),
              ),
              if (!cancelled)
                const BlPill('Verified', icon: 'check', success: true),
            ],
          ),
          const SizedBox(height: 13),
          Text(
              cancelled
                  ? '${fmtBytes(bytes)} made it across before the stop.'
                  : '$files files · ${fmtBytes(total)} · ${avg.toStringAsFixed(1)} MB/s · ${fmtDuration(secs)} · $band',
              style: ts(10, color: BlColors.muted, h: 1.7)),
          if (recv && dir.isNotEmpty && !cancelled) ...[
            const SizedBox(height: 8),
            Text('Saved in $dir',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: ts(9, color: const Color(0xFF8A7881))),
          ],
          const SizedBox(height: 17),
          const _DoneActions(),
        ],
      ),
    );
  }
}

class _DoneActions extends StatelessWidget {
  const _DoneActions();

  @override
  Widget build(BuildContext context) {
    final s = BlSession.I;
    final r = s.result;
    final recv = r?['direction'] == 'receive';
    final cancelled = r?['cancelled'] == true;
    final dir = (r?['dir'] as String?) ?? '';
    final canSendMore = s.role == 'send' && s.linkUp && !cancelled;
    return Row(
      children: [
        if (recv && dir.isNotEmpty && !cancelled)
          Expanded(
            child: BlButton('Open folder',
                icon: 'folder',
                primary: false,
                onTap: () => _openFolder(context, dir)),
          ),
        if (recv && dir.isNotEmpty && !cancelled) const SizedBox(width: 11),
        if (canSendMore) ...[
          Expanded(
              child: BlButton('Send more', icon: 'send', onTap: s.sendMore)),
          const SizedBox(width: 11),
        ],
        Expanded(child: BlButton('Done', primary: false, onTap: s.stop)),
      ],
    );
  }

  Future<void> _openFolder(BuildContext context, String dir) async {
    try {
      final res = await bridge.Engine.openFolder(dir);
      if (!context.mounted) return;
      if (res['opened'] == true) {
        BlToast.show(context, 'Opened in Files');
      } else {
        BlToast.show(context, 'Saved in $dir');
      }
    } catch (_) {
      if (context.mounted) BlToast.show(context, 'Saved in $dir');
    }
  }
}

class _FailureCard extends StatelessWidget {
  const _FailureCard();

  @override
  Widget build(BuildContext context) {
    final s = BlSession.I;
    final reason = (s.failure?['reason'] as String?) ?? '';
    return _card(
      icon: 'alert',
      title: 'Couldn’t finish.',
      body: reason.isEmpty ? 'Something interrupted the session.' : reason,
      actions: [
        BlButton('Try again', onTap: s.retry),
        const SizedBox(width: 11),
        BlButton('Done', primary: false, onTap: s.stop),
      ],
    );
  }
}

// -------------------------------------------------------------- plumbing ---

BoxDecoration _box() => BoxDecoration(
      gradient: blCardGradient,
      border: Border.all(color: const Color(0x0DFFFFFF)),
      borderRadius: BorderRadius.circular(26),
      boxShadow: const [
        BoxShadow(
            color: Color(0x18000000), blurRadius: 28, offset: Offset(0, 10)),
      ],
    );

Widget _card(
        {required String icon,
        required String title,
        required String body,
        Widget? extra,
        List<Widget> actions = const []}) =>
    Container(
      width: double.infinity,
      padding: const EdgeInsets.all(21),
      decoration: _box(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              BlIcon(icon, size: 15, color: BlColors.pink),
              const SizedBox(width: 8),
              Expanded(
                child: Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ts(12, w: 550)),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(body, style: ts(10, color: BlColors.muted, h: 1.7)),
          if (extra != null) extra,
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 17),
            Row(
              children: [
                for (int i = 0; i < actions.length; i++) ...[
                  if (i > 0) const SizedBox(width: 11),
                  Expanded(child: actions[i]),
                ]
              ],
            ),
          ],
        ],
      ),
    );

// ---------------------------------------------------------------- modals ---
// Raised by Shell when the session needs a decision. Every one is a bLinker
// card; the system screens stay system.

/// Receiver: "<name> wants to connect" + band choice. Barrier-dismiss = decline.
Future<void> showInviteModal(BuildContext context) {
  final s = BlSession.I;
  final inv = s.invite!;
  final name = (inv['name'] as String?) ?? 'Someone';
  final fast = inv['fast'] == true;
  final bandOk = inv['bandOk'] == true;
  final acceptNormal = fast && !bandOk;

  return showBlModal(
    context,
    (ctx) => BlModalCard(
      pillIcon: 'receive',
      pillLabel: 'Incoming invite',
      title: '$name wants to connect.',
      body: fast
          ? (bandOk
              ? 'They’re inviting you over a direct 5GHz link — the fastest way.'
              : 'They picked Fast (5GHz), but your device can’t do 5GHz hotspots. Accepting joins over 2.4GHz instead.')
          : 'They’re inviting you over a Normal (2.4GHz) link.',
      actions: [
        BlButton('Decline',
            primary: false,
            onTap: () => _close(ctx, () => s.respondInvite(false))),
        BlButton(
          acceptNormal ? 'Accept in Normal' : 'Accept',
          onTap: () => _close(
              ctx, () => s.respondInvite(true, preferNormal: acceptNormal)),
        ),
      ],
    ),
  ).then((_) {
    // Dismissed without a decision (scrim tap / back): decline honestly.
    if (s.invite != null) s.respondInvite(false);
    return Future<void>.value();
  });
}

/// Receiver: the manifest-first file card. Barrier-dismiss = decline.
Future<void> showAcceptModal(BuildContext context) {
  final s = BlSession.I;
  final m = s.manifest!;
  final sender = m['sender'] is Map ? (m['sender'] as Map)['name'] : 'them';
  final files = (m['files'] as List? ?? [])
      .whereType<Map>()
      .map((f) => Map<String, dynamic>.from(f))
      .toList();
  final total = ((m['totalBytes'] as num?) ?? 0).toDouble();
  final shown = files.take(6).toList();
  final more = files.length - shown.length;

  return showBlModal(
    context,
    (ctx) => BlModalCard(
      pillIcon: 'folder',
      pillLabel: 'Incoming files',
      title:
          '$sender wants to send ${files.length} file${files.length == 1 ? '' : 's'}.',
      body:
          '${fmtBytes(total)} in total. Every file verifies with SHA-256 as it arrives.',
      extra: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 15),
          Container(
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              color: const Color(0x03FFFFFF),
              borderRadius: BorderRadius.circular(15),
              border: Border.all(color: BlColors.line),
            ),
            child: Column(
              children: [
                for (final f in shown)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        BlIcon(fileIconFor((f['name'] as String?) ?? ''),
                            size: 15, color: const Color(0xFFD47C91)),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Text((f['name'] as String?) ?? '',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: ts(10)),
                        ),
                        Text(fmtBytes((f['size'] as num?) ?? 0),
                            style: ts(9, color: BlColors.muted)),
                      ],
                    ),
                  ),
                if (more > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: Text('and $more more…',
                        style: ts(9, color: BlColors.muted)),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 11),
          FutureBuilder<Map<String, dynamic>>(
            future: bridge.Engine.storageState(
                location: (BlStore.prefs['location'] ?? '') as String),
            builder: (_, snap) {
              final st = snap.data;
              final dir = (st?['saveDir'] as String?) ?? '';
              final sandboxed = st?['sandboxed'] == true;
              if (dir.isEmpty) return const SizedBox.shrink();
              return Row(
                children: [
                  BlIcon('folder', size: 11, color: BlColors.muted),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text('Saving to $dir',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: ts(9, color: BlColors.muted)),
                  ),
                  if (sandboxed) const BlPill('App folder'),
                ],
              );
            },
          ),
        ],
      ),
      actions: [
        BlButton('Decline',
            primary: false, onTap: () => _close(ctx, s.rejectManifest)),
        BlButton('Accept',
            icon: 'check', onTap: () => _close(ctx, s.acceptManifest)),
      ],
    ),
  ).then((_) {
    if (s.manifest != null) s.rejectManifest();
    return Future<void>.value();
  });
}

/// Receiver: type the code from the sender's screen (once). Dismiss = later;
/// the joining card keeps a "Type the code" way back in.
Future<void> showJoinModal(BuildContext context) {
  final s = BlSession.I;
  final fb = s.joinFallback;
  final legacy = fb != null;
  final ssidCtrl = TextEditingController(text: (fb?['ssid'] as String?) ?? '');
  final passCtrl = TextEditingController(text: (fb?['pass'] as String?) ?? '');

  return showBlModal(
    context,
    (ctx) => BlModalCard(
      pillIcon: 'lock',
      pillLabel: 'Join the sender',
      title: 'Type their code.',
      body: legacy
          ? 'Your Android needs the network added by hand. Type the code from the sender’s screen, then open Wi-Fi settings.'
          : 'The code is on the sender’s screen. You type it once — after that Android’s own consent card takes over.',
      extra: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 16),
          _field('NETWORK', ssidCtrl),
          const SizedBox(height: 9),
          _field('PASSWORD', passCtrl, obscure: true),
        ],
      ),
      actions: [
        BlTextButton(legacy ? 'Open Wi-Fi settings' : 'Open system panel',
            icon: 'chevron', onTap: () => _close(ctx, s.openJoinPanel)),
        BlButton('Join',
            onTap: () => _close(
                ctx, () => s.joinManual(ssidCtrl.text.trim(), passCtrl.text))),
      ],
    ),
  ).then((_) {
    // Dismissed: leave manualExpected so the joining card can re-open it.
    ssidCtrl.dispose();
    passCtrl.dispose();
    return Future<void>.value();
  });
}

/// Receiver: join timed out - system panel or retry. Dismiss = keep waiting.
Future<void> showJoinTimeoutModal(BuildContext context) {
  final s = BlSession.I;
  final ssid = (s.joinTimedOut?['ssid'] as String?) ?? 'the network';
  return showBlModal(
    context,
    (ctx) => BlModalCard(
      pillIcon: 'wifi',
      pillLabel: 'Join timed out',
      title: 'Couldn’t join $ssid.',
      body:
          'The system can add the network for you - a real Android panel, one tap.',
      actions: [
        BlButton('Try again',
            primary: false, onTap: () => _close(ctx, s.retryJoin)),
        BlButton('Open system panel',
            onTap: () => _close(ctx, s.openJoinPanel)),
      ],
    ),
  ).then((_) => Future<void>.value());
}

/// The bLinker permission explainer; [Continue] opens the REAL system card.
Future<void> showPermModal(BuildContext context) {
  final s = BlSession.I;
  return showBlModal(
    context,
    (ctx) => BlModalCard(
      pillIcon: 'shield',
      pillLabel: 'One permission',
      title: 'bLinker needs your OK.',
      body:
          'Android asks for the Nearby-devices permission to find other bLinker phones. The next card is Android’s own - bLinker never imitates it.',
      actions: [
        BlButton('Not now',
            primary: false, onTap: () => _close(ctx, s.dismissPerms)),
        BlButton('Continue',
            icon: 'check', onTap: () => _close(ctx, s.continuePermissions)),
      ],
    ),
  ).then((_) {
    if (s.permMissing.isNotEmpty) s.dismissPerms();
    return Future<void>.value();
  });
}

/// Phase 5 radio card: the session is parked until Wi-Fi (and Location
/// services) are on - both are required by Wi-Fi Direct discovery on real
/// devices. Every button leads to a REAL system screen; the session resumes
/// by itself the moment both radios report on.
Future<void> showRadioModal(BuildContext context) {
  final s = BlSession.I;
  final wifiOff = s.radioBlocked.contains('wifi');
  final locationOff = s.radioBlocked.contains('location');
  final title = wifiOff && locationOff
      ? 'Wi-Fi and Location are off.'
      : (wifiOff ? 'Wi-Fi is off.' : 'Location is off.');
  final body = wifiOff && locationOff
      ? 'Finding and linking bLinker phones needs both radios. Android opens its own Wi-Fi panel and Location page - bLinker never imitates them.'
      : (wifiOff
          ? 'Nearby search needs the Wi-Fi adapter on. Android opens its own Wi-Fi panel - one real toggle.'
          : 'Android hides nearby devices while Location is off - that is a system rule, not bLinker’s. The real Location page is one toggle away.');
  return showBlModal(
    context,
    (ctx) => BlModalCard(
      pillIcon: 'wifi',
      pillLabel: 'Radios',
      title: title,
      body: body,
      actions: [
        BlButton('Not now',
            primary: false, onTap: () => _close(ctx, s.dismissRadios)),
        BlButton(locationOff ? 'Turn on Location' : 'Turn on Wi-Fi',
            icon: 'chevron',
            onTap: () =>
                _close(ctx, locationOff ? s.enableLocation : s.enableWifi)),
      ],
    ),
  ).then((_) {
    if (s.radioBlocked.isNotEmpty) s.dismissRadios();
    return Future<void>.value();
  });
}

/// Sender: 5GHz unavailable / receiver asked for Normal. Dismiss = end.
Future<void> showBandModal(BuildContext context) {
  final s = BlSession.I;
  final downgrade = s.bandIssue?['kind'] == 'downgrade';
  return showBlModal(
    context,
    (ctx) => BlModalCard(
      pillIcon: 'wifi',
      pillLabel: 'Band',
      title: downgrade ? 'They use 2.4GHz.' : '5GHz is busy here.',
      body: downgrade
          ? 'The receiver asked for Normal. Switching restarts the invite with a 2.4GHz hotspot.'
          : 'No 5GHz channel is free right now. Normal (2.4GHz) still shares at full speed.',
      actions: [
        BlButton('End session',
            primary: false, onTap: () => _close(ctx, s.endBandIssue)),
        BlButton('Switch to Normal',
            icon: 'refresh', onTap: () => _close(ctx, s.switchToNormal)),
      ],
    ),
  ).then((_) {
    if (s.bandIssue != null) s.endBandIssue();
    return Future<void>.value();
  });
}

void _close(BuildContext context, VoidCallback action) {
  Navigator.of(context).pop();
  action();
}

InputDecoration _deco() => InputDecoration(
      filled: true,
      fillColor: const Color(0x77100D0F),
      contentPadding: const EdgeInsets.all(13),
      counterText: '',
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0x16FFFFFF))),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: Color(0xFFD64B6E))),
    );

Widget _field(String label, TextEditingController controller,
        {bool obscure = false}) =>
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: ts(8, w: 650, ls: 1.2, color: BlColors.muted)),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          obscureText: obscure,
          maxLength: 64,
          style: ts(13),
          decoration: _deco(),
        ),
      ],
    );
