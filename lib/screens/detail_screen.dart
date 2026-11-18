import 'package:flutter/material.dart';
import '../core/format.dart';
import '../core/theme.dart';
import '../data/store.dart';
import '../widgets/buttons.dart';
import '../widgets/file_lines.dart';
import '../widgets/page_header.dart';
import '../widgets/toast.dart';

class DetailScreen extends StatelessWidget {
  final String? id;
  final VoidCallback onBack;
  const DetailScreen({super.key, required this.id, required this.onBack});

  @override
  Widget build(BuildContext context) {
    Map<String, dynamic>? t;
    for (final h in BlStore.history) {
      if (h['id'] == id) {
        t = h;
        break;
      }
    }
    if (t == null) {
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(25, 4, 25, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            BlPageHeader(title: 'Transfer details', onBack: onBack),
            Text('This transfer is no longer stored.',
                style: ts(12, color: BlColors.muted)),
          ],
        ),
      );
    }
    final files = ((t['files'] as List?) ?? [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    final recv = t['direction'] == 'receive';
    final peer = (t['peer'] as String?) ?? '';
    final avg = ((t['avg'] as num?) ?? 0).toStringAsFixed(1);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(25, 4, 25, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          BlPageHeader(title: 'Transfer details', onBack: onBack),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 23),
            child: Column(
              children: [
                Container(
                  width: 62,
                  height: 62,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(22),
                    gradient: const LinearGradient(
                      colors: [Color(0xFF613144), Color(0xFF2A1A24)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    border: Border.all(color: const Color(0x15FFFFFF)),
                    boxShadow: const [
                      BoxShadow(
                          color: Color(0x33000000),
                          blurRadius: 25,
                          offset: Offset(0, 7)),
                    ],
                  ),
                  child: Center(
                    child: Text(initials(peer),
                        style:
                            ts(22, color: const Color(0xFFFFC0CB))),
                  ),
                ),
                const SizedBox(height: 13),
                BlPill('Completed', icon: 'check', success: true),
                const SizedBox(height: 13),
                SizedBox(
                  width: double.infinity,
                  child: Text(
                    '${recv ? 'Received from' : 'Sent to'} $peer',
                    style: ts(28, w: 600, ls: -1, h: 1.12),
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 9),
                Text(fullDate((t['date'] as String?) ?? ''),
                    style: ts(11, color: BlColors.muted)),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.all(21),
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
                _info('Files',
                    '${files.length} files · ${fmtSize((t['total'] as num?) ?? 0)}'),
                _div(),
                _info('Average speed', '$avg MB/s'),
                _div(),
                _info('Duration',
                    fmtDuration((t['duration'] as num?) ?? 0)),
                _div(),
                _info('Connection band', '${t['band'] ?? '—'}'),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(5, 25, 5, 10),
            child: Text('FILES IN THIS TRANSFER',
                style: ts(9,
                    w: 650, ls: 1.8, color: const Color(0xFFA47F8C))),
          ),
          Container(
            padding: const EdgeInsets.all(17),
            decoration: BoxDecoration(
              color: const Color(0x03FFFFFF),
              border: Border.all(color: BlColors.line),
              borderRadius: BorderRadius.circular(20),
            ),
            child: BlFileLines(files: files),
          ),
          if (recv)
            Padding(
              padding: const EdgeInsets.only(top: 20),
              child: BlButton(
                'Open folder',
                icon: 'folder',
                primary: false,
                full: true,
                onTap: () => BlToast.show(context,
                    'The folder opens after your first real transfer.'),
              ),
            ),
        ],
      ),
    );
  }

  Widget _div() => Container(height: 1, color: BlColors.line);

  Widget _info(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(k, style: ts(11, color: BlColors.muted)),
            Text(v, style: ts(11)),
          ],
        ),
      );
}
