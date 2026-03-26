import 'package:flutter/material.dart';

class ThemePalette {
  const ThemePalette({
    required this.name,
    required this.primary,
    required this.secondary,
    required this.tertiary,
    required this.surface,
    required this.ink,
    required this.gold,
  });

  final String name;
  final Color primary;
  final Color secondary;
  final Color tertiary;
  final Color surface;
  final Color ink;
  final Color gold;
}

class BrandColors extends ThemeExtension<BrandColors> {
  const BrandColors({required this.ink, required this.gold});

  final Color ink;
  final Color gold;

  @override
  BrandColors copyWith({Color? ink, Color? gold}) {
    return BrandColors(ink: ink ?? this.ink, gold: gold ?? this.gold);
  }

  @override
  BrandColors lerp(ThemeExtension<BrandColors>? other, double t) {
    if (other is! BrandColors) return this;
    return BrandColors(
      ink: Color.lerp(ink, other.ink, t) ?? ink,
      gold: Color.lerp(gold, other.gold, t) ?? gold,
    );
  }
}

const List<ThemePalette> themePalettes = [
  ThemePalette(
    name: 'Marka',
    primary: Color(0xFF1A365D),
    secondary: Color(0xFFF97316),
    tertiary: Color(0xFF2DD4BF),
    surface: Color(0xFFF8FAFC),
    ink: Color(0xFF334155),
    gold: Color(0xFFFBBF24),
  ),
  ThemePalette(
    name: 'Ruby',
    primary: Color(0xFF7F1D1D),
    secondary: Color(0xFFF43F5E),
    tertiary: Color(0xFF22C55E),
    surface: Color(0xFFFFF7F7),
    ink: Color(0xFF3F1D1D),
    gold: Color(0xFFF59E0B),
  ),
  ThemePalette(
    name: 'Citrus',
    primary: Color(0xFF365314),
    secondary: Color(0xFF84CC16),
    tertiary: Color(0xFFF59E0B),
    surface: Color(0xFFFAFDF4),
    ink: Color(0xFF2F2A1A),
    gold: Color(0xFFFACC15),
  ),
  ThemePalette(
    name: 'Indigo',
    primary: Color(0xFF1E1B4B),
    secondary: Color(0xFF6366F1),
    tertiary: Color(0xFF06B6D4),
    surface: Color(0xFFF4F5FF),
    ink: Color(0xFF1E1B4B),
    gold: Color(0xFFFBBF24),
  ),
  ThemePalette(
    name: 'Ocean',
    primary: Color(0xFF0B4F6C),
    secondary: Color(0xFF3AAED8),
    tertiary: Color(0xFF2DD4BF),
    surface: Color(0xFFF2FAFF),
    ink: Color(0xFF0F172A),
    gold: Color(0xFFF59E0B),
  ),
  ThemePalette(
    name: 'Lavender',
    primary: Color(0xFF4C1D95),
    secondary: Color(0xFFC084FC),
    tertiary: Color(0xFFF59E0B),
    surface: Color(0xFFF8F5FF),
    ink: Color(0xFF3B1362),
    gold: Color(0xFFFBBF24),
  ),
  ThemePalette(
    name: 'Forest',
    primary: Color(0xFF14532D),
    secondary: Color(0xFF22C55E),
    tertiary: Color(0xFF14B8A6),
    surface: Color(0xFFF3FBF5),
    ink: Color(0xFF0F2F1C),
    gold: Color(0xFFFACC15),
  ),
  ThemePalette(
    name: 'Sand',
    primary: Color(0xFF7C4A1D),
    secondary: Color(0xFFF59E0B),
    tertiary: Color(0xFF60A5FA),
    surface: Color(0xFFFFF7ED),
    ink: Color(0xFF4A2C12),
    gold: Color(0xFFFBBF24),
  ),
  ThemePalette(
    name: 'Slate',
    primary: Color(0xFF111827),
    secondary: Color(0xFF06B6D4),
    tertiary: Color(0xFFF43F5E),
    surface: Color(0xFFF7F8FA),
    ink: Color(0xFF1F2937),
    gold: Color(0xFFF59E0B),
  ),
  ThemePalette(
    name: 'Copper',
    primary: Color(0xFF4C2C1A),
    secondary: Color(0xFFD97706),
    tertiary: Color(0xFF0EA5E9),
    surface: Color(0xFFFFF7ED),
    ink: Color(0xFF3B2F2F),
    gold: Color(0xFFFBBF24),
  ),
  ThemePalette(
    name: 'Azure',
    primary: Color(0xFF0F172A),
    secondary: Color(0xFF38BDF8),
    tertiary: Color(0xFF22C55E),
    surface: Color(0xFFF2F8FF),
    ink: Color(0xFF0F172A),
    gold: Color(0xFFFBBF24),
  ),
  ThemePalette(
    name: 'Orchid',
    primary: Color(0xFF4A044E),
    secondary: Color(0xFFDB2777),
    tertiary: Color(0xFFF59E0B),
    surface: Color(0xFFFFF5FA),
    ink: Color(0xFF2A072E),
    gold: Color(0xFFFBBF24),
  ),
];

ThemeData buildMarkaTheme(ThemePalette palette) {
  final base = ColorScheme.fromSeed(
    seedColor: palette.primary,
    brightness: Brightness.light,
  );
  final scheme = base.copyWith(
    primary: palette.primary,
    secondary: palette.secondary,
    tertiary: palette.tertiary,
    surface: palette.surface,
    onPrimary: Colors.white,
    onSecondary: Colors.white,
    onSurface: palette.ink,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: palette.surface.withValues(alpha: 0.92),
    iconTheme: IconThemeData(color: palette.primary),
    appBarTheme: AppBarTheme(
      backgroundColor: palette.primary,
      foregroundColor: Colors.white,
    ),
    cardTheme: CardThemeData(
      color: Colors.white.withValues(alpha: 0.94),
      elevation: 1,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white.withValues(alpha: 0.92),
      border: const OutlineInputBorder(),
    ),
    textTheme: Typography.material2021().black.apply(
      bodyColor: palette.ink,
      displayColor: palette.ink,
    ),
    extensions: <ThemeExtension<dynamic>>[
      BrandColors(ink: palette.ink, gold: palette.gold),
    ],
  );
}
