import 'package:flutter/services.dart';

class BlEngine {
  static const MethodChannel _ch = MethodChannel('blinker/engine');
  static bool _supports5 = false;
  static bool _p2p = false;
  static int _android = 0;
  static bool _warmed = false;

  static Future<Map<String, dynamic>> probe() async {
    try {
      final r = await _ch.invokeMethod('probe');
      if (r is Map) return Map<String, dynamic>.from(r);
    } on PlatformException {
      return {};
    } on MissingPluginException {
      return {};
    }
    return {};
  }

  static Future<void> warm() async {
    if (_warmed) return;
    final p = await probe();
    _supports5 = p['supports5GHz'] == true;
    _p2p = p['p2p'] == true;
    _android = (p['android'] as int?) ?? 0;
    _warmed = true;
  }

  static bool get supports5GHz => _supports5;
  static bool get p2p => _p2p;
  static int get android => _android;
}
