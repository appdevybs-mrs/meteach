import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';

import '../shared/app_theme.dart';
import '../shared/offline_action_guard.dart';
import '../shared/human_error.dart';
import 'take_attendance_screen.dart';
import '../shared/app_feedback.dart';
import '../shared/teacher_web_layout.dart';

class AttendanceHistoryScreen extends StatefulWidget {
  final Map<String, dynamic> classData;

  const AttendanceHistoryScreen({super.key, required this.classData});

  @override
  State<AttendanceHistoryScreen> createState() =>
      _AttendanceHistoryScreenState();
}

class _AttendanceHistoryScreenState extends State<AttendanceHistoryScreen> {
  static const Color presentGreen = Color(0xFF27AE60);
  static const Color absentRed = Color(0xFFEB5757);

  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  bool _busy = true;
  String? _error;
  List<Map<String, dynamic>> _sessions = [];

  String get _classId =>
      (widget.classData['class_id'] ?? widget.classData['id'] ?? '').toString();

  String get _courseTitle =>
      (widget.classData['course_title'] ?? 'Course History').toString();

  AppPalette get palette => appThemeController.palette;

  @override
  void initState() {
    super.initState();
    appThemeController.addListener(_onThemeChanged);
    _loadHistory();
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

  Future<void> _loadHistory() async {
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final snap = await _db
          .child("classes")
          .child(_classId)
          .child('attendance')
          .get();

      if (!snap.exists) {
        setState(() {
          _sessions = [];
          _busy = false;
        });
        return;
      }

      final raw = Map<String, dynamic>.from(snap.value as Map);

      final list = raw.entries
          .where((e) => e.value is Map)
          .map(
            (e) => {'id': e.key, ...Map<String, dynamic>.from(e.value as Map)},
          )
          .toList();

      list.sort((a, b) {
        final dateA = (a['date'] ?? '0000-00-00').toString();
        final dateB = (b['date'] ?? '0000-00-00').toString();
        return dateB.compareTo(dateA);
      });

      setState(() {
        _sessions = list;
        _busy = false;
      });
    } catch (e) {
      setState(() {
        _error = toHumanError(e);
        _busy = false;
      });
    }
  }

  Future<void> _deleteSession(Map<String, dynamic> session) async {
    final p = palette;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'Delete Record?',
          style: TextStyle(color: p.primary, fontWeight: FontWeight.w900),
        ),
        content: Text(
          'This will remove attendance for the teacher and all learners. This action cannot be undone.',
          style: TextStyle(
            color: p.text,
            height: 1.4,
            fontWeight: FontWeight.w600,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              'Cancel',
              style: TextStyle(color: p.primary, fontWeight: FontWeight.w800),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: absentRed,
              foregroundColor: Colors.white,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text(
              'Delete',
              style: TextStyle(fontWeight: FontWeight.w900),
            ),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _busy = true);

    try {
      final sId = (session['sessionId'] ?? session['id']).toString();
      final Map<String, dynamic> updates = {};

      updates['classes/$_classId/attendance/$sId'] = null;

      final allUids = <String>{
        ...Map<String, dynamic>.from(
          session['present'] ?? {},
        ).keys.map((e) => e.toString()),
        ...Map<String, dynamic>.from(
          session['absent'] ?? {},
        ).keys.map((e) => e.toString()),
      };

      for (final uid in allUids) {
        final uSnap = await _db
            .child('users')
            .child(uid)
            .child('courses')
            .get();
        if (uSnap.exists) {
          final courses = Map<String, dynamic>.from(uSnap.value as Map);
          for (final entry in courses.entries) {
            final value = entry.value;
            if (value is! Map) continue;

            final classNode = value['class'];
            if (classNode is! Map) continue;

            if ((classNode['class_id'] ?? '').toString() == _classId) {
              updates['users/$uid/courses/${entry.key}/attendance/$sId'] = null;
            }
          }
        }
      }

      await _db.update(updates);
      await _loadHistory();

      if (mounted) {
        AppToast.fromSnackBar(
          context,
          const SnackBar(content: Text('Record deleted successfully')),
        );
      }
    } catch (e) {
      setState(() {
        _error = "Delete failed: $e";
        _busy = false;
      });
    }
  }

  Future<String> _nameOf(String uid) async {
    final snap = await _db.child("users").child(uid).get();
    if (!snap.exists) return uid;

    final m = Map<String, dynamic>.from(snap.value as Map);
    final full = "${m['first_name'] ?? ''} ${m['last_name'] ?? ''}".trim();

    return full.isEmpty ? uid : full;
  }

  int _safeMapLength(dynamic value) {
    if (value is Map) return value.length;
    return 0;
  }

  int _safeInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  String _sessionHeadline(Map<String, dynamic> session) {
    if (session['taughtItems'] is List) {
      final items = (session['taughtItems'] as List).whereType<Map>().toList();

      final titles = items
          .map((e) {
            final item = Map<String, dynamic>.from(e);
            final type = (item['type'] ?? 'syllabus').toString();

            if (type == 'custom') {
              final customTitle = (item['title'] ?? '').toString().trim();
              return customTitle.isEmpty ? 'Custom Lesson' : customTitle;
            }

            final title = (item['title'] ?? '').toString().trim();
            final unitTitle = (item['unitTitle'] ?? '').toString().trim();
            final sn = _safeInt(item['sessionNumber']);
            if (title.isEmpty) return '';
            if (unitTitle.isNotEmpty && sn > 0) {
              return 'Unit $unitTitle • Session $sn • $title';
            }
            if (unitTitle.isNotEmpty) {
              return 'Unit $unitTitle • $title';
            }
            if (sn > 0) {
              return 'Session $sn • $title';
            }
            return title;
          })
          .where((t) => t.isNotEmpty)
          .toList();

      if (titles.isNotEmpty) {
        if (titles.length == 1) return titles.first;
        return '${titles.first} +${titles.length - 1} more';
      }
    }

    if (session['taught'] is Map) {
      final taught = Map<String, dynamic>.from(session['taught'] as Map);
      final title = (taught['title'] ?? '').toString().trim();
      final unitTitle = (taught['unitTitle'] ?? '').toString().trim();
      final sn = _safeInt(taught['sessionNumber']);
      if (title.isNotEmpty) {
        if (unitTitle.isNotEmpty && sn > 0) {
          return 'Unit $unitTitle • Session $sn • $title';
        }
        if (unitTitle.isNotEmpty) {
          return 'Unit $unitTitle • $title';
        }
        if (sn > 0) {
          return 'Session $sn • $title';
        }
        return title;
      }
    }

    return 'Regular Session';
  }

  List<Map<String, dynamic>> _normalizedTaughtItems(
    Map<String, dynamic> session,
  ) {
    final List<Map<String, dynamic>> result = [];

    if (session['taughtItems'] is List) {
      final raw = (session['taughtItems'] as List).whereType<Map>().toList();
      for (final item in raw) {
        result.add(Map<String, dynamic>.from(item));
      }
    } else if (session['taught'] is Map) {
      final taught = Map<String, dynamic>.from(session['taught'] as Map);
      if (taught.isNotEmpty) {
        result.add({
          'type': (taught['type'] ?? 'syllabus').toString(),
          'unitTitle': (taught['unitTitle'] ?? '').toString(),
          'title': (taught['title'] ?? '').toString(),
          'sessionNumber': taught['sessionNumber'] ?? 0,
          'notes': (taught['notes'] ?? '').toString(),

          // NEW snapshot fields
          'objective': (taught['objective'] ?? '').toString(),
          'skillType': (taught['skillType'] ?? '').toString(),
          'lessonHomework': (taught['lessonHomework'] ?? '').toString(),
        });
      }
    }

    return result;
  }

  List<String> _skillTagsForCard(Map<String, dynamic> session) {
    final tags = <String>{};
    final taughtItems = _normalizedTaughtItems(session);
    for (final item in taughtItems) {
      final raw = (item['skillType'] ?? '').toString().trim();
      if (raw.isEmpty) continue;
      tags.add(raw);
    }
    return tags.toList();
  }

  String _lessonSummaryForCard(Map<String, dynamic> session) {
    final taughtItems = _normalizedTaughtItems(session);
    if (taughtItems.isEmpty) return '';
    final first = taughtItems.first;
    final firstTitle = (first['title'] ?? '').toString().trim();
    if (firstTitle.isEmpty) return '';
    if (taughtItems.length == 1) return firstTitle;
    return '$firstTitle +${taughtItems.length - 1} more';
  }

  void _showSessionDetails(Map<String, dynamic> session) {
    final p = palette;
    final taughtItems = _normalizedTaughtItems(session);
    final homework = Map<String, dynamic>.from(session['homework'] ?? {});
    final homeworkText = (homework['text'] ?? '').toString().trim();
    final homeworkDue = (homework['dueDate'] ?? '').toString().trim();
    final meetingNumber = _safeInt(session['meetingNumber']);
    final successRate = _safeInt(session['successRate']);
    final dateText = (session['date'] ?? 'No Date').toString();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: p.appBg,
      showDragHandle: true,
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
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            p.primary,
                            p.primary.withValues(alpha: 0.88),
                          ],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(22),
                        boxShadow: [
                          BoxShadow(
                            color: p.primary.withValues(alpha: 0.14),
                            blurRadius: 18,
                            offset: const Offset(0, 8),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Session Details',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.82),
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            dateText,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w900,
                              fontSize: 22,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              if (meetingNumber > 0)
                                _detailHeroChip(
                                  p,
                                  icon: Icons.confirmation_number_rounded,
                                  text: 'Meeting $meetingNumber',
                                ),
                              _detailHeroChip(
                                p,
                                icon: Icons.insights_rounded,
                                text: '$successRate% success',
                              ),
                              _detailHeroChip(
                                p,
                                icon: Icons.menu_book_rounded,
                                text:
                                    '${taughtItems.length} lesson${taughtItems.length == 1 ? '' : 's'}',
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    _detailSectionTitle(
                      p,
                      icon: Icons.school_rounded,
                      title: 'Lessons Taught',
                    ),
                    const SizedBox(height: 10),
                    if (taughtItems.isEmpty)
                      _emptyDetailsCard(
                        p,
                        'No lesson details found for this session.',
                      )
                    else
                      ...taughtItems.map((item) {
                        final type = (item['type'] ?? 'syllabus').toString();
                        final title = (item['title'] ?? '').toString().trim();
                        final unitTitle = (item['unitTitle'] ?? '')
                            .toString()
                            .trim();
                        final notes = (item['notes'] ?? '').toString().trim();
                        final objective = (item['objective'] ?? '')
                            .toString()
                            .trim();
                        final skillType = (item['skillType'] ?? '')
                            .toString()
                            .trim();
                        final lessonHomework = (item['lessonHomework'] ?? '')
                            .toString()
                            .trim();
                        final sessionNumber = _safeInt(item['sessionNumber']);

                        final isCustom = type == 'custom';

                        return Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: p.cardBg,
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                              color: p.border.withValues(alpha: 0.9),
                            ),
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
                                width: 42,
                                height: 42,
                                decoration: BoxDecoration(
                                  color: isCustom
                                      ? p.accent.withValues(alpha: 0.10)
                                      : p.soft,
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: Icon(
                                  isCustom
                                      ? Icons.edit_note_rounded
                                      : Icons.menu_book_rounded,
                                  color: isCustom ? p.accent : p.primary,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (!isCustom && unitTitle.isNotEmpty) ...[
                                      Text(
                                        unitTitle,
                                        style: TextStyle(
                                          color: p.text.withValues(alpha: 0.65),
                                          fontSize: 12,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      const SizedBox(height: 3),
                                    ],
                                    Text(
                                      isCustom
                                          ? (title.isEmpty
                                                ? 'Custom Lesson'
                                                : title)
                                          : (sessionNumber > 0
                                                ? 'Session $sessionNumber • $title'
                                                : (title.isEmpty
                                                      ? 'Untitled Lesson'
                                                      : title)),
                                      style: TextStyle(
                                        color: p.primary,
                                        fontWeight: FontWeight.w900,
                                        fontSize: 14,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 8,
                                      children: [
                                        _pillChip(
                                          p,
                                          icon: isCustom
                                              ? Icons.star_rounded
                                              : Icons.check_rounded,
                                          text: isCustom
                                              ? 'Custom'
                                              : 'Syllabus',
                                          tint: isCustom ? p.accent : p.primary,
                                        ),
                                        if (skillType.isNotEmpty)
                                          _pillChip(
                                            p,
                                            icon: Icons.category_rounded,
                                            text: skillType,
                                            tint: p.accent,
                                          ),
                                      ],
                                    ),
                                    if (objective.isNotEmpty) ...[
                                      const SizedBox(height: 10),
                                      Container(
                                        width: double.infinity,
                                        padding: const EdgeInsets.all(10),
                                        decoration: BoxDecoration(
                                          color: p.appBg,
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              'Objective',
                                              style: TextStyle(
                                                color: p.text.withValues(
                                                  alpha: 0.65,
                                                ),
                                                fontSize: 11,
                                                fontWeight: FontWeight.w800,
                                                letterSpacing: 0.4,
                                              ),
                                            ),
                                            const SizedBox(height: 6),
                                            Text(
                                              objective,
                                              style: TextStyle(
                                                color: p.text,
                                                height: 1.4,
                                                fontSize: 12,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                    if (notes.isNotEmpty) ...[
                                      const SizedBox(height: 10),
                                      Container(
                                        width: double.infinity,
                                        padding: const EdgeInsets.all(10),
                                        decoration: BoxDecoration(
                                          color: p.appBg,
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              'Notes',
                                              style: TextStyle(
                                                color: p.text.withValues(
                                                  alpha: 0.65,
                                                ),
                                                fontSize: 11,
                                                fontWeight: FontWeight.w800,
                                                letterSpacing: 0.4,
                                              ),
                                            ),
                                            const SizedBox(height: 6),
                                            Text(
                                              notes,
                                              style: TextStyle(
                                                color: p.text,
                                                height: 1.4,
                                                fontSize: 12,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                    if (lessonHomework.isNotEmpty) ...[
                                      const SizedBox(height: 10),
                                      Container(
                                        width: double.infinity,
                                        padding: const EdgeInsets.all(10),
                                        decoration: BoxDecoration(
                                          color: p.appBg,
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                        ),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              'Lesson Homework',
                                              style: TextStyle(
                                                color: p.text.withValues(
                                                  alpha: 0.65,
                                                ),
                                                fontSize: 11,
                                                fontWeight: FontWeight.w800,
                                                letterSpacing: 0.4,
                                              ),
                                            ),
                                            const SizedBox(height: 6),
                                            Text(
                                              lessonHomework,
                                              style: TextStyle(
                                                color: p.text,
                                                height: 1.4,
                                                fontSize: 12,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      }),
                    const SizedBox(height: 8),
                    _detailSectionTitle(
                      p,
                      icon: Icons.assignment_rounded,
                      title: 'Homework',
                    ),
                    const SizedBox(height: 10),
                    if (homeworkText.isEmpty && homeworkDue.isEmpty)
                      _emptyDetailsCard(
                        p,
                        'No homework was added for this session.',
                      )
                    else
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: p.cardBg,
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                            color: p.border.withValues(alpha: 0.9),
                          ),
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
                            if (homeworkText.isNotEmpty) ...[
                              Text(
                                'Instructions',
                                style: TextStyle(
                                  color: p.text.withValues(alpha: 0.65),
                                  fontWeight: FontWeight.w800,
                                  fontSize: 11,
                                  letterSpacing: 1.0,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                homeworkText,
                                style: TextStyle(
                                  color: p.text,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  height: 1.5,
                                ),
                              ),
                            ],
                            if (homeworkText.isNotEmpty &&
                                homeworkDue.isNotEmpty)
                              const SizedBox(height: 14),
                            if (homeworkDue.isNotEmpty)
                              _pillChip(
                                p,
                                icon: Icons.calendar_month_rounded,
                                text: 'Due: $homeworkDue',
                                tint: p.accent,
                              ),
                          ],
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

  Widget _detailHeroChip(
    AppPalette p, {
    required IconData icon,
    required String text,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white24),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: Colors.white),
          const SizedBox(width: 6),
          Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  Widget _detailSectionTitle(
    AppPalette p, {
    required IconData icon,
    required String title,
  }) {
    return Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: p.soft,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(icon, color: p.primary, size: 18),
        ),
        const SizedBox(width: 10),
        Text(
          title,
          style: TextStyle(
            color: p.primary,
            fontWeight: FontWeight.w900,
            fontSize: 15,
          ),
        ),
      ],
    );
  }

  Widget _emptyDetailsCard(AppPalette p, String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: p.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: p.border.withValues(alpha: 0.9)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: p.text.withValues(alpha: 0.7),
          fontWeight: FontWeight.w700,
          fontSize: 13,
        ),
      ),
    );
  }

  Widget _pillChip(
    AppPalette p, {
    required IconData icon,
    required String text,
    required Color tint,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: tint.withValues(alpha: 0.22)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: tint),
          const SizedBox(width: 6),
          Text(
            text,
            style: TextStyle(
              color: tint,
              fontWeight: FontWeight.w800,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  void _editSession(Map<String, dynamic> session) async {
    final sessionId = (session['sessionId'] ?? session['id']).toString();

    await OfflineActionGuard.runExclusive(
      context,
      'teacher.attendance_history.edit.$sessionId',
      () async {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => TakeAttendanceScreen(
              classData: widget.classData,
              existingSessionId: sessionId,
              existingRecord: session,
            ),
          ),
        );
      },
    );

    _loadHistory();
  }

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final totalSessions = _sessions.length;

    return Scaffold(
      backgroundColor: p.appBg,
      appBar: AppBar(
        backgroundColor: p.cardBg,
        elevation: 0,
        centerTitle: false,
        surfaceTintColor: p.cardBg,
        titleSpacing: 16,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Attendance History',
              style: TextStyle(
                color: p.primary,
                fontSize: 16,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              _courseTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: p.text.withValues(alpha: 0.72),
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        actions: [
          const SizedBox.shrink(),
          IconButton(
            tooltip: 'Refresh',
            icon: Icon(Icons.refresh_rounded, color: p.primary),
            onPressed: _busy ? null : _loadHistory,
          ),
        ],
      ),
      body: teacherWebBodyFrame(
        context: context,
        maxWidth: 1400,
        child: Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: Opacity(
                  opacity: 0.04,
                  child: Center(
                    child: Icon(
                      Icons.fact_check_rounded,
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
                ? _buildError(p)
                : _sessions.isEmpty
                ? _buildEmpty(p)
                : RefreshIndicator(
                    color: p.primary,
                    onRefresh: _loadHistory,
                    child: ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
                      children: [
                        _topSummaryCard(p, totalSessions),
                        const SizedBox(height: 14),
                        ..._sessions.map((s) => _buildSessionCard(p, s)),
                      ],
                    ),
                  ),
          ],
        ),
      ),
    );
  }

  Widget _topSummaryCard(AppPalette p, int totalSessions) {
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
      child: Row(
        children: [
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(18),
            ),
            child: const Icon(
              Icons.history_edu_rounded,
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
                  'Session Records',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.80),
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '$totalSessions saved session${totalSessions == 1 ? '' : 's'}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize: 20,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Tap the info icon to view full lesson and homework details.',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.86),
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
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

  Widget _buildSessionCard(AppPalette p, Map<String, dynamic> s) {
    final dateText = (s['date'] ?? 'No Date').toString();
    final taughtTitle = _sessionHeadline(s);
    final lessonSummary = _lessonSummaryForCard(s);
    final skillTags = _skillTagsForCard(s);
    final presentCount = _safeMapLength(s['present']);
    final absentCount = _safeMapLength(s['absent']);
    final successRate = _safeInt(s['successRate']);
    final meetingNumber = _safeInt(s['meetingNumber']);

    final homework = Map<String, dynamic>.from(s['homework'] ?? {});
    final hasHomework =
        (homework['text'] ?? '').toString().trim().isNotEmpty ||
        (homework['dueDate'] ?? '').toString().trim().isNotEmpty;

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: p.cardBg,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: p.border.withValues(alpha: 0.85)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 14,
            offset: const Offset(0, 7),
          ),
        ],
      ),
      child: Theme(
        data: Theme.of(context).copyWith(
          dividerColor: Colors.transparent,
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
        ),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.fromLTRB(16, 14, 10, 10),
          childrenPadding: EdgeInsets.zero,
          iconColor: p.primary,
          collapsedIconColor: p.primary,
          title: Row(
            children: [
              Expanded(
                child: Text(
                  dateText,
                  style: TextStyle(
                    color: p.primary,
                    fontWeight: FontWeight.w900,
                    fontSize: 17,
                  ),
                ),
              ),
              if (meetingNumber > 0)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: p.soft,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    'M$meetingNumber',
                    style: TextStyle(
                      color: p.primary,
                      fontWeight: FontWeight.w900,
                      fontSize: 11,
                    ),
                  ),
                ),
            ],
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        taughtTitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: p.text,
                          fontWeight: FontWeight.w800,
                          fontSize: 13,
                          height: 1.3,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    InkWell(
                      borderRadius: BorderRadius.circular(999),
                      onTap: () => _showSessionDetails(s),
                      child: Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: p.primary.withValues(alpha: 0.08),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: p.primary.withValues(alpha: 0.10),
                          ),
                        ),
                        child: Icon(
                          Icons.info_outline_rounded,
                          color: p.primary,
                          size: 19,
                        ),
                      ),
                    ),
                  ],
                ),
                if (lessonSummary.isNotEmpty || skillTags.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (lessonSummary.isNotEmpty)
                        _statBadge(
                          lessonSummary,
                          p.primary,
                          Icons.menu_book_rounded,
                        ),
                      ...skillTags.map(
                        (tag) => _statBadge(
                          tag,
                          p.accent,
                          Icons.record_voice_over_rounded,
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _statBadge(
                      '$successRate%',
                      Colors.blueGrey,
                      Icons.insights_rounded,
                    ),
                    _statBadge(
                      '$presentCount present',
                      presentGreen,
                      Icons.check_circle_outline_rounded,
                    ),
                    _statBadge(
                      '$absentCount absent',
                      absentRed,
                      Icons.highlight_off_rounded,
                    ),
                    if (hasHomework)
                      _statBadge(
                        'Homework',
                        p.accent,
                        Icons.assignment_turned_in_rounded,
                      ),
                  ],
                ),
              ],
            ),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'Edit',
                icon: Icon(Icons.edit_note_rounded, color: p.primary, size: 26),
                onPressed: () => _editSession(s),
              ),
              IconButton(
                tooltip: 'Delete',
                icon: const Icon(
                  Icons.delete_outline_rounded,
                  color: absentRed,
                  size: 22,
                ),
                onPressed: () => _deleteSession(s),
              ),
            ],
          ),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: p.appBg,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: p.border.withValues(alpha: 0.65)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: _studentList(
                        p,
                        'PRESENT',
                        (s['present'] as Map? ?? {}).keys.toList(),
                        presentGreen,
                        Icons.check_circle_rounded,
                      ),
                    ),
                    Container(
                      width: 1,
                      height: 120,
                      margin: const EdgeInsets.symmetric(horizontal: 12),
                      color: p.border.withValues(alpha: 0.9),
                    ),
                    Expanded(
                      child: _studentList(
                        p,
                        'ABSENT',
                        (s['absent'] as Map? ?? {}).keys.toList(),
                        absentRed,
                        Icons.cancel_rounded,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statBadge(String label, Color color, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w800,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  Widget _studentList(
    AppPalette p,
    String title,
    List<dynamic> uids,
    Color color,
    IconData icon,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 6),
            Text(
              title,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.1,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (uids.isEmpty)
          Text(
            '—',
            style: TextStyle(
              color: p.text.withValues(alpha: 0.65),
              fontWeight: FontWeight.w700,
            ),
          )
        else
          ...uids.map(
            (uid) => FutureBuilder<String>(
              future: _nameOf(uid.toString()),
              builder: (context, snap) {
                final name = snap.data ?? '...';
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 7,
                        height: 7,
                        margin: const EdgeInsets.only(top: 5),
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.8),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          name,
                          style: TextStyle(
                            fontSize: 12,
                            color: p.text,
                            fontWeight: FontWeight.w700,
                            height: 1.3,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _buildEmpty(AppPalette p) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: p.cardBg,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: p.border.withValues(alpha: 0.9)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.history_toggle_off_rounded,
                size: 56,
                color: p.text.withValues(alpha: 0.55),
              ),
              const SizedBox(height: 12),
              Text(
                'No attendance records found.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: p.primary,
                  fontSize: 15,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Saved sessions will appear here.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: p.text.withValues(alpha: 0.7),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildError(AppPalette p) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: p.cardBg,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: absentRed.withValues(alpha: 0.20)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline_rounded,
                size: 56,
                color: absentRed,
              ),
              const SizedBox(height: 12),
              const Text(
                'Something went wrong',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: absentRed,
                  fontSize: 15,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Error: $_error',
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
