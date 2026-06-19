import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

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
                    color: Colors.white.withValues(alpha: 0.70),
                    borderRadius: BorderRadius.circular(26),
                    border: Border.all(
                      color: const Color(0xFF7C3AED).withValues(alpha: 0.12),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF172B85).withValues(alpha: 0.10),
                        blurRadius: 34,
                        offset: const Offset(0, 18),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(25),
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
              colors: [Color(0xFFFFFFFF), Color(0xFFF7F8FF), Color(0xFFEFF6FF)],
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
                color: const Color(0xFF7C3AED).withValues(alpha: 0.10),
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
                color: const Color(0xFF06B6D4).withValues(alpha: 0.12),
              ),
            ),
          ),
        ),

        Positioned.fill(
          child: IgnorePointer(
            child: Opacity(
              opacity: 0.025,
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
