// teacher_syllabus_details_screen.dart
// ✅ FULL DROP-IN REPLACEMENT (copy/paste)
//
// Goal:
// - Force this screen to be LTR (so it won't look RTL even if the app locale is Arabic)
// - Remove ALL Arabic text/comments and use clear English everywhere
// - Keep your current Firebase schema assumptions exactly the same (read-only UI)
// - Make the UI easier to follow: summary + recommendations + search + clean empty states
//
// Data expected (same as your code):
// syllabi/<courseId> -> { title, courseCode, duration, updatedAt, units:[...] or units:{...} }
// units -> { id, order, title, otherTitle, description, sessions:[...] or sessions:{...} }
// sessions -> { id, order, title, skillType, objective, durationMinutes, content, homework }

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

  // Search
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();

    _search.addListener(() {
      final v = _search.text.trim();
      if (v == _query) return;
      setState(() => _query = v);
    });

    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _course = null;
    });

    try {
      final snap = await _db.child('syllabi/${widget.courseId}').get();
      if (!mounted) return;

      final raw = snap.value;
      if (raw is! Map) {
        setState(() {
          _loading = false;
          _course = null;
        });
        return;
      }

      final data = raw.map((k, v) => MapEntry(k.toString(), v));

      final title = (data['title'] ?? widget.courseId).toString().trim();
      final code = (data['courseCode'] ?? '').toString().trim();
      final duration = (data['duration'] ?? '').toString().trim();
      final updatedAt = _toInt(data['updatedAt']);

      final units = _parseUnits(data['units']);

      // Sort units by order, then title
      units.sort((a, b) {
        final c = a.order.compareTo(b.order);
        if (c != 0) return c;
        return a.title.compareTo(b.title);
      });

      // Sort sessions by order inside each unit
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
          title: title.isEmpty ? 'Syllabus' : title,
          code: code,
          duration: duration,
          updatedAt: updatedAt,
          units: units,
        );
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  // ---------- Parsing helpers (same schema expectations) ----------

  static int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
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

  List<_Unit> _parseUnits(dynamic node) {
    final out = <_Unit>[];
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

  // ---------- Search helpers ----------

  bool _matches(_Session s, String q) {
    if (q.isEmpty) return true;
    final z = q.toLowerCase();
    String t(String v) => v.toLowerCase();

    return t(s.title).contains(z) ||
        t(s.skillType).contains(z) ||
        t(s.objective).contains(z) ||
        t(s.content).contains(z) ||
        t(s.homework).contains(z) ||
        t(s.id).contains(z);
  }

  List<_Unit> _filteredUnits(_SyllabusCourse c) {
    if (_query.isEmpty) return c.units;

    final out = <_Unit>[];
    for (final u in c.units) {
      final filteredSessions = u.sessions.where((s) => _matches(s, _query)).toList();
      if (filteredSessions.isEmpty) continue;

      out.add(_Unit(
        id: u.id,
        order: u.order,
        title: u.title,
        otherTitle: u.otherTitle,
        description: u.description,
        sessions: filteredSessions,
      ));
    }
    return out;
  }

  int _totalMinutes(_SyllabusCourse c) {
    int sum = 0;
    for (final u in c.units) {
      for (final s in u.sessions) {
        if (s.durationMinutes > 0) sum += s.durationMinutes;
      }
    }
    return sum;
  }

  int _countFilteredSessions(List<_Unit> units) {
    int sum = 0;
    for (final u in units) {
      sum += u.sessions.length;
    }
    return sum;
  }

  @override
  Widget build(BuildContext context) {
    final c = _course;

    // ✅ Force this screen to stay LTR even if the app locale is RTL.
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Scaffold(
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
                ? _ErrorBox(message: 'Failed to load the syllabus.\n\n$_error', onRetry: _load)
                : c == null
                ? const _InfoBox(
              title: 'Not found',
              message: 'We could not find this course syllabus.',
              icon: Icons.info_rounded,
            )
                : _buildContent(c),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(_SyllabusCourse c) {
    final unitsFiltered = _filteredUnits(c);
    final filteredSessionsCount = _countFilteredSessions(unitsFiltered);

    return ListView(
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

        _SummaryTableCard(
          units: c.units.length,
          sessions: c.units.fold<int>(0, (p, u) => p + u.sessions.length),
          totalMinutes: _totalMinutes(c),
          updatedLabel: _fmtDate(c.updatedAt),
        ),
        const SizedBox(height: 12),

        _RecommendationsCard(course: c),
        const SizedBox(height: 12),

        _SearchCard(
          controller: _search,
          onClear: () => _search.clear(),
          resultLabel: _query.isEmpty
              ? null
              : '$filteredSessionsCount session(s) match “$_query”.',
        ),
        const SizedBox(height: 12),

        if (_query.isNotEmpty && unitsFiltered.isEmpty)
          _EmptySearchResults(
            query: _query,
            onClear: () => _search.clear(),
          )
        else
          ...unitsFiltered.map((u) => _UnitCard(unit: u)),

        const SizedBox(height: 12),
        const _FooterHint(),
      ],
    );
  }
}

/* ================== UI WIDGETS ================== */

class _SearchCard extends StatelessWidget {
  const _SearchCard({
    required this.controller,
    required this.onClear,
    this.resultLabel,
  });

  final TextEditingController controller;
  final VoidCallback onClear;
  final String? resultLabel;

  @override
  Widget build(BuildContext context) {
    final hasText = controller.text.trim().isNotEmpty;

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
          const Text(
            'Search',
            style: TextStyle(color: UiK.primaryBlue, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: controller,
            textInputAction: TextInputAction.search,
            style: const TextStyle(fontWeight: FontWeight.w800),
            decoration: InputDecoration(
              hintText: 'Search sessions (title, objective, content, skill type, ID...)',
              hintStyle: TextStyle(
                color: UiK.mainText.withOpacity(0.55),
                fontWeight: FontWeight.w700,
              ),
              prefixIcon: const Icon(Icons.search_rounded, color: UiK.primaryBlue),
              suffixIcon: hasText
                  ? IconButton(
                tooltip: 'Clear',
                onPressed: onClear,
                icon: const Icon(Icons.clear_rounded),
              )
                  : null,
              filled: true,
              fillColor: UiK.primaryBlue.withOpacity(0.04),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: UiK.uiBorder.withOpacity(0.9)),
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            ),
          ),
          if (resultLabel != null) ...[
            const SizedBox(height: 10),
            Text(
              resultLabel!,
              style: TextStyle(
                color: Colors.grey.shade700,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _EmptySearchResults extends StatelessWidget {
  const _EmptySearchResults({required this.query, required this.onClear});
  final String query;
  final VoidCallback onClear;

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
          const Row(
            children: [
              Icon(Icons.search_off_rounded, color: UiK.actionOrange),
              SizedBox(width: 8),
              Text(
                'No results',
                style: TextStyle(color: UiK.primaryBlue, fontWeight: FontWeight.w900),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'No sessions match “$query”. Try a shorter keyword, or search by skill type, objective, or ID.',
            style: TextStyle(
              color: Colors.grey.shade800,
              fontWeight: FontWeight.w700,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: onClear,
              icon: const Icon(Icons.clear_rounded),
              label: const Text('Clear search', style: TextStyle(fontWeight: FontWeight.w900)),
              style: OutlinedButton.styleFrom(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                side: BorderSide(color: UiK.uiBorder.withOpacity(0.95)),
                padding: const EdgeInsets.symmetric(vertical: 12),
                foregroundColor: UiK.primaryBlue,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SummaryTableCard extends StatelessWidget {
  const _SummaryTableCard({
    required this.units,
    required this.sessions,
    required this.totalMinutes,
    required this.updatedLabel,
  });

  final int units;
  final int sessions;
  final int totalMinutes;
  final String updatedLabel;

  String _fmtTotalMinutes(int m) {
    if (m <= 0) return '—';
    final h = m ~/ 60;
    final r = m % 60;
    if (h <= 0) return '$m min';
    if (r == 0) return '${h}h';
    return '${h}h ${r}m';
  }

  @override
  Widget build(BuildContext context) {
    Widget cell(String v, {bool head = false}) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
        child: Text(
          v,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: UiK.mainText,
            fontWeight: head ? FontWeight.w900 : FontWeight.w800,
          ),
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: UiK.uiBorder.withOpacity(0.85)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Table(
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          border: TableBorder(
            horizontalInside: BorderSide(color: UiK.uiBorder.withOpacity(0.65)),
            verticalInside: BorderSide(color: UiK.uiBorder.withOpacity(0.65)),
          ),
          children: [
            TableRow(
              decoration: BoxDecoration(color: UiK.primaryBlue.withOpacity(0.04)),
              children: [
                cell('Units', head: true),
                cell('Sessions', head: true),
                cell('Total time', head: true),
                cell('Updated', head: true),
              ],
            ),
            TableRow(
              children: [
                cell('$units'),
                cell('$sessions'),
                cell(_fmtTotalMinutes(totalMinutes)),
                cell(updatedLabel.isEmpty ? '—' : updatedLabel),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RecommendationsCard extends StatelessWidget {
  const _RecommendationsCard({required this.course});
  final _SyllabusCourse course;

  int _countMissingDuration() {
    int miss = 0;
    for (final u in course.units) {
      for (final s in u.sessions) {
        if (s.durationMinutes <= 0) miss++;
      }
    }
    return miss;
  }

  int _countMissingObjectives() {
    int miss = 0;
    for (final u in course.units) {
      for (final s in u.sessions) {
        if (s.objective.trim().isEmpty) miss++;
      }
    }
    return miss;
  }

  int _countMissingContent() {
    int miss = 0;
    for (final u in course.units) {
      for (final s in u.sessions) {
        if (s.content.trim().isEmpty) miss++;
      }
    }
    return miss;
  }

  int _countMissingHomework() {
    int miss = 0;
    for (final u in course.units) {
      for (final s in u.sessions) {
        if (s.homework.trim().isEmpty) miss++;
      }
    }
    return miss;
  }

  @override
  Widget build(BuildContext context) {
    final sessionsTotal = course.units.fold<int>(0, (p, u) => p + u.sessions.length);

    final missingDur = _countMissingDuration();
    final missingObj = _countMissingObjectives();
    final missingCont = _countMissingContent();
    final missingHw = _countMissingHomework();

    final List<_RecItem> recs = [];

    if (missingObj > 0) {
      recs.add(_RecItem(
        icon: Icons.flag_rounded,
        title: 'Add objectives',
        desc: '$missingObj session(s) have no objective. Objectives help teachers and learners stay aligned.',
      ));
    }
    if (missingCont > 0) {
      recs.add(_RecItem(
        icon: Icons.article_rounded,
        title: 'Add content details',
        desc: '$missingCont session(s) have empty content. Add key points / activities for consistency.',
      ));
    }
    if (missingDur > 0) {
      recs.add(_RecItem(
        icon: Icons.timelapse_rounded,
        title: 'Add duration',
        desc: '$missingDur session(s) have no duration. Duration helps scheduling and pacing.',
      ));
    }

    if (sessionsTotal > 0 && missingHw == sessionsTotal) {
      recs.add(const _RecItem(
        icon: Icons.assignment_rounded,
        title: 'Consider homework',
        desc: 'No sessions have homework. Even short practice tasks improve retention.',
      ));
    } else if (missingHw > 0) {
      recs.add(_RecItem(
        icon: Icons.assignment_rounded,
        title: 'Improve homework coverage',
        desc: '$missingHw session(s) have no homework. Optional practice tasks are helpful.',
      ));
    }

    if (recs.isEmpty) {
      recs.add(const _RecItem(
        icon: Icons.verified_rounded,
        title: 'Looks consistent',
        desc: 'Objectives, content, and durations look complete. Keep the same structure for new courses.',
      ));
    }

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
          const Row(
            children: [
              Icon(Icons.tips_and_updates_rounded, color: UiK.actionOrange),
              SizedBox(width: 8),
              Text(
                'Recommendations',
                style: TextStyle(color: UiK.primaryBlue, fontWeight: FontWeight.w900),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ...recs.map((r) => _RecRow(item: r)).toList(),
        ],
      ),
    );
  }
}

class _RecItem {
  final IconData icon;
  final String title;
  final String desc;
  const _RecItem({required this.icon, required this.title, required this.desc});
}

class _RecRow extends StatelessWidget {
  const _RecRow({required this.item});
  final _RecItem item;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: UiK.primaryBlue.withOpacity(0.04),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: UiK.uiBorder.withOpacity(0.70)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(item.icon, size: 18, color: UiK.actionOrange),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  style: const TextStyle(color: UiK.primaryBlue, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 4),
                Text(
                  item.desc,
                  style: TextStyle(
                    color: Colors.grey.shade800,
                    fontWeight: FontWeight.w700,
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
  bool _expanded = true;

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
              ...u.sessions.map((s) => _SessionExpansion(session: s)),
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

class _SessionExpansion extends StatefulWidget {
  const _SessionExpansion({required this.session});
  final _Session session;

  @override
  State<_SessionExpansion> createState() => _SessionExpansionState();
}

class _SessionExpansionState extends State<_SessionExpansion> {
  bool _expanded = false;

  List<_RecItem> _sessionRecs(_Session s) {
    final out = <_RecItem>[];

    if (s.objective.trim().isEmpty) {
      out.add(const _RecItem(
        icon: Icons.flag_rounded,
        title: 'Objective missing',
        desc: 'Add a short objective (1–2 lines): what learners should be able to do after this session.',
      ));
    }
    if (s.content.trim().isEmpty) {
      out.add(const _RecItem(
        icon: Icons.article_rounded,
        title: 'Content missing',
        desc: 'Add key points + activities (warm-up, practice, production) for consistent delivery.',
      ));
    }
    if (s.durationMinutes <= 0) {
      out.add(const _RecItem(
        icon: Icons.timelapse_rounded,
        title: 'Duration missing',
        desc: 'Set duration minutes to improve planning and pacing.',
      ));
    }
    if (s.homework.trim().isEmpty) {
      out.add(const _RecItem(
        icon: Icons.assignment_rounded,
        title: 'Homework is optional',
        desc: 'Consider short practice (5–10 minutes) to reinforce the session.',
      ));
    }

    if (out.isEmpty) {
      out.add(const _RecItem(
        icon: Icons.verified_rounded,
        title: 'Ready to teach',
        desc: 'Objective, content, duration, and homework look good.',
      ));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.session;
    final title = s.title.trim().isEmpty ? 'Session' : s.title.trim();
    final recs = _sessionRecs(s);

    return Container(
      margin: const EdgeInsets.only(top: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: UiK.uiBorder.withOpacity(0.70)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            initiallyExpanded: _expanded,
            onExpansionChanged: (v) => setState(() => _expanded = v),
            tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            leading: CircleAvatar(
              backgroundColor: UiK.primaryBlue.withOpacity(0.08),
              child: const Icon(Icons.play_lesson_rounded, color: UiK.primaryBlue),
            ),
            title: Text(
              title,
              style: const TextStyle(
                fontWeight: FontWeight.w900,
                color: UiK.primaryBlue,
                height: 1.2,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              [
                if (s.skillType.trim().isNotEmpty) s.skillType.trim(),
                if (s.durationMinutes > 0) '${s.durationMinutes} min',
                if (s.id.trim().isNotEmpty) 'ID: ${s.id.trim()}',
              ].join(' • '),
              style: UiK.subtleText(),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Icon(
              _expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
              color: UiK.primaryBlue,
            ),
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: UiK.primaryBlue.withOpacity(0.04),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: UiK.uiBorder.withOpacity(0.70)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (s.objective.trim().isNotEmpty) ...[
                      _Line(icon: Icons.flag_rounded, label: 'Objective', text: s.objective),
                      const SizedBox(height: 8),
                    ],
                    if (s.content.trim().isNotEmpty) ...[
                      _Line(icon: Icons.article_rounded, label: 'Content', text: s.content),
                      const SizedBox(height: 8),
                    ],
                    if (s.homework.trim().isNotEmpty) ...[
                      _Line(icon: Icons.assignment_rounded, label: 'Homework', text: s.homework),
                      const SizedBox(height: 8),
                    ],
                    const SizedBox(height: 2),
                    const Row(
                      children: [
                        Icon(Icons.tips_and_updates_rounded, size: 18, color: UiK.actionOrange),
                        SizedBox(width: 8),
                        Text(
                          'Suggestions',
                          style: TextStyle(color: UiK.primaryBlue, fontWeight: FontWeight.w900),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    ...recs.map((r) => _RecRow(item: r)).toList(),
                  ],
                ),
              ),
            ],
          ),
        ),
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
              'Tip: Follow the units and sessions by their order number to deliver the syllabus as planned. Use Search to quickly jump to any session.',
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
              style: TextStyle(fontWeight: FontWeight.w900, color: UiK.primaryBlue, fontSize: 16),
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
                label: const Text('Retry', style: TextStyle(fontWeight: FontWeight.w900)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/* ================== MODELS ================== */

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