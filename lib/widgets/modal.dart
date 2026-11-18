import 'dart:ui';
import 'package:flutter/material.dart';
import '../core/theme.dart';
import 'buttons.dart';

/// bLinker's own modal - bottom-anchored card over a blurred scrim.
/// FAST: 200 ms in / 150 ms out. The [Material] wrapper (transparent) gives
/// every [Text]/[TextField] inside a proper text style - without it Flutter
/// falls back to the debug default style and draws yellow underlines under
/// the text (this only affected overlays: modals + toasts).
Future<T?> showBlModal<T>(BuildContext context, WidgetBuilder builder) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Dismiss',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 200),
    pageBuilder: (_, __, ___) => const SizedBox.shrink(),
    transitionBuilder: (ctx, anim, __, ___) {
      final curved = CurvedAnimation(
        parent: anim,
        curve: const Cubic(0.22, 1, 0.36, 1),
        reverseCurve: const Cubic(0.4, 0, 1, 1),
      );
      return BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
        child: FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: Tween(begin: const Offset(0, 0.06), end: Offset.zero)
                .animate(curved),
            child: Builder(builder: (ctx) => _ModalScope(child: builder(ctx))),
          ),
        ),
      );
    },
  );
}

class _ModalScope extends StatelessWidget {
  final Widget child;
  const _ModalScope({required this.child});
  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    return Material(
      type: MaterialType.transparency,
      child: GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        child: Container(
          color: const Color(0x8A000000),
          padding: EdgeInsets.fromLTRB(
              14, 20, 14, 20 + mq.viewInsets.bottom),
          alignment: Alignment.bottomCenter,
          child: GestureDetector(
            onTap: () {},
            child: Container(
              constraints: const BoxConstraints(maxWidth: 430, maxHeight: 600),
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: const Color(0xFF211A20),
                borderRadius: BorderRadius.circular(29),
                border: Border.all(color: const Color(0x14FFFFFF)),
                boxShadow: const [
                  BoxShadow(
                      color: Color(0x90000000),
                      blurRadius: 90,
                      offset: Offset(0, 30)),
                ],
              ),
              child: SingleChildScrollView(child: child),
            ),
          ),
        ),
      ),
    );
  }
}

class BlModalCard extends StatelessWidget {
  final String? pillIcon;
  final String? pillLabel;
  final String title;
  final String? body;
  final Widget? extra;
  final List<Widget> actions;
  const BlModalCard(
      {super.key,
      this.pillIcon,
      this.pillLabel,
      required this.title,
      this.body,
      this.extra,
      this.actions = const []});
  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Center(
            child: Container(
              width: 31,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: const Color(0x20FFFFFF),
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
          if (pillIcon != null) ...[
            BlPill(pillLabel ?? '', icon: pillIcon),
            const SizedBox(height: 8),
          ],
          Text(title, style: ts(22, w: 600, ls: -0.7)),
          if (body != null) ...[
            const SizedBox(height: 10),
            Text(body!, style: ts(12, color: BlColors.muted, h: 1.65)),
          ],
          if (extra != null) extra!,
          if (actions.isNotEmpty) ...[
            const SizedBox(height: 23),
            Row(
              children: [
                for (int i = 0; i < actions.length; i++) ...[
                  if (i > 0) const SizedBox(width: 11),
                  Expanded(child: actions[i]),
                ],
              ],
            ),
          ],
        ],
      );
}
