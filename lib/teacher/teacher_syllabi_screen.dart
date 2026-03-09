import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';

import '../shared/ui_constants.dart';
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
    _load();
  }

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

        final courseId =
        _readString(courseMap['courseId']).isNotEmpty
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
        _error = e.toString();
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

      final hasUnits = variant['units'] is List && (variant['units'] as List).isNotEmpty;
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
    return Scaffold(
      backgroundColor: UiK.appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        centerTitle: true,
        title: const Text(
          'Syllabi',
          style: TextStyle(
            color: UiK.primaryBlue,
            fontWeight: FontWeight.w900,
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded, color: UiK.primaryBlue),
            onPressed: _load,
          ),
        ],
      ),
      body: WatermarkBackground(
        child: SafeArea(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
              ? _ErrorBox(
            message: 'Failed to load syllabi.\n$_error',
            onRetry: _load,
          )
              : _items.isEmpty
              ? const _InfoBox(
            title: 'No syllabi',
            message: 'لا توجد مناهج متاحة حاليا.',
            icon: Icons.info_rounded,
          )
              : ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
            itemCount: _items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (context, i) {
              final it = _items[i];
              return _SyllabusTile(
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
              );
            },
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

class _SyllabusTile extends StatelessWidget {
  const _SyllabusTile({
    required this.title,
    required this.code,
    required this.duration,
    required this.updatedLabel,
    required this.variants,
    required this.onTap,
  });

  final String title;
  final String code;
  final String duration;
  final String updatedLabel;
  final List<String> variants;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: UiK.uiBorder.withOpacity(0.85)),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: UiK.primaryBlue.withOpacity(0.08),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: UiK.uiBorder.withOpacity(0.85)),
              ),
              child: const Icon(Icons.menu_book_rounded, color: UiK.primaryBlue),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      color: UiK.primaryBlue,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (code.trim().isNotEmpty)
                        _Pill(icon: Icons.qr_code_rounded, text: code),
                      if (duration.trim().isNotEmpty)
                        _Pill(icon: Icons.timer_rounded, text: duration),
                      if (updatedLabel.trim().isNotEmpty)
                        _Pill(icon: Icons.update_rounded, text: updatedLabel),
                    ],
                  ),
                  if (variants.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: variants
                          .map((v) => _Pill(icon: Icons.layers_rounded, text: v))
                          .toList(),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),
            const Icon(Icons.chevron_right_rounded, color: Colors.grey),
          ],
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: UiK.primaryBlue.withOpacity(0.06),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: UiK.uiBorder.withOpacity(0.75)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: UiK.primaryBlue),
          const SizedBox(width: 6),
          Text(
            text,
            style: const TextStyle(
              fontWeight: FontWeight.w900,
              color: UiK.primaryBlue,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoBox extends StatelessWidget {
  const _InfoBox({
    required this.title,
    required this.message,
    required this.icon,
  });

  final String title;
  final String message;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: UiK.uiBorder.withOpacity(0.85)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: UiK.primaryBlue, size: 34),
            const SizedBox(height: 10),
            Text(
              title,
              style: const TextStyle(
                fontWeight: FontWeight.w900,
                color: UiK.primaryBlue,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: Colors.grey.shade700,
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
  const _ErrorBox({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: UiK.uiBorder.withOpacity(0.85)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.error_outline_rounded,
              color: UiK.actionOrange,
              size: 34,
            ),
            const SizedBox(height: 10),
            const Text(
              'Error',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                color: UiK.primaryBlue,
                fontSize: 16,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: Colors.grey.shade700,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: UiK.actionOrange,
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