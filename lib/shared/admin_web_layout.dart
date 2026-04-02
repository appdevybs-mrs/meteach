import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'web_page_frame.dart';

bool isWebDesktop(BuildContext context, {double minWidth = 1180}) {
  if (!kIsWeb) return false;
  return MediaQuery.sizeOf(context).width >= minWidth;
}

Widget adminWebBodyFrame({
  required BuildContext context,
  required Widget child,
  double maxWidth = 1580,
  EdgeInsetsGeometry padding = const EdgeInsets.fromLTRB(12, 10, 12, 12),
}) {
  if (!kIsWeb) return child;
  return webPageFrame(child: child, maxWidth: maxWidth, padding: padding);
}
