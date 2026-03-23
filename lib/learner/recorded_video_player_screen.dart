import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import '../shared/app_feedback.dart';
import '../shared/human_error.dart';
import '../shared/ybs_busy_logo.dart';
import '../shared/learner_tour_guide.dart';

class RecordedVideoPlayerScreen extends StatefulWidget {
  const RecordedVideoPlayerScreen({
    super.key,
    required this.uid,
    required this.courseKey,
    required this.sessionId,
    required this.sessionTitle,
    required this.videoUrl,
  });

  final String uid;
  final String courseKey;
  final String sessionId;
  final String sessionTitle;
  final String videoUrl;

  @override
  State<RecordedVideoPlayerScreen> createState() =>
      _RecordedVideoPlayerScreenState();
}

class _RecordedVideoPlayerScreenState extends State<RecordedVideoPlayerScreen>
    with WidgetsBindingObserver {
  static const String _usersNode = 'users';
  static const String _recordedProgressNode = 'recorded_progress';

  final FirebaseDatabase _db = FirebaseDatabase.instance;

  VideoPlayerController? _controller;
  StreamSubscription<DatabaseEvent>? _progressSub;

  bool _busy = true;
  bool _saving = false;
  bool _initialized = false;
  bool _isPlaying = false;
  bool _isCompleted = false;
  bool _bookmarked = false;
  bool _showControls = true;
  bool _isFullscreen = false;

  String? _error;
  String _notes = '';

  int _savedPositionMs = 0;
  int _savedDurationMs = 0;
  int _bookmarkPositionMs = 0;
  int _lastSavedPositionMs = 0;

  Timer? _saveDebounce;
  Timer? _hideControlsTimer;
  bool _isDisposing = false;

  void _debug(String message) {
    // no-op in production build
  }

  DatabaseReference get _progressRef => _db
      .ref(_usersNode)
      .child(widget.uid)
      .child('courses')
      .child(widget.courseKey)
      .child(_recordedProgressNode)
      .child(widget.sessionId);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _enableScreenRotations();
    _loadAndInit();
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

  Future<void> _loadAndInit() async {
    _debug('loadAndInit start sessionId=${widget.sessionId}');
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final snap = await _progressRef.get();
      if (snap.value is Map) {
        final map = Map<String, dynamic>.from(snap.value as Map);
        _savedPositionMs = _asInt(map['videoPositionMs']);
        _savedDurationMs = _asInt(map['videoDurationMs']);
        _bookmarkPositionMs = _asInt(map['bookmarkPositionMs']);
        _bookmarked = _asBool(map['bookmarked']);
        _notes = (map['notes'] ?? '').toString();
        _isCompleted = _asBool(map['videoCompleted']);
      }

      final uri = Uri.tryParse(widget.videoUrl.trim());
      if (uri == null) {
        throw Exception('Invalid video URL.');
      }
      _debug('video uri=$uri');

      final controller = VideoPlayerController.networkUrl(uri);
      _controller = controller;

      await controller.initialize();
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
      _debug('loadAndInit error=$e');
      if (!mounted) return;
      setState(() {
        _error = toHumanError(e);
        _busy = false;
      });
    }
  }

  void _listenForRemoteProgress() {
    _progressSub?.cancel();
    _progressSub = _progressRef.onValue.listen((event) {
      final raw = event.snapshot.value;
      if (raw is! Map) return;

      final map = Map<String, dynamic>.from(raw);
      final remoteNotes = (map['notes'] ?? '').toString();
      final remoteBookmarked = _asBool(map['bookmarked']);
      final remoteBookmarkMs = _asInt(map['bookmarkPositionMs']);
      final remoteCompleted = _asBool(map['videoCompleted']);

      if (!mounted) return;
      setState(() {
        _notes = remoteNotes;
        _bookmarked = remoteBookmarked;
        _bookmarkPositionMs = remoteBookmarkMs;
        _isCompleted = remoteCompleted;
      });
    });
  }

  Future<void> _writeInitialMetaIfNeeded() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    final durationMs = controller.value.duration.inMilliseconds;

    await _progressRef.update({
      'videoUrl': widget.videoUrl.trim(),
      'sessionTitle': widget.sessionTitle.trim(),
      'videoDurationMs': durationMs,
      'lastOpenedAt': ServerValue.timestamp,
      'updatedAt': ServerValue.timestamp,
      if (_notes.isNotEmpty) 'notes': _notes,
      if (_bookmarked) 'bookmarked': true,
      if (_bookmarkPositionMs > 0) 'bookmarkPositionMs': _bookmarkPositionMs,
    });
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
      final lower = raw.toLowerCase();
      final pretty = lower.contains('response code: 404')
          ? 'Video file not found on server (404). Please contact support.'
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
      await _progressRef.update({
        'videoPositionMs': currentMs,
        'videoDurationMs': durationMs,
        'lastOpenedAt': ServerValue.timestamp,
        'updatedAt': ServerValue.timestamp,
      });
    } catch (_) {
    } finally {
      _saving = false;
    }
  }

  Future<void> _markVideoCompleted() async {
    if (_isCompleted) return;

    final snap = await _progressRef.get();
    final map = snap.value is Map
        ? Map<String, dynamic>.from(snap.value as Map)
        : <String, dynamic>{};

    final materialsCompleted = _asBool(map['materialsCompleted']);
    final durationMs = _controller?.value.duration.inMilliseconds ?? 0;

    await _progressRef.update({
      'videoCompleted': true,
      'videoCompletedAt': ServerValue.timestamp,
      'videoPositionMs': durationMs,
      'videoDurationMs': durationMs,
      'completed': materialsCompleted,
      'lastOpenedAt': ServerValue.timestamp,
      'updatedAt': ServerValue.timestamp,
    });

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

  Future<void> _toggleBookmark() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    final currentMs = controller.value.position.inMilliseconds;
    final nextBookmarked = !_bookmarked;
    final nextBookmarkMs = nextBookmarked ? currentMs : 0;

    await _progressRef.update({
      'bookmarked': nextBookmarked,
      'bookmarkPositionMs': nextBookmarkMs,
      'updatedAt': ServerValue.timestamp,
    });

    if (!mounted) return;
    setState(() {
      _bookmarked = nextBookmarked;
      _bookmarkPositionMs = nextBookmarkMs;
    });

    AppToast.show(
      context,
      nextBookmarked
          ? 'Bookmark saved at ${_formatDurationMs(nextBookmarkMs)}.'
          : 'Bookmark removed.',
      type: AppToastType.info,
    );
  }

  Future<void> _jumpToBookmark() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    if (_bookmarkPositionMs <= 0) return;

    await controller.seekTo(Duration(milliseconds: _bookmarkPositionMs));
    _scheduleProgressSave();
    _showControlsTemporarily();
  }

  Future<void> _editNotes() async {
    final notesController = TextEditingController(text: _notes);

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) {
        final bottom = MediaQuery.of(context).viewInsets.bottom;
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
                    'Session Notes',
                    style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: notesController,
                    minLines: 5,
                    maxLines: 10,
                    decoration: const InputDecoration(
                      hintText: 'Write your notes here...',
                      border: OutlineInputBorder(),
                      filled: true,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Cancel'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Save Notes'),
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

    final nextNotes = notesController.text.trim();
    await _progressRef.update({
      'notes': nextNotes,
      'updatedAt': ServerValue.timestamp,
    });

    if (!mounted) return;
    setState(() {
      _notes = nextNotes;
    });

    AppToast.show(context, 'Notes saved.', type: AppToastType.success);
  }

  void _startHideControlsTimer() {
    _hideControlsTimer?.cancel();
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
              if (_bookmarked)
                const Icon(
                  Icons.bookmark_rounded,
                  size: 18,
                  color: Color(0xFF7C3AED),
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
          const SizedBox(height: 8),
          Text(
            _isCompleted
                ? 'Marked done automatically after reaching the end.'
                : 'Will mark done automatically when the video reaches the end.',
            style: TextStyle(
              fontSize: 12,
              height: 1.25,
              color: _isCompleted
                  ? const Color(0xFF166534)
                  : const Color(0xFF92400E),
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompactActionPanel({required bool isLandscape}) {
    final hasNotes = _notes.trim().isNotEmpty;

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _smallActionButton(
                onPressed: _toggleBookmark,
                icon: _bookmarked
                    ? Icons.bookmark_rounded
                    : Icons.bookmark_border_rounded,
                label: _bookmarked ? 'Saved' : 'Bookmark',
              ),
              _smallActionButton(
                onPressed: _bookmarkPositionMs > 0 ? _jumpToBookmark : null,
                icon: Icons.flag_rounded,
                label: 'Go to mark',
              ),
              _smallActionButton(
                onPressed: _editNotes,
                icon: Icons.note_alt_rounded,
                label: hasNotes ? 'Edit notes' : 'Add notes',
              ),
            ],
          ),
          if (hasNotes) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              constraints: BoxConstraints(maxHeight: isLandscape ? 120 : 150),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFE5E7EB)),
              ),
              child: SingleChildScrollView(
                child: Text(
                  _notes.trim(),
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.3,
                    color: Colors.black.withValues(alpha: 0.78),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _smallActionButton({
    required VoidCallback? onPressed,
    required IconData icon,
    required String label,
  }) {
    return Material(
      color: const Color(0xFFF8FAFC),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFE5E7EB)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 18,
                color: onPressed == null
                    ? Colors.grey
                    : const Color(0xFF1A2B48),
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: onPressed == null
                      ? Colors.grey
                      : const Color(0xFF1A2B48),
                ),
              ),
            ],
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

    return GestureDetector(
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
                              if (_isFullscreen)
                                IconButton(
                                  onPressed: _toggleFullscreen,
                                  color: Colors.white,
                                  icon: const Icon(
                                    Icons.fullscreen_exit_rounded,
                                  ),
                                ),
                              const Spacer(),
                              IconButton(
                                onPressed: _toggleFullscreen,
                                color: Colors.white,
                                icon: Icon(
                                  _isFullscreen
                                      ? Icons.fullscreen_exit_rounded
                                      : Icons.fullscreen_rounded,
                                ),
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
                            iconSize: isLandscape ? 30 : 34,
                            color: Colors.white,
                            icon: const Icon(Icons.replay_10_rounded),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.16),
                              shape: BoxShape.circle,
                            ),
                            child: IconButton(
                              onPressed: _togglePlayPause,
                              iconSize: isLandscape ? 40 : 44,
                              color: Colors.white,
                              icon: Icon(
                                _isPlaying
                                    ? Icons.pause_circle_filled_rounded
                                    : Icons.play_circle_fill_rounded,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          IconButton(
                            onPressed: () => _seekRelative(10),
                            iconSize: isLandscape ? 30 : 34,
                            color: Colors.white,
                            icon: const Icon(Icons.forward_10_rounded),
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
      ],
    );
  }

  Widget _buildLandscapeLayout() {
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(flex: 9, child: _buildVideoArea(isLandscape: true)),
          const SizedBox(width: 10),
          Expanded(
            flex: 5,
            child: SingleChildScrollView(
              child: Column(
                children: [
                  _buildCompactStatusCard(),
                  const SizedBox(height: 10),
                  _buildCompactActionPanel(isLandscape: true),
                ],
              ),
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

  @override
  Widget build(BuildContext context) {
    LearnerTourGuide.schedule(
      context,
      screenId: 'learner_recorded_video',
      hints: const [
        LearnerTourHint(
          title: 'تشغيل الفيديو',
          line: 'استخدم ازرار التشغيل والتقديم لمتابعة الدرس كما تريد.',
        ),
        LearnerTourHint(
          title: 'الملاحظات',
          line: 'يمكنك كتابة ملاحظاتك وحفظها لكل جلسة فيديو.',
        ),
      ],
    );

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
          appBar: _isFullscreen ? null : _buildAppBar(title, isLandscape),
          body: _busy
              ? const Center(
                  child: BrandedInlineLoader(message: 'Loading video...'),
                )
              : _error != null
              ? _buildErrorState()
              : _initialized
              ? (_isFullscreen
                    ? _buildFullscreenLayout()
                    : (isLandscape
                          ? _buildLandscapeLayout()
                          : _buildPortraitLayout()))
              : const Center(
                  child: BrandedInlineLoader(message: 'Preparing player...'),
                ),
        ),
      ),
    );
  }
}
