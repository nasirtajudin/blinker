import 'dart:math';
import 'package:flutter/material.dart';
import '../core/format.dart';
import '../core/icons.dart';
import '../core/theme.dart';
import '../services/session.dart' show BlPeer;
import 'pressable.dart';

class BlRadar extends StatefulWidget {
  final String symbol;
  final double scale;

  /// Nearby bLinker devices (Phase 4). When non-empty AND [onPeerTap] is
  /// given, the decorative satellites are replaced by tappable peer chips.
  final List<BlPeer> peers;
  final void Function(BlPeer peer)? onPeerTap;
  const BlRadar(
      {super.key,
      this.symbol = 'send',
      this.scale = 1,
      this.peers = const [],
      this.onPeerTap});
  @override
  State<BlRadar> createState() => _BlRadarState();
}

class _BlRadarState extends State<BlRadar> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 3800))
    ..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Widget _ring(double s, Color c, [Color? bg]) => Container(
        width: s,
        height: s,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: bg,
          border: Border.all(color: c),
        ),
      );

  Widget _pulse(double delay) => AnimatedBuilder(
        animation: _c,
        builder: (_, __) {
          final t = (_c.value + delay) % 1.0;
          final e = Curves.easeOut.transform(t);
          return Transform.scale(
            scale: 0.75 + 1.45 * e,
            child: Opacity(
              opacity: 0.65 * (1 - t),
              child: Container(
                width: 102,
                height: 102,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0x77EC375A)),
                ),
              ),
            ),
          );
        },
      );

  Widget _satellite(String icon) => Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: const Color(0xFF2A1B22),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: BlColors.line),
          boxShadow: const [
            BoxShadow(color: Color(0x40000000), blurRadius: 15),
          ],
        ),
        child: Center(
            child: BlIcon(icon, size: 13, color: const Color(0xFFD98E9C))),
      );

  /// Fixed satellite slots on the outer ring; deterministic per index.
  static const List<(double top, double left)> _slots = [
    (26, 168), // top right
    (128, 14), // bottom left
    (52, 10), // top left
    (140, 178), // bottom right
    (92, 0), // far left
    (96, 200), // far right
  ];

  Widget _peerChip(BlPeer p) {
    final lan = p.kind == 'lan';
    return SizedBox(
      width: 56,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: lan ? const Color(0xFF222A27) : const Color(0xFF2A1B22),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: BlColors.line),
              boxShadow: const [
                BoxShadow(color: Color(0x4D000000), blurRadius: 13),
              ],
            ),
            child: Center(
              child: lan
                  ? BlIcon('wifi', size: 13, color: const Color(0xFFB0C5B6))
                  : Text(initials(p.name),
                      style: ts(11,
                          w: 600, color: const Color(0xFFE990A1))),
            ),
          ),
          const SizedBox(height: 3),
          Text(
            p.name.length > 9 ? '${p.name.substring(0, 9)}…' : p.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ts(8, color: const Color(0xFF9A8791)),
          ),
        ],
      ),
    );
  }

  List<Widget> _peerSatellites() {
    final shown = widget.peers.take(_slots.length).toList();
    return [
      for (int i = 0; i < shown.length; i++)
        Positioned(
          top: _slots[i].$1,
          left: _slots[i].$2,
          child: Pressable(
            onTap: () => widget.onPeerTap?.call(shown[i]),
            child: _peerChip(shown[i]),
          ),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final live = widget.onPeerTap != null && widget.peers.isNotEmpty;
    final radar = SizedBox(
      width: 248,
      height: 226,
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          _ring(218, const Color(0x20E44D65)),
          _ring(164, const Color(0x2AED5265)),
          _ring(110, const Color(0x33E85169), const Color(0x0ABE1735)),
          const SizedBox(
            width: 218,
            height: 0.7,
            child: DecoratedBox(
                decoration: BoxDecoration(color: Color(0x14D83E50))),
          ),
          const RotatedBox(
            quarterTurns: 1,
            child: SizedBox(
              width: 200,
              height: 0.7,
              child: DecoratedBox(
                  decoration: BoxDecoration(color: Color(0x14D83E50))),
            ),
          ),
          _pulse(0),
          _pulse(0.5),
          Transform.rotate(
            angle: -8 * pi / 180,
            child: Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(25),
                gradient: blCoreGradient,
                border: Border.all(color: const Color(0x4DFFACB2)),
                boxShadow: const [
                  BoxShadow(color: Color(0x3DE52B49), blurRadius: 50),
                  BoxShadow(
                      color: Color(0x50000000),
                      blurRadius: 24,
                      offset: Offset(0, 12)),
                ],
              ),
              child: Center(
                child: Transform.rotate(
                  angle: 8 * pi / 180,
                  child: BlIcon(widget.symbol, size: 34, color: Colors.white),
                ),
              ),
            ),
          ),
          if (live)
            ..._peerSatellites()
          else ...[
            Positioned(
              top: 32,
              right: 41,
              child: Transform.rotate(
                  angle: 13 * pi / 180, child: _satellite('photo')),
            ),
            Positioned(
              bottom: 43,
              left: 25,
              child: Transform.rotate(
                  angle: -12 * pi / 180, child: _satellite('file')),
            ),
          ],
        ],
      ),
    );
    if (widget.scale == 1) return radar;
    return Transform.scale(scale: widget.scale, child: radar);
  }
}
