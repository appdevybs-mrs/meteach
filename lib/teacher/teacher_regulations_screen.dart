// teacher_regulations_screen.dart
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

import '../shared/ui_constants.dart';
import '../shared/watermark_background.dart';

class TeacherRegulationsScreen extends StatefulWidget {
  const TeacherRegulationsScreen({super.key});

  @override
  State<TeacherRegulationsScreen> createState() => _TeacherRegulationsScreenState();
}

class _TeacherRegulationsScreenState extends State<TeacherRegulationsScreen> {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  bool _loading = true;
  String? _error;

  bool _isTeacher = false;
  List<_RegSection> _sections = const [];

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<void> _loadAll() async {
    setState(() {
      _loading = true;
      _error = null;
      _isTeacher = false;
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

      // ✅ 1) Teacher-only (users/$uid/role)
      bool isTeacher = false;
      try {
        final roleSnap = await _db.child('users/$uid/role').get();
        final role = (roleSnap.value ?? '').toString().trim().toLowerCase();
        isTeacher = role == 'teacher' || role == 'teachers' || role == 'teacher(s)';
      } catch (_) {
        isTeacher = false;
      }

      if (!mounted) return;

      if (!isTeacher) {
        setState(() {
          _loading = false;
          _isTeacher = false;
          _sections = const [];
        });
        return;
      }

      // ✅ 2) Load contract/teacher (ALL sections)
      final snap = await _db.child('contract/teacher').get();
      final v = snap.value;

      if (v is! Map) {
        setState(() {
          _loading = false;
          _isTeacher = true;
          _sections = const [];
        });
        return;
      }

      final raw = Map<dynamic, dynamic>.from(v);
      final sections = <_RegSection>[];

      final keys = raw.keys.map((e) => e.toString()).toList();

      // newest first
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

        // ✅ Map OR List (fix for numeric keys)
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
          // if you want to hide 0-index:
          // items.removeWhere((x) => x.n == 0);
        }

        if (items.isEmpty) continue;

        sections.add(_RegSection(
          keyName: key,
          title: title,
          updatedAt: updatedAt,
          items: items,
        ));
      }

      if (!mounted) return;

      setState(() {
        _loading = false;
        _isTeacher = true;
        _sections = sections;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
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
    // ✅ Arabic-friendly (RTL)
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: UiK.appBg,
        appBar: AppBar(
          backgroundColor: Colors.white,
          elevation: 0,
          surfaceTintColor: Colors.white,
          centerTitle: true,
          title: const Text(
            'Regulations',
            style: TextStyle(
              color: UiK.primaryBlue,
              fontWeight: FontWeight.w900,
            ),
          ),
          actions: [
            IconButton(
              tooltip: 'Refresh',
              icon: const Icon(Icons.refresh_rounded, color: UiK.primaryBlue),
              onPressed: _loadAll,
            ),
          ],
        ),
        body: WatermarkBackground(
          child: SafeArea(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? _ErrorBox(
              message: 'Failed to load regulations.\n$_error',
              onRetry: _loadAll,
            )
                : !_isTeacher
                ? const _InfoBox(
              title: 'Teachers only',
              message: 'هذه الصفحة مخصصة للأساتذة فقط.',
              icon: Icons.lock_rounded,
            )
                : _sections.isEmpty
                ? const _InfoBox(
              title: 'No content',
              message: 'لا توجد قوانين متاحة حاليًا.',
              icon: Icons.info_rounded,
            )
                : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
              children: [
                const _HeaderCard(
                  title: 'قوانين الأساتذة',
                  subtitle: 'اضغط على أي عنوان لعرض التفاصيل.',
                ),
                const SizedBox(height: 12),
                ..._sections.map(
                      (s) => _SectionCard(
                    section: s,
                    updatedAtLabel: _formatUpdatedAt(s.updatedAt),
                  ),
                ),
                const SizedBox(height: 12),
                const _FooterHint(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/* ====== UI widgets (same style as learner screen) ====== */

class _HeaderCard extends StatelessWidget {
  const _HeaderCard({required this.title, required this.subtitle});
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: UiK.uiBorder.withOpacity(0.85)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: UiK.primaryBlue.withOpacity(0.08),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: UiK.uiBorder.withOpacity(0.85)),
            ),
            child: const Icon(Icons.policy_rounded, color: UiK.primaryBlue),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
                  subtitle,
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: Colors.grey.shade700,
                    height: 1.35,
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
  const _SectionCard({required this.section, required this.updatedAtLabel});
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

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: UiK.uiBorder.withOpacity(0.85)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            onExpansionChanged: (v) => setState(() => _expanded = v),
            tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            title: Row(
              children: [
                Expanded(
                  child: Text(
                    s.title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      color: UiK.primaryBlue,
                      height: 1.2,
                    ),
                  ),
                ),
                if (widget.updatedAtLabel.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: UiK.primaryBlue.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: UiK.uiBorder.withOpacity(0.85)),
                    ),
                    child: Text(
                      widget.updatedAtLabel,
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        color: UiK.primaryBlue,
                        fontSize: 12,
                      ),
                    ),
                  ),
              ],
            ),
            trailing: Icon(
              _expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
              color: UiK.primaryBlue,
            ),
            children: [
              ...s.items.map((it) => _RegItemRow(item: it)),
            ],
          ),
        ),
      ),
    );
  }
}

class _RegItemRow extends StatelessWidget {
  const _RegItemRow({required this.item});
  final _RegItem item;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: UiK.primaryBlue.withOpacity(0.04),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: UiK.uiBorder.withOpacity(0.70)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: UiK.actionOrange.withOpacity(0.10),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: UiK.actionOrange.withOpacity(0.25)),
            ),
            child: Text(
              item.n <= 0 ? '•' : item.n.toString(),
              style: const TextStyle(
                fontWeight: FontWeight.w900,
                color: UiK.actionOrange,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              item.text,
              textAlign: TextAlign.start,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: Colors.grey.shade800,
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
  const _FooterHint();

  @override
  Widget build(BuildContext context) {
    return Container(
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
              color: UiK.actionOrange.withOpacity(0.10),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: UiK.uiBorder.withOpacity(0.85)),
            ),
            child: const Icon(Icons.info_outline_rounded, color: UiK.actionOrange),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'للاستفسارات أو الاعتراضات، يرجى التواصل عبر القنوات الرسمية للمؤسسة.',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: Colors.grey.shade700,
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
  const _InfoBox({required this.title, required this.message, required this.icon});
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
            const Icon(Icons.error_outline_rounded, color: UiK.actionOrange, size: 34),
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
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
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

/* ====== Models ====== */
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