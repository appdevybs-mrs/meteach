import 'dart:math' as math;

import 'package:flutter/material.dart';

class YbsBusyLogo extends StatefulWidget {
  const YbsBusyLogo({super.key, this.size = 52, this.color, this.strokeWidth});

  final double size;
  final Color? color;
  final double? strokeWidth;

  @override
  State<YbsBusyLogo> createState() => _YbsBusyLogoState();
}

class _YbsBusyLogoState extends State<YbsBusyLogo>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1300),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final spinnerColor =
        widget.color ?? Theme.of(context).colorScheme.primary.withValues(alpha: 0.9);

    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          final progress = _controller.value;
          final turn = progress * 2 * math.pi;
          final pulse = 0.92 + (math.sin(turn) * 0.08);

          return Stack(
            alignment: Alignment.center,
            children: [
              Transform.rotate(
                angle: turn,
                child: SizedBox(
                  width: widget.size,
                  height: widget.size,
                  child: CircularProgressIndicator(
                    strokeWidth: widget.strokeWidth ?? (widget.size * 0.07),
                    valueColor: AlwaysStoppedAnimation<Color>(spinnerColor),
                    backgroundColor: spinnerColor.withValues(alpha: 0.16),
                  ),
                ),
              ),
              Transform.scale(
                scale: pulse,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(widget.size),
                  child: Image.asset(
                    'assets/images/ybs_logo.png',
                    width: widget.size * 0.56,
                    height: widget.size * 0.56,
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => Icon(
                      Icons.school_rounded,
                      size: widget.size * 0.42,
                      color: spinnerColor,
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
