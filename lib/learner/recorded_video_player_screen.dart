import 'dart:async';
import 'dart:io' show File;

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import '../services/recorded_offline_video_service.dart';
import '../services/recorded_progress_sync_service.dart';
import '../shared/app_connectivity.dart';
import '../shared/app_feedback.dart';
import '../shared/human_error.dart';
import '../shared/learner_web_layout.dart';
import '../shared/profile_avatar.dart';
import '../shared/ybs_busy_logo.dart';
import '../services/course_feedback_service.dart';
import 'recorded_lesson_comments_screen.dart';

class RecordedVideoPlayerScreen extends StatefulWidget {
  const RecordedVideoPlayerScreen({
    super.key,
    required this.uid,
    required this.courseKey,
    required this.courseId,
    required this.sessionId,
    required this.sessionTitle,
    required this.videoUrl,
    this.localVideoPath,
    this.flatSessions,
  });

  final String uid;
  final String courseKey;
  final String courseId;
  final String sessionId;
  final String sessionTitle;
  final String videoUrl;
  final String? localVideoPath;
  final List<Map<String, String>>? flatSessions;

  @override
  State<RecordedVideoPlayerScreen> createState() =>
      _RecordedVideoPlayerScreenState();
}

class _RecordedVideoPlayerScreenState extends State<RecordedVideoPlayerScreen>
    with WidgetsBindingObserver {
  static const String _usersNode = 'users';
  static const String _recordedProgressNode = 'recorded_progress';

  final FirebaseDatabase _db = FirebaseDatabase.instance;
  final RecordedProgressSyncService _progressSync =
      RecordedProgressSyncService.instance;

  VideoPlayerController? _controller;
  StreamSubscription<DatabaseEvent>? _progressSub;

  bool _busy = true;
  bool _saving = false;
  bool _initialized = false;
  bool _isPlaying = false;
  bool _isCompleted = false;
  bool _showControls = true;
  bool _isFullscreen = false;
  bool _commentsBusy = false;
  bool _notesExpanded = true;
  bool _commentsExpanded = true;

  String? _error;

  int _savedPositionMs = 0;
  int _savedDurationMs = 0;
  int _lastSavedPositionMs = 0;

  Timer? _saveDebounce;
  Timer? _hideControlsTimer;
  bool _isDisposing = false;
  bool _lastLandscape = false;
  double _playbackSpeed = 1.0;
  List<LessonCommentItem> _comments = const [];
  List<_LessonNoteItem> _lessonNotes = const [];

  void _debug(String message) {
    // no-op in production build
  }

  bool _looksLikeMissingAssetError(String raw) {
    final lower = raw.toLowerCase();
    return lower.contains('404') ||
        lower.contains('410') ||
        lower.contains('not found') ||
        lower.contains('err_file_not_found') ||
        lower.contains('file not found');
  }

  String _videoUnavailableMessage() {
    final sessionTitle = widget.sessionTitle.trim().isEmpty
        ? 'this session'
        : '"${widget.sessionTitle.trim()}"';
    return 'This video lesson is currently unavailable. '
        'Please contact Your Bridge School support and share your course title + session number. Session: $sessionTitle.';
  }

  DatabaseReference get _progressRef => _db
      .ref(_usersNode)
      .child(widget.uid)
      .child('courses')
      .child(widget.courseKey)
      .child(_recordedProgressNode)
      .child(widget.sessionId);

  DatabaseReference get _lessonNotesRef => _progressRef.child('lessonNotes');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _enableScreenRotations();
    _loadAndInit();
    _loadComments();
  }

  @override
  void dispose() {
    _isDisposing = true;
    WidgetsBinding.instance.removeObserver(this);
    _progressSub?.cancel();
    _saveDebounce?.cancel();
    _hideControlsTimer?.cancel();
    _persistProgressNow();
    _controller?.removeListener(_videoListener);
    _controller?.dispose();
    _exitFullscreen(restoreStateOnly: true);
    _restorePreferredOrientations();
    _restoreSystemUi();
    super.dispose();
  }

  Future<void> _enableScreenRotations() async {
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  Future<void> _restorePreferredOrientations() async {
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
    ]);
  }

  Future<void> _enterFullscreen() async {
    if (_isFullscreen) return;

    setState(() {
      _isFullscreen = true;
      _showControls = true;
    });

    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    _startHideControlsTimer();
  }

  Future<void> _restoreSystemUi() async {
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
  }

  Future<void> _exitFullscreen({bool restoreStateOnly = false}) async {
    if (!_isFullscreen && !restoreStateOnly) return;

    final canSetState = mounted && !_isDisposing && !restoreStateOnly;
    if (canSetState) {
      setState(() {
        _isFullscreen = false;
        _showControls = true;
      });
    } else {
      _isFullscreen = false;
      _showControls = true;
    }

    await _restoreSystemUi();
    await _enableScreenRotations();
  }

  Future<void> _toggleFullscreen() async {
    if (_isFullscreen) {
      await _exitFullscreen();
    } else {
      await _enterFullscreen();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _persistProgressNow();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    if (isLandscape == _lastLandscape) return;
    _lastLandscape = isLandscape;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _isDisposing) return;
      if (isLandscape) {
        _enterFullscreen();
      } else {
        _exitFullscreen();
      }
    });
  }

  Future<void> _loadAndInit() async {
    _debug('loadAndInit start sessionId=${widget.sessionId}');
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final map = await _progressSync.loadSessionProgress(
        progressRef: _progressRef,
        uid: widget.uid,
        courseKey: widget.courseKey,
        sessionId: widget.sessionId,
      );
      _savedPositionMs = _asInt(map['videoPositionMs']);
      _savedDurationMs = _asInt(map['videoDurationMs']);
      _lessonNotes = _parseLessonNotes(map['lessonNotes']);
      _isCompleted = _asBool(map['videoCompleted']);

      final uri = Uri.tryParse(widget.videoUrl.trim());
      if (uri == null) {
        throw Exception('Invalid video URL.');
      }
      _debug('video uri=$uri');

      final localPath = widget.localVideoPath?.trim() ?? '';
      final localFile = (!kIsWeb && localPath.isNotEmpty)
          ? File(localPath)
          : null;
      final hasLocal = localFile != null && await localFile.exists();
      final controller = hasLocal
          ? VideoPlayerController.file(localFile)
          : VideoPlayerController.networkUrl(uri);
      _controller = controller;

      final initTimer = Stopwatch()..start();
      _debug('video initialize start sessionId=${widget.sessionId}');
      await controller.initialize();
      _debug(
        'video initialize done sessionId=${widget.sessionId} elapsedMs=${initTimer.elapsedMilliseconds}',
      );
      controller.addListener(_videoListener);

      final durationMs = controller.value.duration.inMilliseconds;
      if (_savedPositionMs > 0 &&
          !_isCompleted &&
          durationMs > 0 &&
          _savedPositionMs < (durationMs - 1500)) {
        await controller.seekTo(Duration(milliseconds: _savedPositionMs));
      }

      await _writeInitialMetaIfNeeded();

      if (!mounted) return;
      setState(() {
        _initialized = true;
        _busy = false;
      });

      _listenForRemoteProgress();
      _startHideControlsTimer();
      _debug('loadAndInit success initialized=true');
    } catch (e) {
      _debug('loadAndInit error sessionId=${widget.sessionId} error=$e');
      final message = e.toString();
      if (!mounted) return;
      setState(() {
        _error = _looksLikeMissingAssetError(message)
            ? _videoUnavailableMessage()
            : toHumanError(e);
        _busy = false;
      });
    }
  }

  void _listenForRemoteProgress() {
    if (AppConnectivity.instance.isOffline) return;
    _progressSub?.cancel();
    _progressSub = _progressRef.onValue.listen((event) {
      final raw = event.snapshot.value;
      if (raw is! Map) return;

      final map = Map<String, dynamic>.from(raw);
      final remoteCompleted = _asBool(map['videoCompleted']);
      final remoteNotes = _parseLessonNotes(map['lessonNotes']);

      if (!mounted) return;
      setState(() {
        if (remoteNotes.isNotEmpty || _lessonNotes.isEmpty) {
          _lessonNotes = remoteNotes;
        }
        _isCompleted = _isCompleted || remoteCompleted;
      });
    });
  }

  Future<void> _writeInitialMetaIfNeeded() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    final durationMs = controller.value.duration.inMilliseconds;

    await _progressSync.updateProgress(
      progressRef: _progressRef,
      uid: widget.uid,
      courseKey: widget.courseKey,
      sessionId: widget.sessionId,
      patch: {
        'videoUrl': widget.videoUrl.trim(),
        'sessionTitle': widget.sessionTitle.trim(),
        'videoDurationMs': durationMs,
        'lastOpenedAt': ServerValue.timestamp,
        'updatedAt': ServerValue.timestamp,
      },
    );
  }

  static int _asInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  static bool _asBool(dynamic v) {
    if (v is bool) return v;
    final s = (v ?? '').toString().trim().toLowerCase();
    return s == 'true' || s == '1';
  }

  void _videoListener() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    final value = controller.value;
    if (value.hasError) {
      final raw = (value.errorDescription ?? '').trim();
      final pretty = _looksLikeMissingAssetError(raw)
          ? _videoUnavailableMessage()
          : (raw.isEmpty
                ? 'Video playback failed.'
                : 'Video playback failed: $raw');

      if (mounted && _error != pretty) {
        _debug('player error=$raw');
        setState(() {
          _error = pretty;
          _busy = false;
        });
      }
      return;
    }

    final positionMs = value.position.inMilliseconds;
    final durationMs = value.duration.inMilliseconds;

    final playing = value.isPlaying;
    if (_isPlaying != playing && mounted) {
      setState(() => _isPlaying = playing);
    }

    if (positionMs > 0) {
      _savedPositionMs = positionMs;
    }
    if (durationMs > 0) {
      _savedDurationMs = durationMs;
    }

    _scheduleProgressSave();

    if (!_isCompleted &&
        durationMs > 0 &&
        positionMs >= (durationMs - 800) &&
        !value.isBuffering) {
      _markVideoCompleted();
    }
  }

  void _scheduleProgressSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(seconds: 3), _persistProgressNow);
  }

  Future<void> _persistProgressNow() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    final currentMs = controller.value.position.inMilliseconds;
    final durationMs = controller.value.duration.inMilliseconds;

    if (currentMs == _lastSavedPositionMs &&
        durationMs == _savedDurationMs &&
        !_saving) {
      return;
    }

    _lastSavedPositionMs = currentMs;
    _savedDurationMs = durationMs;

    try {
      _saving = true;
      await _progressSync.updateProgress(
        progressRef: _progressRef,
        uid: widget.uid,
        courseKey: widget.courseKey,
        sessionId: widget.sessionId,
        patch: {
          'videoPositionMs': currentMs,
          'videoDurationMs': durationMs,
          'lastOpenedAt': ServerValue.timestamp,
          'updatedAt': ServerValue.timestamp,
        },
      );
    } catch (_) {
    } finally {
      _saving = false;
    }
  }

  Future<void> _markVideoCompleted() async {
    if (_isCompleted) return;

    final map = await _progressSync.loadSessionProgress(
      progressRef: _progressRef,
      uid: widget.uid,
      courseKey: widget.courseKey,
      sessionId: widget.sessionId,
    );
    final materialsCompleted = _asBool(map['materialsCompleted']);
    final durationMs = _controller?.value.duration.inMilliseconds ?? 0;

    await _progressSync.updateProgress(
      progressRef: _progressRef,
      uid: widget.uid,
      courseKey: widget.courseKey,
      sessionId: widget.sessionId,
      patch: {
        'videoCompleted': true,
        'videoCompletedAt': ServerValue.timestamp,
        'videoPositionMs': durationMs,
        'videoDurationMs': durationMs,
        'completed': materialsCompleted,
        'lastOpenedAt': ServerValue.timestamp,
        'updatedAt': ServerValue.timestamp,
      },
    );

    if (!mounted) return;
    setState(() {
      _isCompleted = true;
      _savedPositionMs = durationMs;
      _savedDurationMs = durationMs;
    });

    AppToast.show(
      context,
      'Video completed. This session video is now marked done.',
      type: AppToastType.success,
    );
  }

  Future<void> _togglePlayPause() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    if (controller.value.isPlaying) {
      await controller.pause();
    } else {
      await controller.play();
      _startHideControlsTimer();
    }
  }

  Future<void> _seekRelative(int seconds) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    final current = controller.value.position;
    final target = current + Duration(seconds: seconds);
    final duration = controller.value.duration;

    Duration clamped = target;
    if (clamped < Duration.zero) clamped = Duration.zero;
    if (clamped > duration) clamped = duration;

    await controller.seekTo(clamped);
    _scheduleProgressSave();
    _showControlsTemporarily();
  }

  Future<void> _seekToRatio(double ratio) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    final durationMs = controller.value.duration.inMilliseconds;
    if (durationMs <= 0) return;

    final targetMs = (durationMs * ratio).round();
    await controller.seekTo(Duration(milliseconds: targetMs));
    _scheduleProgressSave();
    _showControlsTemporarily();
  }

  Future<void> _navigateToSession({
    required String sessionId,
    required String sessionTitle,
    required String videoUrl,
  }) async {
    final localPath = await _getLocalPath(sessionId, videoUrl);
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => RecordedVideoPlayerScreen(
          uid: widget.uid,
          courseKey: widget.courseKey,
          courseId: widget.courseId,
          sessionId: sessionId,
          sessionTitle: sessionTitle,
          videoUrl: videoUrl,
          localVideoPath: localPath,
          flatSessions: widget.flatSessions,
        ),
      ),
    );
  }

  Map<String, String>? _sessionAtOffset(int offset) {
    final list = widget.flatSessions;
    if (list == null) return null;
    final index = list.indexWhere((m) => m['id'] == widget.sessionId);
    if (index < 0) return null;
    final target = index + offset;
    if (target < 0 || target >= list.length) return null;
    return list[target];
  }

  Future<String?> _getLocalPath(String sessionId, String videoUrl) async {
    final localPath = await RecordedOfflineVideoService.instance.localPathFor(
      uid: widget.uid,
      courseKey: widget.courseKey,
      sessionId: sessionId,
      videoUrl: videoUrl,
    );
    return localPath;
  }

  void _showSpeedMenu() {
    const speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
    showModalBottomSheet<double>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: Text(
                    'Playback Speed',
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 17,
                    ),
                  ),
                ),
                for (final speed in speeds)
                  ListTile(
                    leading: Icon(
                      speed == _playbackSpeed
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      color: speed == _playbackSpeed
                          ? const Color(0xFF4F46E5)
                          : null,
                    ),
                    title: Text(
                      '${speed}x',
                      style: TextStyle(
                        fontWeight: speed == _playbackSpeed
                            ? FontWeight.w900
                            : FontWeight.w600,
                        color: speed == _playbackSpeed
                            ? const Color(0xFF4F46E5)
                            : null,
                      ),
                    ),
                    onTap: () => Navigator.pop(ctx, speed),
                  ),
              ],
            ),
          ),
        );
      },
    ).then((speed) {
      if (speed == null || !mounted) return;
      final controller = _controller;
      if (controller == null || !controller.value.isInitialized) return;
      controller.setPlaybackSpeed(speed);
      setState(() => _playbackSpeed = speed);
      AppToast.show(
        context,
        'Speed: ${speed}x',
        type: AppToastType.info,
      );
    });
  }

  int _currentVideoPositionMs() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return _savedPositionMs;
    }
    return controller.value.position.inMilliseconds;
  }

  List<_LessonNoteItem> _parseLessonNotes(dynamic raw) {
    if (raw is! Map) return <_LessonNoteItem>[];

    final items = <_LessonNoteItem>[];
    for (final entry in Map<dynamic, dynamic>.from(raw).entries) {
      final value = entry.value;
      if (value is! Map) continue;
      final note = _LessonNoteItem.fromMap(
        entry.key.toString(),
        Map<String, dynamic>.from(value),
      );
      if (note.deleted) continue;
      items.add(note);
    }

    items.sort((a, b) {
      final cmp = a.positionMs.compareTo(b.positionMs);
      if (cmp != 0) return cmp;
      return a.createdAt.compareTo(b.createdAt);
    });
    return items;
  }

  Future<void> _openNoteEditor({_LessonNoteItem? note}) async {
    final controller = TextEditingController(text: note?.text ?? '');
    final positionMs = note?.positionMs ?? _currentVideoPositionMs();
    final isEditing = note != null;

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
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
                  Text(
                    isEditing ? 'Edit note' : 'Add note',
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 18,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEFF6FF),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFFBFDBFE)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.access_time_rounded,
                          size: 16,
                          color: Color(0xFF2563EB),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _formatDurationMs(positionMs),
                          style: const TextStyle(
                            color: Color(0xFF1D4ED8),
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: controller,
                    minLines: 4,
                    maxLines: 8,
                    maxLength: 500,
                    decoration: const InputDecoration(
                      hintText: 'Write your note...',
                      border: OutlineInputBorder(),
                      filled: true,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(46),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          child: const Text('Cancel'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () => Navigator.pop(ctx, true),
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF4F46E5),
                            foregroundColor: Colors.white,
                            minimumSize: const Size.fromHeight(46),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                            textStyle: const TextStyle(
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          icon: const Icon(Icons.save_rounded),
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

    if (saved != true) return;

    final text = controller.text.trim();
    if (text.isEmpty) {
      AppToast.show(
        // ignore: use_build_context_synchronously
        context,
        'Write a note before saving.',
        type: AppToastType.error,
      );
      return;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final existingNote = note;
    final ref = existingNote == null
        ? _lessonNotesRef.push()
        : _lessonNotesRef.child(existingNote.id);

    final noteData = {
      'positionMs': positionMs,
      'text': text,
      'createdAt': existingNote?.createdAt ?? now,
      'updatedAt': now,
      'deleted': false,
    };

    final savedId = await _progressSync.saveNote(
      progressRef: _progressRef,
      uid: widget.uid,
      courseKey: widget.courseKey,
      sessionId: widget.sessionId,
      noteId: existingNote?.id ?? ref.key,
      note: noteData,
    );

    final updatedNote = _LessonNoteItem.fromMap(savedId, noteData);
    if (mounted) {
      setState(() {
        final next = _lessonNotes.where((n) => n.id != savedId).toList();
        next.add(updatedNote);
        next.sort((a, b) {
          final cmp = a.positionMs.compareTo(b.positionMs);
          if (cmp != 0) return cmp;
          return a.createdAt.compareTo(b.createdAt);
        });
        _lessonNotes = next;
      });
    }

    if (!mounted) return;
    // ignore: use_build_context_synchronously
    AppToast.show(
      context,
      isEditing
          ? 'Note updated.'
          : 'Note saved at ${_formatDurationMs(positionMs)}.',
      type: AppToastType.success,
    );
  }

  Future<void> _deleteLessonNote(_LessonNoteItem note) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete note?'),
        content: const Text(
          'This note will be removed from your lesson notes.',
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
    );

    if (confirmed != true) return;
    await _progressSync.deleteNote(
      progressRef: _progressRef,
      uid: widget.uid,
      courseKey: widget.courseKey,
      sessionId: widget.sessionId,
      noteId: note.id,
    );
    if (!mounted) return;
    setState(() {
      _lessonNotes = _lessonNotes.where((item) => item.id != note.id).toList();
    });
    AppToast.show(context, 'Note deleted.');
  }

  Future<void> _seekToNote(_LessonNoteItem note) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    await controller.seekTo(Duration(milliseconds: note.positionMs));
    _scheduleProgressSave();
    _showControlsTemporarily();
    if (!mounted) return;
    AppToast.show(
      context,
      'Jumped to ${_formatDurationMs(note.positionMs)}.',
      type: AppToastType.info,
    );
  }

  void _startHideControlsTimer() {
    _hideControlsTimer?.cancel();
    if (kIsWeb) return;
    if (!_isPlaying) return;

    _hideControlsTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted) return;
      setState(() => _showControls = false);
    });
  }

  void _showControlsTemporarily() {
    if (!mounted) return;
    setState(() => _showControls = true);
    _startHideControlsTimer();
  }

  String _formatDurationMs(int ms) {
    final d = Duration(milliseconds: ms.clamp(0, 1 << 31));
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60);
    final seconds = d.inSeconds.remainder(60);

    String two(int n) => n.toString().padLeft(2, '0');

    if (hours > 0) {
      return '${two(hours)}:${two(minutes)}:${two(seconds)}';
    }
    return '${two(minutes)}:${two(seconds)}';
  }

  Widget _buildCompactStatusCard() {
    final controller = _controller;
    final positionMs = controller?.value.isInitialized == true
        ? controller!.value.position.inMilliseconds
        : _savedPositionMs;
    final durationMs = controller?.value.isInitialized == true
        ? controller!.value.duration.inMilliseconds
        : _savedDurationMs;

    final ratio = durationMs <= 0 ? 0.0 : positionMs / durationMs;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _isCompleted
                      ? 'Completed'
                      : '${_formatDurationMs(positionMs)} / ${_formatDurationMs(durationMs)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: _isCompleted
                        ? const Color(0xFF1E8E3E)
                        : const Color(0xFF1A2B48),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: ratio.clamp(0.0, 1.0),
              minHeight: 6,
              backgroundColor: const Color(0xFFEAECEF),
              valueColor: const AlwaysStoppedAnimation<Color>(
                Color(0xFF7C3AED),
              ),
            ),
          ),
          const SizedBox(height: 2),
        ],
      ),
    );
  }

  Widget _buildCompactActionPanel({required bool isLandscape}) {
    final accent = const Color(0xFF0EA5E9);
    final title = 'Lesson Notes';

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [accent.withValues(alpha: 0.08), const Color(0xFFF8FAFC)],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: accent.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.note_alt_rounded, color: accent, size: 16),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 13.5,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                    Text(
                      '${_lessonNotes.length} saved notes',
                      style: const TextStyle(
                        color: Color(0xFF475569),
                        fontWeight: FontWeight.w700,
                        fontSize: 10.5,
                      ),
                    ),
                  ],
                ),
              ),
              TextButton.icon(
                onPressed: () =>
                    setState(() => _notesExpanded = !_notesExpanded),
                icon: Icon(
                  size: 18,
                  _notesExpanded
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                ),
                label: Text(_notesExpanded ? 'Collapse' : 'Expand'),
                style: TextButton.styleFrom(
                  foregroundColor: accent,
                  minimumSize: const Size(0, 34),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  textStyle: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 12.5,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: () => _openNoteEditor(),
                style: FilledButton.styleFrom(
                  backgroundColor: accent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  minimumSize: const Size(0, 34),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  textStyle: const TextStyle(fontWeight: FontWeight.w800),
                ),
                icon: const Icon(Icons.add_rounded, size: 16),
                label: const Text('Add note'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 220),
            crossFadeState: _notesExpanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            firstCurve: Curves.easeOut,
            secondCurve: Curves.easeOut,
            sizeCurve: Curves.easeOut,
            firstChild: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: accent.withValues(alpha: 0.16)),
              ),
              child: Text(
                _lessonNotes.isEmpty
                    ? 'No notes yet. Tap Add note while watching.'
                    : 'Tap Expand to view ${_lessonNotes.length} notes.',
                style: const TextStyle(
                  color: Color(0xFF475569),
                  fontWeight: FontWeight.w700,
                  height: 1.35,
                ),
              ),
            ),
            secondChild: _lessonNotes.isEmpty
                ? Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: accent.withValues(alpha: 0.16)),
                    ),
                    child: const Text(
                      'No notes yet. Tap Add note while watching to capture a moment.',
                      style: TextStyle(
                        color: Color(0xFF475569),
                        fontWeight: FontWeight.w700,
                        height: 1.35,
                      ),
                    ),
                  )
                : ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: isLandscape ? 220 : 260,
                    ),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: _lessonNotes.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (_, index) =>
                          _buildLessonNoteTile(_lessonNotes[index]),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildLessonNoteTile(_LessonNoteItem note) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: () => _seekToNote(note),
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFE2E8F0)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEFF6FF),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      _formatDurationMs(note.positionMs),
                      style: const TextStyle(
                        color: Color(0xFF1D4ED8),
                        fontWeight: FontWeight.w900,
                        fontSize: 10.5,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      note.text,
                      softWrap: true,
                      maxLines: null,
                      style: const TextStyle(
                        color: Color(0xFF0F172A),
                        fontWeight: FontWeight.w600,
                        height: 1.3,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  _noteActionIcon(
                    icon: Icons.edit_rounded,
                    tooltip: 'Edit note',
                    onPressed: () => _openNoteEditor(note: note),
                  ),
                  const SizedBox(width: 6),
                  _noteActionIcon(
                    icon: Icons.delete_outline_rounded,
                    tooltip: 'Delete note',
                    onPressed: () => _deleteLessonNote(note),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _noteActionIcon({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: const Color(0xFFF8FAFC),
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(999),
          child: Padding(
            padding: const EdgeInsets.all(7),
            child: Icon(icon, size: 16, color: const Color(0xFF334155)),
          ),
        ),
      ),
    );
  }

  Widget _buildVideoArea({required bool isLandscape}) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const Center(
        child: BrandedInlineLoader(message: 'Loading video...'),
      );
    }

    final value = controller.value;
    final positionMs = value.position.inMilliseconds;
    final durationMs = value.duration.inMilliseconds;
    final ratio = durationMs <= 0 ? 0.0 : positionMs / durationMs;

    final borderRadius = _isFullscreen
        ? BorderRadius.zero
        : BorderRadius.circular(isLandscape ? 16 : 20);

    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent) {
          final key = event.logicalKey;
          if (key == LogicalKeyboardKey.space) {
            _togglePlayPause();
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.arrowLeft) {
            _seekRelative(-5);
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.arrowRight) {
            _seekRelative(5);
            return KeyEventResult.handled;
          }
          if (key == LogicalKeyboardKey.keyF) {
            _toggleFullscreen();
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
      onTap: _showControlsTemporarily,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: borderRadius,
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (_isFullscreen)
              Positioned.fill(
                child: FittedBox(
                  fit: BoxFit.contain,
                  child: SizedBox(
                    width: controller.value.size.width,
                    height: controller.value.size.height,
                    child: VideoPlayer(controller),
                  ),
                ),
              )
            else
              AspectRatio(
                aspectRatio: value.aspectRatio <= 0
                    ? 16 / 9
                    : value.aspectRatio,
                child: VideoPlayer(controller),
              ),
            if (_showControls)
              Positioned.fill(
                child: Container(
                  color: Colors.black.withValues(alpha: 0.24),
                  child: Column(
                    children: [
                      SafeArea(
                        bottom: false,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                          child: Row(
                            children: [
                              if (_sessionAtOffset(-1) case final prev?)
                                IconButton(
                                  onPressed: () => _navigateToSession(
                                    sessionId: prev['id']!,
                                    sessionTitle:
                                        prev['title'] ?? '',
                                    videoUrl: prev['videoUrl']!,
                                  ),
                                  color: Colors.white,
                                  iconSize: kIsWeb ? 30 : 24,
                                  icon: const Icon(
                                    Icons.skip_previous_rounded,
                                  ),
                                  tooltip: 'Previous session',
                                ),
                              const Spacer(),
                              IconButton(
                                onPressed: _showSpeedMenu,
                                color: Colors.white,
                                iconSize: kIsWeb ? 30 : 24,
                                icon: Text(
                                  '${_playbackSpeed}x',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w900,
                                    fontSize: 13,
                                    color: Colors.white,
                                  ),
                                ),
                                tooltip: 'Playback speed',
                              ),
                              const SizedBox(width: 4),
                              IconButton(
                                onPressed: _toggleFullscreen,
                                color: Colors.white,
                                iconSize: kIsWeb ? 30 : 24,
                                icon: Icon(
                                  _isFullscreen
                                      ? Icons.fullscreen_exit_rounded
                                      : Icons.fullscreen_rounded,
                                ),
                              ),
                              if (_sessionAtOffset(1) case final next?)
                                IconButton(
                                  onPressed: () => _navigateToSession(
                                    sessionId: next['id']!,
                                    sessionTitle:
                                        next['title'] ?? '',
                                    videoUrl: next['videoUrl']!,
                                  ),
                                  color: Colors.white,
                                  iconSize: kIsWeb ? 30 : 24,
                                  icon: const Icon(
                                    Icons.skip_next_rounded,
                                  ),
                                  tooltip: 'Next session',
                                ),
                            ],
                          ),
                        ),
                      ),
                      const Spacer(),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            onPressed: () => _seekRelative(-10),
                            iconSize: isLandscape
                                ? (kIsWeb ? 36 : 30)
                                : (kIsWeb ? 40 : 34),
                            color: Colors.white,
                            icon: const Icon(Icons.replay_10_rounded),
                            tooltip: 'Rewind 10s',
                          ),
                          const SizedBox(width: kIsWeb ? 12 : 8),
                          Container(
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.16),
                              shape: BoxShape.circle,
                            ),
                            child: IconButton(
                              onPressed: _togglePlayPause,
                              iconSize: isLandscape
                                  ? (kIsWeb ? 48 : 40)
                                  : (kIsWeb ? 52 : 44),
                              color: Colors.white,
                              icon: Icon(
                                _isPlaying
                                    ? Icons.pause_circle_filled_rounded
                                    : Icons.play_circle_fill_rounded,
                              ),
                              tooltip:
                                  _isPlaying ? 'Pause' : 'Play',
                            ),
                          ),
                          const SizedBox(width: kIsWeb ? 12 : 8),
                          IconButton(
                            onPressed: () => _seekRelative(10),
                            iconSize: isLandscape
                                ? (kIsWeb ? 36 : 30)
                                : (kIsWeb ? 40 : 34),
                            color: Colors.white,
                            icon: const Icon(Icons.forward_10_rounded),
                            tooltip: 'Forward 10s',
                          ),
                        ],
                      ),
                      const Spacer(),
                      SafeArea(
                        top: false,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                          child: Column(
                            children: [
                              SliderTheme(
                                data: SliderTheme.of(context).copyWith(
                                  thumbShape: const RoundSliderThumbShape(
                                    enabledThumbRadius: 6,
                                  ),
                                  overlayShape: const RoundSliderOverlayShape(
                                    overlayRadius: 12,
                                  ),
                                  trackHeight: 3,
                                ),
                                child: Slider(
                                  value: ratio.clamp(0.0, 1.0),
                                  onChanged: (v) => _seekToRatio(v),
                                ),
                              ),
                              Row(
                                children: [
                                  Text(
                                    _formatDurationMs(positionMs),
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const Spacer(),
                                  Text(
                                    _formatDurationMs(durationMs),
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (value.isBuffering)
              const Positioned(
                child: YbsBusyLogo(size: 36, color: Colors.white),
              ),
          ],
        ),
      ),
      ),
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFF5B5B5)),
          ),
          child: Text(
            _error ?? 'Could not open video.',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Color(0xFFC62828),
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(String title, bool isLandscape) {
    return AppBar(
      toolbarHeight: isLandscape ? 52 : kToolbarHeight,
      backgroundColor: const Color(0xFFFF8C00),
      foregroundColor: Colors.white,
      iconTheme: const IconThemeData(color: Colors.white),
      titleSpacing: 10,
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: isLandscape ? 15 : 17,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
      actions: [
        IconButton(
          tooltip: 'Comments',
          onPressed: _busy ? null : _openCommentsScreen,
          icon: const Icon(Icons.forum_rounded),
        ),
        if (_isCompleted)
          const Padding(
            padding: EdgeInsets.only(right: 12),
            child: Center(
              child: Text(
                'DONE',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  color: Colors.white,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildPortraitLayout() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
      children: [
        _buildCompactStatusCard(),
        const SizedBox(height: 10),
        _buildVideoArea(isLandscape: false),
        const SizedBox(height: 10),
        _buildCompactActionPanel(isLandscape: false),
        const SizedBox(height: 10),
        _buildCommentsPreviewSection(),
      ],
    );
  }

  void _openCommentsScreen() {
    if (AppConnectivity.instance.isOffline) {
      AppToast.show(
        context,
        'Comments need internet. Your lesson notes still work offline.',
        type: AppToastType.info,
      );
      return;
    }
    final lessonTitle = widget.sessionTitle.trim().isEmpty
        ? 'Comments'
        : widget.sessionTitle.trim();

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => RecordedLessonCommentsScreen(
          uid: widget.uid,
          primaryCourseId: _primaryFeedbackCourseId,
          fallbackCourseKey: widget.courseKey,
          lessonId: widget.sessionId,
          lessonTitle: lessonTitle,
        ),
      ),
    ).then((_) {
      if (mounted) {
        _loadComments();
      }
    });
  }

  Widget _buildCommentsPreviewSection() {
    final visible = _comments.take(2).toList();
    final accent = const Color(0xFFF97316);
    final commentsOffline = AppConnectivity.instance.isOffline;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [accent.withValues(alpha: 0.08), const Color(0xFFF8FAFC)],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: accent.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.forum_rounded, color: accent, size: 16),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Comments',
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 13.5,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                    Text(
                      commentsOffline
                          ? 'Online discussion unavailable offline'
                          : _commentsBusy
                          ? 'Loading discussion...'
                          : '${_comments.length} comments',
                      style: const TextStyle(
                        color: Color(0xFF475569),
                        fontWeight: FontWeight.w700,
                        fontSize: 10.5,
                      ),
                    ),
                  ],
                ),
              ),
              TextButton.icon(
                onPressed: () =>
                    setState(() => _commentsExpanded = !_commentsExpanded),
                icon: Icon(
                  size: 18,
                  _commentsExpanded
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                ),
                label: Text(_commentsExpanded ? 'Collapse' : 'Expand'),
                style: TextButton.styleFrom(
                  foregroundColor: accent,
                  minimumSize: const Size(0, 34),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  textStyle: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 12.5,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: commentsOffline ? null : _openCommentsScreen,
                style: FilledButton.styleFrom(
                  backgroundColor: accent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  minimumSize: const Size(0, 34),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  textStyle: const TextStyle(fontWeight: FontWeight.w800),
                ),
                icon: const Icon(Icons.open_in_full_rounded, size: 16),
                label: const Text('Open'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 220),
            crossFadeState: _commentsExpanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            firstCurve: Curves.easeOut,
            secondCurve: Curves.easeOut,
            sizeCurve: Curves.easeOut,
            firstChild: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: accent.withValues(alpha: 0.16)),
              ),
              child: Text(
                _commentsBusy
                    ? 'Loading discussion...'
                    : commentsOffline
                    ? 'Comments need internet. Use Lesson Notes above while offline.'
                    : _comments.isEmpty
                    ? 'No comments yet. Open discussion to start the conversation.'
                    : 'Tap Expand to preview ${_comments.length} comments.',
                style: const TextStyle(
                  color: Color(0xFF475569),
                  fontWeight: FontWeight.w700,
                  height: 1.35,
                ),
              ),
            ),
            secondChild: _commentsBusy
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 18),
                    child: Center(
                      child: SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.2),
                      ),
                    ),
                  )
                : commentsOffline
                ? Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: accent.withValues(alpha: 0.16)),
                    ),
                    child: const Text(
                      'Comments are online-only. Lesson notes are saved offline and sync later.',
                      style: TextStyle(
                        color: Color(0xFF475569),
                        fontWeight: FontWeight.w700,
                        height: 1.35,
                      ),
                    ),
                  )
                : _comments.isEmpty
                ? Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: accent.withValues(alpha: 0.16)),
                    ),
                    child: const Text(
                      'No comments yet. Open discussion to start the conversation.',
                      style: TextStyle(
                        color: Color(0xFF475569),
                        fontWeight: FontWeight.w700,
                        height: 1.35,
                      ),
                    ),
                  )
                : Column(
                    children: [
                      for (final item in visible) ...[
                        _buildPreviewCommentCard(item),
                        const SizedBox(height: 8),
                      ],
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: _openCommentsScreen,
                          icon: const Icon(
                            Icons.arrow_forward_rounded,
                            size: 18,
                          ),
                          label: const Text('View full discussion'),
                          style: TextButton.styleFrom(
                            foregroundColor: accent,
                            textStyle: const TextStyle(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewCommentCard(LessonCommentItem item) {
    final comment = item.text.trim();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ProfileAvatar(
            name: item.displayName,
            photoUrl: item.photoUrl,
            radius: 14,
          ),
          const SizedBox(width: 8),
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
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF0F172A),
                          fontSize: 12.5,
                        ),
                      ),
                    ),
                    Text(
                      _fmtDateTime(item.createdAt),
                      style: const TextStyle(
                        color: Color(0xFF64748B),
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  comment,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF334155),
                    fontWeight: FontWeight.w600,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Spacer(),
                    TextButton(
                      onPressed: _openCommentsScreen,
                      style: TextButton.styleFrom(
                        foregroundColor: const Color(0xFF4F46E5),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        minimumSize: const Size(0, 34),
                        textStyle: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      child: const Text('Reply in comments'),
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

  Widget _buildFullscreenLayout() {
    final orientation = MediaQuery.of(context).orientation;
    final isLandscape = orientation == Orientation.landscape;

    return Container(
      color: Colors.black,
      width: double.infinity,
      height: double.infinity,
      child: SafeArea(
        top: false,
        bottom: false,
        left: false,
        right: false,
        child: _buildVideoArea(isLandscape: isLandscape),
      ),
    );
  }

  String get _primaryFeedbackCourseId {
    final id = widget.courseId.trim();
    if (id.isNotEmpty) return id;
    return widget.courseKey.trim();
  }

  List<String> get _feedbackCourseIds {
    final ordered = <String>[];
    final seen = <String>{};
    final primary = _primaryFeedbackCourseId;
    if (primary.isNotEmpty && seen.add(primary)) ordered.add(primary);
    final secondary = widget.courseKey.trim();
    if (secondary.isNotEmpty && seen.add(secondary)) ordered.add(secondary);
    return ordered;
  }

  Future<void> _loadComments() async {
    if (AppConnectivity.instance.isOffline) return;
    setState(() => _commentsBusy = true);
    try {
      final mergedById = <String, LessonCommentItem>{};
      var okCount = 0;
      for (final courseId in _feedbackCourseIds) {
        try {
          final page = await CourseFeedbackService.listLessonCommentsPage(
            courseId,
            widget.sessionId,
            visibleOnly: true,
            limit: 2,
          );
          okCount += 1;
          for (final comment in page.items) {
            mergedById.putIfAbsent(comment.id, () => comment);
          }
        } catch (_) {
          continue;
        }
      }

      if (okCount == 0) {
        throw Exception('Could not load comments from any source.');
      }

      final comments = mergedById.values.toList();
      comments.sort((a, b) => b.createdAt.compareTo(a.createdAt));

      if (!mounted) return;
      setState(() {
        _comments = comments;
        _commentsBusy = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _commentsBusy = false);
      AppToast.show(
        context,
        'Could not load comments right now.',
        type: AppToastType.error,
      );
    }
  }

  String _fmtDateTime(int ms) {
    if (ms <= 0) return '-';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.sessionTitle.trim().isEmpty
        ? 'Session Video'
        : widget.sessionTitle.trim();

    final orientation = MediaQuery.of(context).orientation;
    final isLandscape = orientation == Orientation.landscape;

    return PopScope(
      canPop: !_isFullscreen,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (_isFullscreen) {
          await _exitFullscreen();
        }
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: _isFullscreen
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.light.copyWith(
                statusBarColor: Colors.transparent,
              ),
        child: Scaffold(
          backgroundColor: _isFullscreen
              ? Colors.black
              : const Color(0xFFF4F7F9),
          appBar: (_isFullscreen || isLandscape)
              ? null
              : _buildAppBar(title, isLandscape),
          body: learnerWebBodyFrame(
            context: context,
            maxWidth: 5000,
            padding: EdgeInsets.zero,
            child: _busy
                ? const Center(
                    child: BrandedInlineLoader(message: 'Loading video...'),
                  )
                : _error != null
                ? _buildErrorState()
                : _initialized
                ? (isLandscape || _isFullscreen
                      ? _buildFullscreenLayout()
                      : _buildPortraitLayout())
                : const Center(
                    child: BrandedInlineLoader(message: 'Preparing player...'),
                  ),
          ),
        ),
      ),
    );
  }
}

class _LessonNoteItem {
  const _LessonNoteItem({
    required this.id,
    required this.positionMs,
    required this.text,
    required this.createdAt,
    required this.updatedAt,
    required this.deleted,
  });

  final String id;
  final int positionMs;
  final String text;
  final int createdAt;
  final int updatedAt;
  final bool deleted;

  factory _LessonNoteItem.fromMap(String id, Map<String, dynamic> map) {
    bool asBool(dynamic v) {
      if (v is bool) return v;
      final s = (v ?? '').toString().trim().toLowerCase();
      return s == 'true' || s == '1';
    }

    int asInt(dynamic v) {
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse((v ?? '').toString()) ?? 0;
    }

    return _LessonNoteItem(
      id: id,
      positionMs: asInt(map['positionMs']),
      text: (map['text'] ?? '').toString().trim(),
      createdAt: asInt(map['createdAt']),
      updatedAt: asInt(map['updatedAt']),
      deleted: asBool(map['deleted']),
    );
  }
}
