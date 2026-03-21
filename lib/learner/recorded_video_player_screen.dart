import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

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
  bool _isScrubbing = false;

  String? _error;
  String _notes = '';

  int _savedPositionMs = 0;
  int _savedDurationMs = 0;
  int _bookmarkPositionMs = 0;
  int _lastSavedPositionMs = 0;

  double _dragSliderValue = 0.0;

  Timer? _saveDebounce;
  Timer? _hideControlsTimer;

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
    WidgetsBinding.instance.removeObserver(this);
    _progressSub?.cancel();
    _saveDebounce?.cancel();
    _hideControlsTimer?.cancel();
    _persistProgressNow();
    _controller?.removeListener(_videoListener);
    _controller?.dispose();
    _restoreDefaultUiAndOrientation();
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

  Future<void> _restoreDefaultUiAndOrientation() async {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
    ]);
  }

  Future<void> _enterFullscreen() async {
    _hideControlsTimer?.cancel();

    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    if (!mounted) return;
    setState(() {
      _isFullscreen = true;
      _showControls = true;
    });

    _startHideControlsTimer();
  }

  Future<void> _exitFullscreen() async {
    _hideControlsTimer?.cancel();

    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    if (!mounted) return;
    setState(() {
      _isFullscreen = false;
      _showControls = true;
    });

    _startHideControlsTimer();
  }

  Future<void> _toggleFullscreen() async {
    if (_isFullscreen) {
      await _exitFullscreen();
    } else {
      await _enterFullscreen();
    }
  }

  Future<bool> _handleBackPressed() async {
    if (_isFullscreen) {
      await _exitFullscreen();
      return false;
    }
    return true;
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
        _isPlaying = controller.value.isPlaying;
      });

      _listenForRemoteProgress();
      _startHideControlsTimer();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
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
    final positionMs = value.position.inMilliseconds;
    final durationMs = value.duration.inMilliseconds;
    final playing = value.isPlaying;

    if (_isPlaying != playing && mounted) {
      setState(() => _isPlaying = playing);
      if (playing) {
        _startHideControlsTimer();
      }
    }

    if (!_isScrubbing && durationMs > 0) {
      _dragSliderValue = (positionMs / durationMs).clamp(0.0, 1.0);
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

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Video completed. This session video is now marked done.'),
      ),
    );
  }

  Future<void> _togglePlayPause() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    if (controller.value.isPlaying) {
      await controller.pause();
      if (mounted) {
        setState(() => _showControls = true);
      }
      _hideControlsTimer?.cancel();
    } else {
      await controller.play();
      _showControlsTemporarily();
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

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          nextBookmarked
              ? 'Bookmark saved at ${_formatDurationMs(nextBookmarkMs)}.'
              : 'Bookmark removed.',
        ),
      ),
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
      backgroundColor: const Color(0xFF101828),
      builder: (_) {
        final bottom = MediaQuery.of(context).viewInsets.bottom;
        return Padding(
          padding: EdgeInsets.only(bottom: bottom),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Session Notes',
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 18,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: notesController,
                    minLines: 5,
                    maxLines: 10,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                    decoration: InputDecoration(
                      hintText: 'Write your notes here...',
                      hintStyle: TextStyle(
                        color: Colors.white.withOpacity(0.45),
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(color: Color(0xFF344054)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(color: Color(0xFF344054)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(color: Color(0xFF7C3AED)),
                      ),
                      filled: true,
                      fillColor: const Color(0xFF182230),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white,
                            side: const BorderSide(color: Color(0xFF475467)),
                            padding: const EdgeInsets.symmetric(vertical: 13),
                          ),
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Cancel'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: const Color(0xFF7C3AED),
                            padding: const EdgeInsets.symmetric(vertical: 13),
                          ),
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

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Notes saved.')),
    );
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
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [
            Color(0xFF111827),
            Color(0xFF1F2937),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.08),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
        ],
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                decoration: BoxDecoration(
                  color: _isCompleted
                      ? const Color(0xFF0B3B2E)
                      : const Color(0xFF2A1A4A),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  _isCompleted ? 'Completed' : 'In Progress',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 12,
                    color: _isCompleted
                        ? const Color(0xFF86EFAC)
                        : const Color(0xFFD8B4FE),
                  ),
                ),
              ),
              const Spacer(),
              if (_bookmarked)
                const Icon(
                  Icons.bookmark_rounded,
                  size: 18,
                  color: Color(0xFFD8B4FE),
                ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            _isCompleted
                ? 'You finished this session.'
                : '${_formatDurationMs(positionMs)} watched of ${_formatDurationMs(durationMs)}',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: ratio.clamp(0.0, 1.0),
              minHeight: 7,
              backgroundColor: Colors.white.withOpacity(0.12),
              valueColor: const AlwaysStoppedAnimation<Color>(
                Color(0xFF8B5CF6),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            _isCompleted
                ? 'Marked done automatically after reaching the end.'
                : 'The session will be marked done automatically at the end.',
            style: TextStyle(
              fontSize: 12,
              height: 1.35,
              color: Colors.white.withOpacity(0.75),
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompactActionPanel({required bool isLandscape}) {
    final hasNotes = _notes.trim().isNotEmpty;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.06),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
        border: Border.all(color: const Color(0xFFEAECF0)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 10,
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
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              constraints: BoxConstraints(
                maxHeight: isLandscape ? 130 : 160,
              ),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFEAECF0)),
              ),
              child: SingleChildScrollView(
                child: Text(
                  _notes.trim(),
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.4,
                    color: Colors.black.withOpacity(0.78),
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
    final enabled = onPressed != null;

    return Material(
      color: enabled ? const Color(0xFFF5F3FF) : const Color(0xFFF2F4F7),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: enabled ? const Color(0xFFE9D5FF) : const Color(0xFFEAECF0),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 18,
                color: enabled ? const Color(0xFF6D28D9) : Colors.grey,
              ),
              const SizedBox(width: 7),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: enabled ? const Color(0xFF1F2937) : Colors.grey,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopLeftChip({
    required IconData icon,
    required String label,
    Color background = const Color(0x66000000),
    Color foreground = Colors.white,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: foreground),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: foreground,
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlayerIconButton({
    required VoidCallback? onPressed,
    required IconData icon,
    double size = 42,
    Color background = const Color(0x33000000),
    Color iconColor = Colors.white,
  }) {
    return Material(
      color: background,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, color: iconColor, size: size * 0.52),
        ),
      ),
    );
  }

  Widget _buildVideoControlsOverlay({
    required bool isLandscape,
    required int positionMs,
    required int durationMs,
    required double ratio,
    required bool isBuffering,
  }) {
    final iconButtonSize = _isFullscreen ? 40.0 : 36.0;
    final playButtonSize = _isFullscreen ? 74.0 : 66.0;

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 180),
      opacity: _showControls ? 1 : 0,
      child: IgnorePointer(
        ignoring: !_showControls,
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Colors.black.withOpacity(0.55),
                Colors.transparent,
                Colors.black.withOpacity(0.72),
              ],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: const [0.0, 0.45, 1.0],
            ),
          ),
          child: SafeArea(
            bottom: false,
            child: Column(
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    _isFullscreen ? 14 : 12,
                    _isFullscreen ? 12 : 10,
                    _isFullscreen ? 14 : 12,
                    0,
                  ),
                  child: Row(
                    children: [
                      if (_isFullscreen)
                        _buildPlayerIconButton(
                          onPressed: _exitFullscreen,
                          icon: Icons.arrow_back_rounded,
                          size: iconButtonSize,
                        ),
                      if (_isFullscreen) const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          widget.sessionTitle.trim().isEmpty
                              ? 'Session Video'
                              : widget.sessionTitle.trim(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: _isFullscreen ? 14 : 13,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      if (_bookmarked)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: _buildTopLeftChip(
                            icon: Icons.bookmark_rounded,
                            label: 'Saved',
                            background: const Color(0x552A1A4A),
                            foreground: const Color(0xFFE9D5FF),
                          ),
                        ),
                      _buildPlayerIconButton(
                        onPressed: _toggleFullscreen,
                        icon: _isFullscreen
                            ? Icons.fullscreen_exit_rounded
                            : Icons.fullscreen_rounded,
                        size: iconButtonSize,
                      ),
                    ],
                  ),
                ),
                const Spacer(),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _buildPlayerIconButton(
                      onPressed: () => _seekRelative(-10),
                      icon: Icons.replay_10_rounded,
                      size: iconButtonSize + 4,
                    ),
                    const SizedBox(width: 14),
                    Material(
                      color: Colors.white.withOpacity(0.14),
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: _togglePlayPause,
                        child: SizedBox(
                          width: playButtonSize,
                          height: playButtonSize,
                          child: Icon(
                            _isPlaying
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            color: Colors.white,
                            size: playButtonSize * 0.56,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    _buildPlayerIconButton(
                      onPressed: () => _seekRelative(10),
                      icon: Icons.forward_10_rounded,
                      size: iconButtonSize + 4,
                    ),
                  ],
                ),
                const Spacer(),
                if (!_isFullscreen)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      children: [
                        _buildTopLeftChip(
                          icon: Icons.lock_clock_rounded,
                          label: _isCompleted ? 'Done' : 'Continue learning',
                        ),
                        _buildTopLeftChip(
                          icon: Icons.screen_rotation_alt_rounded,
                          label: 'Tap fullscreen for locked landscape',
                        ),
                      ],
                    ),
                  ),
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    _isFullscreen ? 14 : 12,
                    0,
                    _isFullscreen ? 14 : 12,
                    _isFullscreen ? 14 : 12,
                  ),
                  child: Column(
                    children: [
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          activeTrackColor: const Color(0xFF8B5CF6),
                          inactiveTrackColor: Colors.white.withOpacity(0.24),
                          thumbColor: Colors.white,
                          overlayColor: const Color(0x228B5CF6),
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 6,
                          ),
                          overlayShape: const RoundSliderOverlayShape(
                            overlayRadius: 12,
                          ),
                          trackHeight: 4,
                        ),
                        child: Slider(
                          value: (_isScrubbing ? _dragSliderValue : ratio)
                              .clamp(0.0, 1.0),
                          onChangeStart: (v) {
                            setState(() {
                              _isScrubbing = true;
                              _dragSliderValue = v;
                              _showControls = true;
                            });
                            _hideControlsTimer?.cancel();
                          },
                          onChanged: (v) {
                            setState(() {
                              _dragSliderValue = v;
                            });
                          },
                          onChangeEnd: (v) async {
                            setState(() {
                              _isScrubbing = false;
                              _dragSliderValue = v;
                            });
                            await _seekToRatio(v);
                          },
                        ),
                      ),
                      Row(
                        children: [
                          Text(
                            _formatDurationMs(positionMs),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const Spacer(),
                          if (isBuffering)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: Row(
                                children: const [
                                  SizedBox(
                                    width: 12,
                                    height: 12,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  ),
                                  SizedBox(width: 6),
                                  Text(
                                    'Buffering',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          Text(
                            _formatDurationMs(durationMs),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
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
  }

  Widget _buildVideoArea({required bool isLandscape}) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }

    final value = controller.value;
    final positionMs = value.position.inMilliseconds;
    final durationMs = value.duration.inMilliseconds;
    final ratio = durationMs <= 0 ? 0.0 : positionMs / durationMs;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (_showControls) {
          if (_isPlaying) {
            setState(() => _showControls = false);
          }
        } else {
          _showControlsTemporarily();
        }
      },
      child: Container(
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(_isFullscreen ? 0 : 24),
          boxShadow: _isFullscreen
              ? null
              : [
            BoxShadow(
              color: Colors.black.withOpacity(0.20),
              blurRadius: 24,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Center(
              child: FittedBox(
                fit: BoxFit.contain,
                child: SizedBox(
                  width: value.size.width <= 0 ? 16 : value.size.width,
                  height: value.size.height <= 0 ? 9 : value.size.height,
                  child: VideoPlayer(controller),
                ),
              ),
            ),
            _buildVideoControlsOverlay(
              isLandscape: isLandscape,
              positionMs: positionMs,
              durationMs: durationMs,
              ratio: ratio,
              isBuffering: value.isBuffering,
            ),
            if (!_showControls && value.isBuffering)
              const Positioned(
                child: CircularProgressIndicator(color: Colors.white),
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
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: const Color(0xFFFECACA)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.05),
                blurRadius: 14,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Text(
            _error ?? 'Could not open video.',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Color(0xFFB42318),
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(String title, bool isLandscape) {
    return AppBar(
      toolbarHeight: isLandscape ? 58 : kToolbarHeight,
      backgroundColor: const Color(0xFF0F172A),
      foregroundColor: Colors.white,
      elevation: 0,
      titleSpacing: 10,
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: isLandscape ? 15 : 17,
          fontWeight: FontWeight.w800,
        ),
      ),
      actions: [
        IconButton(
          tooltip: 'Fullscreen',
          onPressed: _toggleFullscreen,
          icon: const Icon(Icons.fullscreen_rounded),
        ),
        if (_isCompleted)
          const Padding(
            padding: EdgeInsets.only(right: 14),
            child: Center(
              child: Text(
                'DONE',
                style: TextStyle(
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF86EFAC),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildPortraitLayout() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 18),
      children: [
        _buildCompactStatusCard(),
        const SizedBox(height: 12),
        _buildVideoArea(isLandscape: false),
        const SizedBox(height: 12),
        _buildCompactActionPanel(isLandscape: false),
      ],
    );
  }

  Widget _buildLandscapeLayout() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 10,
            child: _buildVideoArea(isLandscape: true),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 5,
            child: SingleChildScrollView(
              child: Column(
                children: [
                  _buildCompactStatusCard(),
                  const SizedBox(height: 12),
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
    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      child: _buildVideoArea(isLandscape: true),
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.sessionTitle.trim().isEmpty
        ? 'Session Video'
        : widget.sessionTitle.trim();

    final orientation = MediaQuery.of(context).orientation;
    final isLandscape = orientation == Orientation.landscape;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: WillPopScope(
        onWillPop: _handleBackPressed,
        child: Scaffold(
          backgroundColor:
          _isFullscreen ? Colors.black : const Color(0xFFF3F5F8),
          appBar: _isFullscreen ? null : _buildAppBar(title, isLandscape),
          body: _busy
              ? const Center(child: CircularProgressIndicator())
              : _error != null
              ? _buildErrorState()
              : _initialized
              ? (_isFullscreen
              ? _buildFullscreenLayout()
              : (isLandscape
              ? _buildLandscapeLayout()
              : _buildPortraitLayout()))
              : const Center(child: CircularProgressIndicator()),
        ),
      ),
    );
  }
}