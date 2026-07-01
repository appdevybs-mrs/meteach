import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

enum ScreenType { phone, tablet, desktop, largeDesktop }

extension ScreenInfo on BuildContext {
  ScreenType get screenType {
    final w = MediaQuery.sizeOf(this).width;
    if (w >= AppResponsive.largeDesktopMin) return ScreenType.largeDesktop;
    if (w >= AppResponsive.desktopMin) return ScreenType.desktop;
    if (w >= AppResponsive.phoneMax + 1) return ScreenType.tablet;
    return ScreenType.phone;
  }

  bool get isPhone => screenType == ScreenType.phone;
  bool get isTablet => screenType == ScreenType.tablet;
  bool get isDesktop => screenType == ScreenType.desktop;
  bool get isLargeDesktop => screenType == ScreenType.largeDesktop;
  bool get isDesktopOrWider =>
      screenType == ScreenType.desktop ||
      screenType == ScreenType.largeDesktop;

  T responsive<T>({
    required T phone,
    T? tablet,
    T? desktop,
    T? largeDesktop,
  }) {
    switch (screenType) {
      case ScreenType.largeDesktop:
        return largeDesktop ?? desktop ?? tablet ?? phone;
      case ScreenType.desktop:
        return desktop ?? tablet ?? phone;
      case ScreenType.tablet:
        return tablet ?? phone;
      case ScreenType.phone:
        return phone;
    }
  }

  double responsiveFontSize({
    double phone = 14,
    double? tablet,
    double? desktop,
    double? largeDesktop,
  }) {
    return responsive<double>(
      phone: phone,
      tablet: tablet ?? phone + 1,
      desktop: desktop ?? (tablet ?? phone + 1) + 2,
      largeDesktop:
          largeDesktop ?? (desktop ?? (tablet ?? phone + 1) + 2) + 2,
    );
  }

  EdgeInsets responsivePadding({
    double phone = 14,
    double? tablet,
    double? desktop,
    double? largeDesktop,
  }) {
    final h = responsive<double>(
      phone: phone,
      tablet: tablet ?? phone + 4,
      desktop: desktop ?? (tablet ?? phone + 4) + 6,
      largeDesktop: largeDesktop ?? (desktop ?? (tablet ?? phone + 4) + 6) + 8,
    );
    return EdgeInsets.symmetric(horizontal: h, vertical: h * 0.6);
  }

  int responsiveGridColumns({
    int phone = 2,
    int? tablet,
    int? desktop,
    int? largeDesktop,
  }) {
    return responsive<int>(
      phone: phone,
      tablet: tablet ?? phone + 1,
      desktop: desktop ?? (tablet ?? phone + 1) + 1,
      largeDesktop:
          largeDesktop ?? (desktop ?? (tablet ?? phone + 1) + 1) + 2,
    );
  }
}

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
