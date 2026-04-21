import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:shared_preferences/shared_preferences.dart';

enum AppThemeMode {
  navy,
  rose,
  emerald,
  lavender,
  sunset,
  charcoal,
  blush,
  pearl,
  royal,
  slate,
  mocha,
  olive,
  sky,
  berry,

  // New themes
  mint,
  ocean,
  coral,
  midnight,
  gold,
  ruby,
  forest,
  aqua,
  sand,
  plum,
  steel,
  ice,
  candy,
  terracotta,
  lemon,
  orchid,
  teal,
  cocoa,
}

enum AppFontMode { system, modern, elegant, rounded, mono }

class AppPalette {
  const AppPalette({
    required this.primary,
    required this.accent,
    required this.text,
    required this.appBg,
    required this.cardBg,
    required this.border,
    required this.soft,
  });

  final Color primary;
  final Color accent;
  final Color text;
  final Color appBg;
  final Color cardBg;
  final Color border;
  final Color soft;

  AppPalette copyWith({
    Color? primary,
    Color? accent,
    Color? text,
    Color? appBg,
    Color? cardBg,
    Color? border,
    Color? soft,
  }) {
    return AppPalette(
      primary: primary ?? this.primary,
      accent: accent ?? this.accent,
      text: text ?? this.text,
      appBg: appBg ?? this.appBg,
      cardBg: cardBg ?? this.cardBg,
      border: border ?? this.border,
      soft: soft ?? this.soft,
    );
  }
}

class AppThemeController extends ChangeNotifier {
  static const String _themePrefsKey = 'selected_app_theme';
  static const String _fontPrefsKey = 'selected_app_font';

  AppThemeMode _mode = AppThemeMode.navy;
  AppFontMode _fontMode = AppFontMode.system;

  AppThemeMode get mode => _mode;
  AppFontMode get fontMode => _fontMode;

  static const AppPalette _websitePalette = AppPalette(
    primary: Color(0xFF0E7C86),
    accent: Color(0xFFBF5D39),
    text: Color(0xFF213038),
    appBg: Color(0xFFF6F2E8),
    cardBg: Color(0xFFFFFCF5),
    border: Color(0xFFD8CFC1),
    soft: Color(0xFFECE4D7),
  );

  AppPalette get palette => kIsWeb ? _websitePalette : _paletteFromMode(_mode);

  String? get selectedFontFamily => _fontFamilyFromMode(_fontMode);

  ThemeData get themeData {
    final p = palette;
    final fontFamily = selectedFontFamily;

    final colorScheme = ColorScheme.fromSeed(
      seedColor: p.primary,
      brightness: Brightness.light,
      primary: p.primary,
      secondary: p.accent,
      surface: p.cardBg,
      onPrimary: Colors.white,
      onSecondary: Colors.white,
      onSurface: p.text,
      outline: p.border,
      error: const Color(0xFFB00020),
    );

    final baseTextTheme = ThemeData.light().textTheme.apply(
      bodyColor: p.text,
      displayColor: p.text,
      fontFamily: fontFamily,
    );

    return ThemeData(
      useMaterial3: true,
      fontFamily: fontFamily,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: p.appBg,
      canvasColor: p.appBg,
      cardColor: p.cardBg,
      appBarTheme: AppBarTheme(
        backgroundColor: p.cardBg,
        foregroundColor: p.primary,
        elevation: 0,
        surfaceTintColor: p.cardBg,
        titleTextStyle: TextStyle(
          color: p.primary,
          fontSize: 20,
          fontWeight: FontWeight.w800,
          fontFamily: fontFamily,
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: p.accent,
        foregroundColor: Colors.white,
      ),
      textTheme: baseTextTheme.copyWith(
        headlineLarge: baseTextTheme.headlineLarge?.copyWith(
          fontWeight: FontWeight.w800,
          color: p.text,
        ),
        headlineMedium: baseTextTheme.headlineMedium?.copyWith(
          fontWeight: FontWeight.w800,
          color: p.text,
        ),
        titleLarge: baseTextTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
          color: p.text,
        ),
        titleMedium: baseTextTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w700,
          color: p.text,
        ),
        bodyLarge: baseTextTheme.bodyLarge?.copyWith(color: p.text),
        bodyMedium: baseTextTheme.bodyMedium?.copyWith(color: p.text),
        labelLarge: baseTextTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w700,
          color: p.text,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: p.cardBg,
        hintStyle: TextStyle(
          color: p.text.withValues(alpha: 0.55),
          fontFamily: fontFamily,
        ),
        labelStyle: TextStyle(color: p.text, fontFamily: fontFamily),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: p.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: p.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: p.accent, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: p.cardBg,
        indicatorColor: p.soft,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            color: states.contains(WidgetState.selected) ? p.primary : p.text,
            fontWeight: FontWeight.w700,
            fontFamily: fontFamily,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected) ? p.primary : p.text,
          ),
        ),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: p.primary,
        unselectedLabelColor: p.text.withValues(alpha: 0.65),
        indicatorColor: p.primary,
        labelStyle: TextStyle(
          fontWeight: FontWeight.w700,
          fontFamily: fontFamily,
        ),
        unselectedLabelStyle: TextStyle(
          fontWeight: FontWeight.w600,
          fontFamily: fontFamily,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: p.primary,
        contentTextStyle: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontFamily: fontFamily,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: p.primary,
          foregroundColor: Colors.white,
          textStyle: TextStyle(
            fontWeight: FontWeight.w700,
            fontFamily: fontFamily,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: p.primary,
          side: BorderSide(color: p.border),
          textStyle: TextStyle(
            fontWeight: FontWeight.w700,
            fontFamily: fontFamily,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      cardTheme: CardThemeData(
        color: p.cardBg,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: p.border),
        ),
      ),
      dividerColor: p.border,
    );
  }

  Future<void> loadSavedTheme() async {
    final prefs = await SharedPreferences.getInstance();

    final rawTheme = prefs.getString(_themePrefsKey);
    final rawFont = prefs.getString(_fontPrefsKey);

    _mode = AppThemeMode.values.firstWhere(
      (e) => e.name == rawTheme,
      orElse: () => AppThemeMode.navy,
    );

    _fontMode = AppFontMode.values.firstWhere(
      (e) => e.name == rawFont,
      orElse: () => AppFontMode.system,
    );

    notifyListeners();
  }

  Future<void> setTheme(AppThemeMode mode) async {
    if (_mode == mode) return;

    _mode = mode;
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themePrefsKey, mode.name);
  }

  Future<void> setFont(AppFontMode fontMode) async {
    if (_fontMode == fontMode) return;

    _fontMode = fontMode;
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_fontPrefsKey, fontMode.name);
  }

  Future<void> resetToDefault() async {
    _mode = AppThemeMode.navy;
    _fontMode = AppFontMode.system;
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themePrefsKey, _mode.name);
    await prefs.setString(_fontPrefsKey, _fontMode.name);
  }

  String? _fontFamilyFromMode(AppFontMode mode) {
    switch (mode) {
      case AppFontMode.system:
        return null;
      case AppFontMode.modern:
        return 'Roboto';
      case AppFontMode.elegant:
        return 'Georgia';
      case AppFontMode.rounded:
        return 'Trebuchet MS';
      case AppFontMode.mono:
        return 'Courier New';
    }
  }

  AppPalette paletteForMode(AppThemeMode mode) {
    if (kIsWeb) return _websitePalette;
    return _paletteFromMode(mode);
  }

  String themeTitle(AppThemeMode mode) {
    switch (mode) {
      case AppThemeMode.navy:
        return 'Navy Classic';
      case AppThemeMode.rose:
        return 'Rose Soft';
      case AppThemeMode.emerald:
        return 'Emerald Fresh';
      case AppThemeMode.lavender:
        return 'Lavender Glow';
      case AppThemeMode.sunset:
        return 'Sunset Warm';
      case AppThemeMode.charcoal:
        return 'Charcoal Cool';
      case AppThemeMode.blush:
        return 'Blush Pink';
      case AppThemeMode.pearl:
        return 'Pearl Bloom';
      case AppThemeMode.royal:
        return 'Royal Blue';
      case AppThemeMode.slate:
        return 'Slate Calm';
      case AppThemeMode.mocha:
        return 'Mocha Earth';
      case AppThemeMode.olive:
        return 'Olive Leaf';
      case AppThemeMode.sky:
        return 'Sky Light';
      case AppThemeMode.berry:
        return 'Berry Pop';
      case AppThemeMode.mint:
        return 'Mint Breeze';
      case AppThemeMode.ocean:
        return 'Ocean Deep';
      case AppThemeMode.coral:
        return 'Coral Glow';
      case AppThemeMode.midnight:
        return 'Midnight Ink';
      case AppThemeMode.gold:
        return 'Golden Shine';
      case AppThemeMode.ruby:
        return 'Ruby Red';
      case AppThemeMode.forest:
        return 'Forest Green';
      case AppThemeMode.aqua:
        return 'Aqua Splash';
      case AppThemeMode.sand:
        return 'Sand Soft';
      case AppThemeMode.plum:
        return 'Plum Rich';
      case AppThemeMode.steel:
        return 'Steel Modern';
      case AppThemeMode.ice:
        return 'Ice Blue';
      case AppThemeMode.candy:
        return 'Candy Pink';
      case AppThemeMode.terracotta:
        return 'Terracotta Warm';
      case AppThemeMode.lemon:
        return 'Lemon Bright';
      case AppThemeMode.orchid:
        return 'Orchid Glow';
      case AppThemeMode.teal:
        return 'Teal Fresh';
      case AppThemeMode.cocoa:
        return 'Cocoa Cozy';
    }
  }

  String themeSubtitle(AppThemeMode mode) {
    switch (mode) {
      case AppThemeMode.navy:
        return 'Clean professional blue';
      case AppThemeMode.rose:
        return 'Light pink girly look';
      case AppThemeMode.emerald:
        return 'Modern green style';
      case AppThemeMode.lavender:
        return 'Purple soft feminine look';
      case AppThemeMode.sunset:
        return 'Orange warm elegant look';
      case AppThemeMode.charcoal:
        return 'Dark grey with cyan accent';
      case AppThemeMode.blush:
        return 'Soft romantic pink';
      case AppThemeMode.pearl:
        return 'Delicate rosy elegance';
      case AppThemeMode.royal:
        return 'Bold rich blue';
      case AppThemeMode.slate:
        return 'Minimal cool grey';
      case AppThemeMode.mocha:
        return 'Warm brown neutral';
      case AppThemeMode.olive:
        return 'Natural earthy green';
      case AppThemeMode.sky:
        return 'Fresh airy blue';
      case AppThemeMode.berry:
        return 'Playful purple tone';
      case AppThemeMode.mint:
        return 'Fresh minty calm';
      case AppThemeMode.ocean:
        return 'Cool ocean energy';
      case AppThemeMode.coral:
        return 'Soft coral warmth';
      case AppThemeMode.midnight:
        return 'Dark refined contrast';
      case AppThemeMode.gold:
        return 'Luxury golden warmth';
      case AppThemeMode.ruby:
        return 'Elegant red style';
      case AppThemeMode.forest:
        return 'Deep natural green';
      case AppThemeMode.aqua:
        return 'Bright aqua freshness';
      case AppThemeMode.sand:
        return 'Soft sandy neutral';
      case AppThemeMode.plum:
        return 'Rich purple mood';
      case AppThemeMode.steel:
        return 'Modern steel grey';
      case AppThemeMode.ice:
        return 'Light cool blue';
      case AppThemeMode.candy:
        return 'Sweet lively pink';
      case AppThemeMode.terracotta:
        return 'Warm clay tone';
      case AppThemeMode.lemon:
        return 'Bright cheerful yellow';
      case AppThemeMode.orchid:
        return 'Soft floral purple';
      case AppThemeMode.teal:
        return 'Clean teal balance';
      case AppThemeMode.cocoa:
        return 'Cozy chocolate warmth';
    }
  }

  AppPalette _paletteFromMode(AppThemeMode mode) {
    switch (mode) {
      case AppThemeMode.rose:
        return const AppPalette(
          primary: Color(0xFFB83B78),
          accent: Color(0xFFFF8FB1),
          text: Color(0xFF3F2A35),
          appBg: Color(0xFFFFF3F7),
          cardBg: Colors.white,
          border: Color(0xFFF2C7D4),
          soft: Color(0xFFFFE2EA),
        );

      case AppThemeMode.emerald:
        return const AppPalette(
          primary: Color(0xFF0F766E),
          accent: Color(0xFF22C55E),
          text: Color(0xFF1F2E2C),
          appBg: Color(0xFFF2FBF8),
          cardBg: Colors.white,
          border: Color(0xFFCDEBE1),
          soft: Color(0xFFDDF7EE),
        );

      case AppThemeMode.lavender:
        return const AppPalette(
          primary: Color(0xFF6D4CC9),
          accent: Color(0xFFA78BFA),
          text: Color(0xFF312C4A),
          appBg: Color(0xFFF6F3FF),
          cardBg: Colors.white,
          border: Color(0xFFDDD4FF),
          soft: Color(0xFFEDE7FF),
        );

      case AppThemeMode.sunset:
        return const AppPalette(
          primary: Color(0xFF9A3412),
          accent: Color(0xFFF97316),
          text: Color(0xFF4A2C21),
          appBg: Color(0xFFFFF7ED),
          cardBg: Colors.white,
          border: Color(0xFFFED7AA),
          soft: Color(0xFFFFEDD5),
        );

      case AppThemeMode.charcoal:
        return const AppPalette(
          primary: Color(0xFF1F2937),
          accent: Color(0xFF06B6D4),
          text: Color(0xFF1F2937),
          appBg: Color(0xFFF3F4F6),
          cardBg: Colors.white,
          border: Color(0xFFD1D5DB),
          soft: Color(0xFFE5E7EB),
        );

      case AppThemeMode.blush:
        return const AppPalette(
          primary: Color(0xFFC0266D),
          accent: Color(0xFFF9A8D4),
          text: Color(0xFF4A2235),
          appBg: Color(0xFFFFF1F7),
          cardBg: Colors.white,
          border: Color(0xFFFBCFE8),
          soft: Color(0xFFFDE7F3),
        );

      case AppThemeMode.pearl:
        return const AppPalette(
          primary: Color(0xFF9D174D),
          accent: Color(0xFFF472B6),
          text: Color(0xFF4B2A39),
          appBg: Color(0xFFFFF7FB),
          cardBg: Colors.white,
          border: Color(0xFFF5D0E6),
          soft: Color(0xFFFCE7F3),
        );

      case AppThemeMode.royal:
        return const AppPalette(
          primary: Color(0xFF1D4ED8),
          accent: Color(0xFF60A5FA),
          text: Color(0xFF1E293B),
          appBg: Color(0xFFF4F8FF),
          cardBg: Colors.white,
          border: Color(0xFFBFDBFE),
          soft: Color(0xFFDBEAFE),
        );

      case AppThemeMode.slate:
        return const AppPalette(
          primary: Color(0xFF334155),
          accent: Color(0xFF0EA5E9),
          text: Color(0xFF1F2937),
          appBg: Color(0xFFF8FAFC),
          cardBg: Colors.white,
          border: Color(0xFFCBD5E1),
          soft: Color(0xFFE2E8F0),
        );

      case AppThemeMode.mocha:
        return const AppPalette(
          primary: Color(0xFF6F4E37),
          accent: Color(0xFFD4A373),
          text: Color(0xFF3E2C23),
          appBg: Color(0xFFFCF8F5),
          cardBg: Colors.white,
          border: Color(0xFFE7D7C9),
          soft: Color(0xFFF3E8E0),
        );

      case AppThemeMode.olive:
        return const AppPalette(
          primary: Color(0xFF556B2F),
          accent: Color(0xFFB5C99A),
          text: Color(0xFF2F3A1F),
          appBg: Color(0xFFF8FAF4),
          cardBg: Colors.white,
          border: Color(0xFFDDE5CF),
          soft: Color(0xFFEAF1DE),
        );

      case AppThemeMode.sky:
        return const AppPalette(
          primary: Color(0xFF0284C7),
          accent: Color(0xFF7DD3FC),
          text: Color(0xFF1E3A4C),
          appBg: Color(0xFFF0F9FF),
          cardBg: Colors.white,
          border: Color(0xFFBAE6FD),
          soft: Color(0xFFE0F2FE),
        );

      case AppThemeMode.berry:
        return const AppPalette(
          primary: Color(0xFF7C3AED),
          accent: Color(0xFFC084FC),
          text: Color(0xFF35204A),
          appBg: Color(0xFFFAF5FF),
          cardBg: Colors.white,
          border: Color(0xFFE9D5FF),
          soft: Color(0xFFF3E8FF),
        );

      case AppThemeMode.mint:
        return const AppPalette(
          primary: Color(0xFF0F766E),
          accent: Color(0xFF5EEAD4),
          text: Color(0xFF173A39),
          appBg: Color(0xFFF0FDFA),
          cardBg: Colors.white,
          border: Color(0xFFBDEDE7),
          soft: Color(0xFFCCFBF1),
        );

      case AppThemeMode.ocean:
        return const AppPalette(
          primary: Color(0xFF155E75),
          accent: Color(0xFF22D3EE),
          text: Color(0xFF1C3B45),
          appBg: Color(0xFFF0FBFF),
          cardBg: Colors.white,
          border: Color(0xFFBFEAF5),
          soft: Color(0xFFD9F7FF),
        );

      case AppThemeMode.coral:
        return const AppPalette(
          primary: Color(0xFFE85D75),
          accent: Color(0xFFFFA69E),
          text: Color(0xFF4B2C33),
          appBg: Color(0xFFFFF5F4),
          cardBg: Colors.white,
          border: Color(0xFFF7CBC7),
          soft: Color(0xFFFFE1DE),
        );

      case AppThemeMode.midnight:
        return const AppPalette(
          primary: Color(0xFF111827),
          accent: Color(0xFF6366F1),
          text: Color(0xFF1F2937),
          appBg: Color(0xFFF5F7FB),
          cardBg: Colors.white,
          border: Color(0xFFD7DDEA),
          soft: Color(0xFFE8ECF8),
        );

      case AppThemeMode.gold:
        return const AppPalette(
          primary: Color(0xFFB45309),
          accent: Color(0xFFFBBF24),
          text: Color(0xFF4A3412),
          appBg: Color(0xFFFFFBEB),
          cardBg: Colors.white,
          border: Color(0xFFFDE68A),
          soft: Color(0xFFFEF3C7),
        );

      case AppThemeMode.ruby:
        return const AppPalette(
          primary: Color(0xFFBE123C),
          accent: Color(0xFFFB7185),
          text: Color(0xFF4A1F2B),
          appBg: Color(0xFFFFF1F2),
          cardBg: Colors.white,
          border: Color(0xFFFBC7D1),
          soft: Color(0xFFFFDDE3),
        );

      case AppThemeMode.forest:
        return const AppPalette(
          primary: Color(0xFF166534),
          accent: Color(0xFF4ADE80),
          text: Color(0xFF203728),
          appBg: Color(0xFFF3FFF7),
          cardBg: Colors.white,
          border: Color(0xFFCBEFD7),
          soft: Color(0xFFDCFCE7),
        );

      case AppThemeMode.aqua:
        return const AppPalette(
          primary: Color(0xFF0891B2),
          accent: Color(0xFF67E8F9),
          text: Color(0xFF1D3C44),
          appBg: Color(0xFFF2FCFF),
          cardBg: Colors.white,
          border: Color(0xFFC7EEF6),
          soft: Color(0xFFDCF8FD),
        );

      case AppThemeMode.sand:
        return const AppPalette(
          primary: Color(0xFF9A6B39),
          accent: Color(0xFFF4C27A),
          text: Color(0xFF493628),
          appBg: Color(0xFFFEF9F3),
          cardBg: Colors.white,
          border: Color(0xFFF1DFC8),
          soft: Color(0xFFF9ECDC),
        );

      case AppThemeMode.plum:
        return const AppPalette(
          primary: Color(0xFF7E22CE),
          accent: Color(0xFFD8B4FE),
          text: Color(0xFF39284A),
          appBg: Color(0xFFFCF5FF),
          cardBg: Colors.white,
          border: Color(0xFFE9D5FF),
          soft: Color(0xFFF3E8FF),
        );

      case AppThemeMode.steel:
        return const AppPalette(
          primary: Color(0xFF475569),
          accent: Color(0xFF94A3B8),
          text: Color(0xFF27313D),
          appBg: Color(0xFFF8FAFC),
          cardBg: Colors.white,
          border: Color(0xFFD7DEE7),
          soft: Color(0xFFEAF0F5),
        );

      case AppThemeMode.ice:
        return const AppPalette(
          primary: Color(0xFF2563EB),
          accent: Color(0xFFBFDBFE),
          text: Color(0xFF24364A),
          appBg: Color(0xFFF7FBFF),
          cardBg: Colors.white,
          border: Color(0xFFD7EBFF),
          soft: Color(0xFFEAF4FF),
        );

      case AppThemeMode.candy:
        return const AppPalette(
          primary: Color(0xFFDB2777),
          accent: Color(0xFFF9A8D4),
          text: Color(0xFF4A2336),
          appBg: Color(0xFFFFF2F8),
          cardBg: Colors.white,
          border: Color(0xFFFBCFE8),
          soft: Color(0xFFFDE7F3),
        );

      case AppThemeMode.terracotta:
        return const AppPalette(
          primary: Color(0xFFC2410C),
          accent: Color(0xFFF59E0B),
          text: Color(0xFF4A2F24),
          appBg: Color(0xFFFFF7F2),
          cardBg: Colors.white,
          border: Color(0xFFF6D3C2),
          soft: Color(0xFFFFE7DB),
        );

      case AppThemeMode.lemon:
        return const AppPalette(
          primary: Color(0xFFCA8A04),
          accent: Color(0xFFFDE047),
          text: Color(0xFF474018),
          appBg: Color(0xFFFFFEEF),
          cardBg: Colors.white,
          border: Color(0xFFFDE68A),
          soft: Color(0xFFFEF9C3),
        );

      case AppThemeMode.orchid:
        return const AppPalette(
          primary: Color(0xFFA21CAF),
          accent: Color(0xFFE879F9),
          text: Color(0xFF48224D),
          appBg: Color(0xFFFDF4FF),
          cardBg: Colors.white,
          border: Color(0xFFF5D0FE),
          soft: Color(0xFFFAE8FF),
        );

      case AppThemeMode.teal:
        return const AppPalette(
          primary: Color(0xFF0F766E),
          accent: Color(0xFF2DD4BF),
          text: Color(0xFF1E3937),
          appBg: Color(0xFFF4FFFD),
          cardBg: Colors.white,
          border: Color(0xFFC6F1EA),
          soft: Color(0xFFDBFBF5),
        );

      case AppThemeMode.cocoa:
        return const AppPalette(
          primary: Color(0xFF5B3A29),
          accent: Color(0xFFD6A77A),
          text: Color(0xFF37251C),
          appBg: Color(0xFFFBF7F4),
          cardBg: Colors.white,
          border: Color(0xFFE8D8CC),
          soft: Color(0xFFF3E7DE),
        );

      case AppThemeMode.navy:
        return const AppPalette(
          primary: Color(0xFF1A2B48),
          accent: Color(0xFFF98D28),
          text: Color(0xFF2D2D2D),
          appBg: Color(0xFFF4F7F9),
          cardBg: Colors.white,
          border: Color(0xFFD1D9E0),
          soft: Color(0xFFEAF0F5),
        );
    }
  }
}

final AppThemeController appThemeController = AppThemeController();
