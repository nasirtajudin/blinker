import 'package:flutter/material.dart';
import '../core/theme.dart';

class BlToast {
  static OverlayEntry? _entry;
  static void show(BuildContext context, String text) {
    _dismiss();
    final entry = OverlayEntry(builder: (_) => _ToastBubble(text: text));
    _entry = entry;
    Overlay.of(context, rootOverlay: true).insert(entry);
    Future.delayed(const Duration(milliseconds: 3500), _dismiss);
  }

  static void _dismiss() {
    _entry?.remove();
    _entry = null;
  }
}

class _ToastBubble extends StatelessWidget {
  final String text;
  const _ToastBubble({required this.text});
  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.of(context).padding;
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: EdgeInsets.only(bottom: 125 + pad.bottom),
        child: IgnorePointer(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width - 48,
            ),
            decoration: BoxDecoration(
              color: const Color(0xFF45323E),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0x14FFFFFF)),
              boxShadow: const [
                BoxShadow(
                    color: Color(0x55000000),
                    blurRadius: 20,
                    offset: Offset(0, 8)),
              ],
            ),
            child: Text(text, style: ts(11), textAlign: TextAlign.center),
          ),
        ),
      ),
    );
  }
}
