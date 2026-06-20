import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'responsive_layout.dart';

Widget webPageFrame({
  required BuildContext context,
  required Widget child,
  double maxWidth = 1380,
  EdgeInsetsGeometry? padding,
  bool fullWidth = false,
}) {
  if (!kIsWeb) return child;

  if (fullWidth) {
    final resolvedPadding =
        padding ??
        AppResponsive.pagePadding(
          context,
          phone: 12,
          tablet: 16,
          desktop: 24,
          largeDesktop: 28,
          topPhone: 10,
          topTablet: 12,
          topDesktop: 18,
          topLargeDesktop: 20,
          bottomPhone: 12,
          bottomTablet: 16,
          bottomDesktop: 24,
          bottomLargeDesktop: 28,
        );
    return Padding(
      padding: resolvedPadding,
      child: child,
    );
  }

  final resolvedPadding =
      padding ??
      AppResponsive.pagePadding(
        context,
        phone: 12,
        tablet: 16,
        desktop: 24,
        largeDesktop: 28,
        topPhone: 10,
        topTablet: 12,
        topDesktop: 18,
        topLargeDesktop: 20,
        bottomPhone: 12,
        bottomTablet: 16,
        bottomDesktop: 24,
        bottomLargeDesktop: 28,
      );

  return Padding(
    padding: resolvedPadding,
    child: Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.82),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: const Color(0xFFD8CFC1)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 28,
                offset: const Offset(0, 14),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(21),
            child: child,
          ),
        ),
      ),
    ),
  );
}
