// learner_regulations_screen.dart
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

import '../shared/app_theme.dart';
import '../shared/human_error.dart';
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
          _error = 'Not logged in.';
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

      keys.sort((a, b) {
        final aa = _extractUpdatedAt(raw[a]);
        final bb = _extractUpdatedAt(raw[b]);
        return bb.compareTo(aa);
      });

      for (final key in keys) {
        final node = raw[key];
        if (node is! Map) continue;

        final m = node.map((k, vv) => MapEntry(k.toString(), vv));

        final title = (m['title'] ?? key).toString().trim();
        final updatedAt = _toInt(m['updatedAt']);

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
            items: items,
          ),
        );
      }

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

  static int _extractUpdatedAt(dynamic node) {
    if (node is! Map) return 0;
    final m = node.map((k, vv) => MapEntry(k.toString(), vv));
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
            'Regulations',
            style: TextStyle(color: p.primary, fontWeight: FontWeight.w900),
          ),
          actions: [
            IconButton(
              tooltip: 'Refresh',
              icon: Icon(Icons.refresh_rounded, color: p.accent),
              onPressed: _loadAll,
            ),
          ],
        ),
        body: WatermarkBackground(
          child: SafeArea(
            child: _loading
                ? Center(child: CircularProgressIndicator(color: p.primary))
                : _error != null
                ? _ErrorBox(
                    palette: p,
                    message: 'Failed to load regulations.\n$_error',
                    onRetry: _loadAll,
                  )
                : !_isLearner
                ? _InfoBox(
                    palette: p,
                    title: 'Learners only',
                    message: 'هذه الصفحة مخصصة للمتعلمين فقط.',
                    icon: Icons.lock_rounded,
                  )
                : _sections.isEmpty
                ? _InfoBox(
                    palette: p,
                    title: 'No content',
                    message: 'لا توجد قوانين متاحة حاليًا.',
                    icon: Icons.info_rounded,
                  )
                : RefreshIndicator(
                    color: p.primary,
                    onRefresh: _loadAll,
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
                      children: [
                        _HeroHeaderCard(palette: p),
                        const SizedBox(height: 16),
                        _QuickMetaStrip(
                          palette: p,
                          sectionsCount: _sections.length,
                        ),
                        const SizedBox(height: 16),
                        ..._sections.map(
                          (s) => _SectionCard(
                            palette: p,
                            section: s,
                            updatedAtLabel: _formatUpdatedAt(s.updatedAt),
                          ),
                        ),
                        const SizedBox(height: 4),
                        _FooterHint(palette: p),
                      ],
                    ),
                  ),
          ),
        ),
      ),
    );
  }
}

class _HeroHeaderCard extends StatelessWidget {
  const _HeroHeaderCard({required this.palette});

  final _RegPalette palette;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [palette.primary, palette.primary.withOpacity(0.88)],
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
        ),
        borderRadius: BorderRadius.circular(26),
        boxShadow: [
          BoxShadow(
            color: palette.primary.withOpacity(0.18),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.14),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.white.withOpacity(0.18)),
            ),
            child: const Icon(
              Icons.policy_rounded,
              color: Colors.white,
              size: 28,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'القوانين والتنظيم',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize: 22,
                    height: 1.1,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'اطلع على التعليمات الرسمية الخاصة بالمتعلمين بشكل منظم وواضح. اضغط على أي قسم لعرض التفاصيل.',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.88),
                    fontWeight: FontWeight.w700,
                    height: 1.45,
                    fontSize: 13,
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

class _QuickMetaStrip extends StatelessWidget {
  const _QuickMetaStrip({required this.palette, required this.sectionsCount});

  final _RegPalette palette;
  final int sectionsCount;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _MetaMiniCard(
            palette: palette,
            icon: Icons.menu_book_rounded,
            title: 'الأقسام',
            value: '$sectionsCount',
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _MetaMiniCard(
            palette: palette,
            icon: Icons.visibility_outlined,
            title: 'التصفح',
            value: 'واضح وسريع',
          ),
        ),
      ],
    );
  }
}

class _MetaMiniCard extends StatelessWidget {
  const _MetaMiniCard({
    required this.palette,
    required this.icon,
    required this.title,
    required this.value,
  });

  final _RegPalette palette;
  final IconData icon;
  final String title;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: palette.border.withOpacity(0.85)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 12,
            offset: const Offset(0, 7),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: palette.soft,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: palette.primary),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: palette.text.withOpacity(0.64),
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  value,
                  style: TextStyle(
                    color: palette.primary,
                    fontWeight: FontWeight.w900,
                    fontSize: 14,
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

  final _RegPalette palette;
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
        border: Border.all(
          color: _expanded
              ? p.accent.withOpacity(0.35)
              : p.border.withOpacity(0.85),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 14,
            offset: const Offset(0, 8),
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
            collapsedBackgroundColor: p.cardBg,
            backgroundColor: p.cardBg,
            title: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: p.soft,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(Icons.gavel_rounded, color: p.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    s.title,
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      color: p.primary,
                      height: 1.2,
                      fontSize: 15,
                    ),
                  ),
                ),
                if (widget.updatedAtLabel.isNotEmpty) ...[
                  const SizedBox(width: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: p.accent.withOpacity(0.10),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: p.accent.withOpacity(0.22)),
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
            trailing: AnimatedRotation(
              turns: _expanded ? 0.5 : 0,
              duration: const Duration(milliseconds: 180),
              child: Icon(
                Icons.keyboard_arrow_down_rounded,
                color: p.primary,
                size: 28,
              ),
            ),
            children: [
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 6),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: p.soft.withOpacity(0.55),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: p.border.withOpacity(0.75)),
                ),
                child: Text(
                  '${s.items.length} بند',
                  style: TextStyle(
                    color: p.text.withOpacity(0.72),
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
                  ),
                ),
              ),
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

  final _RegPalette palette;
  final _RegItem item;

  @override
  Widget build(BuildContext context) {
    final isBullet = item.n <= 0;

    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.soft.withOpacity(0.45),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: palette.border.withOpacity(0.72)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: palette.accent.withOpacity(0.12),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: palette.accent.withOpacity(0.25)),
            ),
            child: Text(
              isBullet ? '•' : item.n.toString(),
              style: TextStyle(
                fontWeight: FontWeight.w900,
                color: palette.accent,
                fontSize: 13,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              item.text,
              textAlign: TextAlign.start,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: palette.text,
                height: 1.5,
                fontSize: 13.5,
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

  final _RegPalette palette;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: palette.cardBg,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: palette.border.withOpacity(0.85)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 12,
            offset: const Offset(0, 7),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: palette.accent.withOpacity(0.10),
              borderRadius: BorderRadius.circular(15),
              border: Border.all(color: palette.accent.withOpacity(0.18)),
            ),
            child: Icon(Icons.info_outline_rounded, color: palette.accent),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'للاستفسارات أو الاعتراضات، يرجى التواصل عبر القنوات الرسمية للمؤسسة.',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: palette.text.withOpacity(0.74),
                height: 1.4,
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
          border: Border.all(color: palette.border.withOpacity(0.85)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.04),
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
                color: palette.text.withOpacity(0.72),
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
          border: Border.all(color: palette.border.withOpacity(0.85)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.04),
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
                color: palette.accent.withOpacity(0.10),
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
              'Error',
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
                color: palette.text.withOpacity(0.72),
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
