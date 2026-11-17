import 'package:flutter/material.dart';

abstract final class BlColors {
  static const bg = Color(0xFF100D0F);
  static const bgDeep = Color(0xFF0A080A);
  static const surface = Color(0xFF1D191C);
  static const surface2 = Color(0xFF262024);
  static const line = Color(0x12FFFFFF);
  static const lineFaint = Color(0x0DFFFFFF);
  static const text = Color(0xFFFBF5F6);
  static const muted = Color(0xFFA89BA1);
  static const red = Color(0xFFFF4057);
  static const red2 = Color(0xFFD6193A);
  static const green = Color(0xFFA4D5BB);
  static const pink = Color(0xFFFFA0AB);
  static const pinkDeep = Color(0xFFF17B8D);
}

const blPrimaryGradient = LinearGradient(
  colors: [Color(0xFFFF4B5F), Color(0xFFD7193C)],
  begin: Alignment(-0.4, -1),
  end: Alignment(0.6, 1),
);
const blCoreGradient = LinearGradient(
  colors: [Color(0xFFFF596F), Color(0xFFB50E30)],
  begin: Alignment(-0.6, -0.8),
  end: Alignment(0.8, 1),
);
const blCardGradient = LinearGradient(
  colors: [Color(0xFF262024), Color(0xFF1C181B)],
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
);
const blDockActiveGradient = LinearGradient(
  colors: [Color(0xFFFF4A63), Color(0xFFD41C3E)],
  begin: Alignment(-0.5, -0.85),
  end: Alignment(0.55, 0.85),
);

FontWeight _fw(double w) =>
    FontWeight.values[(((w / 100).round()) - 1).clamp(0, 8)];

TextStyle ts(
  double size, {
  double w = 400,
  Color color = BlColors.text,
  double ls = 0,
  double h = 1.5,
}) {
  final style = TextStyle(
    fontFamily: 'Inter',
    fontSize: size,
    color: color,
    letterSpacing: ls,
    height: h,
    fontWeight: _fw(w),
  );
  if (w % 100 != 0) return style.copyWith(fontVariations: [FontVariation('wght', w)]);
  return style;
}

ThemeData buildBlTheme() => ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      fontFamily: 'Inter',
      scaffoldBackgroundColor: BlColors.bg,
      splashFactory: NoSplash.splashFactory,
      colorScheme: const ColorScheme.dark(
        primary: BlColors.red,
        surface: BlColors.bg,
      ),
    );
