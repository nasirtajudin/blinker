import 'dart:async';

import '../engine/engine_bridge.dart' as bridge;

/// Convenience wrapper the screens use (onboarding, settings, diagnostics).
/// Talks to native EXCLUSIVELY through the real bridge
/// (channel 'bLinker/engine').
///
/// HARDENING RULE (added after the onboarding freeze): the flow must NEVER
/// dead-end on an engine problem. [probe] is infallible - if the engine is
/// missing, errors, or is slow, it resolves to safe defaults with
/// probeFailed=true, so onboarding continues (Fast stays locked, Normal
/// always works) instead of spinning on "Checking your device" forever.
class BlEngine {
  static bool _supports5 = false;
  static bool _p2p = false;
  static int _android = 0;
  static bool _probeFailed = false;
  static bool _warmed = false;

  /// Safe defaults used when the engine cannot be reached. `sdk` 0 makes
  /// `BlEngine.android` read as "unknown" in Diagnostics.
  static const Map<String, dynamic> _fallback = {
        'model': '',
        'sdk': 0,
        'wifi5ghz': false,
        'wifiDirect': false,
        'networkSuggestions': false,
        'customHotspotCredentials': false,
        'locationServicesOn': false,
        'measuredBand': null,
        'measuredLinkMbps': null,
        'probeFailed': true,
      };

  /// Live hardware probe, straight from the engine:
  /// {model, sdk, wifi5ghz, wifiDirect, networkSuggestions,
  ///  customHotspotCredentials, locationServicesOn, measuredBand, ...}.
  /// NEVER throws and NEVER hangs - see the hardening rule above.
  static Future<Map<String, dynamic>> probe() async {
    try {
      return await bridge.Engine.hardwareProbe()
          .timeout(const Duration(seconds: 6));
    } catch (_) {
      // Engine not attached (wrong MainActivity / early frame) or the call
      // failed / timed out: fall back instead of freezing the UI.
      return _fallback;
    }
  }

  static Future<void> warm() async {
    if (_warmed) return;
    final p = await probe();
    _supports5 = p['wifi5ghz'] == true;
    _p2p = p['wifiDirect'] == true;
    _android = (p['sdk'] as num?)?.toInt() ?? 0;
    _probeFailed = p['probeFailed'] == true;
    _warmed = true;
  }

  static bool get supports5GHz => _supports5;
  static bool get p2p => _p2p;
  static int get android => _android;
  static bool get probeFailed => _probeFailed;
}
