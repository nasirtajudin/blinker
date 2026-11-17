import 'package:flutter/material.dart';
import '../core/theme.dart';
import '../data/store.dart';
import '../services/engine.dart';
import '../widgets/buttons.dart';
import '../widgets/page_header.dart';

class DiagnosticsScreen extends StatelessWidget {
  final VoidCallback onBack;
  const DiagnosticsScreen({super.key, required this.onBack});

  @override
  Widget build(BuildContext context) {
    final supports5 = BlEngine.supports5GHz;
    final p2p = BlEngine.p2p;
    final android = BlEngine.android;
    final last = BlStore.last;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(25, 4, 25, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          BlPageHeader(title: 'Diagnostics', onBack: onBack),
          const BlNotice(
              'Hardware values below are probed live on this device. Last-session values appear after your first transfer.'),
          const SizedBox(height: 23),
          _title('Hardware probe'),
          _group([
            _probe('5GHz AP support',
                supports5 ? 'SUPPORTED' : 'NOT SUPPORTED'),
            _probe('P2P support', p2p ? 'SUPPORTED' : 'UNAVAILABLE'),
            _probe(
                'Android tier',
                android > 0
                    ? 'Android $android${android >= 13 ? ' · modern' : ' · legacy'}'
                    : '—'),
          ]),
          _title('Last session · actual negotiated result'),
          _group([
            _probe('Connection band',
                last != null ? '${last['band'] ?? '—'}' : 'NO SESSION YET'),
            _probe(
                'Transfer speed',
                last != null
                    ? '${((last['avg'] as num?) ?? 0).toStringAsFixed(1)} MB/s'
                    : '—'),
            _probe(
                'Requested → negotiated',
                last != null
                    ? '${last['requested'] ?? '—'} → ${last['method'] ?? '—'}'
                    : '—'),
            _probe(
                'Peer Android / 5GHz AP',
                last != null
                    ? 'Android ${last['peerAndroid'] ?? '—'} / ${last['peer5'] == true ? 'YES' : 'NO'}'
                    : '—'),
          ]),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text(
                  'Transfer details appear here after your first session.',
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

  Widget _title(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(5, 25, 5, 10),
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

  Widget _probe(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Row(
          children: [
            Flexible(child: Text(label, style: ts(11, color: BlColors.muted))),
            const SizedBox(width: 12),
            Text(value,
                style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                    fontFamily: 'monospace',
                    color: BlColors.text)),
          ],
        ),
      );
}
