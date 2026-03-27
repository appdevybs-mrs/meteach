import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';

import '../shared/app_theme.dart';
import '../shared/human_error.dart';
import '../shared/screen_help_guide.dart';
import '../shared/teacher_tour_guide.dart';
import '../shared/watermark_background.dart';
import 'teacher_syllabus_details_screen.dart';

class TeacherSyllabiScreen extends StatefulWidget {
  const TeacherSyllabiScreen({super.key});

  @override
  State<TeacherSyllabiScreen> createState() => _TeacherSyllabiScreenState();
}

class _TeacherSyllabiScreenState extends State<TeacherSyllabiScreen> {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  bool _loading = true;
  String? _error;

  List<_SyllabusLite> _items = const [];

  @override
  void initState() {
    super.initState();
    appThemeController.addListener(_onThemeChanged);
    _load();
  }

  @override
  void dispose() {
    appThemeController.removeListener(_onThemeChanged);
    super.dispose();
  }

  void _onThemeChanged() {
    if (!mounted) return;
    setState(() {});
  }

  AppPalette get p => appThemeController.palette;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _items = const [];
    });

    try {
      final snap = await _db.child('syllabi').get();
      final v = snap.value;

      if (v is! Map) {
        setState(() {
          _loading = false;
          _items = const [];
        });
        return;
      }

      final raw = Map<dynamic, dynamic>.from(v);
      final out = <_SyllabusLite>[];

      raw.forEach((key, value) {
        final courseMap = _asStringKeyMap(value);
        if (courseMap == null) return;

        final fallbackMeta = _firstVariantMeta(courseMap);

        final courseId = _readString(courseMap['courseId']).isNotEmpty
            ? _readString(courseMap['courseId'])
            : key.toString();

        final title = _firstNonEmpty([
          _readString(courseMap['title']),
          _readString(fallbackMeta?['title']),
          'Course',
        ]);

        final code = _firstNonEmpty([
          _readString(courseMap['courseCode']),
          _readString(fallbackMeta?['courseCode']),
          '',
        ]);

        final duration = _firstNonEmpty([
          _readString(courseMap['duration']),
          _readString(fallbackMeta?['duration']),
          '',
        ]);

        final updatedAt = _maxInt([
          _toInt(courseMap['updatedAt']),
          _toInt(fallbackMeta?['updatedAt']),
        ]);

        final variants = _extractAvailableVariants(courseMap);

        out.add(
          _SyllabusLite(
            courseId: courseId,
            title: title,
            code: code,
            duration: duration,
            updatedAt: updatedAt,
            variants: variants,
          ),
        );
      });

      out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

      if (!mounted) return;
      setState(() {
        _loading = false;
        _items = out;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = toHumanError(e);
      });
    }
  }

  Map<String, dynamic>? _asStringKeyMap(dynamic value) {
    if (value is! Map) return null;

    final out = <String, dynamic>{};
    value.forEach((k, v) {
      out[k.toString()] = v;
    });
    return out;
  }

  Map<String, dynamic>? _firstVariantMeta(Map<String, dynamic> courseMap) {
    for (final key in const ['inclass', 'flexible', 'private', 'recorded']) {
      final variant = _asStringKeyMap(courseMap[key]);
      if (variant != null) return variant;
    }
    return null;
  }

  List<String> _extractAvailableVariants(Map<String, dynamic> courseMap) {
    final out = <String>[];

    for (final key in const ['inclass', 'flexible', 'private', 'recorded']) {
      final variant = _asStringKeyMap(courseMap[key]);
      if (variant == null) continue;

      final hasUnits =
          variant['units'] is List && (variant['units'] as List).isNotEmpty;
      final hasMeta =
          _readString(variant['title']).isNotEmpty ||
          _readString(variant['courseCode']).isNotEmpty ||
          _readString(variant['duration']).isNotEmpty ||
          _toInt(variant['updatedAt']) > 0;

      if (hasUnits || hasMeta) {
        out.add(key);
      }
    }

    return out;
  }

  static String _readString(dynamic v) => (v ?? '').toString().trim();

  static String _firstNonEmpty(List<String> values) {
    for (final v in values) {
      if (v.trim().isNotEmpty) return v.trim();
    }
    return '';
  }

  static int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  static int _maxInt(List<int> values) {
    if (values.isEmpty) return 0;
    var max = values.first;
    for (final v in values) {
      if (v > max) max = v;
    }
    return max;
  }

  String _fmtDate(int ms) {
    if (ms <= 0) return '';
    try {
      final dt = DateTime.fromMillisecondsSinceEpoch(ms);
      final y = dt.year.toString().padLeft(4, '0');
      final m = dt.month.toString().padLeft(2, '0');
      final d = dt.day.toString().padLeft(2, '0');
      return '$y-$m-$d';
    } catch (_) {
      return '';
    }
  }

  String _variantLabel(String key) {
    switch (key) {
      case 'inclass':
        return 'In-Class';
      case 'flexible':
        return 'Flexible';
      case 'private':
        return 'Private';
      case 'recorded':
        return 'Recorded';
      default:
        return key;
    }
  }

  @override
  Widget build(BuildContext context) {
    TeacherTourGuide.schedule(
      context,
      screenId: 'teacher_syllabi',
      hints: const [
        TeacherTourHint(
          title: 'Syllabi list',
          line:
              'Browse available course syllabi and open details for each course.',
        ),
      ],
    );

    return Scaffold(
      backgroundColor: p.appBg,
      appBar: AppBar(
        backgroundColor: p.cardBg,
        elevation: 0,
        surfaceTintColor: p.cardBg,
        centerTitle: false,
        iconTheme: IconThemeData(color: p.primary),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Syllabi',
              style: TextStyle(
                color: p.primary,
                fontWeight: FontWeight.w900,
                fontSize: 18,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'Browse course outlines and available variants',
              style: TextStyle(
                color: p.text.withValues(alpha: 0.65),
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Instructions',
            icon: Icon(Icons.help_outline_rounded, color: p.primary),
            onPressed: () => ScreenHelpGuide.show(
              context,
              role: GuideRole.teacher,
              screenId: 'teacher_syllabi',
              screenTitle: 'Syllabi',
            ),
          ),
          IconButton(
            tooltip: 'Refresh',
            icon: Icon(Icons.refresh_rounded, color: p.accent),
            onPressed: _load,
          ),
        ],
      ),
      body: WatermarkBackground(
        child: SafeArea(
          child: _loading
              ? Center(child: CircularProgressIndicator(color: p.accent))
              : _error != null
              ? _ErrorBox(
                  palette: p,
                  message: 'Failed to load syllabi.\n$_error',
                  onRetry: _load,
                )
              : _items.isEmpty
              ? _InfoBox(
                  palette: p,
                  title: 'No syllabi',
                  message: 'No syllabi are available right now.',
                  icon: Icons.info_rounded,
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
                  children: [
                    _HeroCard(palette: p, totalCount: _items.length),
                    const SizedBox(height: 14),
                    ..._items.map((it) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _SyllabusTile(
                          palette: p,
                          title: it.title,
                          code: it.code,
                          duration: it.duration,
                          updatedLabel: _fmtDate(it.updatedAt),
                          variants: it.variants.map(_variantLabel).toList(),
                          onTap: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => TeacherSyllabusDetailsScreen(
                                  courseId: it.courseId,
                                ),
                              ),
                            );
                          },
                        ),
                      );
                    }),
                  ],
                ),
        ),
      ),
    );
  }
}

class _SyllabusLite {
  const _SyllabusLite({
    required this.courseId,
    required this.title,
    required this.code,
    required this.duration,
    required this.updatedAt,
    required this.variants,
  });

  final String courseId;
  final String title;
  final String code;
  final String duration;
  final int updatedAt;
  final List<String> variants;
}

/* ================== UI ================== */

class _HeroCard extends StatelessWidget {
  const _HeroCard({required this.palette, required this.totalCount});

  final AppPalette palette;
  final int totalCount;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [palette.primary, palette.primary.withValues(alpha: 0.88)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(26),
        boxShadow: [
          BoxShadow(
            color: palette.primary.withValues(alpha: 0.18),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Curriculum Center',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.82),
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Available Syllabi',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              fontSize: 22,
              height: 1.1,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Open any course to view its detailed syllabus and structure.',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.86),
              fontWeight: FontWeight.w700,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.menu_book_rounded,
                  color: Colors.white,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Text(
                  '$totalCount course${totalCount == 1 ? '' : 's'} found',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SyllabusTile extends StatelessWidget {
  const _SyllabusTile({
    required this.palette,
    required this.title,
    required this.code,
    required this.duration,
    required this.updatedLabel,
    required this.variants,
    required this.onTap,
  });

  final AppPalette palette;
  final String title;
  final String code;
  final String duration;
  final String updatedLabel;
  final List<String> variants;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(22),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: palette.cardBg,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: palette.border.withValues(alpha: 0.88)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.03),
              blurRadius: 10,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: palette.soft,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: palette.border.withValues(alpha: 0.85),
                ),
              ),
              child: Icon(Icons.menu_book_rounded, color: palette.primary),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      color: palette.primary,
                      fontSize: 15,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (code.trim().isNotEmpty)
                        _Pill(
                          palette: palette,
                          icon: Icons.qr_code_rounded,
                          text: code,
                        ),
                      if (duration.trim().isNotEmpty)
                        _Pill(
                          palette: palette,
                          icon: Icons.timer_rounded,
                          text: duration,
                        ),
                      if (updatedLabel.trim().isNotEmpty)
                        _Pill(
                          palette: palette,
                          icon: Icons.update_rounded,
                          text: updatedLabel,
                        ),
                    ],
                  ),
                  if (variants.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: variants
                          .map(
                            (v) => _Pill(
                              palette: palette,
                              icon: Icons.layers_rounded,
                              text: v,
                            ),
                          )
                          .toList(),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),
            Icon(
              Icons.chevron_right_rounded,
              color: palette.text.withValues(alpha: 0.45),
            ),
          ],
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.palette, required this.icon, required this.text});

  final AppPalette palette;
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final maxWidth = MediaQuery.of(context).size.width * 0.55;

    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: palette.soft.withValues(alpha: 0.8),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: palette.border.withValues(alpha: 0.75)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: palette.primary),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  color: palette.primary,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoBox extends StatelessWidget {
  const _InfoBox({
    required this.palette,
    required this.title,
    required this.message,
    required this.icon,
  });

  final AppPalette palette;
  final String title;
  final String message;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: palette.cardBg,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: palette.border.withValues(alpha: 0.86)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 58,
              height: 58,
              decoration: BoxDecoration(
                color: palette.soft,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: palette.primary, size: 30),
            ),
            const SizedBox(height: 12),
            Text(
              title,
              style: TextStyle(
                fontWeight: FontWeight.w900,
                color: palette.primary,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: palette.text.withValues(alpha: 0.72),
                height: 1.35,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({
    required this.palette,
    required this.message,
    required this.onRetry,
  });

  final AppPalette palette;
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: palette.cardBg,
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: palette.border.withValues(alpha: 0.86)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.error_outline_rounded,
              color: Color(0xFFD97706),
              size: 34,
            ),
            const SizedBox(height: 10),
            Text(
              'Error',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                color: palette.primary,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: palette.text.withValues(alpha: 0.72),
                height: 1.35,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: palette.accent,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                onPressed: onRetry,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text(
                  'Retry',
                  style: TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
