// bLinker engine bridge (Phase 2).
//
// The ONLY Dart file that talks to native code. Contract:
//   MethodChannel 'bLinker/engine'        Flutter -> native
//   EventChannel  'bLinker/engine/events' native -> Flutter (JSON strings)
//
// ---------------------------------------------------------------------------
// UI RULE (locked with the user - applies to every screen built later):
//   * "perm:" events and every system prompt (permission card, one-time
//     Wi-Fi-suggestion consent, "Add network" panel, Wi-Fi panel, app info
//     page) are rendered by Android itself. They are never customised,
//     wrapped or imitated - nothing sits between the user and them.
//   * Every card bLinker itself shows (invite, manifest accept, mode switch,
//     join fallback, manual code, permission explainer) uses bLinker's own
//     design language ONLY. The app must NOT look like the system.
// ---------------------------------------------------------------------------
//
// Events emitted by the engine:
//   engine:ready{sdk}
//   session:state{phase}                     phase: idle|mdns_search|p2p_search|
//        inviting|exchanging|hotspot_starting|waiting_receiver|standby|joining|
//        link_connecting|link_connected|failed
//   session:perm_missing{needed}             -> app-styled explainer, then
//                                               Engine.requestPermissions()
//                                               shows the REAL system card
//   session:band_unavailable{reason}         -> sender dialog [Switch to Normal]
//   session:downgrade_request                -> same dialog, receiver-initiated
//   session:manual_code{ssid,pass}           -> sender shows code (app card)
//   session:manual_expected                  -> receiver asks for code (app card)
//   session:failed{stage,reason}
//   invite:received{name,fast,bandOk,port}   -> bLinker invite card (app UI)
//   p2p:peers{peers:[{id,name,blink}]} p2p:searching p2p:visible p2p:connecting
//   p2p:connected p2p:closed p2p:unavailable p2p:connect_failed p2p:error
//   hotspot:started{ssid,pass,ip,port} hotspot:failed{reason} hotspot:stopped
//   join:waiting{ssid} join:connected{ssid,gateway} join:timeout{ssid}
//   join:manual_needed join:panel_result{added}
//   mdns:registered{name} mdns:found{name,host,port} mdns:error
//   tcp:listening{port}
//   wifi:stats{band,freqMhz,linkMbps,ssid}   -> HUD's MEASURED band chip
//   perm:result{granted,missing,anyPermanentlyDenied}

library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

class EngineEvent {
  EngineEvent(this.type, this.data);
  final String type;
  final Map<String, dynamic>? data;
}

class HotspotCredentials {
  HotspotCredentials._(this.ssid, this.pass, this.port, this.ip);
  final String ssid;
  final String pass;
  final int port;
  final String? ip;

  factory HotspotCredentials.from(Map<String, dynamic> j) => HotspotCredentials._(
        j['ssid'] as String? ?? '',
        j['pass'] as String? ?? '',
        (j['port'] as num?)?.toInt() ?? 58231,
        j['ip'] as String?,
      );
}

class WifiStats {
  WifiStats._(this.band, this.freqMhz, this.linkMbps, this.ssid);
  final String band;
  final int freqMhz;
  final int linkMbps;
  final String? ssid;
}

class Engine {
  Engine._();

  static const MethodChannel _methods = MethodChannel('bLinker/engine');
  static const EventChannel _events = EventChannel('bLinker/engine/events');

  /// Broadcast of every native engine event.
  static final Stream<EngineEvent> events = _events
      .receiveBroadcastStream()
      .map<EngineEvent>((raw) {
    final map = jsonDecode(raw as String) as Map<String, dynamic>;
    return EngineEvent(
      map['type'] as String,
      map['data'] == null ? null : Map<String, dynamic>.from(map['data'] as Map),
    );
  });

  static Future<dynamic> _call(String method, [Map<String, dynamic>? args]) =>
      _methods.invokeMethod(method, args ?? const <String, dynamic>{});

  // -- permissions (system card: untouched, never replicated) ----------------
  static Future<Map<String, dynamic>> permissionState() async =>
      Map<String, dynamic>.from(jsonDecode(await _call('perms.state') as String) as Map);

  static Future<void> requestPermissions() => _call('perms.request');
  static Future<void> openAppSettings() => _call('perms.openSettings');

  // -- identity / diagnostics -------------------------------------------------
  static Future<String> deviceName() async => await _call('device.name') as String;
  static Future<void> setDeviceName(String name) =>
      _methods.invokeMethod('device.setName', name);
  static Future<Map<String, dynamic>> hardwareProbe() async =>
      Map<String, dynamic>.from(jsonDecode(await _call('diag.hardware') as String) as Map);

  // -- sessions ------------------------------------------------------------------
  /// mode: 'fast' (5GHz) | 'normal' (2.4GHz)
  static Future<void> startSenderHotspot({required String mode}) =>
      _call('session.startSenderHotspot', {'mode': mode});
  static Future<void> startSenderLan() => _call('session.startSenderLan');
  static Future<void> startReceiver() => _call('session.startReceiver');
  static Future<void> connectPeer(String peerId) =>
      _call('session.p2pConnect', {'peerId': peerId});
  static Future<void> respondInvite({required bool accept, bool preferNormal = false}) =>
      _call('session.respondInvite', {'accept': accept, 'preferNormal': preferNormal});
  static Future<void> lanConnect(String host, int port) =>
      _call('session.lanConnect', {'host': host, 'port': port});
  static Future<void> joinManual({required String ssid, required String pass}) =>
      _call('session.joinManual', {'ssid': ssid, 'pass': pass});
  static Future<void> joinPanel() => _call('session.joinPanel');
  static Future<void> switchMode(String mode) => _call('session.switchMode', {'mode': mode});
  static Future<void> stopSession() => _call('session.stop');
}
