import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';

import '../shared/app_connectivity.dart';
import '../shared/human_error.dart';
import '../shared/learner_web_layout.dart';
import '../shared/learner_notice_popup.dart';
import '../shared/profile_avatar.dart';
import '../services/course_feedback_service.dart';

class RecordedLessonCommentsScreen extends StatefulWidget {
  const RecordedLessonCommentsScreen({
    super.key,
    required this.uid,
    required this.primaryCourseId,
    required this.fallbackCourseKey,
    required this.lessonId,
    required this.lessonTitle,
  });

  final String uid;
  final String primaryCourseId;
  final String fallbackCourseKey;
  final String lessonId;
  final String lessonTitle;

  @override
  State<RecordedLessonCommentsScreen> createState() =>
      _RecordedLessonCommentsScreenState();
}

class _RecordedLessonCommentsScreenState
    extends State<RecordedLessonCommentsScreen> {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  final TextEditingController _commentC = TextEditingController();
  final FocusNode _commentFocus = FocusNode();
  final ScrollController _scrollController = ScrollController();

  bool _busy = true;
  bool _posting = false;
  bool _loadingMore = false;
  bool _hasMore = false;
  String? _error;

  List<LessonCommentItem> _comments = const [];
  final Map<String, List<Map<String, dynamic>>> _repliesByComment = {};
  final Set<String> _expandedReplies = <String>{};
  final Set<String> _loadingReplies = <String>{};
  final Map<String, int> _replyCountByComment = {};
  int _replyCountRequestId = 0;
  final Map<String, int?> _nextBeforeByCourse = {};
  static const int _pageSize = 18;

  void _notice(String message, {LearnerNoticeTone? tone}) {
    if (!mounted) return;
    unawaited(
      showLearnerNoticePopup(
        context,
        message: message,
        tone: tone ?? learnerNoticeToneForMessage(message),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_handleScroll);
    _loadComments();
  }

  @override
  void dispose() {
    _commentC.dispose();
    _commentFocus.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  String _fmtDateTime(int ms) {
    if (ms <= 0) return '-';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  List<String> get _feedbackCourseIds {
    final ordered = <String>[];
    final seen = <String>{};
    final primary = widget.primaryCourseId.trim();
    if (primary.isNotEmpty && seen.add(primary)) ordered.add(primary);
    final secondary = widget.fallbackCourseKey.trim();
    if (secondary.isNotEmpty && seen.add(secondary)) ordered.add(secondary);
    return ordered;
  }

  void _handleScroll() {
    if (!_scrollController.hasClients || _busy || _loadingMore || !_hasMore) {
      return;
    }
    const threshold = 260.0;
    final remaining =
        _scrollController.position.maxScrollExtent -
        _scrollController.position.pixels;
    if (remaining <= threshold) {
      _loadMoreComments();
    }
  }

  Future<void> _loadComments({bool reset = true}) async {
    if (AppConnectivity.instance.isOffline) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _loadingMore = false;
        _hasMore = false;
        _error =
            'Comments need internet. Lesson notes are available offline in the video player.';
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _repliesByComment.clear();
      _expandedReplies.clear();
      _loadingReplies.clear();
      _replyCountByComment.clear();
      _replyCountRequestId += 1;
      if (reset) {
        _nextBeforeByCourse.clear();
      }
    });

    try {
      final results = await Future.wait(
        _feedbackCourseIds.map((courseId) async {
          try {
            final page = await CourseFeedbackService.listLessonCommentsPage(
              courseId,
              widget.lessonId,
              visibleOnly: true,
              limit: _pageSize,
              beforeCreatedAt: reset ? null : _nextBeforeByCourse[courseId],
            );
            return {'courseId': courseId, 'page': page, 'ok': true};
          } catch (e) {
            return {'courseId': courseId, 'error': e, 'ok': false};
          }
        }),
      );

      final mergedById = <String, LessonCommentItem>{};
      var okCount = 0;
      for (final result in results) {
        final courseId = (result['courseId'] ?? '').toString();
        final ok = result['ok'] == true;
        if (!ok) {
          if (courseId.isNotEmpty) {
            _nextBeforeByCourse[courseId] = null;
          }
          continue;
        }
        okCount += 1;
        final page = result['page'] as LessonCommentPage;
        _nextBeforeByCourse[courseId] = page.hasMore
            ? page.nextBeforeCreatedAt
            : null;
        for (final comment in page.items) {
          mergedById.putIfAbsent(comment.id, () => comment);
        }
      }

      if (okCount == 0) {
        throw Exception('Could not load comments from any source.');
      }

      final comments = mergedById.values.toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

      final hasMore = _feedbackCourseIds.any((courseId) {
        final cursor = _nextBeforeByCourse[courseId];
        return cursor != null && cursor > 0;
      });

      if (!mounted) return;
      setState(() {
        _comments = comments;
        _busy = false;
        _hasMore = hasMore;
      });
      _refreshReplyCountsForComments(comments);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = toHumanError(e);
        _busy = false;
      });
    }
  }

  Future<void> _loadMoreComments() async {
    if (_busy || _loadingMore || !_hasMore) return;

    setState(() {
      _loadingMore = true;
      _error = null;
    });

    try {
      final results = await Future.wait(
        _feedbackCourseIds.map((courseId) async {
          final cursor = _nextBeforeByCourse[courseId];
          if (cursor == null || cursor <= 0) {
            return {
              'courseId': courseId,
              'page': LessonCommentPage(
                items: const [],
                hasMore: false,
                nextBeforeCreatedAt: 0,
              ),
              'ok': true,
            };
          }
          try {
            final page = await CourseFeedbackService.listLessonCommentsPage(
              courseId,
              widget.lessonId,
              visibleOnly: true,
              limit: _pageSize,
              beforeCreatedAt: cursor,
            );
            return {'courseId': courseId, 'page': page, 'ok': true};
          } catch (e) {
            return {'courseId': courseId, 'error': e, 'ok': false};
          }
        }),
      );

      final mergedById = {for (final c in _comments) c.id: c};
      var okCount = 0;
      for (final result in results) {
        final courseId = (result['courseId'] ?? '').toString();
        final ok = result['ok'] == true;
        if (!ok) {
          if (courseId.isNotEmpty) {
            _nextBeforeByCourse[courseId] = null;
          }
          continue;
        }
        okCount += 1;
        final page = result['page'] as LessonCommentPage;
        _nextBeforeByCourse[courseId] = page.hasMore
            ? page.nextBeforeCreatedAt
            : null;
        for (final comment in page.items) {
          mergedById.putIfAbsent(comment.id, () => comment);
        }
      }

      if (okCount == 0) {
        throw Exception('Could not load comments from any source.');
      }

      final comments = mergedById.values.toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

      final hasMore = _feedbackCourseIds.any((courseId) {
        final cursor = _nextBeforeByCourse[courseId];
        return cursor != null && cursor > 0;
      });

      if (!mounted) return;
      setState(() {
        _comments = comments;
        _hasMore = hasMore;
        _loadingMore = false;
      });
      _refreshReplyCountsForComments(comments);
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
      _notice(toHumanError(e), tone: LearnerNoticeTone.error);
    }
  }

  Future<void> _ensureRepliesLoaded(LessonCommentItem item) async {
    if (_repliesByComment.containsKey(item.id) ||
        _loadingReplies.contains(item.id)) {
      return;
    }

    final sourceCourseId = item.courseId.trim().isEmpty
        ? widget.primaryCourseId
        : item.courseId.trim();

    setState(() {
      _loadingReplies.add(item.id);
    });

    try {
      final replies = await CourseFeedbackService.listLessonReplies(
        sourceCourseId,
        widget.lessonId,
        item.id,
      );

      if (!mounted) return;
      setState(() {
        _repliesByComment[item.id] = replies;
        _replyCountByComment[item.id] = replies.length;
        _loadingReplies.remove(item.id);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadingReplies.remove(item.id);
      });
      _notice('Could not load replies.', tone: LearnerNoticeTone.error);
    }
  }

  Future<void> _refreshReplyCountsForComments(
    List<LessonCommentItem> comments,
  ) async {
    final requestId = ++_replyCountRequestId;
    final targets = comments
        .where((item) => !_replyCountByComment.containsKey(item.id))
        .toList();
    if (targets.isEmpty) return;

    final counts = <String, int>{};
    await Future.wait(
      targets.map((item) async {
        final sourceCourseId = item.courseId.trim().isEmpty
            ? widget.primaryCourseId
            : item.courseId.trim();
        try {
          final snap = await _db
              .child(CourseFeedbackService.lessonRepliesNode)
              .child(sourceCourseId)
              .child(widget.lessonId)
              .child(item.id)
              .get();
          if (snap.exists && snap.value is Map) {
            final raw = Map<dynamic, dynamic>.from(snap.value as Map);
            counts[item.id] = raw.length;
          } else {
            counts[item.id] = 0;
          }
        } catch (_) {
          counts[item.id] = 0;
        }
      }),
    );

    if (!mounted || requestId != _replyCountRequestId) return;
    setState(() {
      _replyCountByComment.addAll(counts);
    });
  }

  Future<void> _postComment() async {
    if (AppConnectivity.instance.isOffline) {
      _notice(
        'Comments need internet. Use lesson notes while offline.',
        tone: LearnerNoticeTone.warning,
      );
      return;
    }
    final text = _commentC.text.trim();
    if (text.isEmpty) {
      _notice('Write a comment first.', tone: LearnerNoticeTone.warning);
      return;
    }
    if (text.length > 400) {
      _notice(
        'Comment is too long (max 400 chars).',
        tone: LearnerNoticeTone.warning,
      );
      return;
    }

    setState(() => _posting = true);
    try {
      await CourseFeedbackService.addLessonComment(
        courseId: widget.primaryCourseId,
        lessonId: widget.lessonId,
        uid: widget.uid,
        text: text,
        type: 'comment',
      );
      _commentC.clear();
      await _loadComments(reset: true);
      if (!mounted) return;
      _notice('Comment posted.', tone: LearnerNoticeTone.success);
      FocusScope.of(context).requestFocus(_commentFocus);
    } catch (e) {
      if (!mounted) return;
      _notice(humanizeUiMessage(e.toString()), tone: LearnerNoticeTone.error);
    } finally {
      if (mounted) {
        setState(() => _posting = false);
      }
    }
  }

  Future<void> _replyToComment(String commentId, String courseId) async {
    if (AppConnectivity.instance.isOffline) {
      _notice(
        'Replies need internet. Use lesson notes while offline.',
        tone: LearnerNoticeTone.warning,
      );
      return;
    }
    final controller = TextEditingController();
    final submit = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        final bottom = MediaQuery.of(ctx).viewInsets.bottom;
        return Padding(
          padding: EdgeInsets.only(bottom: bottom),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Reply to comment',
                    style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: controller,
                    maxLength: 400,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      hintText: 'Write your reply...',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('Cancel'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () => Navigator.pop(ctx, true),
                          icon: const Icon(Icons.send_rounded),
                          label: const Text('Reply'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );

    if (submit != true) return;
    final text = controller.text.trim();
    if (text.isEmpty) return;

    await CourseFeedbackService.addLessonReply(
      courseId: courseId,
      lessonId: widget.lessonId,
      commentId: commentId,
      uid: widget.uid,
      text: text,
    );
    await _loadComments(reset: true);
  }

  Future<void> _reportComment(String commentId, String courseId) async {
    if (AppConnectivity.instance.isOffline) {
      _notice(
        'Reporting comments needs internet.',
        tone: LearnerNoticeTone.warning,
      );
      return;
    }
    await CourseFeedbackService.reportLessonComment(
      courseId: courseId,
      lessonId: widget.lessonId,
      commentId: commentId,
      uid: widget.uid,
      reason: 'Reported by learner',
    );
    if (!mounted) return;
    _notice('Comment reported.', tone: LearnerNoticeTone.success);
  }

  Future<void> _editComment(LessonCommentItem item, String courseId) async {
    if (AppConnectivity.instance.isOffline) {
      _notice(
        'Editing comments needs internet.',
        tone: LearnerNoticeTone.warning,
      );
      return;
    }
    if (!mounted) return;
    final controller = TextEditingController(text: item.text.trim());
    final submit = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        final bottom = MediaQuery.of(ctx).viewInsets.bottom;
        return Padding(
          padding: EdgeInsets.only(bottom: bottom),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Edit comment',
                    style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: controller,
                    maxLength: 400,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      hintText: 'Update your comment...',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('Cancel'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () => Navigator.pop(ctx, true),
                          icon: const Icon(Icons.check_rounded),
                          label: const Text('Save'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );

    final text = controller.text.trim();
    controller.dispose();
    if (submit != true) return;
    if (!mounted) return;
    if (text.isEmpty) {
      _notice('Write a comment first.', tone: LearnerNoticeTone.warning);
      return;
    }

    try {
      await CourseFeedbackService.updateOwnLessonCommentText(
        courseId: courseId,
        lessonId: widget.lessonId,
        commentId: item.id,
        uid: widget.uid,
        text: text,
      );
      await _loadComments(reset: true);
      if (!mounted) return;
      _notice('Comment updated.', tone: LearnerNoticeTone.success);
    } catch (e) {
      if (!mounted) return;
      _notice(humanizeUiMessage(e.toString()), tone: LearnerNoticeTone.error);
    }
  }

  Future<void> _deleteOwnComment(
    LessonCommentItem item,
    String courseId,
  ) async {
    if (AppConnectivity.instance.isOffline) {
      _notice(
        'Deleting comments needs internet.',
        tone: LearnerNoticeTone.warning,
      );
      return;
    }
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete comment?'),
        content: const Text(
          'This will remove your comment from the discussion and delete all replies under it. Teachers/admins can still review the removed comment.',
        ),
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFB91C1C),
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    try {
      await CourseFeedbackService.removeOwnLessonCommentWithReplies(
        courseId: courseId,
        lessonId: widget.lessonId,
        commentId: item.id,
        uid: widget.uid,
      );
      await _loadComments(reset: true);
      if (!mounted) return;
      _notice('Comment deleted.', tone: LearnerNoticeTone.success);
    } catch (e) {
      if (!mounted) return;
      _notice(humanizeUiMessage(e.toString()), tone: LearnerNoticeTone.error);
    }
  }

  Widget _buildHeaderCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0B2545), Color(0xFF1D4ED8)],
        ),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Discussion',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            widget.lessonTitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _busy ? 'Loading comments...' : '${_comments.length} comments',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildComposer() {
    final offline = AppConnectivity.instance.isOffline;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE2E8F0)),
      ),
      child: Column(
        children: [
          TextField(
            controller: _commentC,
            focusNode: _commentFocus,
            enabled: !offline,
            maxLength: 400,
            minLines: 1,
            maxLines: 3,
            decoration: InputDecoration(
              counterText: '',
              hintText: offline
                  ? 'Comments need internet. Use lesson notes offline.'
                  : 'Write a comment...',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _posting || offline ? null : _postComment,
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF4F46E5),
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(48),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    textStyle: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                  icon: const Icon(Icons.send_rounded),
                  label: Text(
                    offline
                        ? 'Offline'
                        : _posting
                        ? 'Posting...'
                        : 'Post comment',
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildReplyChip(String label, VoidCallback onPressed, Color color) {
    return FilledButton.tonalIcon(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: color.withValues(alpha: 0.12),
        foregroundColor: color,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        minimumSize: const Size.fromHeight(48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
        textStyle: const TextStyle(fontWeight: FontWeight.w800),
      ),
      icon: const Icon(Icons.reply_rounded, size: 16),
      label: Text(label),
    );
  }

  Widget _buildCommentCard(LessonCommentItem item) {
    final courseId = item.courseId.trim().isEmpty
        ? widget.primaryCourseId
        : item.courseId;
    final isMine = item.uid.trim() == widget.uid.trim();
    final replies = _repliesByComment[item.id] ?? const [];
    final loadingReplies = _loadingReplies.contains(item.id);
    final expanded = _expandedReplies.contains(item.id);
    final replyCount = _replyCountByComment[item.id] ?? replies.length;
    final hasReplies = replyCount > 0 || replies.isNotEmpty;
    final visibleReplies = expanded ? replies : const <Map<String, dynamic>>[];

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE5E7EB)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ProfileAvatar(
                name: item.displayName,
                photoUrl: item.photoUrl,
                radius: 16,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            item.firstName.isEmpty ? 'Learner' : item.firstName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w900,
                              color: Color(0xFF0F172A),
                              fontSize: 13.5,
                            ),
                          ),
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              _fmtDateTime(item.createdAt),
                              style: const TextStyle(
                                color: Color(0xFF64748B),
                                fontSize: 10.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            if (item.updatedAt > item.createdAt)
                              const Text(
                                'edited',
                                style: TextStyle(
                                  color: Color(0xFF64748B),
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                          ],
                        ),
                        if (isMine)
                          PopupMenuButton<String>(
                            tooltip: 'Comment actions',
                            icon: const Icon(
                              Icons.more_horiz_rounded,
                              size: 18,
                            ),
                            onSelected: (choice) {
                              if (choice == 'edit') {
                                _editComment(item, courseId);
                              } else if (choice == 'delete') {
                                _deleteOwnComment(item, courseId);
                              }
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem(value: 'edit', child: Text('Edit')),
                              PopupMenuItem(
                                value: 'delete',
                                child: Text('Delete'),
                              ),
                            ],
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: const Color(0xFFE2E8F0)),
                      ),
                      child: Text(
                        item.text.trim(),
                        style: const TextStyle(
                          color: Color(0xFF334155),
                          fontWeight: FontWeight.w600,
                          height: 1.38,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _buildReplyChip(
                'Reply',
                () => _replyToComment(item.id, courseId),
                const Color(0xFF1D4ED8),
              ),
              if (!isMine)
                FilledButton.tonalIcon(
                  onPressed: () => _reportComment(item.id, courseId),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFFEE2E2),
                    foregroundColor: const Color(0xFFB91C1C),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    minimumSize: const Size.fromHeight(48),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(999),
                    ),
                    textStyle: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  icon: const Icon(Icons.flag_rounded, size: 16),
                  label: const Text('Report'),
                ),
              if (hasReplies)
                OutlinedButton.icon(
                  onPressed: () async {
                    if (expanded) {
                      setState(() => _expandedReplies.remove(item.id));
                      return;
                    }
                    await _ensureRepliesLoaded(item);
                    if (!mounted) return;
                    if ((_repliesByComment[item.id] ?? const []).isEmpty) {
                      return;
                    }
                    setState(() => _expandedReplies.add(item.id));
                  },
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Color(0xFFCBD5E1)),
                    foregroundColor: const Color(0xFF334155),
                    minimumSize: const Size.fromHeight(48),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(999),
                    ),
                    textStyle: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  icon: Icon(
                    expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 18,
                  ),
                  label: Text(
                    expanded
                        ? 'Hide replies ($replyCount)'
                        : 'Show replies ($replyCount)',
                  ),
                ),
            ],
          ),
          if (loadingReplies)
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else if (expanded && replies.isNotEmpty) ...[
            const SizedBox(height: 10),
            for (final reply in visibleReplies)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(top: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: const Color(0xFFE2E8F0)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ProfileAvatar(
                      name: (reply['displayName'] ?? 'User').toString(),
                      photoUrl: (reply['photoUrl'] ?? '').toString(),
                      radius: 11,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            (reply['firstName'] ?? 'User').toString(),
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 11.5,
                              color: Color(0xFF0F172A),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            (reply['text'] ?? '').toString(),
                            style: const TextStyle(
                              color: Color(0xFF334155),
                              fontWeight: FontWeight.w600,
                              height: 1.3,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _fmtDateTime(
                              CourseFeedbackService.asInt(reply['createdAt']),
                            ),
                            style: const TextStyle(
                              color: Color(0xFF64748B),
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F7FB),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0B2545),
        foregroundColor: Colors.white,
        title: const Text(
          'Comments',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loadComments,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: learnerWebBodyFrame(
        context: context,
        maxWidth: 900,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
            child: Column(
              children: [
                _buildHeaderCard(),
                const SizedBox(height: 8),
                _buildComposer(),
                const SizedBox(height: 8),
                Expanded(
                  child: _busy
                      ? const Center(child: CircularProgressIndicator())
                      : _error != null
                      ? Center(
                          child: Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: Color(0xFFB91C1C),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        )
                      : _comments.isEmpty
                      ? const Center(
                          child: Text(
                            'No comments yet.',
                            style: TextStyle(
                              color: Color(0xFF475569),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        )
                      : RefreshIndicator(
                          onRefresh: () => _loadComments(reset: true),
                          child: ListView.builder(
                            controller: _scrollController,
                            physics: const AlwaysScrollableScrollPhysics(),
                            itemCount:
                                _comments.length + (_loadingMore ? 1 : 0),
                            itemBuilder: (_, index) {
                              if (index >= _comments.length) {
                                return const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 18),
                                  child: Center(
                                    child: SizedBox(
                                      width: 22,
                                      height: 22,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                  ),
                                );
                              }
                              return _buildCommentCard(_comments[index]);
                            },
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
