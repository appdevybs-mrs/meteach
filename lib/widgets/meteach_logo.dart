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
            borderRadius: BorderRadius.circular(size * 0.28),
            gradient: const LinearGradient(
              colors: [Color(0xFF114B5F), Color(0xFF1A936F)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: const [
              BoxShadow(
                color: Color(0x33114B5F),
                blurRadius: 8,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Positioned(
                top: size * 0.18,
                child: Icon(
                  Icons.menu_book_rounded,
                  color: Colors.white,
                  size: size * 0.42,
                ),
              ),
              Positioned(
                bottom: size * 0.16,
                child: Icon(
                  Icons.edit_note_rounded,
                  color: const Color(0xFFF3E9D2),
                  size: size * 0.4,
                ),
              ),
            ],
          ),
        ),
        if (showLabel) ...[
          const SizedBox(width: 10),
          Text('Taqyim DZ', style: textStyle),
        ],
      ],
    );
  }
}
