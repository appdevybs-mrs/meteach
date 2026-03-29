import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'ui_constants.dart';

class WatermarkBackground extends StatelessWidget {
  final Widget child;
  const WatermarkBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final framedChild = kIsWeb
        ? Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1360),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.74),
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: UiK.uiBorder),
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
          )
        : child;

    return Stack(
      children: [
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFFF6F2E8), Color(0xFFEEE7D9), Color(0xFFE5EBF1)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),

        Positioned(
          top: -80,
          right: -70,
          child: IgnorePointer(
            child: Container(
              width: 260,
              height: 260,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: UiK.primaryBlue.withValues(alpha: 0.08),
              ),
            ),
          ),
        ),

        Positioned(
          left: -60,
          bottom: -70,
          child: IgnorePointer(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: UiK.actionOrange.withValues(alpha: 0.08),
              ),
            ),
          ),
        ),

        Positioned.fill(
          child: IgnorePointer(
            child: Opacity(
              opacity: 0.035,
              child: Center(
                child: FractionallySizedBox(
                  widthFactor: 0.68,
                  child: Image.asset(
                    'assets/images/ybs_logo.png',
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
          ),
        ),

        framedChild,
      ],
    );
  }
}
