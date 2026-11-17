import 'package:flutter/material.dart';
import '../core/format.dart';
import '../core/icons.dart';
import '../core/theme.dart';
import '../data/store.dart';
import '../widgets/buttons.dart';
import '../widgets/pressable.dart';
import '../widgets/radar.dart';

class HomeScreen extends StatelessWidget {
  final bool historyAll;
  final VoidCallback onHistoryAll;
  final void Function(String id) onDetail;
  const HomeScreen(
      {super.key,
      required this.historyAll,
      required this.onHistoryAll,
      required this.onDetail});

  @override
  Widget build(BuildContext context) {
    final history = BlStore.history;
    final rows = historyAll ? history : history.take(3).toList();
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(25, 8, 25, 176),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _hero(),
          const SizedBox(height: 34),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(historyAll ? 'All transfers' : 'Recent transfers',
                  style: ts(16, w: 600, ls: -0.3)),
              BlTextButton(historyAll ? 'Show less' : 'See all',
                  icon: 'chevron', onTap: onHistoryAll),
            ],
          ),
          const SizedBox(height: 13),
          if (rows.isEmpty) _empty() else _rows(rows),
          const SizedBox(height: 21),
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                BlIcon('shield', size: 11, color: const Color(0xFF6E5E66)),
                const SizedBox(width: 5),
                Text('Direct connection. Just between you two.',
                    style: ts(9, color: const Color(0xFF6E5E66))),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _hero() => Column(
        children: [
          const SizedBox(height: 25),
          Text('A little closer. A lot faster.'.toUpperCase(),
              style: ts(9, w: 650, ls: 2.2, color: const Color(0xFFDC8B9B))),
          const SizedBox(height: 13),
          const BlRadar(),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: Text.rich(
              TextSpan(
                text: 'Ready to share',
                style: ts(36, w: 650, ls: -1.65, h: 1.12),
                children: [
                  TextSpan(
                      text: '.',
                      style: ts(36,
                          w: 650,
                          ls: -1.65,
                          h: 1.12,
                          color: BlColors.red)),
                ],
              ),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 9),
          SizedBox(
            width: double.infinity,
            child: Text('Good things are better shared.',
                style: ts(12, color: BlColors.muted),
                textAlign: TextAlign.center),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const BlDot(color: Color(0xFFF17B8D)),
              const SizedBox(width: 7),
              Text('Your next connection is nearby',
                  style: ts(10, color: const Color(0xFFA6939C))),
            ],
          ),
        ],
      );

  Widget _rows(List<Map<String, dynamic>> rows) => Column(
        children: [
          for (int i = 0; i < rows.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            _row(rows[i]),
          ],
        ],
      );

  Widget _row(Map<String, dynamic> t) {
    final recv = t['direction'] == 'receive';
    final files = ((t['files'] as List?) ?? []).length;
    final avg = ((t['avg'] as num?) ?? 0).toStringAsFixed(1);
    return Pressable(
      onTap: () => onDetail((t['id'] as String?) ?? ''),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 14),
        decoration: BoxDecoration(
          color: const Color(0x03FFFFFF),
          border: Border.all(color: BlColors.line),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: recv
                    ? const Color(0xFF222A27)
                    : const Color(0xFF302129),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Center(
                child: Text(
                  initials((t['peer'] as String?) ?? ''),
                  style: ts(13,
                      w: 600,
                      color: recv
                          ? const Color(0xFFB0C5B6)
                          : const Color(0xFFE990A1)),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text((t['peer'] as String?) ?? '',
                      style: ts(12, w: 550),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 5),
                  Row(
                    children: [
                      BlIcon(recv ? 'arrowdown' : 'arrowup',
                          size: 12, color: const Color(0xFFDA8497)),
                      const SizedBox(width: 3),
                      Text(
                          '$files files · ${fmtSize((t['total'] as num?) ?? 0)}',
                          style: ts(10, color: BlColors.muted)),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('$avg MB/s',
                    style: ts(11,
                        w: 500, color: const Color(0xFFD4C8CE))),
                const SizedBox(height: 4),
                Text(dateText((t['date'] as String?) ?? ''),
                    style: ts(10, color: BlColors.muted)),
              ],
            ),
            const SizedBox(width: 8),
            BlIcon('chevron', size: 15),
          ],
        ),
      ),
    );
  }

  Widget _empty() => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 27),
        child: CustomPaint(
          foregroundPainter: _DashPainter(22),
          child: Column(
            children: [
              const SizedBox(height: 4),
              BlIcon('layers', size: 30, color: const Color(0xFFA95B6E)),
              const SizedBox(height: 9),
              Text('Your transfers will appear here.',
                  style: ts(12, color: BlColors.muted)),
              const SizedBox(height: 4),
              Text('A little less waiting. A lot more sharing.',
                  style: ts(11, color: BlColors.muted)),
            ],
          ),
        ),
      );
}

class _DashPainter extends CustomPainter {
  final double radius;
  _DashPainter(this.radius);
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0x14FFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(
          Offset.zero & size, Radius.circular(radius)));
    for (final metric in path.computeMetrics()) {
      double d = 0;
      bool draw = true;
      while (d < metric.length) {
        if (draw) {
          canvas.drawPath(
              metric.extractPath(
                  d, (d + 6).clamp(0.0, metric.length).toDouble()),
              paint);
        }
        d += 6;
        draw = !draw;
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
