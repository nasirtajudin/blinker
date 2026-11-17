import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'theme.dart';

const Map<String, String> _paths = {
  'flame': 'M13 2c1 5-3 5-2 9 1-1 2-2 2-4 5 4 7 7 5 11-1 3-4 4-6 4-5 0-8-4-7-8 1-3 3-5 4-7 0 3 1 4 2 4-1-4 0-6 2-9Z',
  'send': 'm4 12 16-8-6 16-3-7-7-1Zm7 1 9-9',
  'receive': 'M12 3v12m-5-5 5 5 5-5M5 17v4h14v-4',
  'gear': 'm9 2-.6 2.5-2 1.2L4 5l-3 5 2 1.7v2.6L1 16l3 5 2.4-.7 2 1.2L9 24h6l.6-2.5 2-1.2 2.4.7 3-5-2-1.7v-2.6L23 10l-3-5-2.4.7-2-1.2L15 2H9Z',
  'bolt': 'm13 2-8 12h6l-1 8 9-12h-6l1-8',
  'arrowup': 'M7 17 17 7M7 7h10v10',
  'arrowdown': 'M17 7 7 17M7 7v10h10',
  'chevron': 'm9 5 7 7-7 7',
  'back': 'm14 5-7 7 7 7',
  'check': 'm5 12 4 4L19 6',
  'x': 'm6 6 12 12M18 6 6 18',
  'folder': 'M3 6h7l2 2h9v12H3V6Z',
  'file': 'M6 3h8l4 4v14H6V3Zm8 0v5h5M9 13h6m-6 4h4',
  'photo': 'M3 4h18v16H3V4Zm0 12 5-5 4 4 3-3 6 5M16 8h.01',
  'music': 'M9 18V5l11-2v13M9 5v4l11-2M9 18c0 3-6 4-6 1s6-4 6-1Zm11-2c0 3-6 4-6 1s6-4 6-1Z',
  'video': 'M3 5h13v14H3V5Zm13 5 5-3v10l-5-3',
  'wifi': 'M3 9a15 15 0 0 1 18 0M6 13a10 10 0 0 1 12 0m-9 4a5 5 0 0 1 6 0m-3 3h.01',
  'shield': 'm12 2 8 4v6c0 5-8 10-8 10S4 17 4 12V6l8-4Zm-4 9 3 3 5-5',
  'lock': 'M6 10h12v11H6V10Zm3 0V6a3 3 0 0 1 6 0v4',
  'phone': 'M7 2h10v20H7V2Zm4 17h2',
  'battery': 'M3 7h16v10H3V7Zm18 3v4M6 10h10v4H6v-4',
  'signal': 'M4 20v-3m5 3v-7m5 7V9m5 11V4',
  'alert': 'm12 3 10 18H2L12 3Zm0 6v5m0 3v.1',
  'clock': 'M22 12A10 10 0 1 1 2 12a10 10 0 0 1 20 0ZM12 6v6l4 2',
  'info': 'M22 12A10 10 0 1 1 2 12a10 10 0 0 1 20 0ZM12 11v6m0-10v.1',
  'link': 'm10 14 4-4M8 16l-1 1a4 4 0 0 1-6-6l5-5a4 4 0 0 1 6 0m0 12a4 4 0 0 0 6 0l5-5a4 4 0 0 0-6-6l-1 1',
  'trash': 'M3 6h18M5 6l1 15h12l1-15M9 6V3h6v3m-5 4v7m4-7v7',
  'bell': 'M5 17h14l-2-3V8A5 5 0 0 0 7 8v6l-2 3Zm5 3h4',
  'layers': 'm12 3 10 5-10 5L2 8l10-5ZM2 12l10 5 10-5M2 16l10 5 10-5',
  'refresh': 'M20 7V2l-4 4A9 9 0 1 0 21 15M20 2h-5',
};

String _svg(String n, Color c) {
  final hex = '#${(c.value & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
  final gear = n == 'gear' ? '<circle cx="12" cy="13" r="3"/>' : '';
  return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" '
      'stroke="$hex" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">'
      '<path d="${_paths[n] ?? _paths['file']!}"/>$gear</svg>';
}

class BlIcon extends StatelessWidget {
  final String name;
  final double size;
  final double? width;
  final double? height;
  final Color color;
  const BlIcon(this.name,
      {super.key, this.size = 22, this.width, this.height, this.color = BlColors.text});
  @override
  Widget build(BuildContext context) => SvgPicture.string(_svg(name, color),
      width: width ?? size, height: height ?? size);
}
