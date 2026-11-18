// bLinker Phase 4 - event-flow tests for BlSession.
//
// No live engine needed: the method channel is mocked (calls recorded) and
// events are pumped straight into BlSession.handleEvent, exactly as the
// EventChannel would deliver them. One linear scenario per role, because
// BlSession is the app-lifetime singleton.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:blinker/data/store.dart';
import 'package:blinker/services/session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <MethodCall>[];
  Object? lastSendArg;

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('bLinker/engine'),
            (call) async {
      calls.add(call);
      if (call.method == 'transfer.send') lastSendArg = call.arguments;
      switch (call.method) {
        case 'storage.state':
          return '{"publicAccess":false,"allFilesAccessAvailable":true,'
              '"sandboxed":true,"saveDir":"/data/mock"}';
        case 'folder.open':
          return '{"opened":false,"reason":"app_dir","dir":"/mock"}';
        case 'storage.clearPartials':
          return '{"freed":1024,"files":2}';
      }
      return null;
    });
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues(const {});
    await BlStore.load();
    calls.clear();
    lastSendArg = null;
  });

  void ev(String type, [Map<String, dynamic>? data]) =>
      BlSession.I.handleEvent(type, data);

  test('sender flow: pick -> discover -> lan connect -> auto-send -> history',
      () async {
    final s = BlSession.I;
    BlStore.set('name', 'Tester');
    BlStore.set('method', 'fast');

    s.startSend();
    expect(s.role, 'send');
    expect(calls.any((c) => c.method == 'picker.open'), isTrue);

    ev('picker:result', {
      'files': [
        {'uri': 'content://x/1', 'name': 'cat.jpg', 'size': 1048576},
        {'uri': 'content://x/2', 'name': 'song.mp3', 'size': 2097152},
      ]
    });
    expect(s.staged.length, 2);
    expect(calls.any((c) => c.method == 'session.startSenderHotspot'), isTrue);
    final startCall =
        calls.firstWhere((c) => c.method == 'session.startSenderHotspot');
    expect(startCall.arguments, {'mode': 'fast', 'awake': true});

    ev('session:state', {'phase': 'p2p_search'});
    expect(s.phase, 'p2p_search');

    // Only bLinker-advertising peers make the radar.
    ev('p2p:peers', {
      'peers': [
        {'id': 'aa:bb', 'name': 'Mia', 'blink': true},
        {'id': 'cc:dd', 'name': 'Stranger', 'blink': false},
      ]
    });
    expect(s.peers.length, 1);
    expect(s.peers.first.name, 'Mia');

    ev('mdns:found', {'name': 'Router Buddy', 'host': '192.168.1.9', 'port': 58231});
    expect(s.peers.length, 2);
    expect(s.peers.last.kind, 'lan');

    // Sender taps the LAN peer.
    s.pickPeer(s.peers.last);
    final lan = calls.firstWhere((c) => c.method == 'session.lanConnect');
    expect(lan.arguments, {'host': '192.168.1.9', 'port': 58231});
    expect(s.linkKind, 'lan');

    // Link up -> the staged files go out immediately.
    ev('session:state', {'phase': 'link_connected'});
    expect(lastSendArg, isNotNull);
    expect((lastSendArg as List).length, 2);

    ev('transfer:accepted', {'id': 't1', 'peer': 'Router Buddy'});
    expect(s.progress?['totalBytes'], 1048576 + 2097152);

    ev('transfer:progress', {
      'id': 't1',
      'bytes': 512000,
      'totalBytes': 3145728,
      'filesDone': 0,
      'fileCount': 2,
      'index': 0,
      'name': 'cat.jpg',
      'bps': 900000,
      'etaSec': 3,
    });
    expect(s.progress?['name'], 'cat.jpg');

    ev('transfer:complete', {
      'id': 't1',
      'direction': 'send',
      'peer': 'Router Buddy',
      'peerAndroid': 34,
      'peer5': true,
      'files': [
        {'name': 'cat.jpg', 'size': 1048576},
        {'name': 'song.mp3', 'size': 2097152},
      ],
      'totalBytes': 3145728,
      'bodyBytes': 3145728,
      'durationMs': 4000,
      'avgBps': 786432,
      'band': '5GHz',
    });

    expect(BlStore.history.length, 1);
    final h = BlStore.history.first;
    expect(h['direction'], 'send');
    expect(h['peer'], 'Router Buddy');
    expect((h['total'] as num).toStringAsFixed(2), '3.00'); // MB convention
    expect(h['files'][0]['type'], 'photo');
    expect(h['files'][1]['type'], 'music');
    expect(h['band'], '5GHz');
    expect(s.result?['direction'], 'send');
    expect(s.staged, isEmpty);
    expect(calls.any((c) => c.method == 'picker.release'), isTrue);
    // Diagnostics "last session" is filled.
    expect(BlStore.last?['method'], 'Same-router LAN');
    expect(BlStore.last?['requested'], 'fast');
    expect((BlStore.last?['avg'] as num), closeTo(0.75, 0.01));

    // Multi-manifest: send more over the same link, then cancel the pick.
    s.sendMore();
    expect(calls.where((c) => c.method == 'picker.open').length, 2);
    ev('picker:cancelled', {'reason': 'user'});
    expect(s.role, 'send'); // link still up -> session stays
    expect(s.linkUp, isTrue);

    s.stop();
    expect(calls.any((c) => c.method == 'session.stop'), isTrue);
    expect(s.role, 'none');
    expect(s.active, isFalse);
  });

  test('receiver flow: invite -> manual join -> accept card -> history', () {
    final s = BlSession.I;
    BlStore.set('auto', false);

    s.startReceive();
    expect(calls.any((c) => c.method == 'session.startReceiver'), isTrue);
    expect(s.role, 'receive');

    // Invite from a Fast sender, but this device can't do 5GHz.
    ev('invite:received',
        {'name': 'Mia', 'fast': true, 'bandOk': false, 'port': 58231});
    expect(s.invite?['name'], 'Mia');
    expect(s.cardQueue, contains('invite'));

    s.respondInvite(true, preferNormal: true);
    final inv = calls.firstWhere((c) => c.method == 'session.respondInvite');
    expect(inv.arguments, {'accept': true, 'preferNormal': true});
    expect(s.invite, isNull);

    // Manual join path.
    ev('session:manual_expected');
    expect(s.manualExpected, isTrue);
    s.joinManual('AndroidAP_1234', 'secret123');
    final join = calls.firstWhere((c) => c.method == 'session.joinManual');
    expect(join.arguments, {'ssid': 'AndroidAP_1234', 'pass': 'secret123'});

    ev('join:waiting', {'ssid': 'AndroidAP_1234'});
    ev('join:connected', {'ssid': 'AndroidAP_1234', 'gateway': '192.168.43.1'});
    ev('session:state', {'phase': 'link_connected'});
    expect(s.linkKind, 'direct');

    // Manifest -> accept card -> accept with the configured location.
    ev('transfer:manifest', {
      'id': 't2',
      'sender': {'name': 'Mia', 'sdk': 33, 'five': true},
      'count': 1,
      'totalBytes': 5242880,
      'files': [
        {'key': '0', 'name': 'movie.mkv', 'rel': '', 'size': 5242880},
      ],
    });
    expect(s.manifest?['count'], 1);
    expect(s.cardQueue, contains('accept'));

    s.acceptManifest();
    final acc = calls.firstWhere((c) => c.method == 'transfer.accept');
    expect(acc.arguments?['location'], 'Downloads/bLinker/');

    ev('transfer:progress', {
      'id': 't2',
      'bytes': 5242880,
      'totalBytes': 5242880,
      'filesDone': 1,
      'fileCount': 1,
      'index': 0,
      'name': 'movie.mkv',
      'bps': 0,
      'etaSec': -1,
    });
    ev('transfer:complete', {
      'id': 't2',
      'direction': 'receive',
      'peer': 'Mia',
      'peerAndroid': 33,
      'peer5': true,
      'files': [
        {'name': 'movie.mkv', 'size': 5242880},
      ],
      'totalBytes': 5242880,
      'bodyBytes': 5242880,
      'durationMs': 1000,
      'avgBps': 5242880,
      'band': '2.4GHz',
      'dir': '/storage/emulated/0/Download/bLinker',
      'location': 'Downloads/bLinker/',
    });

    expect(BlStore.history.first['direction'], 'receive');
    expect(BlStore.history.first['dir'], '/storage/emulated/0/Download/bLinker');
    expect(s.result?['dir'], '/storage/emulated/0/Download/bLinker');
    expect(BlStore.last?['method'], 'Direct hotspot');

    s.stop();
  });

  test('receiver: cancelled transfer keeps partial records for resume', () {
    final s = BlSession.I;
    BlStore.partial = [];
    s.startReceive();
    ev('session:state', {'phase': 'link_connected'});
    ev('transfer:cancelled', {
      'id': 't3',
      'direction': 'receive',
      'reason': 'local',
      'bytes': 1048576,
      'totalBytes': 3145728,
      'filesDone': 0,
      'files': [
        {'name': 'big.bin', 'done': 1048576, 'size': 3145728},
      ],
    });
    expect(BlStore.partial.length, 1);
    expect(BlStore.partial.first['name'], 'big.bin');
    expect((BlStore.partial.first['done'] as num).toStringAsFixed(1), '1.0');
    expect(s.result?['cancelled'], true);

    // Completing the same file later clears the stale partial record.
    ev('transfer:complete', {
      'id': 't4',
      'direction': 'receive',
      'peer': 'Mia',
      'files': [
        {'name': 'big.bin', 'size': 3145728},
      ],
      'totalBytes': 3145728,
      'durationMs': 1000,
      'avgBps': 3145728,
      'band': '2.4GHz',
      'dir': '/x',
      'location': 'Downloads/bLinker/',
    });
    expect(BlStore.partial, isEmpty);
    s.stop();
  });

  test('auto-accept skips the card and answers immediately', () {
    final s = BlSession.I;
    BlStore.set('auto', true);
    s.startReceive();
    ev('session:state', {'phase': 'link_connected'});
    ev('transfer:manifest', {
      'id': 't5',
      'sender': {'name': 'Mia', 'sdk': 34, 'five': true},
      'count': 2,
      'totalBytes': 10,
      'files': [
        {'key': '0', 'name': 'a.txt', 'rel': '', 'size': 5},
        {'key': '1', 'name': 'b.txt', 'rel': '', 'size': 5},
      ],
    });
    expect(s.manifest, isNull, reason: 'auto-accept consumed the card');
    expect(calls.any((c) => c.method == 'transfer.accept'), isTrue);
    BlStore.set('auto', false);
    s.stop();
  });

  test('failures surface honest reasons and retry restarts the session', () {
    final s = BlSession.I;
    s.startSend();
    ev('picker:result', {
      'files': [
        {'uri': 'content://x/9', 'name': 'f.bin', 'size': 10},
      ]
    });
    ev('session:failed',
        {'stage': 'receiver_timeout', 'reason': 'No receiver joined in time'});
    expect(s.failure?['stage'], 'receiver_timeout');
    expect(s.toast, 'No receiver joined in time');
    expect(s.active, isTrue);

    s.retry();
    expect(s.failure, isNull);
    expect(calls.where((c) => c.method == 'session.startSenderHotspot').length,
        greaterThanOrEqualTo(2));
    s.stop();
  });

  test('band card: switch to normal restarts the invite', () {
    final s = BlSession.I;
    s.startSend();
    ev('picker:result', {
      'files': [
        {'uri': 'content://x/8', 'name': 'g.bin', 'size': 10},
      ]
    });
    ev('session:band_unavailable', {'reason': 'no_channel'});
    expect(s.bandIssue?['kind'], 'unavailable');
    expect(s.cardQueue, contains('band'));

    s.switchToNormal();
    expect(s.bandIssue, isNull);
    expect(calls.any((c) => c.method == 'session.switchMode'), isTrue);
    s.stop();
  });

  test('join timeout falls back to the system panel', () {
    final s = BlSession.I;
    s.startReceive();
    ev('session:manual_expected');
    s.joinManual('SSID', 'PASS');
    ev('join:timeout', {'ssid': 'SSID'});
    expect(s.joinTimedOut?['ssid'], 'SSID');
    expect(s.cardQueue, contains('joinTimeout'));

    s.openJoinPanel();
    expect(calls.any((c) => c.method == 'session.joinPanel'), isTrue);
    s.retryJoin();
    expect(calls.where((c) => c.method == 'session.joinManual').length, 2,
        reason: 'retry reuses the remembered credentials');
    s.stop();
  });

  test('picker cancel with no staged files returns to idle', () {
    final s = BlSession.I;
    s.startSend();
    ev('picker:cancelled', null);
    expect(s.role, 'none');
    expect(s.active, isFalse);
  });
}
