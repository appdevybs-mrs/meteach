// teacher_syllabus_details_screen.dart
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';

import '../shared/ui_constants.dart';
import '../shared/watermark_background.dart';

class TeacherSyllabusDetailsScreen extends StatefulWidget {
  const TeacherSyllabusDetailsScreen({super.key, required this.courseId});
  final String courseId;

  @override
  State<TeacherSyllabusDetailsScreen> createState() => _TeacherSyllabusDetailsScreenState();
}

class _TeacherSyllabusDetailsScreenState extends State<TeacherSyllabusDetailsScreen> {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  bool _loading = true;
  String? _error;

  _SyllabusCourse? _course;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _course = null;
    });

    try {
      final snap = await _db.child('syllabi/${widget.courseId}').get();
      final v = snap.value;

      if (v is! Map) {
        setState(() {
          _loading = false;
          _course = null;
        });
        return;
      }

      final m = v.map((k, vv) => MapEntry(k.toString(), vv));
      final title = (m['title'] ?? widget.courseId).toString().trim();
      final code = (m['courseCode'] ?? '').toString().trim();
      final duration = (m['duration'] ?? '').toString().trim();
      final updatedAt = _toInt(m['updatedAt']);

      final units = _parseUnits(m['units']);

      // sort units by order (then title)
      units.sort((a, b) {
        final c = a.order.compareTo(b.order);
        if (c != 0) return c;
        return a.title.compareTo(b.title);
      });

      // sort sessions inside unit by order
      for (final u in units) {
        u.sessions.sort((a, b) {
          final c = a.order.compareTo(b.order);
          if (c != 0) return c;
          return a.title.compareTo(b.title);
        });
      }

      setState(() {
        _loading = false;
        _course = _SyllabusCourse(
          id: widget.courseId,
          title: title,
          code: code,
          duration: duration,
          updatedAt: updatedAt,
          units: units,
        );
      });
    } catch (e) {
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  static int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  List<_Unit> _parseUnits(dynamic node) {
    final out = <_Unit>[];

    // units can be List or Map
    final unitMaps = _asListOfMaps(node);

    for (final um in unitMaps) {
      final title = (um['title'] ?? '').toString().trim();
      final otherTitle = (um['otherTitle'] ?? '').toString().trim();
      final desc = (um['description'] ?? '').toString().trim();
      final id = (um['id'] ?? '').toString().trim();
      final order = _toInt(um['order']);

      final sessions = _parseSessions(um['sessions']);

      out.add(_Unit(
        id: id,
        order: order <= 0 ? 999999 : order,
        title: title.isEmpty ? 'Unit' : title,
        otherTitle: otherTitle,
        description: desc,
        sessions: sessions,
      ));
    }

    return out;
  }

  List<_Session> _parseSessions(dynamic node) {
    final out = <_Session>[];
    final sessionMaps = _asListOfMaps(node);

    for (final sm in sessionMaps) {
      out.add(_Session(
        id: (sm['id'] ?? '').toString().trim(),
        order: _toInt(sm['order']) <= 0 ? 999999 : _toInt(sm['order']),
        title: (sm['title'] ?? '').toString().trim(),
        skillType: (sm['skillType'] ?? '').toString().trim(),
        objective: (sm['objective'] ?? '').toString().trim(),
        durationMinutes: _toInt(sm['durationMinutes']),
        content: (sm['content'] ?? '').toString().trim(),
        homework: (sm['homework'] ?? '').toString().trim(),
      ));
    }

    return out;
  }

  static List<Map<String, dynamic>> _asListOfMaps(dynamic node) {
    final out = <Map<String, dynamic>>[];

    if (node is List) {
      for (final x in node) {
        if (x is Map) out.add(Map<String, dynamic>.from(x));
      }
      return out;
    }

    if (node is Map) {
      final mm = Map<dynamic, dynamic>.from(node);
      for (final entry in mm.entries) {
        final v = entry.value;
        if (v is Map) out.add(Map<String, dynamic>.from(v));
      }
      return out;
    }

    return out;
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

  @override
  Widget build(BuildContext context) {
    final c = _course;

    return Scaffold(
        backgroundColor: UiK.appBg,
        appBar: AppBar(
          backgroundColor: Colors.white,
          elevation: 0,
          surfaceTintColor: Colors.white,
          centerTitle: true,
          title: Text(
            c?.title ?? 'Syllabus',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
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
                ? _ErrorBox(message: 'Failed to load syllabus.\n$_error', onRetry: _load)
                : c == null
                ? const _InfoBox(
              title: 'Not found',
              message: 'لا يمكن العثور على هذه الدورة.',
              icon: Icons.info_rounded,
            )
                : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
              children: [
                _CourseTopCard(
                  title: c.title,
                  code: c.code,
                  duration: c.duration,
                  updatedLabel: _fmtDate(c.updatedAt),
                  unitsCount: c.units.length,
                  sessionsCount: c.units.fold<int>(0, (p, u) => p + u.sessions.length),
                ),
                const SizedBox(height: 12),

                ...c.units.map((u) => _UnitCard(unit: u)),
                const SizedBox(height: 12),
                const _FooterHint(),
              ],
            ),
          ),
        ),

    );
  }
}

/* ================== UI ================== */

class _CourseTopCard extends StatelessWidget {
  const _CourseTopCard({
    required this.title,
    required this.code,
    required this.duration,
    required this.updatedLabel,
    required this.unitsCount,
    required this.sessionsCount,
  });

  final String title;
  final String code;
  final String duration;
  final String updatedLabel;
  final int unitsCount;
  final int sessionsCount;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: UiK.uiBorder.withOpacity(0.85)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
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
                child: Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    color: UiK.primaryBlue,
                    fontSize: 16,
                    height: 1.2,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (code.trim().isNotEmpty) _Pill(icon: Icons.qr_code_rounded, text: code),
              if (duration.trim().isNotEmpty) _Pill(icon: Icons.timer_rounded, text: duration),
              _Pill(icon: Icons.layers_rounded, text: '$unitsCount units'),
              _Pill(icon: Icons.playlist_play_rounded, text: '$sessionsCount sessions'),
              if (updatedLabel.isNotEmpty) _Pill(icon: Icons.update_rounded, text: updatedLabel),
            ],
          ),
        ],
      ),
    );
  }
}

class _UnitCard extends StatefulWidget {
  const _UnitCard({required this.unit});
  final _Unit unit;

  @override
  State<_UnitCard> createState() => _UnitCardState();
}

class _UnitCardState extends State<_UnitCard> {
  bool _expanded = true; // start expanded (easy to follow)

  @override
  Widget build(BuildContext context) {
    final u = widget.unit;

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
            initiallyExpanded: _expanded,
            onExpansionChanged: (v) => setState(() => _expanded = v),
            tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            title: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: UiK.actionOrange.withOpacity(0.10),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: UiK.actionOrange.withOpacity(0.22)),
                  ),
                  child: Text(
                    (u.order >= 999999) ? '•' : u.order.toString(),
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      color: UiK.actionOrange,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        u.title,
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          color: UiK.primaryBlue,
                          height: 1.2,
                        ),
                      ),
                      if (u.otherTitle.trim().isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          u.otherTitle,
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            color: Colors.grey.shade600,
                            fontSize: 12,
                          ),
                        ),
                      ],
                      if (u.description.trim().isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(
                          u.description,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: Colors.grey.shade700,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            trailing: Icon(
              _expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
              color: UiK.primaryBlue,
            ),
            children: [
              ...u.sessions.map((s) => _SessionCard(session: s)),
              if (u.sessions.isEmpty)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(top: 10),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: UiK.primaryBlue.withOpacity(0.04),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: UiK.uiBorder.withOpacity(0.70)),
                  ),
                  child: Text(
                    'No sessions in this unit.',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: Colors.grey.shade700,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SessionCard extends StatelessWidget {
  const _SessionCard({required this.session});
  final _Session session;

  @override
  Widget build(BuildContext context) {
    final title = session.title.trim().isEmpty ? 'Session' : session.title.trim();

    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: UiK.primaryBlue.withOpacity(0.04),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: UiK.uiBorder.withOpacity(0.70)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: UiK.primaryBlue.withOpacity(0.10),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: UiK.primaryBlue.withOpacity(0.20)),
                ),
                child: Text(
                  (session.order >= 999999) ? '•' : session.order.toString(),
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    color: UiK.primaryBlue,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    color: UiK.primaryBlue,
                    height: 1.2,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (session.skillType.trim().isNotEmpty)
                _Pill(icon: Icons.category_rounded, text: session.skillType),
              if (session.durationMinutes > 0)
                _Pill(icon: Icons.timelapse_rounded, text: '${session.durationMinutes} min'),
            ],
          ),
          if (session.objective.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            _Line(icon: Icons.flag_rounded, label: 'Objective', text: session.objective),
          ],
          if (session.content.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            _Line(icon: Icons.article_rounded, label: 'Content', text: session.content),
          ],
          if (session.homework.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            _Line(icon: Icons.assignment_rounded, label: 'Homework', text: session.homework),
          ],
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.icon, required this.label, required this.text});
  final IconData icon;
  final String label;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: UiK.actionOrange),
        const SizedBox(width: 8),
        Expanded(
          child: RichText(
            text: TextSpan(
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: Colors.grey.shade800,
                height: 1.45,
              ),
              children: [
                TextSpan(
                  text: '$label: ',
                  style: const TextStyle(fontWeight: FontWeight.w900, color: UiK.primaryBlue),
                ),
                TextSpan(text: text),
              ],
            ),
          ),
        ),
      ],
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
              'اتبع الوحدات والحصص حسب الترتيب (Order) لتطبيق البرنامج كما هو مخطط.',
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
              style: const TextStyle(fontWeight: FontWeight.w900, color: UiK.primaryBlue, fontSize: 16),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(fontWeight: FontWeight.w700, color: Colors.grey.shade700, height: 1.35),
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
              style: TextStyle(fontWeight: FontWeight.w900, color: UiK.primaryBlue, fontSize: 16),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(fontWeight: FontWeight.w700, color: Colors.grey.shade700, height: 1.35),
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
                label: const Text('Retry', style: TextStyle(fontWeight: FontWeight.w900)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/* ================== Models ================== */

class _SyllabusCourse {
  const _SyllabusCourse({
    required this.id,
    required this.title,
    required this.code,
    required this.duration,
    required this.updatedAt,
    required this.units,
  });

  final String id;
  final String title;
  final String code;
  final String duration;
  final int updatedAt;
  final List<_Unit> units;
}

class _Unit {
  _Unit({
    required this.id,
    required this.order,
    required this.title,
    required this.otherTitle,
    required this.description,
    required this.sessions,
  });

  final String id;
  final int order;
  final String title;
  final String otherTitle;
  final String description;
  final List<_Session> sessions;
}

class _Session {
  const _Session({
    required this.id,
    required this.order,
    required this.title,
    required this.skillType,
    required this.objective,
    required this.durationMinutes,
    required this.content,
    required this.homework,
  });

  final String id;
  final int order;
  final String title;
  final String skillType;
  final String objective;
  final int durationMinutes;
  final String content;
  final String homework;
}