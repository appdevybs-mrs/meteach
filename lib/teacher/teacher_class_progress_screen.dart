import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_database/firebase_database.dart';

import '../shared/app_theme.dart';
import '../shared/offline_action_guard.dart';
import '../shared/human_error.dart';
import '../shared/study_variant.dart';
import '../shared/teacher_web_layout.dart';
import 'take_attendance_screen.dart';

class TeacherClassProgressScreen extends StatefulWidget {
  final String classId;
  final Map<String, dynamic> classData;

  const TeacherClassProgressScreen({
    super.key,
    required this.classId,
    required this.classData,
  });

  @override
  State<TeacherClassProgressScreen> createState() =>
      _TeacherClassProgressScreenState();
}

class _TeacherClassProgressScreenState
    extends State<TeacherClassProgressScreen> {
  static const Color successGreen = Color(0xFF10B981);
  static const Color warningOrange = Color(0xFFF59E0B);
  static const Color dangerRed = Color(0xFFEF4444);
  static const Color vividHomework = Color(0xFFF59E0B);
  static const Color vividEdit = Color(0xFF2563EB);

  static const String classesNode = "classes";
  static const String syllabiNode = "syllabi";
  static const String usersNode = "users";

  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  late final DatabaseReference _classRef = _db
      .child(classesNode)
      .child(widget.classId);
  late final DatabaseReference _syllabiRef = _db.child(syllabiNode);
  late final DatabaseReference _usersRef = _db.child(usersNode);

  StreamSubscription<DatabaseEvent>? _classSub;

  bool _busy = true;
  String? _error;

  Map<String, dynamic> _attendance = {};
  Map<String, dynamic> _learners = {};

  List<Map<String, dynamic>> _syllabiFlat = [];
  int _totalSyllabusSessions = 0;
  List<Map<String, dynamic>> _sessionsToReview = [];

  Set<String> _classCoveredSessionIds = {};
  int _classProgressPct = 0;

  String? _selectedLearnerUid;

  Map<String, Map<String, dynamic>> _paymentSummaries = {};

  AppPalette get palette => appThemeController.palette;

  @override
  void initState() {
    super.initState();
    appThemeController.addListener(_onThemeChanged);
    _boot();
  }

  @override
  void dispose() {
    appThemeController.removeListener(_onThemeChanged);
    _classSub?.cancel();
    super.dispose();
  }

  void _onThemeChanged() {
    if (!mounted) return;
    setState(() {});
  }

  String get _courseTitle =>
      (widget.classData['course_title'] ??
              widget.classData['courseTitle'] ??
              'Class')
          .toString();

  String get _courseId => (widget.classData['course_id'] ?? '').toString();
  String get _variantKey => normalizeVariantKey(
    (widget.classData['variantKey'] ?? widget.classData['variant'] ?? '')
        .toString(),
  );

  bool get _hasLearnerSelected =>
      _selectedLearnerUid != null && _selectedLearnerUid!.isNotEmpty;

  Future<void> _boot() async {
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await _loadSyllabus();

      await _classSub?.cancel();
      _classSub = _classRef.onValue.listen(
        (event) {
          final raw = event.snapshot.value;
          final data = raw is Map
              ? Map<String, dynamic>.from(raw)
              : <String, dynamic>{};

          final att = (data['attendance'] is Map)
              ? Map<String, dynamic>.from(data['attendance'] as Map)
              : <String, dynamic>{};

          final learners = (data['learners'] is Map)
              ? Map<String, dynamic>.from(data['learners'] as Map)
              : <String, dynamic>{};

          final covered = _computeCoveredFromClassAttendance(att);
          final reviewSessions = _computeSessionsToReview(att);
          final pct = _totalSyllabusSessions <= 0
              ? 0
              : ((covered.length / _totalSyllabusSessions) * 100).round().clamp(
                  0,
                  100,
                );

          String? selected = _selectedLearnerUid;
          if ((selected == null ||
                  selected.isEmpty ||
                  !learners.containsKey(selected)) &&
              learners.isNotEmpty) {
            selected = learners.keys.first.toString();
          }

          if (!mounted) return;
          setState(() {
            _attendance = att;
            _learners = learners;
            _classCoveredSessionIds = covered;
            _sessionsToReview = reviewSessions;
            _classProgressPct = pct;
            _selectedLearnerUid = selected;
            _busy = false;
          });

          _loadPaymentSummaries(learners, _courseId);
        },
        onError: (e) {
          if (!mounted) return;
          setState(() {
            _error = toHumanError(e);
            _busy = false;
          });
        },
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = toHumanError(e);
        _busy = false;
      });
    }
  }

  Future<void> _loadPaymentSummaries(
    Map<String, dynamic> learners,
    String courseId,
  ) async {
    final uids = learners.keys.map((e) => e.toString()).toList();
    if (uids.isEmpty) return;

    final summaries = <String, Map<String, dynamic>>{};
    final futures = <Future<void>>[];

    for (final uid in uids) {
      futures.add(_loadLearnerPaymentSummary(uid, courseId, summaries));
    }

    await Future.wait(futures);
    if (!mounted) return;
    setState(() {
      _paymentSummaries = summaries;
    });
  }

  Future<void> _loadLearnerPaymentSummary(
    String uid,
    String courseId,
    Map<String, Map<String, dynamic>> summaries,
  ) async {
    try {
      final snap = await _usersRef.child('$uid/courses').get();
      if (!snap.exists || snap.value is! Map) return;
      final courses = Map<String, dynamic>.from(snap.value as Map);
      for (final entry in courses.entries) {
        if (entry.value is! Map) continue;
        final course = Map<String, dynamic>.from(entry.value as Map);
        final cid = (course['id'] ?? '').toString().trim();
        if (cid == courseId && course['payment_summary'] is Map) {
          summaries[uid] = Map<String, dynamic>.from(
            course['payment_summary'] as Map,
          );
          return;
        }
      }
    } catch (_) {}
  }

  Future<void> _loadSyllabus() async {
    _syllabiFlat = [];
    _totalSyllabusSessions = 0;

    final cid = _courseId.trim();
    if (cid.isEmpty) return;

    final syllabusVariant = syllabusVariantForScheduledAttendance(_variantKey);
    var sSnap = await _syllabiRef.child(cid).child(syllabusVariant).get();
    if ((!sSnap.exists || sSnap.value == null || sSnap.value is! Map) &&
        syllabusVariant == 'private') {
      sSnap = await _syllabiRef.child(cid).child('inclass').get();
    }
    if (!sSnap.exists || sSnap.value == null || sSnap.value is! Map) return;

    final s = Map<String, dynamic>.from(sSnap.value as Map);
    final List<Map<String, dynamic>> flat = [];

    final modules = s['modules'];
    if (modules is List) {
      for (final m in modules) {
        if (m is! Map) continue;
        final module = Map<String, dynamic>.from(m);
        final units = module['units'];
        if (units is! List) continue;
        for (final u in units) {
          if (u is! Map) continue;
          final unit = Map<String, dynamic>.from(u);
          final unitId = (unit['id'] ?? '').toString();
          final unitTitle = ((unit['title'] ?? '').toString().trim().isNotEmpty)
              ? (unit['title'] ?? '').toString()
              : (unit['description'] ?? '').toString();
          final unitOrder = unit['order'] ?? 0;
          final lessons = unit['lessons'];
          if (lessons is! List) continue;
          for (final ss in lessons) {
            if (ss is! Map) continue;
            final sess = Map<String, dynamic>.from(ss);
            flat.add({
              'unitOrder': unitOrder,
              'unitId': unitId,
              'unitTitle': unitTitle,
              'order': sess['order'] ?? 0,
              'sessionId': (sess['id'] ?? '').toString(),
              'title': (sess['title'] ?? '').toString(),
              'skillType': (sess['skillType'] ?? '').toString(),
              'objective': (sess['objective'] ?? '').toString(),
              'content': (sess['content'] ?? '').toString(),
            });
          }
        }
      }
    } else {
      final units = s['units'];
      if (units is List) {
        for (final u in units) {
          if (u is! Map) continue;
          final unit = Map<String, dynamic>.from(u);
          final unitId = (unit['id'] ?? '').toString();
          final unitTitle = ((unit['title'] ?? '').toString().trim().isNotEmpty)
              ? (unit['title'] ?? '').toString()
              : (unit['description'] ?? '').toString();
          final unitOrder = unit['order'] ?? 0;

          final sessions = unit['sessions'];
          if (sessions is List) {
            for (final ss in sessions) {
              if (ss is! Map) continue;
              final sess = Map<String, dynamic>.from(ss);

              flat.add({
                'unitOrder': unitOrder,
                'unitId': unitId,
                'unitTitle': unitTitle,
                'order': sess['order'] ?? 0,
                'sessionId': (sess['id'] ?? '').toString(),
                'title': (sess['title'] ?? '').toString(),
                'skillType': (sess['skillType'] ?? '').toString(),
                'objective': (sess['objective'] ?? '').toString(),
                'content': (sess['content'] ?? '').toString(),
              });
            }
          }
        }
      }
    }

    int n(dynamic v) =>
        (v is num) ? v.toInt() : int.tryParse(v?.toString() ?? '') ?? 0;

    flat.sort((a, b) {
      final uo = n(a['unitOrder']).compareTo(n(b['unitOrder']));
      if (uo != 0) return uo;
      return n(a['order']).compareTo(n(b['order']));
    });

    _syllabiFlat = flat;
    _totalSyllabusSessions = flat.length;
  }

  Set<String> _computeCoveredFromClassAttendance(Map<String, dynamic> att) {
    final Set<String> covered = {};

    for (final entry in att.entries) {
      final rec = entry.value;
      if (rec is! Map) continue;
      final r = Map<String, dynamic>.from(rec);

      if (r['taughtItems'] is List) {
        final items = (r['taughtItems'] as List).whereType<Map>().toList();
        for (final item in items) {
          final m = Map<String, dynamic>.from(item);
          final sid = (m['sessionId'] ?? '').toString().trim();
          if (sid.isNotEmpty) covered.add(sid);
        }
      }

      final taught = r['taught'];
      if (taught is Map) {
        final tm = Map<String, dynamic>.from(taught);
        final sid = (tm['sessionId'] ?? '').toString().trim();
        if (sid.isNotEmpty) covered.add(sid);
      }
    }

    return covered;
  }

  Set<String> _syllabusSessionIdSet() {
    return _syllabiFlat
        .map((s) => (s['sessionId'] ?? '').toString().trim())
        .where((sid) => sid.isNotEmpty)
        .toSet();
  }

  bool _recordHasSyllabusLink(Map<String, dynamic> record) {
    final syllabusIds = _syllabusSessionIdSet();
    if (syllabusIds.isEmpty) return false;

    if (record['taughtItems'] is List) {
      final items = (record['taughtItems'] as List).whereType<Map>().toList();
      for (final item in items) {
        final m = Map<String, dynamic>.from(item);
        final sid = (m['sessionId'] ?? '').toString().trim();
        if (sid.isNotEmpty && syllabusIds.contains(sid)) return true;
      }
    }

    final taught = record['taught'];
    if (taught is Map) {
      final tm = Map<String, dynamic>.from(taught);
      final sid = (tm['sessionId'] ?? '').toString().trim();
      if (sid.isNotEmpty && syllabusIds.contains(sid)) return true;
    }

    return false;
  }

  String _reviewRecordLabel(Map<String, dynamic> record) {
    if (record['taughtItems'] is List) {
      final items = (record['taughtItems'] as List).whereType<Map>().toList();
      for (final item in items) {
        final m = Map<String, dynamic>.from(item);
        final title = (m['title'] ?? '').toString().trim();
        if (title.isNotEmpty) return title;
      }
    }

    final taught = record['taught'];
    if (taught is Map) {
      final tm = Map<String, dynamic>.from(taught);
      final title = (tm['title'] ?? '').toString().trim();
      if (title.isNotEmpty) return title;
    }

    return 'Session to review';
  }

  List<Map<String, dynamic>> _computeSessionsToReview(
    Map<String, dynamic> att,
  ) {
    if (_syllabiFlat.isEmpty) return <Map<String, dynamic>>[];

    final list = <Map<String, dynamic>>[];

    for (final entry in att.entries) {
      final rec = entry.value;
      if (rec is! Map) continue;

      final record = <String, dynamic>{
        'id': entry.key,
        ...Map<String, dynamic>.from(rec),
      };
      if (_recordHasSyllabusLink(record)) continue;
      list.add(record);
    }

    list.sort((a, b) {
      final dateA = (a['date'] ?? '0000-00-00').toString();
      final dateB = (b['date'] ?? '0000-00-00').toString();
      final cmp = dateB.compareTo(dateA);
      if (cmp != 0) return cmp;
      final idA = (a['id'] ?? '').toString();
      final idB = (b['id'] ?? '').toString();
      return idB.compareTo(idA);
    });

    return list;
  }

  Set<String> _computeCoveredForLearner(String learnerUid) {
    final Set<String> covered = {};

    for (final entry in _attendance.entries) {
      final rec = entry.value;
      if (rec is! Map) continue;

      final r = Map<String, dynamic>.from(rec);

      bool isPresent = false;
      final p = r['present'];
      if (p is Map) {
        final pm = Map<String, dynamic>.from(p);
        if (pm.containsKey(learnerUid) && pm[learnerUid] == true) {
          isPresent = true;
        }
      }

      if (!isPresent) continue;

      if (r['taughtItems'] is List) {
        final items = (r['taughtItems'] as List).whereType<Map>().toList();
        for (final item in items) {
          final m = Map<String, dynamic>.from(item);
          final sid = (m['sessionId'] ?? '').toString().trim();
          if (sid.isNotEmpty) covered.add(sid);
        }
      }

      final taught = r['taught'];
      if (taught is Map) {
        final tm = Map<String, dynamic>.from(taught);
        final sid = (tm['sessionId'] ?? '').toString().trim();
        if (sid.isNotEmpty) covered.add(sid);
      }
    }

    return covered;
  }

  _LearnerStats _statsForLearner(String learnerUid) {
    int present = 0;
    int absent = 0;
    int held = 0;

    for (final entry in _attendance.entries) {
      final rec = entry.value;
      if (rec is! Map) continue;
      held++;

      final r = Map<String, dynamic>.from(rec);
      final p = r['present'];
      final a = r['absent'];

      if (p is Map && p.containsKey(learnerUid) && (p[learnerUid] == true)) {
        present++;
      }
      if (a is Map && a.containsKey(learnerUid) && (a[learnerUid] == true)) {
        absent++;
      }
    }

    final v = _normalizeVariantKey(_variantKey);
    int consumed;
    if (v == 'private') {
      consumed = present + (absent > 2 ? absent - 2 : 0);
    } else {
      consumed = held;
    }

    final summary = _paymentSummaries[learnerUid];
    final paid = _asInt(summary?['sessionsPaidTotal']);
    final left = paid > 0 ? (paid - consumed).clamp(0, paid) : 0;

    return _LearnerStats(
      sessionsHeld: held,
      present: present,
      absent: absent,
      consumed: consumed,
      paid: paid,
      left: left,
    );
  }

  String _normalizeVariantKey(String raw) {
    final v = raw.trim().toLowerCase();
    if (v == 'inclass' || v == 'private' || v == 'flexible' || v == 'recorded') {
      return v;
    }
    return 'inclass';
  }

  int _asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  String _learnerName(String uid) {
    final node = _learners[uid];
    if (node is Map) {
      final m = Map<String, dynamic>.from(node);
      final name = (m['name'] ?? '').toString().trim();
      if (name.isNotEmpty) return name;
    }
    return 'Learner';
  }

  String _dropdownLabelFor(String uid) {
    final name = _learnerName(uid);
    final stats = _statsForLearner(uid);
    return '$name — ${stats.present}/${stats.sessionsHeld} present';
  }

  List<Map<String, dynamic>> _groupSyllabiByUnit() {
    final Map<String, Map<String, dynamic>> groups = {};

    int n(dynamic v) =>
        (v is num) ? v.toInt() : int.tryParse(v?.toString() ?? '') ?? 0;

    for (final s in _syllabiFlat) {
      final unitId = (s['unitId'] ?? '').toString();
      final unitTitle = (s['unitTitle'] ?? '').toString();
      final unitOrder = n(s['unitOrder']);

      final key = unitId.isNotEmpty ? unitId : 'unit_$unitOrder|$unitTitle';

      groups.putIfAbsent(key, () {
        return {
          'unitId': unitId,
          'unitTitle': unitTitle.isEmpty ? 'Unit' : unitTitle,
          'unitOrder': unitOrder,
          'sessions': <Map<String, dynamic>>[],
        };
      });

      (groups[key]!['sessions'] as List<Map<String, dynamic>>).add(s);
    }

    final list = groups.values.toList();
    list.sort((a, b) => n(a['unitOrder']).compareTo(n(b['unitOrder'])));

    for (final u in list) {
      final sessions = (u['sessions'] as List<Map<String, dynamic>>);
      sessions.sort((a, b) => n(a['order']).compareTo(n(b['order'])));
    }

    return list;
  }

  List<Map<String, dynamic>> _groupAttendanceByDate(Set<String> coveredSet) {
    final Map<String, Map<String, dynamic>> groups = {};
    var order = 0;

    int n(dynamic v) =>
        (v is num) ? v.toInt() : int.tryParse(v?.toString() ?? '') ?? 0;

    DateTime? parseDate(String raw) {
      final v = raw.trim();
      if (v.isEmpty) return null;
      return DateTime.tryParse(v);
    }

    Map<String, dynamic> normalizeSession(Map<String, dynamic> raw) {
      final out = Map<String, dynamic>.from(raw);
      if ((out['sessionId'] ?? '').toString().trim().isNotEmpty) return out;
      if ((out['id'] ?? '').toString().trim().isNotEmpty) {
        out['sessionId'] = out['id'];
      }
      return out;
    }

    void addGroupItem({
      required String dateKey,
      required String dateLabel,
      required DateTime? sortDate,
      required Map<String, dynamic> session,
      required String recordId,
      required Map<String, dynamic> record,
    }) {
      groups.putIfAbsent(dateKey, () {
        return {
          'dateLabel': dateLabel,
          'sortDate': sortDate,
          'order': order++,
          'sessions': <Map<String, dynamic>>[],
        };
      });

      (groups[dateKey]!['sessions'] as List<Map<String, dynamic>>).add({
        ...session,
        '_recordId': recordId,
        '_record': record,
      });
    }

    for (final entry in _attendance.entries) {
      final raw = entry.value;
      if (raw is! Map) continue;

      final record = Map<String, dynamic>.from(raw);
      final dateLabel = (record['date'] ?? '').toString().trim();
      final key = dateLabel.isEmpty ? 'No date' : dateLabel;
      final sortDate = parseDate(dateLabel);

      final taughtItems = record['taughtItems'];
      if (taughtItems is List && taughtItems.isNotEmpty) {
        for (final item in taughtItems.whereType<Map>()) {
          final session = normalizeSession(Map<String, dynamic>.from(item));
          final sessionId = (session['sessionId'] ?? '').toString().trim();
          if (sessionId.isEmpty || !coveredSet.contains(sessionId)) continue;
          addGroupItem(
            dateKey: key,
            dateLabel: key,
            sortDate: sortDate,
            session: session,
            recordId: entry.key,
            record: record,
          );
        }
        continue;
      }

      final taught = record['taught'];
      if (taught is Map && taught.isNotEmpty) {
        final session = normalizeSession(Map<String, dynamic>.from(taught));
        final sessionId = (session['sessionId'] ?? '').toString().trim();
        if (sessionId.isEmpty || !coveredSet.contains(sessionId)) continue;
        addGroupItem(
          dateKey: key,
          dateLabel: key,
          sortDate: sortDate,
          session: session,
          recordId: entry.key,
          record: record,
        );
      }
    }

    final list = groups.values.toList();
    list.sort((a, b) {
      final ad = a['sortDate'] as DateTime?;
      final bd = b['sortDate'] as DateTime?;
      if (ad != null && bd != null) {
        final c = bd.compareTo(ad);
        if (c != 0) return c;
      } else if (ad != null) {
        return -1;
      } else if (bd != null) {
        return 1;
      }
      return (a['order'] as int).compareTo(b['order'] as int);
    });

    for (final group in list) {
      final sessions = (group['sessions'] as List<Map<String, dynamic>>);
      sessions.sort((a, b) {
        final ao = n(a['unitOrder']).compareTo(n(b['unitOrder']));
        if (ao != 0) return ao;
        final so = n(a['order']).compareTo(n(b['order']));
        if (so != 0) return so;
        return (a['title'] ?? '').toString().compareTo(
          (b['title'] ?? '').toString(),
        );
      });
    }

    return list;
  }

  Color _progressColor(int pct) {
    if (pct >= 75) return successGreen;
    if (pct >= 40) return warningOrange;
    return dangerRed;
  }

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final mq = MediaQuery.of(context);
    final scale = mq.textScaler.scale(1);
    final clampedScale = scale.clamp(0.85, 1.20);

    return MediaQuery(
      data: mq.copyWith(textScaler: TextScaler.linear(clampedScale.toDouble())),
      child: Scaffold(
        backgroundColor: p.appBg,
        appBar: AppBar(
          backgroundColor: p.cardBg,
          elevation: 0,
          surfaceTintColor: p.cardBg,
          iconTheme: IconThemeData(color: p.primary),
          title: Text(
            'Class Progress',
            style: TextStyle(color: p.primary, fontWeight: FontWeight.w900),
          ),
          actions: [
            const SizedBox.shrink(),
            IconButton(
              tooltip: 'Refresh',
              icon: Icon(Icons.refresh_rounded, color: p.primary),
              onPressed: _busy ? null : _boot,
            ),
          ],
        ),
        body: teacherWebBodyFrame(
          context: context,
          maxWidth: 1480,
          child: Stack(
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  child: Opacity(
                    opacity: 0.04,
                    child: Center(
                      child: Icon(
                        Icons.auto_graph_rounded,
                        size: 220,
                        color: p.primary.withValues(alpha: 0.12),
                      ),
                    ),
                  ),
                ),
              ),
              _busy
                  ? Center(child: CircularProgressIndicator(color: p.primary))
                  : _error != null
                  ? _buildErrorState(p)
                  : ListView(
                      padding: EdgeInsets.fromLTRB(
                        16,
                        16,
                        16,
                        MediaQuery.of(context).padding.bottom + 20,
                      ),
                      children: [
                        _headerHeroCard(p),
                        const SizedBox(height: 12),
                        if (_sessionsToReview.isNotEmpty) ...[
                          _reviewBanner(p),
                          const SizedBox(height: 12),
                        ],
                        _unitsProgressCard(p),
                        const SizedBox(height: 12),
                        _timelineSection(p),
                      ],
                    ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _reviewBanner(AppPalette p) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: warningOrange.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: warningOrange.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: warningOrange, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '${_sessionsToReview.length} session(s) need syllabus check',
              style: TextStyle(
                color: warningOrange,
                fontWeight: FontWeight.w800,
                fontSize: 13,
              ),
            ),
          ),
          TextButton(
            onPressed: () => _openSessionsToReview(p),
            style: TextButton.styleFrom(
              foregroundColor: warningOrange,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text(
              'Review',
              style: TextStyle(fontWeight: FontWeight.w900),
            ),
          ),
        ],
      ),
    );
  }

  void _openSessionsToReview(AppPalette p) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: p.cardBg,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) {
        final groups = <String, List<Map<String, dynamic>>>{};
        for (final r in _sessionsToReview) {
          final d = (r['date'] ?? 'No date').toString();
          groups.putIfAbsent(d, () => []);
          groups[d]!.add(r);
        }
        final sortedDates = groups.keys.toList()..sort((a, b) => b.compareTo(a));
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Sessions to Review',
                  style: TextStyle(
                    color: p.primary,
                    fontWeight: FontWeight.w900,
                    fontSize: 17,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'These sessions need a syllabus lesson selected.',
                  style: TextStyle(
                    color: p.text.withValues(alpha: 0.72),
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: ListView(
                    children: sortedDates.map((date) {
                      final records = groups[date]!;
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              date,
                              style: TextStyle(
                                color: p.primary,
                                fontWeight: FontWeight.w900,
                                fontSize: 14,
                              ),
                            ),
                            const SizedBox(height: 6),
                            ...records.map((record) {
                              final title = _reviewRecordLabel(record);
                              final sid = (record['sessionId'] ?? record['id'] ?? '').toString();
                              return Container(
                                margin: const EdgeInsets.only(bottom: 6),
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: warningOrange.withValues(alpha: 0.06),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: p.border.withValues(alpha: 0.85),
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        title,
                                        style: TextStyle(
                                          fontWeight: FontWeight.w800,
                                          color: p.text,
                                        ),
                                      ),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.edit_rounded, size: 20),
                                      color: vividEdit,
                                      onPressed: sid.isEmpty
                                          ? null
                                          : () {
                                              Navigator.pop(ctx);
                                              _openEditAttendance(
                                                record,
                                                preserveExistingLearnerAttendanceOnly: true,
                                              );
                                            },
                                    ),
                                  ],
                                ),
                              );
                            }),
                          ],
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _headerHeroCard(AppPalette p) {
    final learnersCount = _learners.length;
    final learnerUids = _learners.keys.map((e) => e.toString()).toList();

    Set<String> coveredSet = _classCoveredSessionIds;
    int pct = _classProgressPct;
    int lessonsCovered = coveredSet.length;
    _LearnerStats stats = _LearnerStats.zero();
    int totalPaid = 0;
    int totalConsumed = 0;
    int totalPresent = 0;
    int totalAbsent = 0;

    if (_hasLearnerSelected && learnerUids.contains(_selectedLearnerUid)) {
      final uid = _selectedLearnerUid!;
      stats = _statsForLearner(uid);
      coveredSet = _computeCoveredForLearner(uid);
      lessonsCovered = coveredSet.length;
      pct = _totalSyllabusSessions <= 0
          ? 0
          : ((lessonsCovered / _totalSyllabusSessions) * 100).round().clamp(0, 100);
    }

    for (final uid in learnerUids) {
      final s = _statsForLearner(uid);
      totalPaid += s.paid;
      totalConsumed += s.consumed;
      totalPresent += s.present;
      totalAbsent += s.absent;
    }

    final displayPaid = _hasLearnerSelected ? stats.paid : totalPaid;
    final displayConsumed = _hasLearnerSelected ? stats.consumed : totalConsumed;
    final displayLeft = displayPaid > 0 ? (displayPaid - displayConsumed).clamp(0, displayPaid) : 0;
    final displayPresent = _hasLearnerSelected ? stats.present : totalPresent;
    final displayAbsent = _hasLearnerSelected ? stats.absent : totalAbsent;

    final progressColor = _progressColor(pct);

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [p.primary, p.primary.withValues(alpha: 0.88)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: p.primary.withValues(alpha: 0.16),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: const Icon(
                  Icons.timeline_rounded,
                  color: Colors.white,
                  size: 30,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _courseTitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                        fontSize: 20,
                        height: 1.15,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        _heroChip(label: 'Learners $learnersCount'),
                        const SizedBox(width: 8),
                        _heroChip(label: '${_attendance.length} sessions'),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (learnerUids.isNotEmpty) ...[
            _heroLearnerDropdown(p, learnerUids),
            const SizedBox(height: 14),
          ],
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Lessons covered: $lessonsCovered / ${_totalSyllabusSessions <= 0 ? '-' : _totalSyllabusSessions}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    Text(
                      '$pct%',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                        fontSize: 15,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: _totalSyllabusSessions <= 0
                        ? 0
                        : (lessonsCovered / _totalSyllabusSessions).clamp(0, 1),
                    minHeight: 9,
                    backgroundColor: Colors.white.withValues(alpha: 0.20),
                    valueColor: AlwaysStoppedAnimation(progressColor),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    _compactStat(
                      label: _hasLearnerSelected ? 'Used' : 'Sessions',
                      value: '$displayConsumed',
                    ),
                    if (displayPaid > 0) ...[
                      const _DivDot(color: Colors.white54),
                      _compactStat(
                        label: 'Paid',
                        value: '$displayPaid',
                      ),
                      const _DivDot(color: Colors.white54),
                      _compactStat(
                        label: 'Left',
                        value: '$displayLeft',
                      ),
                    ],
                    const _DivDot(color: Colors.white54),
                    _compactStat(
                      label: 'Present',
                      value: '$displayPresent',
                    ),
                    const _DivDot(color: Colors.white54),
                    _compactStat(
                      label: 'Absent',
                      value: '$displayAbsent',
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

  Widget _compactStat({required String label, required String value}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w900,
            fontSize: 15,
          ),
        ),
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.72),
            fontWeight: FontWeight.w800,
            fontSize: 10,
          ),
        ),
      ],
    );
  }

  Widget _heroChip({required String label}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white24),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w800,
          fontSize: 11,
        ),
      ),
    );
  }

  Widget _heroLearnerDropdown(
    AppPalette p,
    List<String> uids,
  ) {
    final items = uids.map((uid) {
      final label = _dropdownLabelFor(uid);
      return DropdownMenuItem<String>(
        value: uid,
        child: SizedBox(
          width: double.infinity,
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontWeight: FontWeight.w800,
              color: Colors.white,
            ),
          ),
        ),
      );
    }).toList();

    final allItem = const DropdownMenuItem<String>(
      value: '__all__',
      child: Text(
        'All learners',
        style: TextStyle(
          fontWeight: FontWeight.w800,
          color: Colors.white,
        ),
      ),
    );

    final currentValue = _hasLearnerSelected ? _selectedLearnerUid : '__all__';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white24),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: currentValue,
          isExpanded: true,
          dropdownColor: p.primary,
          iconEnabledColor: Colors.white,
          items: [allItem, ...items],
          onChanged: (v) {
            if (v == '__all__') {
              setState(() => _selectedLearnerUid = null);
            } else {
              setState(() => _selectedLearnerUid = v);
            }
          },
          selectedItemBuilder: (ctx) {
            return [allItem, ...uids.map((uid) {
              final label = _dropdownLabelFor(uid);
              return DropdownMenuItem<String>(
                value: uid,
                child: Text(
                  _hasLearnerSelected ? label : 'All learners',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
              );
            })];
          },
        ),
      ),
    );
  }

  Widget _unitsProgressCard(AppPalette p) {
    if (_syllabiFlat.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: p.cardBg,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: p.border.withValues(alpha: 0.85)),
        ),
        child: Text(
          'Syllabus not found for this course.',
          style: TextStyle(color: p.text, fontWeight: FontWeight.w900),
        ),
      );
    }

    final units = _groupSyllabiByUnit();

    Set<String> coveredSet = _classCoveredSessionIds;
    if (_hasLearnerSelected &&
        _selectedLearnerUid != null &&
        _selectedLearnerUid!.isNotEmpty) {
      coveredSet = _computeCoveredForLearner(_selectedLearnerUid!);
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.cardBg,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: p.border.withValues(alpha: 0.85)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Course Units',
            style: TextStyle(
              color: p.primary,
              fontWeight: FontWeight.w900,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _hasLearnerSelected
                ? 'Lessons the selected learner attended.'
                : 'Lessons taught in class.',
            style: TextStyle(
              color: p.text.withValues(alpha: 0.72),
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 12),
          ...units.map((u) => _unitExpansion(p, u, coveredSet)),
        ],
      ),
    );
  }

  Widget _unitExpansion(
    AppPalette p,
    Map<String, dynamic> u,
    Set<String> coveredSet,
  ) {
    final unitTitle = (u['unitTitle'] ?? 'Unit').toString();
    final sessions = (u['sessions'] as List<Map<String, dynamic>>);

    int unitTotal = sessions.length;
    int unitPassed = 0;
    for (final s in sessions) {
      final sid = (s['sessionId'] ?? '').toString();
      if (sid.isNotEmpty && coveredSet.contains(sid)) unitPassed++;
    }

    final unitPct = unitTotal == 0
        ? 0
        : ((unitPassed / unitTotal) * 100).round();
    final unitColor = _progressColor(unitPct);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: p.border.withValues(alpha: 0.85)),
        color: p.cardBg,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 8,
            ),
            childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            leading: Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: p.soft,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(Icons.folder_open_rounded, color: p.primary),
            ),
            title: Text(
              unitTitle.isEmpty ? 'Unit' : unitTitle,
              style: TextStyle(color: p.text, fontWeight: FontWeight.w900),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Covered: $unitPassed / $unitTotal',
                      style: TextStyle(
                        color: p.text.withValues(alpha: 0.7),
                        fontWeight: FontWeight.w800,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '$unitPct%',
                    style: TextStyle(
                      color: unitColor,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
              ),
            ),
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: unitTotal == 0 ? 0 : unitPassed / unitTotal,
                  minHeight: 8,
                  backgroundColor: unitColor.withValues(alpha: 0.12),
                  valueColor: AlwaysStoppedAnimation(unitColor),
                ),
              ),
              const SizedBox(height: 12),
              ...sessions.map((s) => _sessionExpansion(p, s, coveredSet)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _timelineSection(AppPalette p) {
    final groups = _groupAttendanceByDate(_classCoveredSessionIds);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.cardBg,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: p.border.withValues(alpha: 0.85)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(top: 8),
          initiallyExpanded: false,
          title: Text(
            'Lesson Timeline',
            style: TextStyle(
              color: p.primary,
              fontWeight: FontWeight.w900,
              fontSize: 16,
            ),
          ),
          subtitle: Text(
            '${groups.length} date(s) — tap to expand',
            style: TextStyle(
              color: p.text.withValues(alpha: 0.72),
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
          children: [
            if (groups.isEmpty)
              Text(
                'No lessons recorded yet.',
                style: TextStyle(color: p.text, fontWeight: FontWeight.w800),
              )
            else
              ...groups.map(
                (group) => _attendanceDateGroupCard(
                  p,
                  dateLabel: (group['dateLabel'] ?? 'No date').toString(),
                  sessions:
                      (group['sessions'] as List<Map<String, dynamic>>),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _attendanceDateGroupCard(
    AppPalette p, {
    required String dateLabel,
    required List<Map<String, dynamic>> sessions,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: p.primary.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: p.border.withValues(alpha: 0.85)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            dateLabel,
            style: TextStyle(
              color: p.primary,
              fontWeight: FontWeight.w900,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 10),
          ...sessions.map(
            (s) => _sessionExpansion(p, s, _classCoveredSessionIds),
          ),
        ],
      ),
    );
  }

  Widget _sessionExpansion(
    AppPalette p,
    Map<String, dynamic> s,
    Set<String> coveredSet,
  ) {
    final title = (s['title'] ?? '').toString();
    final unitTitle = (s['unitTitle'] ?? '').toString();
    final sessionId = (s['sessionId'] ?? '').toString();
    final skill = (s['skillType'] ?? '').toString();
    final objective = (s['objective'] ?? '').toString();
    final content = (s['content'] ?? '').toString();
    final sessionDate = (s['_record'] is Map)
        ? (Map<String, dynamic>.from(s['_record'] as Map)['date'] ?? '')
              .toString()
              .trim()
        : '';

    final bool passed = sessionId.isNotEmpty && coveredSet.contains(sessionId);
    final statusText = passed ? 'Taught' : 'Pending';
    final statusColor = passed ? successGreen : warningOrange;
    final attendanceRecord = passed
        ? _attendanceRecordForSession(sessionId)
        : null;

    return GestureDetector(
      onLongPress: () => _copySessionCardDetails(
        topic: title,
        unitTitle: unitTitle,
        skill: skill,
        objective: objective,
        content: content,
      ),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: p.border.withValues(alpha: 0.85)),
          color: p.cardBg,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 6,
              ),
              childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              leading: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  passed ? Icons.check_circle_rounded : Icons.schedule_rounded,
                  color: statusColor,
                ),
              ),
              title: Row(
                children: [
                  Expanded(
                    child: Text(
                      title.isEmpty ? 'Session' : title,
                      style: TextStyle(
                        color: p.text,
                        fontWeight: FontWeight.w900,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (passed && attendanceRecord != null) ...[
                    const SizedBox(width: 6),
                    InkWell(
                      borderRadius: BorderRadius.circular(999),
                      onTap: () =>
                          _showTaughtSessionDetails(s, attendanceRecord),
                      child: Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: vividHomework.withValues(alpha: 0.16),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.assignment_rounded,
                          color: vividHomework,
                          size: 17,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    InkWell(
                      borderRadius: BorderRadius.circular(999),
                      onTap: () => _openEditAttendance(attendanceRecord),
                      child: Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: vividEdit.withValues(alpha: 0.16),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.edit_note_rounded,
                          color: vividEdit,
                          size: 18,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              subtitle: Text(
                [
                  if (skill.isNotEmpty) skill,
                  statusText,
                  if (passed && sessionDate.isNotEmpty) sessionDate,
                ].join(' • '),
                style: TextStyle(
                  color: p.text.withValues(alpha: 0.7),
                  fontWeight: FontWeight.w700,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: p.primary.withValues(alpha: 0.04),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _detailLine(p, 'Status', statusText),
                      if (objective.trim().isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Text(
                          'Objective',
                          style: TextStyle(
                            color: p.text,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          objective,
                          style: TextStyle(
                            color: p.text,
                            fontWeight: FontWeight.w700,
                            height: 1.35,
                          ),
                        ),
                      ],
                      if (content.trim().isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Text(
                          'Content',
                          style: TextStyle(
                            color: p.text,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          content,
                          style: TextStyle(
                            color: p.text,
                            fontWeight: FontWeight.w700,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _copySessionCardDetails({
    required String topic,
    required String unitTitle,
    required String skill,
    required String objective,
    required String content,
  }) async {
    final level =
        (widget.classData['level'] ??
                widget.classData['course_level'] ??
                widget.classData['levelName'] ??
                _courseTitle)
            .toString()
            .trim();

    final lines = <String>[
      'Topic: ${topic.trim().isEmpty ? '-' : topic.trim()}',
      'Unit Theme: ${unitTitle.trim().isEmpty ? '-' : unitTitle.trim()}',
      'Skill: ${skill.trim().isEmpty ? '-' : skill.trim()}',
      'Level: ${level.isEmpty ? '-' : level}',
      'Objective: ${objective.trim().isEmpty ? '-' : objective.trim()}',
      'Content: ${content.trim().isEmpty ? '-' : content.trim()}',
    ];

    await Clipboard.setData(ClipboardData(text: lines.join('\n')));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Unit details copied')));
  }

  Map<String, dynamic>? _attendanceRecordForSession(String sessionId) {
    if (sessionId.trim().isEmpty) return null;
    for (final entry in _attendance.entries) {
      final raw = entry.value;
      if (raw is! Map) continue;
      final rec = Map<String, dynamic>.from(raw);

      bool matched = false;
      if (rec['taughtItems'] is List) {
        final items = (rec['taughtItems'] as List).whereType<Map>().toList();
        for (final item in items) {
          final m = Map<String, dynamic>.from(item);
          final sid = (m['sessionId'] ?? '').toString().trim();
          if (sid == sessionId) {
            matched = true;
            break;
          }
        }
      }

      if (!matched && rec['taught'] is Map) {
        final taught = Map<String, dynamic>.from(rec['taught'] as Map);
        final sid = (taught['sessionId'] ?? '').toString().trim();
        if (sid == sessionId) matched = true;
      }

      if (matched) {
        return {'id': entry.key, ...rec};
      }
    }
    return null;
  }

  int _safeMapLength(dynamic value) {
    if (value is Map) return value.length;
    return 0;
  }

  Future<void> _openEditAttendance(
    Map<String, dynamic> record, {
    bool preserveExistingLearnerAttendanceOnly = false,
  }) async {
    final sessionId = (record['sessionId'] ?? record['id'] ?? '').toString();
    if (sessionId.isEmpty) return;

    await OfflineActionGuard.runExclusive(
      context,
      'teacher.class_progress.edit_attendance.$sessionId',
      () async {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => TakeAttendanceScreen(
              classData: widget.classData,
              existingSessionId: sessionId,
              existingRecord: record,
              preserveExistingLearnerAttendanceOnly:
                  preserveExistingLearnerAttendanceOnly,
            ),
          ),
        );
      },
    );

    if (!mounted) return;
    await _boot();
  }

  Future<void> _showTaughtSessionDetails(
    Map<String, dynamic> session,
    Map<String, dynamic> record,
  ) async {
    final p = palette;
    final date = (record['date'] ?? 'No date').toString();
    final taughtTitle = (session['title'] ?? '').toString().trim();
    final presentCount = _safeMapLength(record['present']);
    final absentCount = _safeMapLength(record['absent']);
    final homework = Map<String, dynamic>.from(record['homework'] ?? {});
    final homeworkText = (homework['text'] ?? '').toString().trim();
    final homeworkDue = (homework['dueDate'] ?? '').toString().trim();
    final hasHomework = homeworkText.isNotEmpty || homeworkDue.isNotEmpty;
    final unitTheme = (session['unitTitle'] ?? '').toString().trim();
    final skill = (session['skillType'] ?? '').toString().trim();
    final objective = (session['objective'] ?? '').toString().trim();
    final content = (session['content'] ?? '').toString().trim();
    final level =
        (widget.classData['level'] ??
                widget.classData['course_level'] ??
                widget.classData['levelName'] ??
                _courseTitle)
            .toString()
            .trim();

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: p.cardBg,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.85,
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Session Details',
                      style: TextStyle(
                        color: p.primary,
                        fontWeight: FontWeight.w900,
                        fontSize: 17,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      date,
                      style: TextStyle(
                        color: p.primary,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      taughtTitle.isEmpty ? 'Untitled session' : taughtTitle,
                      style: TextStyle(
                        color: p.text,
                        fontWeight: FontWeight.w800,
                        height: 1.3,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _kpi(
                          p,
                          label: 'Present',
                          value: '$presentCount',
                          icon: Icons.check_circle_outline_rounded,
                        ),
                        _kpi(
                          p,
                          label: 'Absent',
                          value: '$absentCount',
                          icon: Icons.highlight_off_rounded,
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _detailLine(
                      p,
                      'Unit Theme',
                      unitTheme.isEmpty ? '-' : unitTheme,
                    ),
                    const SizedBox(height: 6),
                    _detailLine(p, 'Skill', skill.isEmpty ? '-' : skill),
                    const SizedBox(height: 6),
                    _detailLine(p, 'Level', level.isEmpty ? '-' : level),
                    if (objective.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text(
                        'Objective',
                        style: TextStyle(
                          color: p.text,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        objective,
                        style: TextStyle(
                          color: p.text,
                          fontWeight: FontWeight.w700,
                          height: 1.35,
                        ),
                      ),
                    ],
                    if (content.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text(
                        'Content',
                        style: TextStyle(
                          color: p.text,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        content,
                        style: TextStyle(
                          color: p.text,
                          fontWeight: FontWeight.w700,
                          height: 1.35,
                        ),
                      ),
                    ],
                    if (hasHomework) ...[
                      const SizedBox(height: 12),
                      Text(
                        'Homework',
                        style: TextStyle(
                          color: p.text,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 6),
                      if (homeworkText.isNotEmpty)
                        Text(
                          homeworkText,
                          style: TextStyle(
                            color: p.text,
                            fontWeight: FontWeight.w700,
                            height: 1.35,
                          ),
                        ),
                      if (homeworkDue.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            'Due: $homeworkDue',
                            style: TextStyle(
                              color: p.text.withValues(alpha: 0.72),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                    ],
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: p.accent,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        onPressed: () async {
                          Navigator.pop(ctx);
                          await _openEditAttendance(record);
                        },
                        icon: const Icon(Icons.edit_note_rounded),
                        label: const Text(
                          'Edit Attendance',
                          style: TextStyle(fontWeight: FontWeight.w900),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _detailLine(AppPalette p, String k, String v) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            k,
            style: TextStyle(
              color: p.text.withValues(alpha: 0.70),
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            v,
            textAlign: TextAlign.right,
            style: TextStyle(color: p.text, fontWeight: FontWeight.w900),
          ),
        ),
      ],
    );
  }

  Widget _kpi(
    AppPalette p, {
    required String label,
    required String value,
    required IconData icon,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: p.border.withValues(alpha: 0.85)),
        color: p.primary.withValues(alpha: 0.04),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: p.primary),
          const SizedBox(width: 8),
          Text(
            value,
            style: TextStyle(color: p.text, fontWeight: FontWeight.w900),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              color: p.text.withValues(alpha: 0.7),
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState(AppPalette p) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: p.cardBg,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: dangerRed.withValues(alpha: 0.20)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline_rounded,
                size: 56,
                color: dangerRed,
              ),
              const SizedBox(height: 12),
              const Text(
                'Something went wrong',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: dangerRed,
                  fontSize: 15,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _error ?? 'Unknown error',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: p.text,
                  fontWeight: FontWeight.w700,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DivDot extends StatelessWidget {
  final Color color;
  const _DivDot({required this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Text(
        '|',
        style: TextStyle(color: color, fontWeight: FontWeight.w900),
      ),
    );
  }
}

class _LearnerStats {
  final int sessionsHeld;
  final int present;
  final int absent;
  final int consumed;
  final int paid;
  final int left;

  const _LearnerStats({
    required this.sessionsHeld,
    required this.present,
    required this.absent,
    required this.consumed,
    required this.paid,
    required this.left,
  });

  factory _LearnerStats.zero() => const _LearnerStats(
    sessionsHeld: 0,
    present: 0,
    absent: 0,
    consumed: 0,
    paid: 0,
    left: 0,
  );
}
