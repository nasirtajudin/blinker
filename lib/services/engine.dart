import '../engine/engine_bridge.dart' as bridge;

/// Convenience wrapper the Phase-1 screens use (onboarding, settings,
/// diagnostics). Talks to native EXCLUSIVELY through the real bridge
/// (channel 'bLinker/engine') - the old direct channel here was misspelled
/// ('blinker/engine') and called a method name that never existed, which
/// made every hardware probe silently fail.
class BlEngine {
  static bool _supports5 = false;
  static bool _p2p = false;
  static int _android = 0;
  static bool _warmed = false;

  /// Live hardware probe, straight from the engine:
  /// {model, sdk, wifi5ghz, wifiDirect, networkSuggestions,
  ///  customHotspotCredentials, locationServicesOn, measuredBand, ...}
  static Future<Map<String, dynamic>> probe() {
    return bridge.Engine.hardwareProbe();
  }

  static Future<void> warm() async {
    if (_warmed) return;
    try {
      final p = await bridge.Engine.hardwareProbe();
      _supports5 = p['wifi5ghz'] == true;
      _p2p = p['wifiDirect'] == true;
      _android = (p['sdk'] as num?)?.toInt() ?? 0;
    } catch (_) {
      // Engine not attached yet (very first frame / tests): defaults stay.
    }
    _warmed = true;
  }

  static bool get supports5GHz => _supports5;
  static bool get p2p => _p2p;
  static int get android => _android;
}
