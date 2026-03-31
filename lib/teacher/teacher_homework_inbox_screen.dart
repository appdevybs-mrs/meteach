import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../shared/human_error.dart';
import 'teacher_mail_thread_screen.dart';

enum _HomeworkFilter { all, notReviewed, reviewed }

class TeacherHomeworkInboxScreen extends StatefulWidget {
  const TeacherHomeworkInboxScreen({super.key});

  @override
  State<TeacherHomeworkInboxScreen> createState() =>
      _TeacherHomeworkInboxScreenState();
}

class _TeacherHomeworkInboxScreenState
    extends State<TeacherHomeworkInboxScreen> {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  String _meUid = '';
  Stream<DatabaseEvent>? _indexStream;
  _HomeworkFilter _filter = _HomeworkFilter.notReviewed;

  Future<List<_HomeworkThreadView>>? _viewsFuture;
  String _rowsSignature = '';

  @override
  void initState() {
    super.initState();
    _meUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (_meUid.isNotEmpty) {
      _indexStream = _db.child('mail_index/$_meUid').onValue;
    }
  }

  bool _isHomework(Map<String, dynamic> m) {
    final type = (m['type'] ?? '').toString().trim().toLowerCase();
    if (type == 'homework') return true;

    final subject = (m['subject'] ?? '').toString().trim().toLowerCase();
    if (subject.startsWith('[hw]')) return true;
    if (subject.contains('homework')) return true;
    return false;
  }

  int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  List<_HomeworkThreadRow> _rowsFromSnapshot(dynamic value) {
    if (value is! Map) return const <_HomeworkThreadRow>[];
    final out = <_HomeworkThreadRow>[];

    value.forEach((threadIdRaw, rowRaw) {
      if (rowRaw is! Map) return;
      final m = rowRaw.map((k, v) => MapEntry(k.toString(), v));
      if (!_isHomework(m)) return;

      final threadId = threadIdRaw.toString().trim();
      if (threadId.isEmpty) return;

      out.add(
        _HomeworkThreadRow(
          threadId: threadId,
          peerUid: (m['peerUid'] ?? '').toString().trim(),
          peerName: ((m['peerName'] ?? '').toString().trim().isEmpty)
              ? 'Learner'
              : (m['peerName'] ?? '').toString().trim(),
          subject: ((m['subject'] ?? '').toString().trim().isEmpty)
              ? 'Homework'
              : (m['subject'] ?? '').toString().trim(),
          lastMessage: (m['lastMessage'] ?? '').toString().trim(),
          updatedAtMs: _toInt(m['updatedAt']),
          unreadCount: _toInt(m['unreadCount']),
          deletedAtMs: (m['deletedAt'] == null) ? null : _toInt(m['deletedAt']),
        ),
      );
    });

    out.sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
    return out;
  }

  String _fmtTime(int ms) {
    if (ms <= 0) return '-';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    final dd = dt.day.toString().padLeft(2, '0');
    final mo = dt.month.toString().padLeft(2, '0');
    return '$dd/$mo ${dt.year} $hh:$mm';
  }

  String _signatureForRows(List<_HomeworkThreadRow> rows) {
    return rows
        .map((r) => '${r.threadId}:${r.updatedAtMs}:${r.unreadCount}')
        .join('|');
  }

  Future<List<_HomeworkThreadView>> _ensureViews(
    List<_HomeworkThreadRow> rows,
  ) {
    final sig = _signatureForRows(rows);
    if (_viewsFuture != null && sig == _rowsSignature) return _viewsFuture!;

    _rowsSignature = sig;
    _viewsFuture = _composeViews(rows);
    return _viewsFuture!;
  }

  Future<List<_HomeworkThreadView>> _composeViews(
    List<_HomeworkThreadRow> rows,
  ) async {
    final list = await Future.wait(rows.map(_loadView));
    list.sort((a, b) => b.row.updatedAtMs.compareTo(a.row.updatedAtMs));
    return list;
  }

  Future<_HomeworkThreadView> _loadView(_HomeworkThreadRow row) async {
    String courseTitle = '';
    String courseKey = '';
    String sessionId = '';
    String classId = '';
    String homeworkRefPath = '';
    String homeworkText = '';
    bool reviewed = false;
    bool needsRedo = false;
    int reviewedAt = 0;
    int score = 0;
    String grade = '';
    String reviewStatus = '';

    try {
      final tSnap = await _db.child('mail_threads/${row.threadId}').get();
      if (tSnap.exists && tSnap.value is Map) {
        final t = (tSnap.value as Map).map((k, v) => MapEntry('$k', v));
        courseKey = (t['courseKey'] ?? '').toString().trim();
        sessionId = (t['sessionId'] ?? '').toString().trim();
        classId = (t['classId'] ?? '').toString().trim();

        final tCourseTitle = (t['courseTitle'] ?? '').toString().trim();
        courseTitle = tCourseTitle.isNotEmpty
            ? tCourseTitle
            : (courseKey.isNotEmpty ? courseKey : 'Course not set');

        homeworkRefPath = (t['homeworkRef'] ?? '').toString().trim();
        if (homeworkRefPath.isNotEmpty) {
          final hwSnap = await _db.child(homeworkRefPath).get();
          if (hwSnap.exists && hwSnap.value is Map) {
            final hw = (hwSnap.value as Map).map((k, v) => MapEntry('$k', v));
            reviewedAt = _toInt(hw['reviewedAt']);
            reviewStatus = (hw['reviewStatus'] ?? '')
                .toString()
                .trim()
                .toLowerCase();
            score = _toInt(hw['reviewScore']);
            grade = (hw['reviewGrade'] ?? '').toString().trim();
            needsRedo = hw['needsRedo'] == true || reviewStatus == 'redo';
            reviewed = reviewedAt > 0 || reviewStatus.isNotEmpty;
            homeworkText =
                (hw['text'] ?? hw['homeworkText'] ?? hw['note'] ?? '')
                    .toString()
                    .trim();
          }
        }

        if ((courseTitle.isEmpty || courseTitle == courseKey) &&
            row.peerUid.isNotEmpty &&
            courseKey.isNotEmpty) {
          final cSnap = await _db
              .child('users/${row.peerUid}/courses/$courseKey')
              .get();
          if (cSnap.exists && cSnap.value is Map) {
            final c = (cSnap.value as Map).map((k, v) => MapEntry('$k', v));
            final title = (c['title'] ?? c['course_title'] ?? '')
                .toString()
                .trim();
            if (title.isNotEmpty) courseTitle = title;

            if (classId.isEmpty && c['class'] is Map) {
              final cls = (c['class'] as Map).map((k, v) => MapEntry('$k', v));
              classId = (cls['class_id'] ?? '').toString().trim();
              final classTitle = (cls['course_title'] ?? '').toString().trim();
              if (courseTitle.isEmpty && classTitle.isNotEmpty) {
                courseTitle = classTitle;
              }
            }
          }
        }

        if (classId.isNotEmpty &&
            (courseTitle.isEmpty || courseTitle == 'Course not set')) {
          final clsSnap = await _db.child('classes/$classId').get();
          if (clsSnap.exists && clsSnap.value is Map) {
            final c = (clsSnap.value as Map).map((k, v) => MapEntry('$k', v));
            final classCourseTitle =
                (c['course_title'] ?? c['courseTitle'] ?? '').toString().trim();
            if (classCourseTitle.isNotEmpty) courseTitle = classCourseTitle;
          }
        }

        if ((courseTitle.isEmpty || courseTitle == courseKey) &&
            courseKey.isNotEmpty) {
          final courseSnap = await _db.child('courses/$courseKey').get();
          if (courseSnap.exists && courseSnap.value is Map) {
            final c = (courseSnap.value as Map).map(
              (k, v) => MapEntry('$k', v),
            );
            final t = (c['title'] ?? c['course_title'] ?? '').toString().trim();
            if (t.isNotEmpty) courseTitle = t;
          }
        }
      }
    } catch (_) {}

    return _HomeworkThreadView(
      row: row,
      courseTitle: courseTitle.isEmpty ? 'Course not set' : courseTitle,
      courseKey: courseKey,
      sessionId: sessionId,
      classId: classId,
      homeworkRefPath: homeworkRefPath,
      homeworkText: homeworkText,
      reviewed: reviewed,
      needsRedo: needsRedo,
      reviewedAtMs: reviewedAt,
      reviewScore: score,
      reviewGrade: grade,
      reviewStatus: reviewStatus,
    );
  }

  Future<void> _deleteForMe(_HomeworkThreadView v) async {
    final ok =
        await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Delete from your homework inbox?'),
            content: const Text(
              'This hides it for you only. You can restore it later.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        ) ??
        false;
    if (!ok) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.child('mail_index/$_meUid/${v.row.threadId}').update({
      'deletedAt': now,
    });
    _viewsFuture = null;
    if (mounted) setState(() {});
  }

  Future<void> _restoreForMe(String threadId) async {
    await _db.child('mail_index/$_meUid/$threadId').update({'deletedAt': null});
    _viewsFuture = null;
    if (mounted) setState(() {});
  }

  Future<void> _markReviewed(_HomeworkThreadView v) async {
    if (v.homeworkRefPath.trim().isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db.child(v.homeworkRefPath).update({
      'reviewedAt': now,
      'reviewStatus': 'pass',
      'needsRedo': false,
      'reviewNote': 'Marked reviewed from homework inbox.',
    });
    _viewsFuture = null;
    if (mounted) setState(() {});
  }

  List<_HomeworkThreadView> _applyFilter(List<_HomeworkThreadView> views) {
    switch (_filter) {
      case _HomeworkFilter.notReviewed:
        return views.where((v) => !v.reviewed).toList();
      case _HomeworkFilter.reviewed:
        return views.where((v) => v.reviewed).toList();
      case _HomeworkFilter.all:
        return views;
    }
  }

  void _showDetails(_HomeworkThreadView v) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Homework details'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Learner: ${v.row.peerName}'),
            const SizedBox(height: 6),
            Text('Course: ${v.courseTitle}'),
            if (v.courseKey.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text('Course key: ${v.courseKey}'),
            ],
            if (v.sessionId.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text('Session ID: ${v.sessionId}'),
            ],
            const SizedBox(height: 8),
            Text('Status: ${v.reviewed ? 'Reviewed' : 'Not reviewed'}'),
            if (v.needsRedo) ...[
              const SizedBox(height: 6),
              const Text('Needs redo: Yes'),
            ],
            if (v.reviewed &&
                (v.reviewScore > 0 || v.reviewGrade.isNotEmpty)) ...[
              const SizedBox(height: 6),
              Text(
                'Score/Grade: ${v.reviewScore > 0 ? '${v.reviewScore}/100' : '-'} ${v.reviewGrade.isNotEmpty ? '• ${v.reviewGrade}' : ''}',
              ),
            ],
            if (v.reviewedAtMs > 0) ...[
              const SizedBox(height: 6),
              Text('Reviewed at: ${_fmtTime(v.reviewedAtMs)}'),
            ],
            const SizedBox(height: 8),
            Text(
              'Homework text:',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: Colors.black.withValues(alpha: 0.75),
              ),
            ),
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 180),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.black.withValues(alpha: 0.12)),
                color: Colors.black.withValues(alpha: 0.03),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  v.homeworkText.trim().isEmpty ? '-' : v.homeworkText,
                  style: TextStyle(
                    color: Colors.black.withValues(alpha: 0.78),
                    height: 1.3,
                  ),
                ),
              ),
            ),
          ],
        ),
        actions: [
          if (v.homeworkText.trim().isNotEmpty)
            TextButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: v.homeworkText));
                if (!context.mounted) return;
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Homework text copied'),
                    duration: Duration(milliseconds: 1200),
                  ),
                );
              },
              icon: const Icon(Icons.copy_rounded, size: 18),
              label: const Text('Copy text'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterBar(List<_HomeworkThreadView> all) {
    final allCount = all.length;
    final reviewedCount = all.where((v) => v.reviewed).length;
    final notReviewedCount = allCount - reviewedCount;

    Widget chip(String text, _HomeworkFilter value, int count) {
      return ChoiceChip(
        selected: _filter == value,
        label: Text('$text ($count)'),
        onSelected: (_) => setState(() => _filter = value),
      );
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        chip('All', _HomeworkFilter.all, allCount),
        chip('Not reviewed', _HomeworkFilter.notReviewed, notReviewedCount),
        chip('Reviewed', _HomeworkFilter.reviewed, reviewedCount),
      ],
    );
  }

  void _showDeletedSheet(List<_HomeworkThreadView> deleted) {
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) {
        if (deleted.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(20),
            child: Center(child: Text('No deleted homework threads.')),
          );
        }

        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 20),
          itemCount: deleted.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, i) {
            final v = deleted[i];
            return ListTile(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: Colors.black.withValues(alpha: 0.08)),
              ),
              title: Text(
                v.row.peerName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
              subtitle: Text(
                v.courseTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: TextButton.icon(
                onPressed: () async {
                  await _restoreForMe(v.row.threadId);
                  if (context.mounted) Navigator.pop(context);
                },
                icon: const Icon(Icons.restore_rounded, size: 18),
                label: const Text('Restore'),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _refreshInbox() async {
    _rowsSignature = '';
    _viewsFuture = null;
    if (mounted) setState(() {});
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Homework Inbox'),
        actions: [
          if (_viewsFuture != null)
            FutureBuilder<List<_HomeworkThreadView>>(
              future: _viewsFuture,
              builder: (context, s) {
                final all = s.data ?? const <_HomeworkThreadView>[];
                final deleted = all
                    .where((v) => v.row.deletedAtMs != null)
                    .toList();
                return IconButton(
                  tooltip: 'Deleted',
                  onPressed: () => _showDeletedSheet(deleted),
                  icon: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      const Icon(Icons.delete_outline_rounded),
                      if (deleted.isNotEmpty)
                        Positioned(
                          right: -6,
                          top: -4,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.red,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              deleted.length > 99 ? '99+' : '${deleted.length}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 9,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
        ],
      ),
      body: _indexStream == null
          ? const Center(child: Text('Please sign in again.'))
          : StreamBuilder<DatabaseEvent>(
              stream: _indexStream,
              builder: (context, snap) {
                if (snap.hasError) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        toHumanError(snap.error ?? Exception('Unknown error')),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.red.shade700,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  );
                }

                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }

                final rows = _rowsFromSnapshot(snap.data?.snapshot.value);
                final activeRows = rows
                    .where((r) => r.deletedAtMs == null)
                    .toList();
                if (activeRows.isEmpty) {
                  return RefreshIndicator(
                    onRefresh: _refreshInbox,
                    child: ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: const [
                        SizedBox(height: 180),
                        Center(child: Text('No homework threads yet.')),
                      ],
                    ),
                  );
                }

                return FutureBuilder<List<_HomeworkThreadView>>(
                  future: _ensureViews(rows),
                  builder: (context, viewsSnap) {
                    if (!viewsSnap.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }

                    final allViews =
                        viewsSnap.data ?? const <_HomeworkThreadView>[];
                    final activeViews = allViews
                        .where((v) => v.row.deletedAtMs == null)
                        .toList();
                    final views = _applyFilter(activeViews);

                    return RefreshIndicator(
                      onRefresh: _refreshInbox,
                      child: ListView.builder(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
                        itemCount: views.length + 1,
                        itemBuilder: (context, i) {
                          if (i == 0) {
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: _buildFilterBar(activeViews),
                            );
                          }

                          final v = views[i - 1];
                          return Dismissible(
                            key: ValueKey('hw_${v.row.threadId}'),
                            direction: DismissDirection.startToEnd,
                            confirmDismiss: (_) async {
                              if (v.reviewed) return false;
                              final ok =
                                  await showDialog<bool>(
                                    context: context,
                                    builder: (ctx) => AlertDialog(
                                      title: const Text('Mark as reviewed?'),
                                      content: const Text(
                                        'This will mark this homework thread as reviewed and remove it from "Not reviewed".',
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () =>
                                              Navigator.pop(ctx, false),
                                          child: const Text('Cancel'),
                                        ),
                                        FilledButton(
                                          onPressed: () =>
                                              Navigator.pop(ctx, true),
                                          child: const Text('Mark reviewed'),
                                        ),
                                      ],
                                    ),
                                  ) ??
                                  false;
                              if (!ok) return false;
                              await _markReviewed(v);
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Marked reviewed'),
                                    duration: Duration(milliseconds: 1200),
                                  ),
                                );
                              }
                              return false;
                            },
                            background: Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              alignment: Alignment.centerLeft,
                              decoration: BoxDecoration(
                                color: Colors.green.withValues(alpha: 0.18),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Row(
                                children: [
                                  Icon(
                                    Icons.check_circle_outline_rounded,
                                    color: Colors.green,
                                  ),
                                  SizedBox(width: 8),
                                  Text(
                                    'Mark reviewed',
                                    style: TextStyle(
                                      color: Colors.green,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            child: Card(
                              margin: const EdgeInsets.only(bottom: 8),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(12),
                                onLongPress: () => _deleteForMe(v),
                                onTap: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => TeacherMailThreadScreen(
                                        threadId: v.row.threadId,
                                        peerUid: v.row.peerUid,
                                        peerName: v.row.peerName,
                                        subject: v.row.subject,
                                      ),
                                    ),
                                  );
                                },
                                child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      CircleAvatar(
                                        radius: 18,
                                        backgroundColor: v.reviewed
                                            ? Colors.green.withValues(
                                                alpha: 0.14,
                                              )
                                            : Colors.orange.withValues(
                                                alpha: 0.14,
                                              ),
                                        child: Icon(
                                          Icons.assignment_rounded,
                                          color: v.reviewed
                                              ? Colors.green.shade700
                                              : Colors.orange.shade700,
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              v.row.peerName,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w900,
                                                fontSize: 14.5,
                                              ),
                                            ),
                                            const SizedBox(height: 3),
                                            Text(
                                              v.courseTitle,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontWeight: FontWeight.w800,
                                                color: Colors.black.withValues(
                                                  alpha: 0.67,
                                                ),
                                                fontSize: 12.2,
                                              ),
                                            ),
                                            if (v.classId.isNotEmpty) ...[
                                              const SizedBox(height: 3),
                                              Text(
                                                'Class: ${v.classId}',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontWeight: FontWeight.w700,
                                                  color: Colors.black
                                                      .withValues(alpha: 0.55),
                                                  fontSize: 11.2,
                                                ),
                                              ),
                                            ],
                                            const SizedBox(height: 6),
                                            Text(
                                              v.row.lastMessage.isEmpty
                                                  ? '-'
                                                  : v.row.lastMessage,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: Colors.black.withValues(
                                                  alpha: 0.62,
                                                ),
                                                fontSize: 12,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.end,
                                        children: [
                                          Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              if (v.unreadCount > 0)
                                                Container(
                                                  margin: const EdgeInsets.only(
                                                    right: 6,
                                                  ),
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 8,
                                                        vertical: 4,
                                                      ),
                                                  decoration: BoxDecoration(
                                                    color: Colors.red
                                                        .withValues(
                                                          alpha: 0.12,
                                                        ),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          999,
                                                        ),
                                                  ),
                                                  child: Text(
                                                    v.unreadCount.toString(),
                                                    style: const TextStyle(
                                                      color: Colors.red,
                                                      fontSize: 11,
                                                      fontWeight:
                                                          FontWeight.w900,
                                                    ),
                                                  ),
                                                ),
                                              IconButton(
                                                tooltip: 'Homework details',
                                                visualDensity:
                                                    VisualDensity.compact,
                                                onPressed: () =>
                                                    _showDetails(v),
                                                icon: Icon(
                                                  Icons.info_outline_rounded,
                                                  color: Colors.black
                                                      .withValues(alpha: 0.65),
                                                ),
                                              ),
                                            ],
                                          ),
                                          Text(
                                            _fmtTime(v.row.updatedAtMs),
                                            style: TextStyle(
                                              fontSize: 11,
                                              color: Colors.black.withValues(
                                                alpha: 0.58,
                                              ),
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 8,
                                              vertical: 4,
                                            ),
                                            decoration: BoxDecoration(
                                              color: v.reviewed
                                                  ? Colors.green.withValues(
                                                      alpha: 0.12,
                                                    )
                                                  : Colors.orange.withValues(
                                                      alpha: 0.12,
                                                    ),
                                              borderRadius:
                                                  BorderRadius.circular(999),
                                            ),
                                            child: Text(
                                              v.needsRedo
                                                  ? 'Redo'
                                                  : (v.reviewed
                                                        ? 'Reviewed'
                                                        : 'Not reviewed'),
                                              style: TextStyle(
                                                fontSize: 11,
                                                fontWeight: FontWeight.w900,
                                                color: v.needsRedo
                                                    ? Colors.orange.shade800
                                                    : (v.reviewed
                                                          ? Colors
                                                                .green
                                                                .shade800
                                                          : Colors
                                                                .orange
                                                                .shade800),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    );
                  },
                );
              },
            ),
    );
  }
}

class _HomeworkThreadRow {
  const _HomeworkThreadRow({
    required this.threadId,
    required this.peerUid,
    required this.peerName,
    required this.subject,
    required this.lastMessage,
    required this.updatedAtMs,
    required this.unreadCount,
    required this.deletedAtMs,
  });

  final String threadId;
  final String peerUid;
  final String peerName;
  final String subject;
  final String lastMessage;
  final int updatedAtMs;
  final int unreadCount;
  final int? deletedAtMs;
}

class _HomeworkThreadView {
  const _HomeworkThreadView({
    required this.row,
    required this.courseTitle,
    required this.courseKey,
    required this.sessionId,
    required this.classId,
    required this.homeworkRefPath,
    required this.homeworkText,
    required this.reviewed,
    required this.needsRedo,
    required this.reviewedAtMs,
    required this.reviewScore,
    required this.reviewGrade,
    required this.reviewStatus,
  });

  final _HomeworkThreadRow row;
  final String courseTitle;
  final String courseKey;
  final String sessionId;
  final String classId;
  final String homeworkRefPath;
  final String homeworkText;
  final bool reviewed;
  final bool needsRedo;
  final int reviewedAtMs;
  final int reviewScore;
  final String reviewGrade;
  final String reviewStatus;

  int get unreadCount => row.unreadCount;
}
