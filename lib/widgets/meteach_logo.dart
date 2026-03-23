import 'package:flutter/material.dart';

class MeTeachLogo extends StatelessWidget {
  const MeTeachLogo({super.key, this.size = 56, this.showLabel = false});

  final double size;
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final textStyle = Theme.of(context).textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w700,
      color: const Color(0xFF114B5F),
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(size * 0.2),
            color: Colors.white,
            boxShadow: const [
              BoxShadow(
                color: Color(0x33114B5F),
                blurRadius: 8,
                offset: Offset(0, 4),
              ),
            ],
          ),
          padding: EdgeInsets.all(size * 0.11),
          child: Image.asset('assets/logo.png', fit: BoxFit.contain),
        ),
        if (showLabel) ...[
          const SizedBox(width: 10),
          Text('Taqym DZ', style: textStyle),
        ],
      ],
    );
  }
}
