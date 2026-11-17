import 'package:flutter/material.dart';
import '../core/icons.dart';
import '../core/theme.dart';
import 'pressable.dart';

class BlButton extends StatelessWidget {
  final String label;
  final String? icon;
  final bool primary;
  final bool full;
  final VoidCallback? onTap;
  const BlButton(this.label,
      {super.key, this.icon, this.primary = true, this.full = false, this.onTap});

  @override
  Widget build(BuildContext context) {
    final child = Container(
      width: full ? double.infinity : null,
      padding: const EdgeInsets.symmetric(horizontal: 19, vertical: 16),
      constraints: const BoxConstraints(minHeight: 49),
      decoration: primary
          ? const BoxDecoration(
              gradient: blPrimaryGradient,
              borderRadius: BorderRadius.all(Radius.circular(17)),
              boxShadow: [
                BoxShadow(
                    color: Color(0x26DF1933),
                    blurRadius: 25,
                    offset: Offset(0, 8)),
              ],
            )
          : BoxDecoration(
              color: Color(0x08FFFFFF),
              borderRadius: const BorderRadius.all(Radius.circular(17)),
              border: Border.all(color: const Color(0x12FFFFFF)),
            ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (icon != null) ...[
            BlIcon(icon!, size: 17),
            const SizedBox(width: 9),
          ],
          Flexible(
            child: Text(label,
                style: ts(13, w: 600), textAlign: TextAlign.center),
          ),
        ],
      ),
    );
    return Opacity(
      opacity: onTap != null ? 1 : 0.35,
      child: Pressable(onTap: onTap, child: child),
    );
  }
}

class BlTextButton extends StatelessWidget {
  final String label;
  final String? icon;
  final VoidCallback? onTap;
  const BlTextButton(this.label, {super.key, this.icon, this.onTap});
  @override
  Widget build(BuildContext context) => Pressable(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label, style: ts(11, color: BlColors.pinkDeep)),
              if (icon != null) ...[
                const SizedBox(width: 4),
                BlIcon(icon!, size: 11, color: BlColors.pinkDeep),
              ],
            ],
          ),
        ),
      );
}

class BlPill extends StatelessWidget {
  final String label;
  final String? icon;
  final Color? color;
  final bool success;
  const BlPill(this.label, {super.key, this.icon, this.color, this.success = false});
  @override
  Widget build(BuildContext context) {
    final c = color ??
        (success ? BlColors.green : const Color(0xFFC7BAC0));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(9),
        border: Border.all(
            color: success
                ? const Color(0x22A4D5BB)
                : BlColors.line),
        color: success ? const Color(0x08A4D5BB) : const Color(0x04FFFFFF),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            BlIcon(icon!, size: 12, color: c),
            const SizedBox(width: 6),
          ],
          Text(label, style: ts(10, color: c)),
        ],
      ),
    );
  }
}

class BlDot extends StatelessWidget {
  final Color color;
  const BlDot({super.key, this.color = BlColors.green});
  @override
  Widget build(BuildContext context) => Container(
        width: 5,
        height: 5,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          boxShadow: [BoxShadow(color: color.withValues(alpha: 0.27), blurRadius: 9)],
        ),
      );
}

class BlNotice extends StatelessWidget {
  final String text;
  const BlNotice(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0x2AFA5362)),
          color: const Color(0x10E84050),
        ),
        child: Text(text,
            style: ts(11, color: const Color(0xFFF3A0AD), h: 1.6)),
      );
}
