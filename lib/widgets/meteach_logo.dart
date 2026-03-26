import 'package:flutter/material.dart';

class MarkaGlyph extends StatelessWidget {
  const MarkaGlyph({super.key, this.size = 56, this.showShadow = true});

  final double size;
  final bool showShadow;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.2),
        color: Colors.white,
        border: Border.all(color: scheme.primary.withValues(alpha: 0.2)),
        boxShadow: showShadow
            ? [
                BoxShadow(
                  color: scheme.primary.withValues(alpha: 0.2),
                  blurRadius: 12,
                  offset: const Offset(0, 6),
                ),
              ]
            : null,
      ),
      alignment: Alignment.center,
      child: Padding(
        padding: EdgeInsets.all(size * 0.12),
        child: Image.asset('assets/logo.png', fit: BoxFit.contain),
      ),
    );
  }
}

class MeTeachLogo extends StatelessWidget {
  const MeTeachLogo({super.key, this.size = 56, this.showLabel = false});

  final double size;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textStyle = Theme.of(context).textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w700,
      color: scheme.primary,
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        MarkaGlyph(size: size),
        if (showLabel) ...[
          const SizedBox(width: 10),
          Text('Marka', style: textStyle),
        ],
      ],
    );
  }
}
