import 'package:flutter/material.dart';
import '../core/format.dart';
import '../core/icons.dart';
import '../core/theme.dart';

class BlFileLines extends StatelessWidget {
  final List<Map<String, dynamic>> files;
  const BlFileLines({super.key, required this.files});
  @override
  Widget build(BuildContext context) => Column(
        children: [
          for (final f in files)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 11),
              child: Row(
                children: [
                  BlIcon(
                    (f['type'] as String?) ?? 'file',
                    size: 17,
                    color: const Color(0xFFD47C91),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      (f['name'] as String?) ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ts(11),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    fmtSize((f['size'] as num?) ?? 0),
                    style: ts(10, color: BlColors.muted),
                  ),
                ],
              ),
            ),
        ],
      );
}
