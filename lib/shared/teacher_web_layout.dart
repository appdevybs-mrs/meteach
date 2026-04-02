import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'web_page_frame.dart';

bool isTeacherWebDesktop(BuildContext context, {double minWidth = 1180}) {
  if (!kIsWeb) return false;
  return MediaQuery.sizeOf(context).width >= minWidth;
}

Widget teacherWebBodyFrame({
  required BuildContext context,
  required Widget child,
  double maxWidth = 1560,
  EdgeInsetsGeometry padding = const EdgeInsets.fromLTRB(12, 10, 12, 12),
}) {
  if (!kIsWeb) return child;
  return webPageFrame(child: child, maxWidth: maxWidth, padding: padding);
}
