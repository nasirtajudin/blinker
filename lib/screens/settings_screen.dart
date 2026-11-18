import 'package:flutter/material.dart';
import '../core/format.dart';
import '../core/icons.dart';
import '../core/theme.dart';
import '../data/store.dart';
import '../engine/engine_bridge.dart' as bridge;
import '../services/engine.dart';
import '../widgets/buttons.dart';
import '../widgets/modal.dart';
import '../widgets/page_header.dart';
import '../widgets/pressable.dart';
import '../widgets/toggle.dart';
import '../widgets/toast.dart';

class SettingsScreen extends StatefulWidget {
  final VoidCallback onBack;
  final VoidCallback onDiagnostics;
  final bool autoFocusName;
  const SettingsScreen(
      {super.key,
      required this.onBack,
      required this.onDiagnostics,
      this.autoFocusName = false});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _name =
      TextEditingController(text: BlStore.name);
  late final FocusNode _nameFocus = FocusNode();
  bool _nameOk = true;
  bool _howOpen = false;

  @override
  void initState() {
    super.initState();
    if (widget.autoFocusName) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _nameFocus.requestFocus());
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  InputDecoration _fieldDeco() => InputDecoration(
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

  @override
  Widget build(BuildContext context) {
    final method = (BlStore.prefs['method'] ?? 'fast') as String;
    final supports5 = BlEngine.supports5GHz;
    final partialBytes = BlStore.partial
        .fold<num>(0, (a, p) => a + ((p['size'] as num?) ?? 0));

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(25, 4, 25, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          BlPageHeader(title: 'Settings', onBack: widget.onBack),
          _title('Your identity', first: true),
          _group([
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Display name', style: ts(12, w: 550)),
                  const SizedBox(height: 4),
                  Text('This is what others see when you send',
                      style: ts(10, color: BlColors.muted)),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _name,
                    focusNode: _nameFocus,
                    maxLength: 28,
                    style: ts(13),
                    decoration: _fieldDeco(),
                    onChanged: (v) {
                      final t = v.trim();
                      if (t.isEmpty) {
                        setState(() => _nameOk = false);
                        return;
                      }
                      setState(() {
                        _nameOk = true;
                        BlStore.set('name', t);
                      });
                    },
                  ),
                  const SizedBox(height: 6),
                  Text(
                      _nameOk
                          ? 'Saved automatically'
                          : 'A display name is required',
                      style: ts(11, color: BlColors.muted)),
                ],
              ),
            ),
          ]),
          _title('Connections'),
          _group([
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Default transfer method', style: ts(12, w: 550)),
                  const SizedBox(height: 13),
                  Row(
                    children: [
                      Expanded(
                          child: _seg('fast', 'Fast (5GHz)', 'bolt',
                              method, supports5)),
                      const SizedBox(width: 7),
                      Expanded(
                          child: _seg('normal', 'Normal (2.4GHz)', 'wifi',
                              method, true)),
                    ],
                  ),
                  if (!supports5) ...[
                    const SizedBox(height: 10),
                    Text('Your device doesn’t support 5GHz hotspot',
                        style: ts(10, color: const Color(0xFFE69AAC))),
                  ],
                ],
              ),
            ),
            _toggle('Auto-accept incoming files',
                'Skip the incoming file confirmation.', 'auto'),
            _toggle('Keep screen awake during transfer',
                'Prevents the screen from sleeping during transfers.', 'awake'),
          ]),
          _title('Files & storage'),
          _group([
            _btnRow('folder', 'Save location',
                (BlStore.prefs['location'] ?? '') as String, _openLocation),
            _btnRow(
                'trash',
                'Clear partial files',
                partialBytes > 0
                    ? '${fmtSize(partialBytes)} from cancelled transfers'
                    : 'No partial files stored',
                _openClear),
          ]),
          _title('Notifications'),
          _group([
            _toggle('Transfer complete', '', 'complete'),
            _toggle('Transfer failed', '', 'failed'),
            _toggle('Haptics', 'A small pulse when devices pair.', 'haptics'),
          ]),
          _title('Under the hood'),
          _group([
            _btnRow('signal', 'Diagnostics',
                'Hardware probes & last session', widget.onDiagnostics),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 18),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('About bLinker', style: ts(12, w: 550)),
                      const BlPill('v1.0.0'),
                    ],
                  ),
                  const SizedBox(height: 17),
                  GestureDetector(
                    onTap: () => setState(() => _howOpen = !_howOpen),
                    child: SizedBox(
                      width: double.infinity,
                      child: Text('How Fast mode works',
                          style: ts(11, color: const Color(0xFFD9A7B7))),
                    ),
                  ),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 250),
                    child: _howOpen
                        ? Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Text(
                              'Fast mode uses a direct 5GHz Wi-Fi hotspot when both devices support it. The sender’s preference sets the method; a receiver without 5GHz support requires switching to Normal. Android may choose 2.4GHz instead, so the transfer always shows the session’s actual band. Devices on the same router use the existing LAN connection.',
                              style:
                                  ts(10, color: BlColors.muted, h: 1.8),
                            ),
                          )
                        : const SizedBox(width: double.infinity),
                  ),
                ],
              ),
            ),
          ]),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text('bLinker 1.0.0',
                  style: const TextStyle(
                      fontSize: 10,
                      color: Color(0xFF836B77),
                      fontFamily: 'Inter')),
            ),
          ),
        ],
      ),
    );
  }

  Widget _title(String t, {bool first = false}) => Padding(
        padding: EdgeInsets.fromLTRB(5, first ? 0 : 25, 5, 10),
        child: Text(t.toUpperCase(),
            style: ts(9,
                w: 650, ls: 1.8, color: const Color(0xFFA47F8C))),
      );

  Widget _group(List<Widget> children) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 17),
        decoration: BoxDecoration(
          color: const Color(0x03FFFFFF),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: BlColors.line),
        ),
        child: Column(
          children: [
            for (int i = 0; i < children.length; i++) ...[
              if (i > 0) Container(height: 1, color: BlColors.line),
              children[i],
            ],
          ],
        ),
      );

  Widget _toggle(String title, String desc, String key) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: ts(12, w: 550)),
                  if (desc.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(desc, style: ts(10, color: BlColors.muted)),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            BlToggle(
              value: BlStore.flag(key),
              onChanged: (v) => setState(() => BlStore.set(key, v)),
            ),
          ],
        ),
      );

  Widget _btnRow(
      String icon, String title, String sub, VoidCallback onTap) {
    return Pressable(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Row(
          children: [
            BlIcon(icon, size: 18, color: const Color(0xFFB3919F)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: ts(12, w: 550)),
                  const SizedBox(height: 5),
                  Text(sub, style: ts(10, color: BlColors.muted)),
                ],
              ),
            ),
            BlIcon('chevron', size: 15, color: const Color(0xFFB3919F)),
          ],
        ),
      ),
    );
  }

  Widget _seg(String value, String label, String icon, String current,
      bool enabled) {
    final selected = current == value;
    return Opacity(
      opacity: enabled ? 1 : 0.35,
      child: Pressable(
        onTap: enabled && !selected
            ? () {
                BlStore.set('method', value);
                setState(() {});
              }
            : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding:
              const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: selected
                ? const Color(0x15E43253)
                : const Color(0x05FFFFFF),
            border: Border.all(
                color: selected
                    ? const Color(0x55F25570)
                    : const Color(0x0CFFFFFF)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              BlIcon(icon,
                  size: 12,
                  color: selected
                      ? const Color(0xFFFF9AAD)
                      : BlColors.text),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ts(11,
                      color: selected
                          ? const Color(0xFFFF9AAD)
                          : BlColors.text),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openLocation() {
    final ctrl = TextEditingController(
        text: (BlStore.prefs['location'] ?? '') as String);
    showBlModal(context, (ctx) => _LocationSheet(ctrl))
        .then((_) {
      ctrl.dispose();
      if (mounted) setState(() {});
    });
  }

  void _openClear() {
    final bytes = BlStore.partial
        .fold<num>(0, (a, p) => a + ((p['size'] as num?) ?? 0));
    showBlModal(
      context,
      (ctx) => BlModalCard(
        pillIcon: 'trash',
        pillLabel: 'Storage',
        title: 'Clear partial files?',
        body:
            '${bytes > 0 ? fmtSize(bytes) : 'No partial files'} from cancelled transfers. Completed files are never removed. Clearing partials does not remove the original selected files.',
        actions: [
          BlButton('Keep files',
              primary: false, onTap: () => Navigator.of(ctx).pop()),
          BlButton('Clear partials', onTap: () {
            Navigator.of(ctx).pop();
            _clearPartials();
          }),
        ],
      ),
    );
  }

  /// Deletes the real "*.bpart" files on disk (both possible roots),
  /// then clears the Dart-side records.
  Future<void> _clearPartials() async {
    var freed = 0;
    var files = 0;
    try {
      final res = await bridge.Engine.clearPartials(
          location: (BlStore.prefs['location'] ?? '') as String);
      freed = (res['freed'] as num?)?.toInt() ?? 0;
      files = (res['files'] as num?)?.toInt() ?? 0;
    } catch (_) {}
    BlStore.partial = [];
    BlStore.save();
    if (mounted) setState(() {});
    if (!mounted) return;
    BlToast.show(
        context,
        files > 0
            ? 'Cleared $files partial${files == 1 ? '' : 's'} · ${fmtBytes(freed)} freed'
            : 'No partial files on disk. Completed files are safe.');
  }
}

/// Save-location sheet: path input + the REAL resolved storage state
/// (public Downloads vs the app's own dir) + the system All-Files page.
class _LocationSheet extends StatefulWidget {
  final TextEditingController controller;
  const _LocationSheet(this.controller);

  @override
  State<_LocationSheet> createState() => _LocationSheetState();
}

class _LocationSheetState extends State<_LocationSheet> {
  Map<String, dynamic>? _state;
  bool _probing = true;
  String _probedPath = '';

  @override
  void initState() {
    super.initState();
    _probe();
  }

  Future<void> _probe() async {
    final p = widget.controller.text.trim();
    if (_probing && p == _probedPath) return;
    _probedPath = p;
    try {
      final st = await bridge.Engine.storageState(location: p);
      if (mounted) setState(() => _state = st);
    } catch (_) {
      if (mounted) setState(() => _state = null);
    } finally {
      if (mounted) setState(() => _probing = false);
    }
  }

  void _save(BuildContext context) {
    final p = widget.controller.text.trim().replaceAll('\\', '/');
    if (p.isEmpty ||
        p.contains('..') ||
        RegExp(r'[<>\x00-\x1f]').hasMatch(p)) {
      BlToast.show(context, 'Enter a valid folder path without \u201c..\u201d.');
      return;
    }
    BlStore.set('location', p.endsWith('/') ? p : '$p/');
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final sandboxed = _state?['sandboxed'] == true;
    final canGrant = _state?['allFilesAccessAvailable'] == true;
    return BlModalCard(
      pillIcon: 'folder',
      pillLabel: 'Save location',
      title: 'A place for everything.',
      body: 'Choose where received files are saved.',
      extra: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 20),
          Text('FOLDER PATH', style: ts(11, color: BlColors.muted)),
          const SizedBox(height: 7),
          TextField(
            controller: widget.controller,
            autofocus: true,
            maxLength: 120,
            style: ts(13),
            decoration: InputDecoration(
              filled: true,
              fillColor: const Color(0x77100D0F),
              contentPadding: const EdgeInsets.all(13),
              counterText: '',
              enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide:
                      const BorderSide(color: Color(0x16FFFFFF))),
              focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide:
                      const BorderSide(color: Color(0xFFD64B6E))),
            ),
            onSubmitted: (_) => _save(context),
            onChanged: (_) => _probe(),
          ),
          const SizedBox(height: 13),
          if (_probing)
            Text('Checking this device\u2019s storage\u2026',
                style: ts(10, color: BlColors.muted))
          else if (_state != null) ...[
            Row(
              children: [
                BlIcon('folder', size: 12, color: BlColors.muted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text('Resolves to ${_state!['saveDir']}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: ts(9, color: BlColors.muted)),
                ),
                const SizedBox(width: 8),
                if (sandboxed)
                  const BlPill('App folder')
                else
                  const BlPill('Public storage', success: true),
              ],
            ),
            if (sandboxed) ...[
              const SizedBox(height: 7),
              Text(
                'Without All-Files access, Android keeps received files inside bLinker\u2019s own folder.',
                style: ts(9, color: BlColors.muted, h: 1.7),
              ),
              if (canGrant)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: BlTextButton('Grant All-Files access',
                      icon: 'chevron',
                      onTap: () {
                    bridge.Engine.openAllFilesAccess();
                    BlToast.show(context,
                        'Allow bLinker on the system page, then come back.');
                  }),
                ),
            ],
          ],
        ],
      ),
      actions: [
        BlButton('Cancel',
            primary: false, onTap: () => Navigator.of(context).pop()),
        BlButton('Use this folder', onTap: () => _save(context)),
      ],
    );
  }
}
