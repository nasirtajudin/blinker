import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class BlStore {
  static late SharedPreferences _sp;
  static const _kPrefs = 'blinker.prefs';
  static const _kHistory = 'blinker.history';
  static const _kPartial = 'blinker.partial';
  static const _kLast = 'blinker.last';

  static Map<String, dynamic> prefs = {
    'name': '',
    'method': 'fast',
    'auto': false,
    'location': 'Downloads/bLinker/',
    'awake': true,
    'complete': true,
    'failed': true,
    'haptics': true,
    'onboard': false,
    'permission': false,
  };
  static List<Map<String, dynamic>> history = [];
  static List<Map<String, dynamic>> partial = [];
  static Map<String, dynamic>? last;

  static Future<void> load() async {
    _sp = await SharedPreferences.getInstance();
    _prefs(_kPrefs, (v) => prefs = {...prefs, ...Map<String, dynamic>.from(v)});
    _list(_kHistory, (v) => history = v);
    _list(_kPartial, (v) => partial = v);
    try {
      final raw = _sp.getString(_kLast);
      if (raw != null) last = Map<String, dynamic>.from(jsonDecode(raw));
    } catch (_) {}
  }

  static void _prefs(String key, void Function(Map) apply) {
    try {
      final raw = _sp.getString(key);
      if (raw != null) apply(Map.from(jsonDecode(raw) as Map));
    } catch (_) {}
  }

  static void _list(String key, void Function(List<Map<String, dynamic>>) apply) {
    try {
      final raw = _sp.getString(key);
      if (raw != null) {
        apply((jsonDecode(raw) as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList());
      }
    } catch (_) {}
  }

  static void save() {
    _sp.setString(_kPrefs, jsonEncode(prefs));
    _sp.setString(_kHistory, jsonEncode(history));
    _sp.setString(_kPartial, jsonEncode(partial));
    if (last != null) _sp.setString(_kLast, jsonEncode(last));
  }

  static void set(String k, dynamic v) {
    prefs[k] = v;
    save();
  }

  static String get name => prefs['name'] as String? ?? '';
  static bool flag(String k) => prefs[k] == true;
}
