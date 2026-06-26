// learner_regulations_screen.dart
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

import '../shared/app_theme.dart';
import '../shared/human_error.dart';
import '../shared/learner_web_layout.dart';
import '../shared/watermark_background.dart';

class LearnerRegulationsScreen extends StatefulWidget {
  const LearnerRegulationsScreen({super.key});

  @override
  State<LearnerRegulationsScreen> createState() =>
      _LearnerRegulationsScreenState();
}

class _LearnerRegulationsScreenState extends State<LearnerRegulationsScreen> {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  bool _loading = true;
  String? _error;

  bool _isLearner = false;
  List<_RegSection> _sections = const [];

  @override
  void initState() {
    super.initState();
    appThemeController.addListener(_onThemeChanged);
    _loadAll();
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

  _RegPalette get palette => _toRegPalette(appThemeController.palette);

  _RegPalette _toRegPalette(AppPalette p) {
    return _RegPalette(
      primary: p.primary,
      accent: p.accent,
      text: p.text,
      appBg: p.appBg,
      cardBg: p.cardBg,
      border: p.border,
      soft: p.soft,
    );
  }

  Future<void> _loadAll() async {
    setState(() {
      _loading = true;
      _error = null;
      _isLearner = false;
      _sections = const [];
    });

    try {
      final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
      if (uid.isEmpty) {
        setState(() {
          _loading = false;
          _error = 'يجب تسجيل الدخول أولًا.';
        });
        return;
      }

      bool isLearner = false;
      try {
        final roleSnap = await _db.child('users/$uid/role').get();
        final role = (roleSnap.value ?? '').toString().trim().toLowerCase();
        isLearner = role == 'learner' || role == 'student';
      } catch (_) {
        isLearner = false;
      }

      if (!mounted) return;

      if (!isLearner) {
        setState(() {
          _loading = false;
          _isLearner = false;
          _sections = const [];
        });
        return;
      }

      final snap = await _db.child('contract/learner').get();
      final v = snap.value;

      if (v is! Map) {
        setState(() {
          _loading = false;
          _isLearner = true;
          _sections = const [];
        });
        return;
      }

      final raw = Map<dynamic, dynamic>.from(v);
      final sections = <_RegSection>[];

      final keys = raw.keys.map((e) => e.toString()).toList();

      for (final key in keys) {
        final node = raw[key];
        if (node is! Map) continue;

        final m = node.map((k, vv) => MapEntry(k.toString(), vv));

        final title = (m['title'] ?? key).toString().trim();
        final updatedAt = _toInt(m['updatedAt']);
        final sortOrder = _toNullableInt(m['sortOrder']);

        final itemsNode = m['items'];
        final items = <_RegItem>[];

        if (itemsNode is Map) {
          final im = Map<dynamic, dynamic>.from(itemsNode);

          final itemKeys = im.keys.map((e) => e.toString()).toList()
            ..sort((a, b) => _safeInt(a).compareTo(_safeInt(b)));

          for (final ik in itemKeys) {
            final text = (im[ik] ?? '').toString().trim();
            if (text.isEmpty) continue;
            items.add(_RegItem(n: _safeInt(ik), text: text));
          }
        } else if (itemsNode is List) {
          for (int i = 0; i < itemsNode.length; i++) {
            final text = (itemsNode[i] ?? '').toString().trim();
            if (text.isEmpty) continue;
            items.add(_RegItem(n: i, text: text));
          }
        }

        if (items.isEmpty) continue;

        sections.add(
          _RegSection(
            keyName: key,
            title: title,
            updatedAt: updatedAt,
            sortOrder: sortOrder,
            items: items,
          ),
        );
      }

      sections.sort(_compareSections);

      if (!mounted) return;

      setState(() {
        _loading = false;
        _isLearner = true;
        _sections = sections;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = toHumanError(e);
      });
    }
  }

  static int _safeInt(String s) => int.tryParse(s.trim()) ?? 0;

  static int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  static int? _toNullableInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '');
  }

  static int _compareSections(_RegSection a, _RegSection b) {
    final ao = a.sortOrder;
    final bo = b.sortOrder;
    final aHas = ao != null;
    final bHas = bo != null;

    if (aHas && bHas) {
      final byOrder = ao.compareTo(bo);
      if (byOrder != 0) return byOrder;
    } else if (aHas != bHas) {
      return aHas ? -1 : 1;
    }

    return b.updatedAt.compareTo(a.updatedAt);
  }

  String _formatUpdatedAt(int ms) {
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

  @override
  Widget build(BuildContext context) {
    final p = palette;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: p.appBg,
        appBar: AppBar(
          backgroundColor: p.cardBg,
          elevation: 0,
          surfaceTintColor: p.cardBg,
          centerTitle: true,
          iconTheme: IconThemeData(color: p.primary),
          title: Text(
            'القوانين',
            style: TextStyle(color: p.primary, fontWeight: FontWeight.w900),
          ),
          actions: [
            IconButton(
              tooltip: 'تحديث',
              icon: Icon(Icons.refresh_rounded, color: p.accent),
              onPressed: _loadAll,
            ),
          ],
        ),
        body: learnerWebBodyFrame(
          context: context,
          maxWidth: 1220,
          child: WatermarkBackground(
            child: SafeArea(
              child: _loading
                  ? Center(child: CircularProgressIndicator(color: p.primary))
                  : _error != null
                  ? _ErrorBox(
                      palette: p,
                      message: 'تعذر تحميل القوانين.\n$_error',
                      onRetry: _loadAll,
                    )
                  : !_isLearner
                  ? _InfoBox(
                      palette: p,
                      title: 'للمتعلمين فقط',
                      message: 'هذه الصفحة مخصصة للمتعلمين فقط.',
                      icon: Icons.lock_rounded,
                    )
                  : _sections.isEmpty
                  ? _InfoBox(
                      palette: p,
                      title: 'لا يوجد محتوى',
                      message: 'لا توجد قوانين متاحة حاليًا.',
                      icon: Icons.info_rounded,
                    )
                  : _RegSectionCarousel(
                      palette: p,
                      sections: _sections,
                      formatUpdatedAt: _formatUpdatedAt,
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RegSectionCarousel extends StatefulWidget {
  const _RegSectionCarousel({
    required this.palette,
    required this.sections,
    required this.formatUpdatedAt,
  });

  final _RegPalette palette;
  final List<_RegSection> sections;
  final String Function(int ms) formatUpdatedAt;

  @override
  State<_RegSectionCarousel> createState() => _RegSectionCarouselState();
}

class _RegSectionCarouselState extends State<_RegSectionCarousel> {
  late final PageController _controller;
  double _page = 0;

  @override
  void initState() {
    super.initState();
    _controller = PageController(viewportFraction: 0.82);
    _controller.addListener(_syncPage);
  }

  @override
  void dispose() {
    _controller.removeListener(_syncPage);
    _controller.dispose();
    super.dispose();
  }

  void _syncPage() {
    if (!_controller.hasClients || !mounted) return;
    setState(() {
      _page = _controller.page ?? _controller.initialPage.toDouble();
    });
  }

  @override
  Widget build(BuildContext context) {
    final sections = widget.sections;
    final p = widget.palette;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: PageView.builder(
            controller: _controller,
            itemCount: sections.length,
            itemBuilder: (context, i) {
              final section = sections[i];
              return _RegSectionPage(
                palette: p,
                section: section,
                updatedAtLabel: widget.formatUpdatedAt(section.updatedAt),
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        Center(
          child: Wrap(
            spacing: 7,
            children: List.generate(sections.length, (i) {
              final active = (_page - i).abs() < 0.5;
              return AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                width: active ? 22 : 8,
                height: 8,
                decoration: BoxDecoration(
                  color: active
                      ? p.accent.withValues(alpha: 0.95)
                      : p.border.withValues(alpha: 0.9),
                  borderRadius: BorderRadius.circular(999),
                ),
              );
            }),
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }
}

class _RegSectionPage extends StatelessWidget {
  const _RegSectionPage({
    required this.palette,
    required this.section,
    required this.updatedAtLabel,
  });

  final _RegPalette palette;
  final _RegSection section;
  final String updatedAtLabel;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: palette.cardBg,
          borderRadius: BorderRadius.circular(26),
          border: Border.all(color: palette.border.withValues(alpha: 0.85)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 18,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              section.title,
              style: TextStyle(
                color: palette.primary,
                fontWeight: FontWeight.w900,
                fontSize: 24,
                height: 1.2,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _MiniChip(
                  palette: palette,
                  label: '${section.items.length} بنود',
                  icon: Icons.format_list_bulleted_rounded,
                ),
                if (updatedAtLabel.isNotEmpty)
                  _MiniChip(
                    palette: palette,
                    label: updatedAtLabel,
                    icon: Icons.update_rounded,
                  ),
              ],
            ),
            const SizedBox(height: 14),
            Divider(color: palette.border.withValues(alpha: 0.9), height: 1),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.builder(
                padding: EdgeInsets.zero,
                itemCount: section.items.length,
                itemBuilder: (context, i) {
                  return _PopupRegulationCard(
                    palette: palette,
                    item: section.items[i],
                    index: i,
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniChip extends StatelessWidget {
  const _MiniChip({
    required this.palette,
    required this.label,
    required this.icon,
  });

  final _RegPalette palette;
  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: palette.accent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: palette.accent.withValues(alpha: 0.2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: palette.accent, size: 14),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w900,
              color: palette.accent,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

class _PopupRegulationCard extends StatelessWidget {
  const _PopupRegulationCard({
    required this.palette,
    required this.item,
    required this.index,
  });

  final _RegPalette palette;
  final _RegItem item;
  final int index;

  @override
  Widget build(BuildContext context) {
    final isBullet = item.n <= 0;
    final animationStep = index > 8 ? 8 : index;

    return TweenAnimationBuilder<double>(
      duration: Duration(milliseconds: 280 + (animationStep * 60)),
      curve: Curves.easeOutCubic,
      tween: Tween(begin: 0, end: 1),
      builder: (context, t, child) {
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, 14 * (1 - t)),
            child: child,
          ),
        );
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: palette.cardBg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: palette.border.withValues(alpha: 0.8)),
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
              width: 33,
              height: 33,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: palette.accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: palette.accent.withValues(alpha: 0.22),
                ),
              ),
              child: Text(
                isBullet ? '•' : item.n.toString(),
                style: TextStyle(
                  color: palette.accent,
                  fontWeight: FontWeight.w900,
                  fontSize: 13,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                item.text,
                style: TextStyle(
                  color: palette.text,
                  fontWeight: FontWeight.w700,
                  height: 1.5,
                  fontSize: 13.5,
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

  final _RegPalette palette;
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
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: palette.border.withValues(alpha: 0.85)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 14,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 58,
              height: 58,
              decoration: BoxDecoration(
                color: palette.soft,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Icon(icon, color: palette.primary, size: 30),
            ),
            const SizedBox(height: 14),
            Text(
              title,
              style: TextStyle(
                fontWeight: FontWeight.w900,
                color: palette.primary,
                fontSize: 17,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: palette.text.withValues(alpha: 0.72),
                height: 1.4,
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

  final _RegPalette palette;
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
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: palette.border.withValues(alpha: 0.85)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 14,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 58,
              height: 58,
              decoration: BoxDecoration(
                color: palette.accent.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Icon(
                Icons.error_outline_rounded,
                color: palette.accent,
                size: 30,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'حدث خطأ',
              style: TextStyle(
                fontWeight: FontWeight.w900,
                color: palette.primary,
                fontSize: 17,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: palette.text.withValues(alpha: 0.72),
                height: 1.4,
              ),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: onRetry,
                style: ElevatedButton.styleFrom(
                  backgroundColor: palette.accent,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                icon: const Icon(Icons.refresh_rounded),
                label: const Text(
                  'إعادة المحاولة',
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

class _RegSection {
  const _RegSection({
    required this.keyName,
    required this.title,
    required this.updatedAt,
    required this.sortOrder,
    required this.items,
  });

  final String keyName;
  final String title;
  final int updatedAt;
  final int? sortOrder;
  final List<_RegItem> items;
}

class _RegItem {
  const _RegItem({required this.n, required this.text});

  final int n;
  final String text;
}

class _RegPalette {
  const _RegPalette({
    required this.primary,
    required this.accent,
    required this.text,
    required this.appBg,
    required this.cardBg,
    required this.border,
    required this.soft,
  });

  final Color primary;
  final Color accent;
  final Color text;
  final Color appBg;
  final Color cardBg;
  final Color border;
  final Color soft;
}
