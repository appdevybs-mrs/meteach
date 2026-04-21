import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'responsive_layout.dart';
import 'web_page_frame.dart';

bool isWebDesktop(BuildContext context, {double minWidth = 1180}) {
  return AppResponsive.isWebDesktop(context, minWidth: minWidth);
}

Widget adminWebBodyFrame({
  required BuildContext context,
  required Widget child,
  double maxWidth = 1580,
  EdgeInsetsGeometry? padding,
}) {
  if (!kIsWeb) return child;
  return webPageFrame(
    context: context,
    child: child,
    maxWidth: maxWidth,
    padding: padding,
  );
}
