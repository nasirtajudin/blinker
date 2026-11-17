import 'package:flutter/material.dart';
import '../core/icons.dart';
import '../core/theme.dart';
import 'pressable.dart';

class BlTopBar extends StatelessWidget {
  final String name;
  final String method;
  final VoidCallback onName;
  final VoidCallback onMethod;
  final VoidCallback onSettings;
  const BlTopBar(
      {super.key,
      required this.name,
      required this.method,
      required this.onName,
      required this.onMethod,
      required this.onSettings});

  Widget _iconBtn(String icon, VoidCallback onTap) => Pressable(
        onTap: onTap,
        child: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: BlColors.line),
            color: const Color(0x04FFFFFF),
          ),
          child: Center(child: BlIcon(icon, size: 18)),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.of(context).padding;
    final fast = method == 'fast';
    return Padding(
      padding: EdgeInsets.only(top: pad.top > 12 ? pad.top : 12),
      child: SizedBox(
        height: 67,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 23),
          child: Row(
            children: [
              Row(
                children: [
                  BlIcon('flame',
                      width: 20, height: 25, color: BlColors.red),
                  const SizedBox(width: 7),
                  Text.rich(TextSpan(
                    text: 'bLinker',
                    style: ts(19, w: 650, ls: -0.8),
                    children: [
                      TextSpan(
                          text: '.',
                          style: ts(19,
                              w: 650,
                              ls: -0.8,
                              color: const Color(0xFFFF5069))),
                    ],
                  )),
                ],
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Center(
                  child: Pressable(
                    onTap: onName,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 130),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 13, vertical: 9),
                        decoration: BoxDecoration(
                          color: const Color(0x08FFFFFF),
                          border: Border.all(color: BlColors.line),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: ts(12),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Pressable(
                onTap: onMethod,
                child: Row(
                  children: [
                    BlIcon(fast ? 'bolt' : 'wifi',
                        size: 12, color: BlColors.pink),
                    const SizedBox(width: 4),
                    Text(
                      fast ? 'FAST 5G' : 'NORMAL',
                      style: ts(8, w: 700, ls: 1, color: BlColors.pink),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 9),
              _iconBtn('gear', onSettings),
            ],
          ),
        ),
      ),
    );
  }
}
