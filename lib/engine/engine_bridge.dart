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
//   -- phase 3 ----------------------------------------------------------
//   transfer:manifest{id,sender{name,sdk,five},count,totalBytes,
//        files:[{key,name,rel,size}]}        -> bLinker accept card (app UI)
//   transfer:accepted{id,peer}  transfer:rejected{id}
//   transfer:progress{id,bytes,totalBytes,filesDone,fileCount,index,name,
//        bps,etaSec}                         -> HUD progress + speed + ETA
//   transfer:file_done{id,key,index,name,bytes,ms,bps}
//   transfer:complete{id,direction,peer,peerAndroid,peer5,
//        files:[{name,size}],totalBytes,bodyBytes,durationMs,avgBps,
//        band,linkMbps,dir?,location?}       -> Dart writes BlStore.history
//   transfer:cancelled{id,direction,reason,bytes,totalBytes,filesDone,
//        files:[{name,done,size}]?}          -> receiver keeps .bpart partials
//   transfer:failed{id?,direction,stage,reason}
//   -- phase 4 ----------------------------------------------------------
//   picker:result{files:[{uri,name,size}]}   -> sender stages + starts
//   picker:cancelled{reason?}                -> back to idle (or keep link)
//   -- phase 5: radio gate ------------------------------------------------
//   radio:blocked{blocked:["wifi"|"location"],wifiOn,locationOn}
//        -> bLinker radio card: real system enable paths. The session is
//           parked in needs_radios until both are on.
//   radio:ok                                  -> parked session starts now

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

  factory HotspotCredentials.from(Map<String, dynamic> j) =>
      HotspotCredentials._(
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
  static final Stream<EngineEvent> events =
      _events.receiveBroadcastStream().map<EngineEvent>((raw) {
    final map = jsonDecode(raw as String) as Map<String, dynamic>;
    return EngineEvent(
      map['type'] as String,
      map['data'] == null
          ? null
          : Map<String, dynamic>.from(map['data'] as Map),
    );
  });

  static Future<dynamic> _call(String method, [Map<String, dynamic>? args]) =>
      _methods.invokeMethod(method, args ?? const <String, dynamic>{});

  // -- permissions (system card: untouched, never replicated) ----------------
  static Future<Map<String, dynamic>> permissionState() async =>
      Map<String, dynamic>.from(
          jsonDecode(await _call('perms.state') as String) as Map);

  static Future<void> requestPermissions() => _call('perms.request');
  static Future<void> openAppSettings() => _call('perms.openSettings');

  // -- phase 5: radio gate -------------------------------------------------

  /// {blocked:["wifi"|"location"], wifiOn:bool, locationOn:bool} - the REAL
  /// Wi-Fi adapter / Location-services state, not a guess.
  static Future<Map<String, dynamic>> radioState() async =>
      Map<String, dynamic>.from(
          jsonDecode(await _call('radio.state') as String) as Map);

  /// Android 10+: the REAL system Wi-Fi panel. Android 8-9: the adapter is
  /// enabled directly (allowed for apps below API 29).
  static Future<void> openWifiPanel() => _call('radio.wifi.enable');

  /// The REAL system Location page (no app can flip that toggle silently).
  static Future<void> openLocationSettings() => _call('radio.location.enable');

  /// Re-check the radios now; native emits radio:blocked / radio:ok.
  static Future<void> recheckRadios() => _call('radio.recheck');

  // -- identity / diagnostics -------------------------------------------------
  static Future<String> deviceName() async =>
      await _call('device.name') as String;
  static Future<void> setDeviceName(String name) =>
      _methods.invokeMethod('device.setName', name);
  static Future<Map<String, dynamic>> hardwareProbe() async =>
      Map<String, dynamic>.from(
          jsonDecode(await _call('diag.hardware') as String) as Map);

  // -- sessions ------------------------------------------------------------------
  /// mode: 'fast' (5GHz) | 'normal' (2.4GHz); awake = the Keep-screen-awake
  /// preference from Settings (native FLAG_KEEP_SCREEN_ON).
  static Future<void> startSenderHotspot(
          {required String mode, bool awake = true}) =>
      _call('session.startSenderHotspot', {'mode': mode, 'awake': awake});
  static Future<void> startSenderLan() => _call('session.startSenderLan');
  static Future<void> startReceiver({bool awake = true}) =>
      _call('session.startReceiver', {'awake': awake});
  static Future<void> connectPeer(String peerId) =>
      _call('session.p2pConnect', {'peerId': peerId});
  static Future<void> respondInvite(
          {required bool accept, bool preferNormal = false}) =>
      _call('session.respondInvite',
          {'accept': accept, 'preferNormal': preferNormal});
  static Future<void> lanConnect(String host, int port) =>
      _call('session.lanConnect', {'host': host, 'port': port});
  static Future<void> joinManual(
          {required String ssid, required String pass}) =>
      _call('session.joinManual', {'ssid': ssid, 'pass': pass});
  static Future<void> joinPanel() => _call('session.joinPanel');
  static Future<void> switchMode(String mode) =>
      _call('session.switchMode', {'mode': mode});
  static Future<void> stopSession() => _call('session.stop');

  // -- transfers (phase 3) ---------------------------------------------------
  /// Sends a manifest over the established link.
  /// files: [{uri | path, name, size, rel?}] - uri = SAF content URI from
  /// the system picker. Call only after session:state == link_connected.
  static Future<void> sendTransfer(List<Map<String, dynamic>> files) =>
      _methods.invokeMethod('transfer.send', files);

  /// Receiver's answer to the bLinker accept card. [location] = the
  /// configured save folder (BlStore.prefs['location']).
  static Future<void> acceptTransfer({String? location}) =>
      _call('transfer.accept', {'location': location});

  static Future<void> rejectTransfer() => _call('transfer.reject');
  static Future<void> cancelTransfer() => _call('transfer.cancel');

  /// {publicAccess, allFilesAccessAvailable, sandboxed, saveDir}
  static Future<Map<String, dynamic>> storageState({String? location}) async =>
      Map<String, dynamic>.from(jsonDecode(
              await _call('storage.state', {'location': location}) as String)
          as Map);

  /// Opens the system "All files access" page (real system screen, 11+).
  static Future<void> openAllFilesAccess() => _call('storage.openAllFiles');

  // -- phase 4: picker, folder view, partials -------------------------------
  /// The system document picker (its own UI, untouched). The answer arrives
  /// as picker:result / picker:cancelled events.
  static Future<void> openPicker() => _call('picker.open');

  /// Releases the persistable URI grants of the staged pick.
  static Future<void> releasePicker() => _call('picker.release');

  /// {opened, reason?, dir} - opens the save folder in the system Files UI
  /// when possible; reason=app_dir means the path is the app's own dir.
  static Future<Map<String, dynamic>> openFolder(String dir) async =>
      Map<String, dynamic>.from(
          jsonDecode(await _call('folder.open', {'dir': dir}) as String)
              as Map);

  /// Deletes every "*.bpart" partial under both possible roots.
  /// Returns {freed, files}.
  static Future<Map<String, dynamic>> clearPartials({String? location}) async =>
      Map<String, dynamic>.from(jsonDecode(
          await _call('storage.clearPartials', {'location': location})
              as String) as Map);
}
