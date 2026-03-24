// teacher_syllabus_details_screen.dart
// ✅ FULL DROP-IN REPLACEMENT
//
// What this version fixes:
// - Reads the NEW variant-based schema from: syllabi/<courseId>
// - Shows a tab for each variant: In-Class, Online, Live, Recorded
// - Keeps the screen forced to LTR
// - Uses top-level course meta as fallback
// - Reads units from each variant separately
// - Search works inside the selected tab
// - Clean empty states for variants with no units

import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import '../shared/human_error.dart';
import '../shared/material_webview_screen.dart';
import '../shared/teacher_tour_guide.dart';
import '../shared/ui_constants.dart';
import '../shared/watermark_background.dart';
import '../shared/app_feedback.dart';

class TeacherSyllabusDetailsScreen extends StatefulWidget {
  const TeacherSyllabusDetailsScreen({super.key, required this.courseId});
  final String courseId;

  @override
  State<TeacherSyllabusDetailsScreen> createState() =>
      _TeacherSyllabusDetailsScreenState();
}

class _TeacherSyllabusDetailsScreenState
    extends State<TeacherSyllabusDetailsScreen>
    with SingleTickerProviderStateMixin {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  static const List<String> _variantKeys = [
    'inclass',
    'flexible',
    'private',
    'recorded',
  ];

  late final TabController _tabController;

  bool _loading = true;
  String? _error;
  _SyllabusCourse? _course;

  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();

    _tabController = TabController(length: _variantKeys.length, vsync: this);
    _tabController.addListener(() {
      if (!mounted) return;
      setState(() {});
    });

    _search.addListener(() {
      final v = _search.text.trim();
      if (v == _query) return;
      setState(() => _query = v);
    });

    _load();
  }

  @override
  void dispose() {
    _tabController.dispose();
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

      final data = Map<String, dynamic>.from(
        raw.map((k, v) => MapEntry(k.toString(), v)),
      );

      final topTitle = _readString(data['title']);
      final topCode = _readString(data['courseCode']);
      final topDuration = _readString(data['duration']);
      final topUpdatedAt = _toInt(data['updatedAt']);

      final variants = <String, _SyllabusVariant>{};

      for (final key in _variantKeys) {
        final variantMap = _asStringKeyMap(data[key]);

        final title = _firstNonEmpty([
          _readString(variantMap?['title']),
          topTitle,
          'Syllabus',
        ]);

        final code = _firstNonEmpty([
          _readString(variantMap?['courseCode']),
          topCode,
          '',
        ]);

        final duration = _firstNonEmpty([
          _readString(variantMap?['duration']),
          topDuration,
          '',
        ]);

        final updatedAt = _maxInt([
          _toInt(variantMap?['updatedAt']),
          topUpdatedAt,
        ]);

        final units = _parseUnits(variantMap?['units']);

        units.sort((a, b) {
          final c = a.order.compareTo(b.order);
          if (c != 0) return c;
          return a.title.compareTo(b.title);
        });

        for (final u in units) {
          u.sessions.sort((a, b) {
            final c = a.order.compareTo(b.order);
            if (c != 0) return c;
            return a.title.compareTo(b.title);
          });
        }

        variants[key] = _SyllabusVariant(
          key: key,
          title: title,
          code: code,
          duration: duration,
          updatedAt: updatedAt,
          units: units,
        );
      }

      setState(() {
        _loading = false;
        _course = _SyllabusCourse(
          id: widget.courseId,
          title: _firstNonEmpty([
            topTitle,
            variants['inclass']?.title ?? '',
            'Syllabus',
          ]),
          code: _firstNonEmpty([topCode, variants['inclass']?.code ?? '', '']),
          duration: _firstNonEmpty([
            topDuration,
            variants['inclass']?.duration ?? '',
            '',
          ]),
          updatedAt: _maxInt([
            topUpdatedAt,
            ...variants.values.map((e) => e.updatedAt),
          ]),
          variants: variants,
        );
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
      final title = _readString(um['title']);
      final otherTitle = _readString(um['otherTitle']);
      final desc = _readString(um['description']);
      final id = _readString(um['id']);
      final order = _toInt(um['order']);

      final sessions = _parseSessions(um['sessions']);

      out.add(
        _Unit(
          id: id,
          order: order <= 0 ? 999999 : order,
          title: title.isEmpty ? 'Unit' : title,
          otherTitle: otherTitle,
          description: desc,
          sessions: sessions,
        ),
      );
    }

    return out;
  }

  List<_Session> _parseSessions(dynamic node) {
    final out = <_Session>[];
    final sessionMaps = _asListOfMaps(node);

    for (final sm in sessionMaps) {
      out.add(
        _Session(
          id: _readString(sm['id']),
          order: _toInt(sm['order']) <= 0 ? 999999 : _toInt(sm['order']),
          title: _readString(sm['title']),
          skillType: _readString(sm['skillType']),
          objective: _readString(sm['objective']),
          durationMinutes: _toInt(sm['durationMinutes']),
          content: _readString(sm['content']),
          homework: _readString(sm['homework']),
          materialsUrl: _readString(sm['materialsUrl']),
        ),
      );
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

  List<_Unit> _filteredUnits(_SyllabusVariant variant) {
    if (_query.isEmpty) return variant.units;

    final out = <_Unit>[];
    for (final u in variant.units) {
      final filteredSessions = u.sessions
          .where((s) => _matches(s, _query))
          .toList();
      if (filteredSessions.isEmpty) continue;

      out.add(
        _Unit(
          id: u.id,
          order: u.order,
          title: u.title,
          otherTitle: u.otherTitle,
          description: u.description,
          sessions: filteredSessions,
        ),
      );
    }
    return out;
  }

  int _totalMinutes(_SyllabusVariant variant) {
    int sum = 0;
    for (final u in variant.units) {
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

  _SyllabusVariant? get _currentVariant {
    final c = _course;
    if (c == null) return null;
    final index = _tabController.index.clamp(0, _variantKeys.length - 1);
    return c.variants[_variantKeys[index]];
  }

  @override
  Widget build(BuildContext context) {
    final c = _course;

    TeacherTourGuide.schedule(
      context,
      screenId: 'teacher_syllabus_details',
      hints: const [
        TeacherTourHint(
          title: 'Syllabus details',
          line: 'Use tabs to switch variants and inspect units, sessions, and resources.',
        ),
      ],
    );

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
          bottom: TabBar(
            controller: _tabController,
            isScrollable: true,
            labelColor: UiK.primaryBlue,
            unselectedLabelColor: UiK.primaryBlue.withValues(alpha: 0.55),
            indicatorColor: UiK.primaryBlue,
            tabs: _variantKeys.map((e) => Tab(text: _variantLabel(e))).toList(),
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
                    message: 'Failed to load the syllabus.\n\n$_error',
                    onRetry: _load,
                  )
                : c == null
                ? const _InfoBox(
                    title: 'Not found',
                    message: 'We could not find this course syllabus.',
                    icon: Icons.info_rounded,
                  )
                : TabBarView(
                    controller: _tabController,
                    children: _variantKeys.map((key) {
                      final variant = c.variants[key]!;
                      return _buildVariantContent(variant);
                    }).toList(),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildVariantContent(_SyllabusVariant variant) {
    final unitsFiltered = _filteredUnits(variant);
    final filteredSessionsCount = _countFilteredSessions(unitsFiltered);
    final unitsCount = variant.units.length;
    final sessionsCount = variant.units.fold<int>(
      0,
      (p, u) => p + u.sessions.length,
    );

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
      children: [
        _CourseTopCard(
          title: variant.title,
          code: variant.code,
          duration: variant.duration,
          updatedLabel: _fmtDate(variant.updatedAt),
          unitsCount: unitsCount,
          sessionsCount: sessionsCount,
          variantLabel: _variantLabel(variant.key),
        ),
        const SizedBox(height: 12),
        _SummaryTableCard(
          units: unitsCount,
          sessions: sessionsCount,
          totalMinutes: _totalMinutes(variant),
          updatedLabel: _fmtDate(variant.updatedAt),
        ),
        const SizedBox(height: 12),
        _RecommendationsCard(variant: variant),
        const SizedBox(height: 12),
        _SearchCard(
          controller: _search,
          onClear: () => _search.clear(),
          resultLabel: _query.isEmpty
              ? null
              : '$filteredSessionsCount session(s) match “$_query”.',
        ),
        const SizedBox(height: 12),
        if (variant.units.isEmpty)
          _VariantEmptyState(variantLabel: _variantLabel(variant.key))
        else if (_query.isNotEmpty && unitsFiltered.isEmpty)
          _EmptySearchResults(query: _query, onClear: () => _search.clear())
        else
          ...unitsFiltered.map((u) => _UnitCard(unit: u)),
        const SizedBox(height: 12),
        const _FooterHint(),
      ],
    );
  }
}

/* ================== UI WIDGETS ================== */

class _VariantEmptyState extends StatelessWidget {
  const _VariantEmptyState({required this.variantLabel});
  final String variantLabel;

  @override
  Widget build(BuildContext context) {
    return _InfoBox(
      title: 'No units in $variantLabel',
      message: 'This variant does not have any syllabus units yet.',
      icon: Icons.menu_book_outlined,
    );
  }
}

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
        border: Border.all(color: UiK.uiBorder.withValues(alpha: 0.85)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Search',
            style: TextStyle(
              color: UiK.primaryBlue,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: controller,
            textInputAction: TextInputAction.search,
            style: const TextStyle(fontWeight: FontWeight.w800),
            decoration: InputDecoration(
              hintText:
                  'Search sessions (title, objective, content, skill type, ID...)',
              hintStyle: TextStyle(
                color: UiK.mainText.withValues(alpha: 0.55),
                fontWeight: FontWeight.w700,
              ),
              prefixIcon: const Icon(
                Icons.search_rounded,
                color: UiK.primaryBlue,
              ),
              suffixIcon: hasText
                  ? IconButton(
                      tooltip: 'Clear',
                      onPressed: onClear,
                      icon: const Icon(Icons.clear_rounded),
                    )
                  : null,
              filled: true,
              fillColor: UiK.primaryBlue.withValues(alpha: 0.04),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(color: UiK.uiBorder.withValues(alpha: 0.9)),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 12,
              ),
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
        border: Border.all(color: UiK.uiBorder.withValues(alpha: 0.85)),
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
                style: TextStyle(
                  color: UiK.primaryBlue,
                  fontWeight: FontWeight.w900,
                ),
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
              label: const Text(
                'Clear search',
                style: TextStyle(fontWeight: FontWeight.w900),
              ),
              style: OutlinedButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                side: BorderSide(color: UiK.uiBorder.withValues(alpha: 0.95)),
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
        border: Border.all(color: UiK.uiBorder.withValues(alpha: 0.85)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Table(
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          border: TableBorder(
            horizontalInside: BorderSide(color: UiK.uiBorder.withValues(alpha: 0.65)),
            verticalInside: BorderSide(color: UiK.uiBorder.withValues(alpha: 0.65)),
          ),
          children: [
            TableRow(
              decoration: BoxDecoration(
                color: UiK.primaryBlue.withValues(alpha: 0.04),
              ),
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
  const _RecommendationsCard({required this.variant});
  final _SyllabusVariant variant;

  int _countMissingDuration() {
    int miss = 0;
    for (final u in variant.units) {
      for (final s in u.sessions) {
        if (s.durationMinutes <= 0) miss++;
      }
    }
    return miss;
  }

  int _countMissingObjectives() {
    int miss = 0;
    for (final u in variant.units) {
      for (final s in u.sessions) {
        if (s.objective.trim().isEmpty) miss++;
      }
    }
    return miss;
  }

  int _countMissingContent() {
    int miss = 0;
    for (final u in variant.units) {
      for (final s in u.sessions) {
        if (s.content.trim().isEmpty) miss++;
      }
    }
    return miss;
  }

  int _countMissingHomework() {
    int miss = 0;
    for (final u in variant.units) {
      for (final s in u.sessions) {
        if (s.homework.trim().isEmpty) miss++;
      }
    }
    return miss;
  }

  @override
  Widget build(BuildContext context) {
    final sessionsTotal = variant.units.fold<int>(
      0,
      (p, u) => p + u.sessions.length,
    );

    final missingDur = _countMissingDuration();
    final missingObj = _countMissingObjectives();
    final missingCont = _countMissingContent();
    final missingHw = _countMissingHomework();

    final List<_RecItem> recs = [];

    if (missingObj > 0) {
      recs.add(
        _RecItem(
          icon: Icons.flag_rounded,
          title: 'Add objectives',
          desc:
              '$missingObj session(s) have no objective. Objectives help teachers and learners stay aligned.',
        ),
      );
    }
    if (missingCont > 0) {
      recs.add(
        _RecItem(
          icon: Icons.article_rounded,
          title: 'Add content details',
          desc:
              '$missingCont session(s) have empty content. Add key points / activities for consistency.',
        ),
      );
    }
    if (missingDur > 0) {
      recs.add(
        _RecItem(
          icon: Icons.timelapse_rounded,
          title: 'Add duration',
          desc:
              '$missingDur session(s) have no duration. Duration helps scheduling and pacing.',
        ),
      );
    }

    if (sessionsTotal > 0 && missingHw == sessionsTotal) {
      recs.add(
        const _RecItem(
          icon: Icons.assignment_rounded,
          title: 'Consider homework',
          desc:
              'No sessions have homework. Even short practice tasks improve retention.',
        ),
      );
    } else if (missingHw > 0) {
      recs.add(
        _RecItem(
          icon: Icons.assignment_rounded,
          title: 'Improve homework coverage',
          desc:
              '$missingHw session(s) have no homework. Optional practice tasks are helpful.',
        ),
      );
    }

    if (recs.isEmpty) {
      recs.add(
        const _RecItem(
          icon: Icons.verified_rounded,
          title: 'Looks consistent',
          desc:
              'Objectives, content, and durations look complete. Keep the same structure for new courses.',
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: UiK.uiBorder.withValues(alpha: 0.85)),
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
                style: TextStyle(
                  color: UiK.primaryBlue,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ...recs.map((r) => _RecRow(item: r)),
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
        color: UiK.primaryBlue.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: UiK.uiBorder.withValues(alpha: 0.70)),
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
                  style: const TextStyle(
                    color: UiK.primaryBlue,
                    fontWeight: FontWeight.w900,
                  ),
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
    required this.variantLabel,
  });

  final String title;
  final String code;
  final String duration;
  final String updatedLabel;
  final int unitsCount;
  final int sessionsCount;
  final String variantLabel;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: UiK.uiBorder.withValues(alpha: 0.85)),
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
                  color: UiK.primaryBlue.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: UiK.uiBorder.withValues(alpha: 0.85)),
                ),
                child: const Icon(
                  Icons.menu_book_rounded,
                  color: UiK.primaryBlue,
                ),
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
              _Pill(icon: Icons.layers_rounded, text: variantLabel),
              if (code.trim().isNotEmpty)
                _Pill(icon: Icons.qr_code_rounded, text: code),
              if (duration.trim().isNotEmpty)
                _Pill(icon: Icons.timer_rounded, text: duration),
              _Pill(icon: Icons.layers_rounded, text: '$unitsCount units'),
              _Pill(
                icon: Icons.playlist_play_rounded,
                text: '$sessionsCount sessions',
              ),
              if (updatedLabel.isNotEmpty)
                _Pill(icon: Icons.update_rounded, text: updatedLabel),
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
        border: Border.all(color: UiK.uiBorder.withValues(alpha: 0.85)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            initiallyExpanded: _expanded,
            onExpansionChanged: (v) => setState(() => _expanded = v),
            tilePadding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 10,
            ),
            childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            title: Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: UiK.actionOrange.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: UiK.actionOrange.withValues(alpha: 0.22),
                    ),
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
                    color: UiK.primaryBlue.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: UiK.uiBorder.withValues(alpha: 0.70)),
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
  Future<void> _openMaterials(String url) async {
    final cleanUrl = url.trim();
    final uri = Uri.tryParse(cleanUrl);

    if (cleanUrl.isEmpty || uri == null) {
      if (!mounted) return;
      AppToast.fromSnackBar(context,  const SnackBar(content: Text('Invalid materials link.')));
      return;
    }

    if (!mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MaterialWebViewScreen.fromUrl(
          title: widget.session.title.trim().isEmpty
              ? 'Material Viewer'
              : widget.session.title.trim(),
          url: cleanUrl,
        ),
      ),
    );
  }

  List<_RecItem> _sessionRecs(_Session s) {
    final out = <_RecItem>[];

    if (s.objective.trim().isEmpty) {
      out.add(
        const _RecItem(
          icon: Icons.flag_rounded,
          title: 'Objective missing',
          desc:
              'Add a short objective (1–2 lines): what learners should be able to do after this session.',
        ),
      );
    }
    if (s.content.trim().isEmpty) {
      out.add(
        const _RecItem(
          icon: Icons.article_rounded,
          title: 'Content missing',
          desc:
              'Add key points + activities (warm-up, practice, production) for consistent delivery.',
        ),
      );
    }
    if (s.durationMinutes <= 0) {
      out.add(
        const _RecItem(
          icon: Icons.timelapse_rounded,
          title: 'Duration missing',
          desc: 'Set duration minutes to improve planning and pacing.',
        ),
      );
    }
    if (s.homework.trim().isEmpty) {
      out.add(
        const _RecItem(
          icon: Icons.assignment_rounded,
          title: 'Homework is optional',
          desc:
              'Consider short practice (5–10 minutes) to reinforce the session.',
        ),
      );
    }

    if (out.isEmpty) {
      out.add(
        const _RecItem(
          icon: Icons.verified_rounded,
          title: 'Ready to teach',
          desc: 'Objective, content, duration, and homework look good.',
        ),
      );
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
        border: Border.all(color: UiK.uiBorder.withValues(alpha: 0.70)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            initiallyExpanded: _expanded,
            onExpansionChanged: (v) => setState(() => _expanded = v),
            tilePadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 6,
            ),
            childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            leading: CircleAvatar(
              backgroundColor: UiK.primaryBlue.withValues(alpha: 0.08),
              child: const Icon(
                Icons.play_lesson_rounded,
                color: UiK.primaryBlue,
              ),
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
                  color: UiK.primaryBlue.withValues(alpha: 0.04),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: UiK.uiBorder.withValues(alpha: 0.70)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (s.objective.trim().isNotEmpty) ...[
                      _Line(
                        icon: Icons.flag_rounded,
                        label: 'Objective',
                        text: s.objective,
                      ),
                      const SizedBox(height: 8),
                    ],
                    if (s.content.trim().isNotEmpty) ...[
                      _Line(
                        icon: Icons.article_rounded,
                        label: 'Content',
                        text: s.content,
                      ),
                      const SizedBox(height: 8),
                    ],
                    if (s.homework.trim().isNotEmpty) ...[
                      _Line(
                        icon: Icons.assignment_rounded,
                        label: 'Homework',
                        text: s.homework,
                      ),
                      const SizedBox(height: 8),
                    ],
                    if (s.materialsUrl.trim().isNotEmpty) ...[
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: () => _openMaterials(s.materialsUrl),
                          icon: const Icon(Icons.menu_book_rounded),
                          label: const Text(
                            'Open Materials',
                            style: TextStyle(fontWeight: FontWeight.w900),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: UiK.primaryBlue,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                    const SizedBox(height: 2),
                    const Row(
                      children: [
                        Icon(
                          Icons.tips_and_updates_rounded,
                          size: 18,
                          color: UiK.actionOrange,
                        ),
                        SizedBox(width: 8),
                        Text(
                          'Suggestions',
                          style: TextStyle(
                            color: UiK.primaryBlue,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    ...recs.map((r) => _RecRow(item: r)),
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
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    color: UiK.primaryBlue,
                  ),
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
        color: UiK.primaryBlue.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: UiK.uiBorder.withValues(alpha: 0.75)),
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
        border: Border.all(color: UiK.uiBorder.withValues(alpha: 0.85)),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: UiK.actionOrange.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: UiK.uiBorder.withValues(alpha: 0.85)),
            ),
            child: const Icon(
              Icons.info_outline_rounded,
              color: UiK.actionOrange,
            ),
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
          border: Border.all(color: UiK.uiBorder.withValues(alpha: 0.85)),
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
          border: Border.all(color: UiK.uiBorder.withValues(alpha: 0.85)),
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

/* ================== MODELS ================== */

class _SyllabusCourse {
  const _SyllabusCourse({
    required this.id,
    required this.title,
    required this.code,
    required this.duration,
    required this.updatedAt,
    required this.variants,
  });

  final String id;
  final String title;
  final String code;
  final String duration;
  final int updatedAt;
  final Map<String, _SyllabusVariant> variants;
}

class _SyllabusVariant {
  const _SyllabusVariant({
    required this.key,
    required this.title,
    required this.code,
    required this.duration,
    required this.updatedAt,
    required this.units,
  });

  final String key;
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
    required this.materialsUrl,
  });

  final String id;
  final int order;
  final String title;
  final String skillType;
  final String objective;
  final int durationMinutes;
  final String content;
  final String homework;
  final String materialsUrl;
}
