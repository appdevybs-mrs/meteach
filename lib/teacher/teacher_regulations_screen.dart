// teacher_regulations_screen.dart
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

import '../shared/app_theme.dart';
import '../shared/screen_help_guide.dart';
import '../shared/teacher_tour_guide.dart';
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

    sectionEntries.sort((a, b) {
      final aa = _extractUpdatedAt(a.value);
      final bb = _extractUpdatedAt(b.value);
      return bb.compareTo(aa);
    });

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

      final items = _parseItems(data['items']);
      if (items.isEmpty) continue;

      sections.add(
        _RegSection(
          keyName: keyName,
          title: title,
          updatedAt: updatedAt,
          items: items,
        ),
      );
    }

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

  static int _extractUpdatedAt(dynamic node) {
    if (node is! Map) return 0;
    final m = node.map((k, v) => MapEntry(k.toString(), v));
    return _toInt(m['updatedAt']);
  }

  static int _safeInt(String s) => int.tryParse(s.trim()) ?? 0;

  static int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
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
        ..._sections.map(
          (s) => _SectionCard(
            palette: p,
            section: s,
            updatedAtLabel: _formatUpdatedAt(s.updatedAt),
          ),
        ),
        const SizedBox(height: 12),
        _FooterHint(palette: p),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    TeacherTourGuide.schedule(
      context,
      screenId: 'teacher_regulations',
      hints: const [
        TeacherTourHint(
          title: 'Regulations',
          line: 'Read academy rules and updated policy sections here.',
        ),
      ],
    );

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

class _SectionCard extends StatefulWidget {
  const _SectionCard({
    required this.palette,
    required this.section,
    required this.updatedAtLabel,
  });

  final AppPalette palette;
  final _RegSection section;
  final String updatedAtLabel;

  @override
  State<_SectionCard> createState() => _SectionCardState();
}

class _SectionCardState extends State<_SectionCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final s = widget.section;
    final p = widget.palette;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: p.cardBg,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: p.border.withValues(alpha: 0.88)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22),
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            onExpansionChanged: (v) => setState(() => _expanded = v),
            tilePadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 10,
            ),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            title: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: p.soft,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(Icons.gavel_rounded, color: p.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      s.title,
                      textAlign: TextAlign.left,
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        color: p.primary,
                        height: 1.2,
                        fontSize: 15,
                      ),
                    ),
                  ),
                ),
                if (widget.updatedAtLabel.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: p.accent.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: p.accent.withValues(alpha: 0.22),
                      ),
                    ),
                    child: Text(
                      widget.updatedAtLabel,
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        color: p.accent,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            trailing: Icon(
              _expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
              color: p.primary,
            ),
            children: [
              ...s.items.map((it) => _RegItemRow(palette: p, item: it)),
            ],
          ),
        ),
      ),
    );
  }
}

class _RegItemRow extends StatelessWidget {
  const _RegItemRow({required this.palette, required this.item});

  final AppPalette palette;
  final _RegItem item;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: palette.soft.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: palette.border.withValues(alpha: 0.74)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: palette.accent.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: palette.accent.withValues(alpha: 0.24)),
            ),
            child: Text(
              item.number.toString(),
              style: TextStyle(
                fontWeight: FontWeight.w900,
                color: palette.accent,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              item.text,
              textAlign: TextAlign.left,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: palette.text.withValues(alpha: 0.88),
                height: 1.45,
              ),
            ),
          ),
        ],
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
    required this.items,
  });

  final String keyName;
  final String title;
  final int updatedAt;
  final List<_RegItem> items;
}

class _RegItem {
  const _RegItem({required this.number, required this.text});

  final int number;
  final String text;
}
