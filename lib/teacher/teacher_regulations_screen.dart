// teacher_regulations_screen.dart
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

import '../shared/app_theme.dart';
import '../shared/teacher_web_layout.dart';
import '../shared/watermark_background.dart';

class TeacherRegulationsScreen extends StatefulWidget {
  const TeacherRegulationsScreen({super.key});

  @override
  State<TeacherRegulationsScreen> createState() =>
      _TeacherRegulationsScreenState();
}

class _TeacherRegulationsScreenState extends State<TeacherRegulationsScreen> {
  final DatabaseReference _dbRef = FirebaseDatabase.instance.ref();

  bool _isLoading = true;
  String? _errorMessage;

  bool _isTeacher = false;
  List<_RegSection> _sections = const [];

  @override
  void initState() {
    super.initState();
    appThemeController.addListener(_onThemeChanged);
    _loadRegulations();
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

  Future<void> _loadRegulations() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _isTeacher = false;
      _sections = const [];
    });

    try {
      final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
      if (uid.isEmpty) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'You are not logged in.';
        });
        return;
      }

      final isTeacher = await _checkIsTeacher(uid);

      if (!mounted) return;

      if (!isTeacher) {
        setState(() {
          _isLoading = false;
          _isTeacher = false;
          _sections = const [];
        });
        return;
      }

      final sections = await _fetchTeacherSections();

      if (!mounted) return;

      setState(() {
        _isLoading = false;
        _isTeacher = true;
        _sections = sections;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = e.toString();
      });
    }
  }

  Future<bool> _checkIsTeacher(String uid) async {
    try {
      final roleSnap = await _dbRef.child('users/$uid/role').get();
      final role = (roleSnap.value ?? '').toString().trim().toLowerCase();

      return role == 'teacher' || role == 'teachers' || role == 'teacher(s)';
    } catch (_) {
      return false;
    }
  }

  Future<List<_RegSection>> _fetchTeacherSections() async {
    final snap = await _dbRef.child('contract/teacher').get();
    final value = snap.value;

    if (value is! Map) return const [];

    final raw = Map<dynamic, dynamic>.from(value);

    final sectionEntries = raw.entries
        .map((e) => MapEntry(e.key.toString(), e.value))
        .toList();

    final sections = <_RegSection>[];

    for (final entry in sectionEntries) {
      final keyName = entry.key;
      final node = entry.value;

      if (node is! Map) continue;

      final Map<String, dynamic> data = (node).map(
        (k, v) => MapEntry(k.toString(), v),
      );

      final title = (data['title'] ?? keyName).toString().trim();
      final updatedAt = _toInt(data['updatedAt']);
      final sortOrder = _toNullableInt(data['sortOrder']);

      final items = _parseItems(data['items']);
      if (items.isEmpty) continue;

      sections.add(
        _RegSection(
          keyName: keyName,
          title: title,
          updatedAt: updatedAt,
          sortOrder: sortOrder,
          items: items,
        ),
      );
    }

    sections.sort(_compareSections);

    return sections;
  }

  List<_RegItem> _parseItems(dynamic itemsNode) {
    final items = <_RegItem>[];

    if (itemsNode is Map) {
      final entries =
          itemsNode.entries
              .map((e) => MapEntry(e.key.toString(), e.value))
              .toList()
            ..sort((a, b) => _safeInt(a.key).compareTo(_safeInt(b.key)));

      final numericKeys = entries
          .map((e) => int.tryParse(e.key.trim()))
          .whereType<int>()
          .toList();
      final zeroBased = numericKeys.isNotEmpty && numericKeys.contains(0);

      int fallbackNumber = 1;
      for (final e in entries) {
        final text = (e.value ?? '').toString().trim();
        if (text.isEmpty) continue;

        final rawNum = int.tryParse(e.key.trim());
        final displayNum = rawNum == null
            ? fallbackNumber
            : (zeroBased ? rawNum + 1 : rawNum);

        items.add(
          _RegItem(
            number: displayNum <= 0 ? fallbackNumber : displayNum,
            text: text,
          ),
        );
        fallbackNumber++;
      }
    } else if (itemsNode is List) {
      for (int i = 0; i < itemsNode.length; i++) {
        final text = (itemsNode[i] ?? '').toString().trim();
        if (text.isEmpty) continue;

        items.add(_RegItem(number: i + 1, text: text));
      }
    }

    return items;
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

  Widget _buildContent() {
    if (_isLoading) {
      return Center(child: CircularProgressIndicator(color: p.accent));
    }

    if (_errorMessage != null) {
      return _ErrorBox(
        palette: p,
        message: 'Failed to load regulations.\n$_errorMessage',
        onRetry: _loadRegulations,
      );
    }

    if (!_isTeacher) {
      return _InfoBox(
        palette: p,
        title: 'Teachers only',
        message: 'This page is available to teachers only.',
        icon: Icons.lock_rounded,
      );
    }

    if (_sections.isEmpty) {
      return _InfoBox(
        palette: p,
        title: 'No content',
        message: 'There are no regulations available right now.',
        icon: Icons.info_rounded,
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
      children: [
        _HeaderHeroCard(
          palette: p,
          title: 'Teacher Regulations',
          subtitle: 'Tap any section to read the full rules and guidance.',
          sectionsCount: _sections.length,
        ),
        const SizedBox(height: 14),
        _RegSectionCarousel(
          palette: p,
          sections: _sections,
          formatUpdatedAt: _formatUpdatedAt,
          onTapSection: _openSectionSheet,
        ),
        const SizedBox(height: 12),
        _FooterHint(palette: p),
      ],
    );
  }

  void _openSectionSheet(_RegSection section) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) {
        return _RegSectionSheet(
          palette: p,
          section: section,
          updatedAtLabel: _formatUpdatedAt(section.updatedAt),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Scaffold(
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
                'Regulations',
                style: TextStyle(
                  color: p.primary,
                  fontWeight: FontWeight.w900,
                  fontSize: 18,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'Teacher policy and institution rules',
                style: TextStyle(
                  color: p.text.withValues(alpha: 0.65),
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          actions: [
            const SizedBox.shrink(),
            IconButton(
              tooltip: 'Refresh',
              icon: Icon(Icons.refresh_rounded, color: p.accent),
              onPressed: _loadRegulations,
            ),
          ],
        ),
        body: teacherWebBodyFrame(
          context: context,
          maxWidth: 1260,
          child: WatermarkBackground(child: SafeArea(child: _buildContent())),
        ),
      ),
    );
  }
}

/* ===================== UI Widgets ===================== */

class _HeaderHeroCard extends StatelessWidget {
  const _HeaderHeroCard({
    required this.palette,
    required this.title,
    required this.subtitle,
    required this.sectionsCount,
  });

  final AppPalette palette;
  final String title;
  final String subtitle;
  final int sectionsCount;

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
            'Policy Center',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.82),
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            title,
            style: const TextStyle(
              fontWeight: FontWeight.w900,
              color: Colors.white,
              fontSize: 22,
              height: 1.1,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
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
                const Icon(Icons.policy_rounded, color: Colors.white, size: 18),
                const SizedBox(width: 8),
                Text(
                  '$sectionsCount section${sectionsCount == 1 ? '' : 's'} available',
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

class _RegSectionCarousel extends StatefulWidget {
  const _RegSectionCarousel({
    required this.palette,
    required this.sections,
    required this.formatUpdatedAt,
    required this.onTapSection,
  });

  final AppPalette palette;
  final List<_RegSection> sections;
  final String Function(int ms) formatUpdatedAt;
  final void Function(_RegSection section) onTapSection;

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
        Text(
          'Swipe to pick a category',
          style: TextStyle(
            color: p.text.withValues(alpha: 0.7),
            fontWeight: FontWeight.w800,
            fontSize: 12,
          ),
        ),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.center,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 940),
            child: SizedBox(
              height: 288,
              child: PageView.builder(
                controller: _controller,
                itemCount: sections.length,
                itemBuilder: (context, i) {
                  final section = sections[i];
                  final delta = (_page - i).abs().clamp(0.0, 1.0);
                  final scale = 1 - (delta * 0.04);
                  final active = delta < 0.45;

                  return Transform.translate(
                    offset: Offset(0, active ? -8 : 0),
                    child: Transform.scale(
                      scale: scale,
                      child: _RegCategoryCard(
                        palette: p,
                        section: section,
                        updatedAtLabel: widget.formatUpdatedAt(
                          section.updatedAt,
                        ),
                        active: active,
                        onTap: () => widget.onTapSection(section),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
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
      ],
    );
  }
}

class _RegCategoryCard extends StatelessWidget {
  const _RegCategoryCard({
    required this.palette,
    required this.section,
    required this.updatedAtLabel,
    required this.active,
    required this.onTap,
  });

  final AppPalette palette;
  final _RegSection section;
  final String updatedAtLabel;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                palette.cardBg,
                active
                    ? palette.soft.withValues(alpha: 0.65)
                    : palette.cardBg.withValues(alpha: 0.98),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: active
                  ? palette.accent.withValues(alpha: 0.45)
                  : palette.border.withValues(alpha: 0.85),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: active ? 0.12 : 0.05),
                blurRadius: active ? 26 : 14,
                spreadRadius: active ? 1 : 0,
                offset: Offset(0, active ? 14 : 8),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: palette.primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(
                      Icons.category_rounded,
                      color: palette.primary,
                      size: 28,
                    ),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: palette.accent.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '${section.items.length} rules',
                      style: TextStyle(
                        color: palette.accent,
                        fontWeight: FontWeight.w900,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                section.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  color: palette.primary,
                  fontSize: 22,
                  height: 1.25,
                ),
              ),
              const Spacer(),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      updatedAtLabel.isEmpty
                          ? 'No update date'
                          : updatedAtLabel,
                      style: TextStyle(
                        color: palette.text.withValues(alpha: 0.6),
                        fontWeight: FontWeight.w700,
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                  Icon(
                    Icons.arrow_forward_rounded,
                    color: palette.primary,
                    size: 22,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RegSectionSheet extends StatelessWidget {
  const _RegSectionSheet({
    required this.palette,
    required this.section,
    required this.updatedAtLabel,
  });

  final AppPalette palette;
  final _RegSection section;
  final String updatedAtLabel;

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).viewPadding.bottom;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.9,
      ),
      decoration: BoxDecoration(
        color: palette.appBg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 10 + bottomPad),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 48,
                  height: 5,
                  decoration: BoxDecoration(
                    color: palette.border,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              _SectionPopupHeader(
                palette: palette,
                title: section.title,
                count: section.items.length,
                updatedAtLabel: updatedAtLabel,
              ),
              const SizedBox(height: 12),
              Expanded(
                child: ListView.builder(
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
      ),
    );
  }
}

class _SectionPopupHeader extends StatelessWidget {
  const _SectionPopupHeader({
    required this.palette,
    required this.title,
    required this.count,
    required this.updatedAtLabel,
  });

  final AppPalette palette;
  final String title;
  final int count;
  final String updatedAtLabel;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: palette.border.withValues(alpha: 0.85)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: palette.soft,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(Icons.rule_rounded, color: palette.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: palette.primary,
                    fontSize: 16,
                    height: 1.15,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _MiniChip(
                      palette: palette,
                      label: '$count rules',
                      icon: Icons.format_list_numbered_rounded,
                    ),
                    if (updatedAtLabel.isNotEmpty)
                      _MiniChip(
                        palette: palette,
                        label: updatedAtLabel,
                        icon: Icons.update_rounded,
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
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

  final AppPalette palette;
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

  final AppPalette palette;
  final _RegItem item;
  final int index;

  @override
  Widget build(BuildContext context) {
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
                item.number.toString(),
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

class _FooterHint extends StatelessWidget {
  const _FooterHint({required this.palette});

  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: palette.cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: palette.border.withValues(alpha: 0.86)),
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: palette.accent.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: palette.border.withValues(alpha: 0.85)),
            ),
            child: Icon(Icons.info_outline_rounded, color: palette.accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'For questions or objections, please contact the institution through official channels.',
              textAlign: TextAlign.left,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: palette.text.withValues(alpha: 0.72),
                height: 1.35,
              ),
            ),
          ),
        ],
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
              textAlign: TextAlign.center,
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
            const SizedBox(height: 14),
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

/* ===================== Models ===================== */

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
  const _RegItem({required this.number, required this.text});

  final int number;
  final String text;
}
