import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/format.dart' show fileIconFor;
import '../data/store.dart';
import '../engine/engine_bridge.dart' as bridge;

/// A nearby device on the radar: a bLinker receiver seen over Wi-Fi Direct
/// ([kind] = p2p) or a receiver on the same router discovered via mDNS
/// ([kind] = lan).
class BlPeer {
  BlPeer(
      {required this.id,
      required this.name,
      required this.kind,
      this.host,
      this.port});
  final String id;
  final String name;
  final String kind; // 'p2p' | 'lan'
  final String? host;
  final int? port;
}

/// THE session controller (Phase 4). Owns no UI - every screen and modal
/// reads this and renders in bLinker's own design language.
///
/// HARDENING RULE (same as BlEngine): the flow must never dead-end on an
/// engine problem. Every native call is best-effort; state changes only on
/// real events. [handleEvent] is public so the event flow is unit-testable
/// without a live engine.
class BlSession extends ChangeNotifier {
  BlSession._();
  static final BlSession I = BlSession._();

  StreamSubscription? _sub;
  bool _started = false;

  // -- live state -----------------------------------------------------------
  String role = 'none'; // 'none' | 'send' | 'receive'
  String phase = 'idle'; // native session:state phase id
  bool pickerOpen = false;

  final List<BlPeer> _p2pPeersList = [];
  final List<BlPeer> _lanPeersList = [];

  /// Nearby devices for the radar: bLinker receivers seen over Wi-Fi Direct
  /// plus same-router receivers found via mDNS. P2P rounds never wipe LAN
  /// finds - the two channels are tracked separately.
  List<BlPeer> get peers => [..._p2pPeersList, ..._lanPeersList];
  Map<String, dynamic>? wifiStats; // wifi:stats (MEASURED band)

  Map<String, dynamic>? invite; // pending invite card (receiver)
  Map<String, dynamic>? manualCode; // sender: {ssid, pass}
  bool manualExpected = false; // receiver: show the join-entry card
  Map<String, dynamic>? joinFallback; // join:manual_needed (legacy)
  Map<String, dynamic>? joinTimedOut; // join:timeout
  List<String> permMissing = []; // session:perm_missing -> explainer
  List<String> radioBlocked = []; // radio:blocked -> 'wifi' | 'location'
  Map<String, dynamic>? p2pIssue; // p2p:unavailable - radar hint
  Map<String, dynamic>? bandIssue; // band_unavailable / downgrade_request

  List<Map<String, dynamic>> staged = []; // picked files awaiting the link
  Map<String, dynamic>? manifest; // receiver: pending accept card
  Map<String, dynamic>? progress; // live transfer:progress
  Map<String, dynamic>? result; // transfer:complete / cancelled summary
  Map<String, dynamic>? failure; // session:failed / transfer:failed

  String requestedMethod = 'fast';
  String linkKind = 'direct'; // 'direct' (hotspot) | 'lan'
  bool _sawJoin = false;
  String _peerName = '';
  String _joinSsid = '';
  String _joinPass = '';

  /// The peer this session is about (tapped peer / invite sender).
  String get peerName => _peerName.isEmpty ? 'them' : _peerName;

  String? toast; // transient message
  int toastSeq = 0;

  /// Decision cards waiting to be shown, in arrival order:
  /// 'invite' | 'accept' | 'join' | 'joinTimeout' | 'perm' | 'band'.
  /// Edge-triggered (a card queues once per appearance) so the 1-second
  /// wifi:stats tick can never re-raise a dismissed card.
  final List<String> cardQueue = [];
  bool _qInvite = false,
      _qManifest = false,
      _qJoin = false,
      _qJoinTimeout = false,
      _qPerm = false,
      _qBand = false,
      _qRadio = false;

  // -- lifecycle -------------------------------------------------------------

  /// Called once from app boot. Idempotent, never throws.
  void init() {
    if (_started) return;
    _started = true;
    _sub = bridge.Engine.events.listen(
      (e) => handleEvent(e.type, e.data),
      onError: (Object _) {},
      cancelOnError: false,
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  bool get active => role != 'none' || failure != null;
  bool get linkUp => phase == 'link_connected';

  // -- actions ----------------------------------------------------------------

  /// Dock "Send": system picker first, session starts once files are staged.
  void startSend() {
    role = 'send';
    failure = null;
    result = null;
    manifest = null;
    progress = null;
    invite = null;
    pickerOpen = true;
    _toast('Pick the files to send');
    _try(() => bridge.Engine.openPicker());
    _notify();
  }

  /// Dock "Receive": become visible to nearby senders on both channels.
  void startReceive() {
    role = 'receive';
    _resetFlowState();
    requestedMethod = (BlStore.prefs['method'] ?? 'fast') as String;
    _try(() => bridge.Engine.startReceiver(awake: BlStore.flag('awake')));
    _notify();
  }

  /// Sender tapped a device on the radar.
  void pickPeer(BlPeer p) {
    _peerName = p.name;
    if (p.kind == 'lan' && p.host != null) {
      linkKind = 'lan';
      _try(() => bridge.Engine.lanConnect(p.host!, p.port ?? 58231));
    } else {
      linkKind = 'direct';
      _try(() => bridge.Engine.connectPeer(p.id));
    }
    _notify();
  }

  /// Receiver's answer to the invite card.
  void respondInvite(bool accept, {bool preferNormal = false}) {
    invite = null;
    _try(() => bridge.Engine.respondInvite(
        accept: accept, preferNormal: preferNormal));
    _notify();
  }

  /// Receiver typed the code shown on the sender's screen.
  void joinManual(String ssid, String pass) {
    _joinSsid = ssid;
    _joinPass = pass;
    manualExpected = false;
    _try(() => bridge.Engine.joinManual(ssid: ssid, pass: pass));
    _notify();
  }

  /// join:timeout -> try the same credentials once more.
  void retryJoin() {
    joinTimedOut = null;
    if (_joinSsid.isEmpty) {
      openJoinPanel();
      return;
    }
    _try(() => bridge.Engine.joinManual(ssid: _joinSsid, pass: _joinPass));
    _notify();
  }

  /// Sender accepted [Switch to Normal] on the band card.
  void switchToNormal() {
    bandIssue = null;
    _try(() => bridge.Engine.switchMode('normal'));
    _notify();
  }

  /// Sender declined the band card.
  void endBandIssue() {
    bandIssue = null;
    stop();
  }

  /// Receiver: open the system Wi-Fi panel / settings (real system screen).
  void openJoinPanel() {
    _try(() => bridge.Engine.joinPanel());
    _notify();
  }

  /// "Not now" on the permission explainer: keep the session going without
  /// the grant (P2P discovery may fail honestly on 33+).
  void dismissPerms() {
    permMissing = [];
    _notify();
  }

  // -- phase 5: the radio gate -------------------------------------------

  /// The REAL system Wi-Fi panel (Android 10+) / direct enable (Android 8-9).
  void enableWifi() {
    _try(() => bridge.Engine.openWifiPanel());
    _notify();
  }

  /// The REAL system Location page.
  void enableLocation() {
    _try(() => bridge.Engine.openLocationSettings());
    _notify();
  }

  /// "Check again" on the radio card: native re-checks and answers with
  /// radio:blocked / radio:ok.
  void recheckRadios() {
    _try(() => bridge.Engine.recheckRadios());
    _notify();
  }

  /// Dismiss the radio card but keep the session parked in needs_radios;
  /// the native poller re-raises radio:blocked (and so the card) if a radio
  /// is still off on the next check.
  void dismissRadios() {
    radioBlocked = [];
    _notify();
  }

  /// The join card was dismissed - bring it back from the joining card.
  void reopenJoinCard() {
    manualExpected = true;
    _notify();
  }

  /// After the bLinker permission explainer card: show the REAL system card.
  void continuePermissions() {
    permMissing = [];
    _try(() => bridge.Engine.requestPermissions());
    _notify();
  }

  /// Receiver accepted the bLinker file card.
  void acceptManifest() {
    final m = manifest;
    manifest = null;
    if (m == null) return;
    _try(() => bridge.Engine.acceptTransfer(
        location: (BlStore.prefs['location'] ?? '') as String));
    _notify();
  }

  void rejectManifest() {
    manifest = null;
    _try(() => bridge.Engine.rejectTransfer());
    _notify();
  }

  void cancelTransfer() {
    _try(() => bridge.Engine.cancelTransfer());
    _notify();
  }

  /// "Send more" over the established link (multi-manifest protocol).
  void sendMore() {
    if (!linkUp || role != 'send') return;
    pickerOpen = true;
    _try(() => bridge.Engine.openPicker());
    _notify();
  }

  void retry() {
    final r = role;
    failure = null;
    result = null;
    if (r == 'receive') {
      startReceive();
    } else if (staged.isNotEmpty) {
      _try(() => bridge.Engine.startSenderHotspot(
          mode: (BlStore.prefs['method'] ?? 'fast') as String,
          awake: BlStore.flag('awake')));
      _notify();
    } else {
      startSend();
    }
  }

  void stop() {
    _try(() => bridge.Engine.stopSession());
    if (staged.isNotEmpty) _try(() => bridge.Engine.releasePicker());
    role = 'none';
    _resetFlowState();
    _notify();
  }

  // -- the event core ---------------------------------------------------------

  /// Every engine event lands here. Never throws.
  void handleEvent(String type, Map<String, dynamic>? data) {
    final d = data ?? const <String, dynamic>{};
    try {
      _onEvent(type, d);
    } catch (e) {
      debugPrint('blinker session: $type handler failed: $e');
    }
    _notify();
  }

  void _onEvent(String type, Map<String, dynamic> d) {
    switch (type) {
      // ---- session ------------------------------------------------------
      case 'session:state':
        phase = (d['phase'] as String?) ?? phase;
        if (phase == 'link_connected') {
          if (role == 'receive' && linkKind != 'lan') {
            linkKind = _sawJoin ? 'direct' : 'lan';
          }
          _haptic();
          if (role == 'send' && staged.isNotEmpty) {
            _try(() => bridge.Engine.sendTransfer(staged));
          }
        } else if (phase == 'idle' || phase == 'failed') {
          pickerOpen = false;
        }
        break;

      case 'session:perm_missing':
        final needed = d['needed'];
        if (needed is List) {
          permMissing = needed.whereType<String>().toList();
        }
        break;

      // ---- phase 5: radio gate ------------------------------------------
      case 'radio:blocked':
        final b = d['blocked'];
        radioBlocked = b is List ? b.whereType<String>().toList() : [];
        if (radioBlocked.isNotEmpty) {
          _toast(radioBlocked.length == 2
              ? 'Wi-Fi and Location are off'
              : (radioBlocked.contains('wifi')
                  ? 'Wi-Fi is off'
                  : 'Location is off'));
        }
        break;

      case 'radio:ok':
        if (radioBlocked.isNotEmpty) {
          radioBlocked = [];
          p2pIssue = null;
          _toast('Radios ready — searching…');
        }
        break;

      case 'p2p:unavailable':
        // Discovery honestly failed (radios off / busy). No dead silence:
        // surface it so the user can fix the radio instead of staring at an
        // empty radar.
        p2pIssue = Map<String, dynamic>.from(d);
        _toast('Nearby search failed — Wi-Fi and Location must be on');
        break;

      case 'p2p:connect_failed':
        _toast('Couldn’t reach that device — pick another');
        break;

      case 'session:band_unavailable':
        bandIssue = {'kind': 'unavailable', 'reason': d['reason'] ?? ''};
        break;

      case 'session:downgrade_request':
        bandIssue = {'kind': 'downgrade'};
        break;

      case 'session:manual_code':
        manualCode = {
          'ssid': (d['ssid'] as String?) ?? '',
          'pass': (d['pass'] as String?) ?? '',
        };
        break;

      case 'session:manual_expected':
        manualExpected = true;
        _sawJoin = true;
        break;

      case 'session:failed':
        // A dead link invalidates any pending decision cards.
        invite = null;
        manifest = null;
        failure = {
          'stage': (d['stage'] as String?) ?? 'failed',
          'reason': (d['reason'] as String?) ?? '',
        };
        _toast(_failText(failure!));
        break;

      // ---- discovery ----------------------------------------------------
      case 'p2p:peers':
        _p2pPeersList
          ..clear()
          ..addAll(_p2pPeers(d)..sort((a, b) => a.id.compareTo(b.id)));
        break;

      case 'mdns:found':
        final name = (d['name'] as String?) ?? '';
        final host = (d['host'] as String?) ?? '';
        final port = (d['port'] as num?)?.toInt();
        if (name.isEmpty || host.isEmpty) break;
        final id = 'lan:$host:$port';
        final peer =
            BlPeer(id: id, name: name, kind: 'lan', host: host, port: port);
        final i = _lanPeersList.indexWhere((p) => p.id == id);
        if (i >= 0) {
          _lanPeersList[i] = peer;
        } else {
          _lanPeersList.add(peer);
        }
        _lanPeersList.sort((a, b) => a.id.compareTo(b.id));
        break;

      // ---- invite (receiver) ---------------------------------------------
      case 'invite:received':
        _peerName = (d['name'] as String?) ?? _peerName;
        invite = Map<String, dynamic>.from(d);
        _haptic();
        break;

      // ---- join (receiver) ------------------------------------------------
      case 'join:waiting':
        _sawJoin = true;
        manualExpected = false;
        break;

      case 'join:connected':
        _sawJoin = true;
        linkKind = 'direct';
        break;

      case 'join:timeout':
        joinTimedOut = Map<String, dynamic>.from(d);
        break;

      case 'join:manual_needed':
        _sawJoin = true;
        joinFallback = Map<String, dynamic>.from(d);
        break;

      case 'join:panel_result':
        if (d['added'] == true) {
          joinTimedOut = null;
          _toast('Network added — joining…');
        }
        break;

      case 'hotspot:stopped':
        // Only a live hotspot phase matters; during a switchMode restart
        // the reservation is closed by us and must not end the session.
        const hotspotPhases = {
          'hotspot_starting',
          'waiting_receiver',
          'link_connecting',
          'link_connected',
        };
        if (role == 'send' && hotspotPhases.contains(phase)) {
          _toast('Hotspot closed — session ended');
          _try(() => bridge.Engine.stopSession());
        }
        break;

      // ---- picker -----------------------------------------------------------
      case 'picker:result':
        pickerOpen = false;
        final files = d['files'];
        staged = files is List
            ? files
                .whereType<Map>()
                .map((m) => Map<String, dynamic>.from(m))
                .toList()
            : <Map<String, dynamic>>[];
        if (role == 'send') {
          if (linkUp) {
            _try(() => bridge.Engine.sendTransfer(staged));
          } else if (phase == 'idle' || phase == 'failed') {
            requestedMethod = (BlStore.prefs['method'] ?? 'fast') as String;
            _try(() => bridge.Engine.startSenderHotspot(
                mode: requestedMethod, awake: BlStore.flag('awake')));
          }
        }
        break;

      case 'picker:cancelled':
        pickerOpen = false;
        if (role == 'send' && staged.isEmpty && !linkUp) {
          role = 'none';
        } else if (linkUp) {
          _toast('Nothing picked — link stays open');
        }
        break;

      // ---- transfer ---------------------------------------------------------
      case 'transfer:manifest':
        manifest = Map<String, dynamic>.from(d);
        if (BlStore.flag('auto')) {
          _toast('Auto-accepted from ${_senderName(d)}');
          acceptManifest();
        }
        break;

      case 'transfer:accepted':
        manualCode = null;
        result = null; // a second manifest replaces the old result card
        final total = (manifest?['totalBytes'] as num?)?.toDouble() ??
            staged.fold<double>(0, (a, f) => a + ((f['size'] as num?) ?? 0));
        final count = (manifest?['count'] as num?)?.toInt() ?? staged.length;
        progress = {
          'id': d['id'],
          'bytes': 0,
          'totalBytes': total,
          'filesDone': 0,
          'fileCount': count,
          'index': 0,
          'name': '',
          'bps': 0,
          'etaSec': -1,
        };
        break;

      case 'transfer:progress':
        progress = Map<String, dynamic>.from(d);
        break;

      case 'transfer:complete':
        _onComplete(d);
        break;

      case 'transfer:cancelled':
        _onCancelled(d);
        break;

      case 'transfer:rejected':
        failure = {
          'stage': 'rejected',
          'reason': 'The other side declined the files',
        };
        _toast(failure!['reason'] as String);
        break;

      case 'transfer:failed':
        // The link is gone; pending decision cards can never be answered.
        invite = null;
        manifest = null;
        failure = {
          'stage': (d['stage'] as String?) ?? 'failed',
          'reason': (d['reason'] as String?) ?? '',
        };
        if (BlStore.flag('failed')) _toast(_failText(failure!));
        break;

      // ---- misc ---------------------------------------------------------------
      case 'wifi:stats':
        wifiStats = Map<String, dynamic>.from(d);
        break;
    }
  }

  // -- event helpers -----------------------------------------------------------

  List<BlPeer> _p2pPeers(Map<String, dynamic> d) {
    final list = d['peers'];
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((m) => BlPeer(
              id: (m['id'] as String?) ?? '',
              name: (m['name'] as String?) ?? 'Android device',
              kind: 'p2p',
            ))
        .where((p) => p.id.isNotEmpty)
        .where((p) => _blinkOnly(p, list))
        .toList();
  }

  /// Only devices advertising the bLinker service are shown on the radar.
  bool _blinkOnly(BlPeer p, List<dynamic> raw) =>
      raw.whereType<Map>().any((m) => m['id'] == p.id && m['blink'] == true);

  String _senderName(Map<String, dynamic> manifest) {
    final s = manifest['sender'];
    if (s is Map) return (s['name'] as String?) ?? '';
    return '';
  }

  void _onComplete(Map<String, dynamic> d) {
    final direction = (d['direction'] as String?) ?? 'send';
    final files = (d['files'] as List? ?? [])
        .whereType<Map>()
        .map((f) => {
              'name': (f['name'] as String?) ?? '',
              'size': ((f['size'] as num?) ?? 0) / 1048576,
              'type': fileIconFor((f['name'] as String?) ?? ''),
            })
        .toList();
    final totalBytes = (d['totalBytes'] as num?) ?? 0;
    final avgBps = (d['avgBps'] as num?) ?? 0;
    final durationMs = (d['durationMs'] as num?) ?? 0;
    final entry = <String, dynamic>{
      'id': (d['id'] as String?) ?? '',
      'direction': direction,
      'peer': (d['peer'] as String?) ?? _peerName,
      'files': files,
      'total': totalBytes / 1048576,
      'avg': avgBps / 1048576,
      'duration': durationMs / 1000,
      'date': DateTime.now().toIso8601String(),
      'band': d['band'],
      'dir': d['dir'],
      'location': d['location'],
    };
    BlStore.history.insert(0, entry);
    BlStore.last = {
      'band': d['band'] ?? '—',
      'avg': avgBps / 1048576,
      'requested': requestedMethod,
      'method': linkKind == 'lan' ? 'Same-router LAN' : 'Direct hotspot',
      'peerAndroid': d['peerAndroid'],
      'peer5': d['peer5'],
      'peer': entry['peer'],
      'date': entry['date'],
    };
    BlStore.save();
    if (direction == 'receive') {
      _dropPartials(files.map((f) => f['name'] as String).toList());
    } else if (staged.isNotEmpty) {
      staged = [];
      _try(() => bridge.Engine.releasePicker());
    }
    result = Map<String, dynamic>.from(d);
    result!['filesDone'] = files.length;
    progress = null;
    manifest = null;
    manualCode = null;
    _haptic();
  }

  void _onCancelled(Map<String, dynamic> d) {
    result = Map<String, dynamic>.from(d);
    result!['cancelled'] = true;
    progress = null;
    manifest = null;
    if (d['direction'] == 'receive') {
      final files = (d['files'] as List? ?? [])
          .whereType<Map>()
          .map((f) => {
                'name': (f['name'] as String?) ?? '',
                'done': ((f['done'] as num?) ?? 0) / 1048576,
                'size': ((f['size'] as num?) ?? 0) / 1048576,
              })
          .toList();
      _mergePartials(files);
      if (files.isNotEmpty) {
        _toast('Cancelled — partial files kept for resume');
      } else {
        _toast('Transfer cancelled');
      }
    } else {
      staged = [];
      _try(() => bridge.Engine.releasePicker());
      _toast('Transfer cancelled');
    }
  }

  /// Receiver: completed files remove their stale partial records.
  void _dropPartials(List<String> names) {
    if (BlStore.partial.isEmpty) return;
    BlStore.partial =
        BlStore.partial.where((p) => !names.contains(p['name'])).toList();
    BlStore.save();
  }

  /// Receiver: merge a cancel's partials into the store (max progress wins).
  void _mergePartials(List<Map<String, dynamic>> files) {
    for (final f in files) {
      final i = BlStore.partial
          .indexWhere((p) => p['name'] == f['name'] && p['size'] == f['size']);
      if (i >= 0) {
        final done = ((BlStore.partial[i]['done'] as num?) ?? 0);
        if ((f['done'] as num? ?? 0) > done) BlStore.partial[i] = f;
      } else {
        BlStore.partial.add(f);
      }
    }
    BlStore.save();
  }

  String _failText(Map<String, dynamic> f) {
    final stage = f['stage'] as String? ?? '';
    switch (stage) {
      case 'rejected':
        return 'The other side declined';
      case 'receiver_timeout':
        return 'No receiver joined in time';
      case 'no_accept':
        return 'No answer to the file request';
      case 'link':
        return 'Connection lost mid-transfer';
      default:
        return 'Couldn’t connect — ${f['reason'] ?? stage}';
    }
  }

  void _haptic() {
    if (!BlStore.flag('haptics')) return;
    _try(() => HapticFeedback.mediumImpact());
  }

  void _resetFlowState() {
    phase = 'idle';
    _p2pPeersList.clear();
    _lanPeersList.clear();
    invite = null;
    manualCode = null;
    manualExpected = false;
    joinFallback = null;
    joinTimedOut = null;
    permMissing = [];
    radioBlocked = [];
    p2pIssue = null;
    bandIssue = null;
    staged = [];
    manifest = null;
    progress = null;
    result = null;
    failure = null;
    pickerOpen = false;
    wifiStats = null;
    _sawJoin = false;
    _joinSsid = '';
    _joinPass = '';
    linkKind = 'direct';
    cardQueue.clear();
  }

  void _toast(String message) {
    toast = message;
    toastSeq++;
  }

  void _try(Future<void> Function() f) {
    try {
      f().catchError((Object _) {});
    } catch (_) {
      // Engine missing / channel cold: never freeze the UI over it.
    }
  }

  void _notify() {
    _syncCards();
    notifyListeners();
  }

  void _syncCards() {
    void edge(bool shown, bool present, String id, void Function(bool) set) {
      if (present && !shown) {
        set(true);
        cardQueue.add(id);
      } else if (!present && shown) {
        set(false);
      }
    }

    edge(_qInvite, invite != null, 'invite', (v) => _qInvite = v);
    edge(_qManifest, manifest != null, 'accept', (v) => _qManifest = v);
    edge(_qJoin, manualExpected || joinFallback != null, 'join',
        (v) => _qJoin = v);
    edge(_qJoinTimeout, joinTimedOut != null, 'joinTimeout',
        (v) => _qJoinTimeout = v);
    edge(_qPerm, permMissing.isNotEmpty, 'perm', (v) => _qPerm = v);
    edge(_qBand, bandIssue != null, 'band', (v) => _qBand = v);
    edge(_qRadio, radioBlocked.isNotEmpty, 'radio', (v) => _qRadio = v);
  }
}
