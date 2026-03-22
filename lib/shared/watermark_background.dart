import 'package:flutter/material.dart';
import 'ui_constants.dart';

class WatermarkBackground extends StatelessWidget {
  final Widget child;
  const WatermarkBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Container(color: UiK.appBg),

        Positioned.fill(
          child: IgnorePointer(
            child: Opacity(
              opacity: 0.05,
              child: Center(
                child: FractionallySizedBox(
                  widthFactor: 0.75,
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

        child,
      ],
    );
  }
}
