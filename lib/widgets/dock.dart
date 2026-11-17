import 'dart:ui';
import 'package:flutter/material.dart';
import '../core/icons.dart';
import '../core/theme.dart';
import 'pressable.dart';

class BlDock extends StatelessWidget {
  final String? mode;
  final void Function(String mode) onMode;
  const BlDock({super.key, this.mode, required this.onMode});

  Widget _btn(String label, String icon, String m, bool active) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5),
        child: Pressable(
          onTap: () => onMode(m),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            padding: const EdgeInsets.symmetric(vertical: 15),
            decoration: active
                ? BoxDecoration(
                    gradient: blDockActiveGradient,
                    borderRadius: BorderRadius.circular(19),
                    boxShadow: const [
                      BoxShadow(
                          color: Color(0x33CF1536), blurRadius: 17),
                    ],
                  )
                : BoxDecoration(
                    borderRadius: BorderRadius.circular(19),
                  ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                BlIcon(icon,
                    size: 18,
                    color: active
                        ? Colors.white
                        : const Color(0xFFB7A8B0)),
                const SizedBox(width: 9),
                Text(
                  label,
                  style: ts(12,
                      w: 600,
                      color: active
                          ? Colors.white
                          : const Color(0xFFB7A8B0)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.of(context).padding;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        padding: EdgeInsets.fromLTRB(
            28, 22, 28, pad.bottom > 27 ? pad.bottom : 27),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0x00100D0F), Color(0xF0100D0F), BlColors.bg],
            stops: [0, 0.25, 1],
          ),
        ),
        child: Center(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(26),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: Container(
                width: 290,
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: const Color(0xD9252025),
                  borderRadius: BorderRadius.circular(26),
                  border: Border.all(color: const Color(0x15FFFFFF)),
                  boxShadow: const [
                    BoxShadow(
                        color: Color(0x80000000),
                        blurRadius: 40,
                        offset: Offset(0, 12)),
                  ],
                ),
                child: Row(
                  children: [
                    _btn('Send', 'send', 'send', mode == 'send'),
                    _btn('Receive', 'receive', 'receive', mode == 'receive'),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
