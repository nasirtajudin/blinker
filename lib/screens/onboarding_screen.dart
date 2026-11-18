import 'package:flutter/material.dart';
import '../core/routes.dart';
import '../core/theme.dart';
import '../core/icons.dart';
import '../data/store.dart';
import '../services/engine.dart';
import '../widgets/buttons.dart';
import '../widgets/radar.dart';
import '../widgets/toast.dart';
import 'shell.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});
  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  int _step = 0;
  String _probe = 'idle';
  bool _supports5 = false;
  late final TextEditingController _name =
      TextEditingController(text: BlStore.name);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _confirmName() async {
    final n = _name.text.trim();
    if (n.isEmpty) {
      BlToast.show(context, 'Add a name to continue.');
      return;
    }
    BlStore.set('name', n);
    setState(() {
      _step = 1;
      _probe = 'running';
    });
    final probeTask = BlEngine.probe();
    await Future<void>.delayed(const Duration(milliseconds: 600));
    final probe = await probeTask;
    if (!mounted) return;
    setState(() {
      _probe = 'done';
      _supports5 = probe['wifi5ghz'] == true;
    });
  }

  void _pickMethod(String m) {
    BlStore.set('method', m);
    setState(() => _step = 2);
  }

  void _finish() {
    BlStore.set('onboard', true);
    Navigator.of(context).pushReplacement(
        BlPageRoute(builder: (_) => const Shell()));
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
    final pad = MediaQuery.of(context).padding;
    return Scaffold(
      backgroundColor: BlColors.bg,
      body: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(25, pad.top + 28, 25, 40),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                BlIcon('flame', width: 20, height: 25, color: BlColors.red),
                const SizedBox(width: 7),
                Text.rich(TextSpan(
                  text: 'bLinker',
                  style: ts(24, w: 650, ls: -0.8),
                  children: [
                    TextSpan(
                        text: '.',
                        style: ts(24, w: 650, ls: -0.8, color: BlColors.red)),
                  ],
                )),
              ],
            ),
            const SizedBox(height: 26),
            Text('LESS WAITING. MORE SHARING.',
                style: ts(9,
                    w: 650, ls: 2.2, color: const Color(0xFFDC8B9B))),
            SizedBox(
                height: 158,
                child: Center(child: BlRadar(scale: 0.72))),
            Text.rich(
              TextSpan(
                text: 'Make room for\nconnection',
                style: ts(37, w: 650, ls: -1.65, h: 1.12),
                children: [
                  TextSpan(
                      text: '.',
                      style: ts(37,
                          w: 650, ls: -1.65, h: 1.12, color: BlColors.red)),
                ],
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 280),
              child: SizedBox(
                width: double.infinity,
                child: Text('Your people. Your files. A little closer.',
                    style: ts(12, color: BlColors.muted),
                    textAlign: TextAlign.center),
              ),
            ),
            const SizedBox(height: 25),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 19),
              decoration: BoxDecoration(
                gradient: blCardGradient,
                border: Border.all(color: const Color(0x0DFFFFFF)),
                borderRadius: BorderRadius.circular(26),
                boxShadow: const [
                  BoxShadow(
                      color: Color(0x18000000),
                      blurRadius: 28,
                      offset: Offset(0, 10)),
                ],
              ),
              child: Column(
                children: [
                  _beat1(),
                  _divider(),
                  _beat2(),
                  _divider(),
                  _beat3(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _divider() => Container(height: 1, color: BlColors.line);

  Widget _beatNum(Widget child) => Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: const Color(0x35FA8DA7)),
          color: const Color(0x12F24566),
        ),
        child: Center(child: child),
      );

  Widget _check() =>
      BlIcon('check', size: 12, color: const Color(0xFFF499AE));

  Widget _num(String n) =>
      Text(n, style: ts(9, w: 600, color: const Color(0xFFF499AE)));

  Widget _beat1() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 17),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _step > 0 ? _beatNum(_check()) : _beatNum(_num('01')),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('A familiar name', style: ts(12, w: 550)),
                  const SizedBox(height: 6),
                  Text('Your friends will see this name.',
                      style: ts(10, color: BlColors.muted)),
                  const SizedBox(height: 9),
                  TextField(
                    controller: _name,
                    enabled: _step == 0,
                    maxLength: 28,
                    style: ts(13),
                    decoration: _fieldDeco(),
                  ),
                  if (_step == 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: BlButton('That’s me',
                          full: true, onTap: _confirmName),
                    ),
                ],
              ),
            ),
          ],
        ),
      );

  Widget _beat2() => Opacity(
        opacity: _step == 0 ? 0.35 : 1,
        child: IgnorePointer(
          ignoring: _step == 0,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 17),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _step > 1 ? _beatNum(_check()) : _beatNum(_num('02')),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Your fastest connection',
                          style: ts(12, w: 550)),
                      const SizedBox(height: 6),
                      _probeLine(),
                      if (_step == 1 && _probe == 'done')
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Row(
                            children: [
                              Expanded(
                                child: BlButton('Use Fast',
                                    icon: 'bolt',
                                    onTap: _supports5
                                        ? () => _pickMethod('fast')
                                        : null),
                              ),
                              const SizedBox(width: 11),
                              Expanded(
                                child: BlButton('Use Normal',
                                    icon: 'wifi',
                                    primary: false,
                                    onTap: () => _pickMethod('normal')),
                              ),
                            ],
                          ),
                        ),
                      if (_step > 1)
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Text(
                            (BlStore.prefs['method'] == 'fast'
                                    ? 'Fast (5GHz)'
                                    : 'Normal (2.4GHz)') +
                                ' confirmed',
                            style: ts(11, color: const Color(0xFFD5A6B4)),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );

  Widget _probeLine() {
    if (_probe == 'running') {
      return Row(
        children: [
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: Color(0xFFFF8A9C),
                backgroundColor: Color(0x20FFFFFF)),
          ),
          const SizedBox(width: 7),
          Text('Checking your device…',
              style: ts(10, color: BlColors.muted)),
        ],
      );
    }
    if (_probe == 'done') {
      return Text(
        _supports5
            ? 'Your phone supports Fast mode (5GHz)'
            : 'Your device doesn’t support 5GHz hotspot',
        style: ts(10, color: BlColors.muted),
      );
    }
    return Text('A quick hardware compatibility check.',
        style: ts(10, color: BlColors.muted));
  }

  Widget _beat3() => Opacity(
        opacity: _step < 2 ? 0.35 : 1,
        child: IgnorePointer(
          ignoring: _step < 2,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 17),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _beatNum(_num('03')),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('You’re all set', style: ts(12, w: 550)),
                      const SizedBox(height: 6),
                      Text('Great things are just a tap away.',
                          style: ts(10, color: BlColors.muted)),
                      if (_step == 2)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: BlButton('Let’s share',
                              icon: 'arrowup', full: true, onTap: _finish),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
}
