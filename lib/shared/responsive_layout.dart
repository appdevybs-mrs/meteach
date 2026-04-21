import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

class AppResponsive {
  static const double phoneMax = 767;
  static const double tabletMax = 1023;
  static const double desktopMin = 1024;
  static const double largeDesktopMin = 1440;

  static bool isWebDesktop(
    BuildContext context, {
    double minWidth = desktopMin,
  }) {
    if (!kIsWeb) return false;
    return MediaQuery.sizeOf(context).width >= minWidth;
  }

  static bool isTabletOrWider(BuildContext context) {
    return MediaQuery.sizeOf(context).width >= phoneMax + 1;
  }

  static bool isLargeDesktop(BuildContext context) {
    return isWebDesktop(context, minWidth: largeDesktopMin);
  }

  static double contentMaxWidth(
    BuildContext context, {
    double? desktop,
    double? largeDesktop,
    double fallback = 1380,
  }) {
    if (!kIsWeb) return fallback;
    if (isLargeDesktop(context) && largeDesktop != null) return largeDesktop;
    if (isWebDesktop(context) && desktop != null) return desktop;
    return fallback;
  }

  static EdgeInsets pagePadding(
    BuildContext context, {
    double phone = 14,
    double tablet = 18,
    double desktop = 24,
    double largeDesktop = 32,
    double topPhone = 10,
    double topTablet = 14,
    double topDesktop = 18,
    double topLargeDesktop = 22,
    double bottomPhone = 14,
    double bottomTablet = 18,
    double bottomDesktop = 24,
    double bottomLargeDesktop = 28,
  }) {
    final width = MediaQuery.sizeOf(context).width;
    if (width >= largeDesktopMin) {
      return EdgeInsets.fromLTRB(
        largeDesktop,
        topLargeDesktop,
        largeDesktop,
        bottomLargeDesktop,
      );
    }
    if (width >= desktopMin) {
      return EdgeInsets.fromLTRB(desktop, topDesktop, desktop, bottomDesktop);
    }
    if (width >= phoneMax + 1) {
      return EdgeInsets.fromLTRB(tablet, topTablet, tablet, bottomTablet);
    }
    return EdgeInsets.fromLTRB(phone, topPhone, phone, bottomPhone);
  }
}
