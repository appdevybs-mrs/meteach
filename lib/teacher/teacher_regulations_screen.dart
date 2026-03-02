// teacher_regulations_screen.dart
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

import '../shared/ui_constants.dart';
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
    _loadRegulations();
  }

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

      // 1) Teacher-only gate: users/$uid/role
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

      // 2) Load all teacher contract sections: contract/teacher
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

      // Adjust these if your database uses different role values.
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

    // Convert to a list of entries with string keys (safe even if keys aren't strings).
    final sectionEntries = raw.entries
        .map((e) => MapEntry(e.key.toString(), e.value))
        .toList();

    // Newest first (by updatedAt)
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

      final Map<String, dynamic> data =
      (node as Map).map((k, v) => MapEntry(k.toString(), v));

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

    // Case A: Items stored as a Map (often numeric keys like "0", "1", "2"...)
    if (itemsNode is Map) {
      final entries = itemsNode.entries
          .map((e) => MapEntry(e.key.toString(), e.value))
          .toList()
        ..sort((a, b) => _safeInt(a.key).compareTo(_safeInt(b.key)));

      // Detect 0-based numbering and shift to 1-based for display
      final numericKeys =
      entries.map((e) => int.tryParse(e.key.trim())).whereType<int>().toList();
      final zeroBased = numericKeys.isNotEmpty && numericKeys.contains(0);

      int fallbackNumber = 1;
      for (final e in entries) {
        final text = (e.value ?? '').toString().trim();
        if (text.isEmpty) continue;

        final rawNum = int.tryParse(e.key.trim());
        final displayNum = rawNum == null
            ? fallbackNumber
            : (zeroBased ? rawNum + 1 : rawNum);

        items.add(_RegItem(number: displayNum <= 0 ? fallbackNumber : displayNum, text: text));
        fallbackNumber++;
      }
    }

    // Case B: Items stored as a List
    else if (itemsNode is List) {
      for (int i = 0; i < itemsNode.length; i++) {
        final text = (itemsNode[i] ?? '').toString().trim();
        if (text.isEmpty) continue;

        // 1-based numbering
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
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null) {
      return _ErrorBox(
        message: 'Failed to load regulations.\n$_errorMessage',
        onRetry: _loadRegulations,
      );
    }

    if (!_isTeacher) {
      return const _InfoBox(
        title: 'Teachers only',
        message: 'This page is available to teachers only.',
        icon: Icons.lock_rounded,
      );
    }

    if (_sections.isEmpty) {
      return const _InfoBox(
        title: 'No content',
        message: 'There are no regulations available right now.',
        icon: Icons.info_rounded,
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
      children: [
        const _HeaderCard(
          title: 'Teacher Regulations',
          subtitle: 'Tap any section title to view the details.',
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
    );
  }

  @override
  Widget build(BuildContext context) {
    // Force LTR so the screen never appears RTL.
    return Directionality(
      textDirection: TextDirection.ltr,
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
              onPressed: _loadRegulations,
            ),
          ],
        ),
        body: WatermarkBackground(
          child: SafeArea(child: _buildContent()),
        ),
      ),
    );
  }
}

/* ===================== UI Widgets ===================== */

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
                  textAlign: TextAlign.left,
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    color: UiK.primaryBlue,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  subtitle,
                  textAlign: TextAlign.left,
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
                    textAlign: TextAlign.left,
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      color: UiK.primaryBlue,
                      height: 1.2,
                    ),
                  ),
                ),
                if (widget.updatedAtLabel.isNotEmpty)
                  Container(
                    padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
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
              item.number.toString(),
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
              textAlign: TextAlign.left,
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
              'For questions or objections, please contact the institution through official channels.',
              textAlign: TextAlign.left,
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
              textAlign: TextAlign.center,
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
            const Icon(Icons.error_outline_rounded,
                color: UiK.actionOrange, size: 34),
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
                      borderRadius: BorderRadius.circular(14)),
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