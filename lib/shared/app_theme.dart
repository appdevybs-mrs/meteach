import 'package:flutter/material.dart';
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
}

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
}

class AppThemeController extends ChangeNotifier {
  static const String _prefsKey = 'selected_app_theme';

  AppThemeMode _mode = AppThemeMode.navy;

  AppThemeMode get mode => _mode;

  AppPalette get palette => _paletteFromMode(_mode);

  ThemeData get themeData {
    final p = palette;

    final colorScheme = ColorScheme.fromSeed(
      seedColor: p.primary,
      brightness: Brightness.light,
      primary: p.primary,
      secondary: p.accent,
      surface: p.cardBg,
      background: p.appBg,
      onPrimary: Colors.white,
      onSecondary: Colors.white,
      onSurface: p.text,
      onBackground: p.text,
      outline: p.border,
      error: const Color(0xFFB00020),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: p.appBg,
      appBarTheme: AppBarTheme(
        backgroundColor: p.cardBg,
        foregroundColor: p.primary,
        elevation: 0,
        surfaceTintColor: p.cardBg,
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: p.accent,
        foregroundColor: Colors.white,
      ),
      textTheme: TextTheme(
        bodyMedium: TextStyle(color: p.text),
        bodyLarge: TextStyle(color: p.text),
        titleLarge: TextStyle(color: p.text),
        titleMedium: TextStyle(color: p.text),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: p.cardBg,
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
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: p.cardBg,
        indicatorColor: p.soft,
        labelTextStyle: WidgetStateProperty.resolveWith(
              (states) => TextStyle(
            color: states.contains(WidgetState.selected) ? p.primary : p.text,
            fontWeight: FontWeight.w700,
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
        unselectedLabelColor: p.text.withOpacity(0.65),
        indicatorColor: p.primary,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: p.primary,
        contentTextStyle: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Future<void> loadSavedTheme() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);

    if (raw == null || raw.trim().isEmpty) {
      _mode = AppThemeMode.navy;
      return;
    }

    _mode = AppThemeMode.values.firstWhere(
          (e) => e.name == raw,
      orElse: () => AppThemeMode.navy,
    );
  }

  Future<void> setTheme(AppThemeMode mode) async {
    if (_mode == mode) return;

    _mode = mode;
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, mode.name);
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