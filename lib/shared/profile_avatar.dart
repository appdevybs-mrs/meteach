import 'package:flutter/material.dart';

class ProfileAvatar extends StatelessWidget {
  const ProfileAvatar({
    super.key,
    required this.name,
    required this.photoUrl,
    this.radius = 20,
    this.fallbackBg,
    this.fallbackFg,
    this.borderColor,
  });

  final String name;
  final String photoUrl;
  final double radius;
  final Color? fallbackBg;
  final Color? fallbackFg;
  final Color? borderColor;

  static String resolvePhotoFromMap(Map<dynamic, dynamic> raw) {
    final m = raw.map((k, v) => MapEntry(k.toString(), v));
    final direct = (m['profile_photo'] ?? '').toString().trim();
    if (direct.isNotEmpty) return direct;

    final photos = m['profile_photos'];
    if (photos is List) {
      for (final item in photos) {
        final p = item.toString().trim();
        if (p.isNotEmpty) return p;
      }
    }

    if (photos is Map) {
      final entries = photos.entries.toList()
        ..sort((a, b) {
          final ai = int.tryParse(a.key.toString()) ?? 999999;
          final bi = int.tryParse(b.key.toString()) ?? 999999;
          return ai.compareTo(bi);
        });
      for (final e in entries) {
        final p = e.value.toString().trim();
        if (p.isNotEmpty) return p;
      }
    }

    return '';
  }

  @override
  Widget build(BuildContext context) {
    final safeName = name.trim();
    final initial = safeName.isEmpty
        ? '?'
        : safeName.characters.first.toUpperCase();

    final bg = fallbackBg ?? Theme.of(context).colorScheme.primaryContainer;
    final fg = fallbackFg ?? Theme.of(context).colorScheme.onPrimaryContainer;

    final cleanUrl = photoUrl.trim();
    final px = MediaQuery.of(context).devicePixelRatio;
    final cache = (radius * 2 * px).round().clamp(32, 384);

    return Container(
      width: radius * 2,
      height: radius * 2,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: borderColor == null ? null : Border.all(color: borderColor!),
      ),
      child: ClipOval(
        child: cleanUrl.isEmpty
            ? Container(
                color: bg,
                alignment: Alignment.center,
                child: Text(
                  initial,
                  style: TextStyle(
                    color: fg,
                    fontWeight: FontWeight.w900,
                    fontSize: radius * 0.9,
                  ),
                ),
              )
            : Image.network(
                cleanUrl,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.low,
                cacheWidth: cache,
                cacheHeight: cache,
                errorBuilder: (_, _, _) => Container(
                  color: bg,
                  alignment: Alignment.center,
                  child: Text(
                    initial,
                    style: TextStyle(
                      color: fg,
                      fontWeight: FontWeight.w900,
                      fontSize: radius * 0.9,
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}
