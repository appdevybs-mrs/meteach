import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

Widget webPageFrame({
  required Widget child,
  double maxWidth = 1380,
  EdgeInsetsGeometry padding = const EdgeInsets.fromLTRB(14, 10, 14, 14),
}) {
  if (!kIsWeb) return child;

  return Padding(
    padding: padding,
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
