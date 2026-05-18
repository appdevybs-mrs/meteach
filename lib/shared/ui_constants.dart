import 'package:flutter/material.dart';

class UiK {
  static const primaryBlue = Color(0xFF0E7C86);
  static const actionOrange = Color(0xFFBF5D39);
  static const mainText = Color(0xFF213038);
  static const appBg = Color(0xFFFAFCFF);
  static const uiBorder = Color(0xFFD8CFC1);

  static RoundedRectangleBorder cardShape() => RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(18),
    side: BorderSide(color: uiBorder.withValues(alpha: 0.8)),
  );

  static TextStyle titleText({double size = 16}) => const TextStyle(
    color: primaryBlue,
    fontWeight: FontWeight.w900,
    fontSize: 16,
  ).copyWith(fontSize: size);

  static TextStyle labelText() =>
      const TextStyle(color: mainText, fontWeight: FontWeight.w900);

  static TextStyle subtleText() => TextStyle(
    color: mainText.withValues(alpha: 0.7),
    fontWeight: FontWeight.w700,
  );

  static String yyyyMmDd(DateTime d) {
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    return '${d.year}-$mm-$dd';
  }

  static DateTime? parseYyyyMmDd(String s) {
    try {
      final p = s.split('-');
      if (p.length != 3) return null;
      return DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
    } catch (_) {
      return null;
    }
  }
}
