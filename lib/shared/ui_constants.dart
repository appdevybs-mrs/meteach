import 'package:flutter/material.dart';

class UiK {
  // Same style as Teacher
  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
  static const mainText = Color(0xFF2D2D2D);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);

  static RoundedRectangleBorder cardShape() => RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(18),
    side: BorderSide(color: uiBorder.withOpacity(0.8)),
  );

  static TextStyle titleText({double size = 16}) => const TextStyle(
    color: primaryBlue,
    fontWeight: FontWeight.w900,
    fontSize: 16,
  ).copyWith(fontSize: size);

  static TextStyle labelText() =>
      const TextStyle(color: mainText, fontWeight: FontWeight.w900);

  static TextStyle subtleText() =>
      TextStyle(color: mainText.withOpacity(0.7), fontWeight: FontWeight.w700);

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
