import 'package:flutter/material.dart';
import '../core/icons.dart';
import '../core/theme.dart';
import 'pressable.dart';

class BlPageHeader extends StatelessWidget {
  final String title;
  final VoidCallback onBack;
  const BlPageHeader({super.key, required this.title, required this.onBack});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 15, bottom: 28),
        child: Row(
          children: [
            Pressable(
              onTap: onBack,
              child: Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: BlColors.line),
                  color: const Color(0x04FFFFFF),
                ),
                child: Center(child: BlIcon('back', size: 18)),
              ),
            ),
            const SizedBox(width: 14),
            Text(title, style: ts(28, w: 600, ls: -1)),
          ],
        ),
      );
}
