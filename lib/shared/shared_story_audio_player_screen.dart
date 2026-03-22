import 'dart:async';
import 'dart:ui';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import 'app_theme.dart';

class SharedAudioPlayerScreen extends StatefulWidget {
  const SharedAudioPlayerScreen({
    super.key,
    required this.title,
    required this.audioUrl,
    this.imageUrl = '',
  });

  final String title;
  final String audioUrl;
  final String imageUrl;

  @override
  State<SharedAudioPlayerScreen> createState() =>
      _SharedAudioPlayerScreenState();
}

enum _LearningMode { listen, study, shadow, review }

enum _RepeatMode { off, one, loop10 }

class _SharedAudioPlayerScreenState extends State<SharedAudioPlayerScreen> {
  late final AudioPlayer _player;

  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  PlayerState _playerState = PlayerState.stopped;
  bool _loading = true;
  String? _error;

  double _playbackRate = 1.0;
  _LearningMode _learningMode = _LearningMode.listen;
  _RepeatMode _repeatMode = _RepeatMode.off;

  bool _focusMode = false;
  bool _isFavorite = false;

  Duration? _sleepRemaining;
  Timer? _sleepTimer;

  final List<Duration> _bookmarks = [];
  final List<String> _notes = [];
  final List<String> _savedItems = [];

  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<void>? _completeSub;

  @override
  void initState() {
    super.initState();
    _player = AudioPlayer();
    _bindPlayer();
    _loadAudio();
  }

  void _bindPlayer() {
    _durationSub = _player.onDurationChanged.listen((d) {
      if (!mounted) return;
      setState(() {
        _duration = d;
      });
    });

    _positionSub = _player.onPositionChanged.listen((p) async {
      if (!mounted) return;

      if (_repeatMode == _RepeatMode.loop10 && _duration > Duration.zero) {
        final loopStart = _position.inSeconds >= 10
            ? _position - const Duration(seconds: 10)
            : Duration.zero;
        final loopEnd = loopStart + const Duration(seconds: 10);

        if (p >= loopEnd) {
          await _player.seek(loopStart);
          return;
        }
      }

      setState(() {
        _position = p;
      });
    });

    _stateSub = _player.onPlayerStateChanged.listen((s) {
      if (!mounted) return;
      setState(() {
        _playerState = s;
        _loading = false;
      });
    });

    _completeSub = _player.onPlayerComplete.listen((_) async {
      if (!mounted) return;

      if (_repeatMode == _RepeatMode.one) {
        await _player.seek(Duration.zero);
        await _player.resume();
        return;
      }

      setState(() {
        _position = Duration.zero;
        _playerState = PlayerState.completed;
      });
    });
  }

  Future<void> _loadAudio() async {
    try {
      setState(() {
        _loading = true;
        _error = null;
      });

      await _player.setSourceUrl(widget.audioUrl);
      await _player.setReleaseMode(ReleaseMode.stop);
      await _player.setPlaybackRate(_playbackRate);

      if (!mounted) return;
      setState(() {
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not load audio.\n$e';
      });
    }
  }

  Future<void> _togglePlayPause() async {
    try {
      if (_playerState == PlayerState.playing) {
        await _player.pause();
      } else {
        if (_playerState == PlayerState.completed) {
          await _player.seek(Duration.zero);
        }
        await _player.resume();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Playback failed.\n$e';
      });
    }
  }

  Future<void> _seekTo(double valueMs) async {
    final target = Duration(milliseconds: valueMs.round());
    await _player.seek(target);
  }

  Future<void> _jumpBySeconds(int seconds) async {
    final newPosition = _position + Duration(seconds: seconds);
    final bounded = Duration(
      milliseconds: newPosition.inMilliseconds.clamp(
        0,
        _duration.inMilliseconds > 0 ? _duration.inMilliseconds : 0,
      ),
    );
    await _player.seek(bounded);
  }

  Future<void> _setPlaybackRate(double rate) async {
    try {
      await _player.setPlaybackRate(rate);
      if (!mounted) return;
      setState(() {
        _playbackRate = rate;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not change speed.\n$e';
      });
    }
  }

  void _toggleFavorite() {
    setState(() {
      _isFavorite = !_isFavorite;
    });
  }

  void _toggleRepeatMode() {
    setState(() {
      switch (_repeatMode) {
        case _RepeatMode.off:
          _repeatMode = _RepeatMode.one;
          break;
        case _RepeatMode.one:
          _repeatMode = _RepeatMode.loop10;
          break;
        case _RepeatMode.loop10:
          _repeatMode = _RepeatMode.off;
          break;
      }
    });
  }

  void _addBookmark() {
    setState(() {
      _bookmarks.add(_position);
      _bookmarks.sort((a, b) => a.compareTo(b));
    });

    _toast('Bookmark added at ${_format(_position)}');
  }

  void _clearSleepTimer() {
    _sleepTimer?.cancel();
    setState(() {
      _sleepRemaining = null;
    });
  }

  void _startSleepTimer(Duration duration) {
    _sleepTimer?.cancel();

    setState(() {
      _sleepRemaining = duration;
    });

    _sleepTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (!mounted) {
        timer.cancel();
        return;
      }

      final remaining = _sleepRemaining ?? Duration.zero;

      if (remaining <= const Duration(seconds: 1)) {
        timer.cancel();
        await _player.pause();
        if (!mounted) return;
        setState(() {
          _sleepRemaining = null;
        });
        _toast('Sleep timer finished');
        return;
      }

      setState(() {
        _sleepRemaining = remaining - const Duration(seconds: 1);
      });
    });
  }

  void _toast(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  String _format(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');

    if (hours > 0) {
      return '$hours:$minutes:$seconds';
    }
    return '${d.inMinutes}:$seconds';
  }

  String _formatRemaining(Duration total, Duration current) {
    final remaining = total - current;
    final safe = remaining.isNegative ? Duration.zero : remaining;
    return '-${_format(safe)}';
  }

  String _modeLabel(_LearningMode mode) {
    switch (mode) {
      case _LearningMode.listen:
        return 'Listen';
      case _LearningMode.study:
        return 'Study';
      case _LearningMode.shadow:
        return 'Shadow';
      case _LearningMode.review:
        return 'Review';
    }
  }

  String _modeHint() {
    switch (_learningMode) {
      case _LearningMode.listen:
        return 'clean listening';
      case _LearningMode.study:
        return 'notes and saving';
      case _LearningMode.shadow:
        return 'slow and repeat';
      case _LearningMode.review:
        return 'bookmarks first';
    }
  }

  String _repeatShortLabel() {
    switch (_repeatMode) {
      case _RepeatMode.off:
        return 'Repeat Off';
      case _RepeatMode.one:
        return 'Repeat Track';
      case _RepeatMode.loop10:
        return 'Loop 10s';
    }
  }

  Future<void> _setMode(_LearningMode mode) async {
    setState(() {
      _learningMode = mode;
    });

    switch (mode) {
      case _LearningMode.listen:
        await _setPlaybackRate(1.0);
        setState(() {
          _repeatMode = _RepeatMode.off;
        });
        break;
      case _LearningMode.study:
        await _setPlaybackRate(1.0);
        break;
      case _LearningMode.shadow:
        await _setPlaybackRate(0.9);
        setState(() {
          _repeatMode = _RepeatMode.loop10;
        });
        break;
      case _LearningMode.review:
        if (_bookmarks.isNotEmpty) {
          await _player.seek(_bookmarks.first);
        }
        await _setPlaybackRate(0.95);
        break;
    }
  }

  void _saveMoment() {
    final text = 'Saved moment at ${_format(_position)}';
    setState(() {
      _savedItems.add(text);
    });
    _toast('Saved for later');
  }

  Future<void> _showAddNoteSheet() async {
    final controller = TextEditingController();
    final p = palette;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: p.cardBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) {
        return Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            16,
            16,
            MediaQuery.of(context).viewInsets.bottom + 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Add note',
                style: TextStyle(
                  color: p.text,
                  fontWeight: FontWeight.w900,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                maxLines: 3,
                decoration: const InputDecoration(
                  hintText: 'Write a quick note...',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      onPressed: () {
                        final text = controller.text.trim();
                        if (text.isNotEmpty) {
                          setState(() {
                            _notes.add(text);
                          });
                          Navigator.of(context).pop();
                          _toast('Note saved');
                        }
                      },
                      child: const Text('Save'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showBookmarksSheet() async {
    final p = palette;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: p.cardBg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) {
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.of(context).size.height * 0.55,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
              child: Column(
                children: [
                  Row(
                    children: [
                      Text(
                        'Bookmarks',
                        style: TextStyle(
                          color: p.text,
                          fontWeight: FontWeight.w900,
                          fontSize: 16,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '${_bookmarks.length}',
                        style: TextStyle(
                          color: p.text.withOpacity(0.65),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: _bookmarks.isEmpty
                        ? Center(
                            child: Text(
                              'No bookmarks yet',
                              style: TextStyle(
                                color: p.text.withOpacity(0.65),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          )
                        : ListView.builder(
                            itemCount: _bookmarks.length,
                            itemBuilder: (_, index) {
                              final bookmark = _bookmarks[index];
                              return ListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                leading: CircleAvatar(
                                  radius: 14,
                                  backgroundColor: p.primary.withOpacity(0.12),
                                  child: Text(
                                    '${index + 1}',
                                    style: TextStyle(
                                      color: p.primary,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                                title: Text(
                                  _format(bookmark),
                                  style: TextStyle(
                                    color: p.text,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                trailing: IconButton(
                                  onPressed: () {
                                    setState(() {
                                      _bookmarks.removeAt(index);
                                    });
                                    Navigator.of(context).pop();
                                    _showBookmarksSheet();
                                  },
                                  icon: const Icon(
                                    Icons.delete_outline_rounded,
                                    size: 20,
                                  ),
                                ),
                                onTap: () async {
                                  Navigator.of(context).pop();
                                  await _player.seek(bookmark);
                                },
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _showSavedItemsSheet() async {
    final p = palette;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: p.cardBg,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) {
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.of(context).size.height * 0.6,
            child: DefaultTabController(
              length: 2,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
                child: Column(
                  children: [
                    Text(
                      'Saved items',
                      style: TextStyle(
                        color: p.text,
                        fontWeight: FontWeight.w900,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const TabBar(
                      tabs: [
                        Tab(text: 'Saved'),
                        Tab(text: 'Notes'),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: TabBarView(
                        children: [
                          _savedItems.isEmpty
                              ? Center(
                                  child: Text(
                                    'Nothing saved yet',
                                    style: TextStyle(
                                      color: p.text.withOpacity(0.65),
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                )
                              : ListView.builder(
                                  itemCount: _savedItems.length,
                                  itemBuilder: (_, index) {
                                    final item = _savedItems[index];
                                    return ListTile(
                                      dense: true,
                                      contentPadding: EdgeInsets.zero,
                                      title: Text(
                                        item,
                                        style: TextStyle(
                                          color: p.text,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      trailing: IconButton(
                                        onPressed: () {
                                          setState(() {
                                            _savedItems.removeAt(index);
                                          });
                                          Navigator.of(context).pop();
                                          _showSavedItemsSheet();
                                        },
                                        icon: const Icon(
                                          Icons.delete_outline_rounded,
                                          size: 20,
                                        ),
                                      ),
                                    );
                                  },
                                ),
                          _notes.isEmpty
                              ? Center(
                                  child: Text(
                                    'No notes yet',
                                    style: TextStyle(
                                      color: p.text.withOpacity(0.65),
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                )
                              : ListView.builder(
                                  itemCount: _notes.length,
                                  itemBuilder: (_, index) {
                                    final note = _notes[index];
                                    return ListTile(
                                      dense: true,
                                      contentPadding: EdgeInsets.zero,
                                      title: Text(
                                        note,
                                        style: TextStyle(
                                          color: p.text,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      trailing: IconButton(
                                        onPressed: () {
                                          setState(() {
                                            _notes.removeAt(index);
                                          });
                                          Navigator.of(context).pop();
                                          _showSavedItemsSheet();
                                        },
                                        icon: const Icon(
                                          Icons.delete_outline_rounded,
                                          size: 20,
                                        ),
                                      ),
                                    );
                                  },
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

  Future<void> _showSpeedSheet() async {
    final p = palette;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: p.cardBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) {
        final speeds = [0.75, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0];

        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Playback speed',
                  style: TextStyle(
                    color: p.text,
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: speeds.map((speed) {
                    final selected = _playbackRate == speed;
                    return ChoiceChip(
                      selected: selected,
                      label: Text('${speed}x'),
                      onSelected: (_) async {
                        Navigator.of(context).pop();
                        await _setPlaybackRate(speed);
                      },
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _showSleepTimerSheet() async {
    final p = palette;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: p.cardBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (_) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Sleep timer',
                  style: TextStyle(
                    color: p.text,
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _sheetAction('5 min', () {
                      Navigator.of(context).pop();
                      _startSleepTimer(const Duration(minutes: 5));
                    }),
                    _sheetAction('10 min', () {
                      Navigator.of(context).pop();
                      _startSleepTimer(const Duration(minutes: 10));
                    }),
                    _sheetAction('15 min', () {
                      Navigator.of(context).pop();
                      _startSleepTimer(const Duration(minutes: 15));
                    }),
                    _sheetAction('30 min', () {
                      Navigator.of(context).pop();
                      _startSleepTimer(const Duration(minutes: 30));
                    }),
                    _sheetAction('Clear', () {
                      Navigator.of(context).pop();
                      _clearSleepTimer();
                    }),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _sheetAction(String label, VoidCallback onTap) {
    return FilledButton(onPressed: onTap, child: Text(label));
  }

  _AudioPalette get palette => _toAudioPalette(appThemeController.palette);

  _AudioPalette _toAudioPalette(AppPalette p) {
    return _AudioPalette(
      primary: p.primary,
      accent: p.accent,
      text: p.text,
      appBg: p.appBg,
      cardBg: p.cardBg,
      border: p.border,
      soft: p.soft,
    );
  }

  @override
  void dispose() {
    _sleepTimer?.cancel();
    _durationSub?.cancel();
    _positionSub?.cancel();
    _stateSub?.cancel();
    _completeSub?.cancel();
    unawaited(_player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final hasImage = widget.imageUrl.trim().isNotEmpty;
    final totalMs = _duration.inMilliseconds <= 0
        ? 1.0
        : _duration.inMilliseconds.toDouble();
    final currentMs = _position.inMilliseconds
        .clamp(0, _duration.inMilliseconds)
        .toDouble();

    return Scaffold(
      backgroundColor: p.appBg,
      body: Stack(
        children: [
          _buildBackground(p, hasImage),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
              child: Column(
                children: [
                  _buildTopBar(p),
                  const SizedBox(height: 8),
                  if (!_focusMode) _buildCompactHeader(p, hasImage),
                  if (!_focusMode) const SizedBox(height: 8),
                  _buildProgressCard(p, totalMs, currentMs),
                  const SizedBox(height: 8),
                  _buildTransportRow(p),
                  const SizedBox(height: 8),
                  _buildUtilityRow(p),
                  const SizedBox(height: 8),
                  _buildModeRow(p),
                  const SizedBox(height: 8),
                  Expanded(child: _buildCenterStage(p, hasImage)),
                  const SizedBox(height: 8),
                  _buildBottomActionBar(p),
                  if (_error != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.redAccent,
                        fontWeight: FontWeight.w800,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBackground(_AudioPalette p, bool hasImage) {
    if (!hasImage) {
      return Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              p.primary.withOpacity(0.12),
              p.accent.withOpacity(0.08),
              p.appBg,
            ],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        Image.network(
          widget.imageUrl.trim(),
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => Container(color: p.appBg),
        ),
        BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(color: Colors.black.withOpacity(0.18)),
        ),
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                Colors.black.withOpacity(0.34),
                p.primary.withOpacity(0.14),
                p.appBg.withOpacity(0.95),
              ],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTopBar(_AudioPalette p) {
    return SizedBox(
      height: 36,
      child: Row(
        children: [
          _glassIconButton(
            icon: Icons.arrow_back_rounded,
            onTap: () => Navigator.of(context).maybePop(),
          ),
          const Spacer(),
          Text(
            _modeLabel(_learningMode),
            style: TextStyle(
              color: p.text,
              fontSize: 15,
              fontWeight: FontWeight.w900,
            ),
          ),
          const Spacer(),
          _glassIconButton(
            icon: _focusMode
                ? Icons.fullscreen_exit_rounded
                : Icons.fullscreen_rounded,
            onTap: () {
              setState(() {
                _focusMode = !_focusMode;
              });
            },
          ),
        ],
      ),
    );
  }

  Widget _buildCompactHeader(_AudioPalette p, bool hasImage) {
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: _glassDecoration(p),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: hasImage
                ? Image.network(
                    widget.imageUrl.trim(),
                    width: 48,
                    height: 48,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => _fallbackCover(),
                  )
                : _fallbackCover(),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  widget.title.trim().isEmpty
                      ? 'Audio Story'
                      : widget.title.trim(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: p.text,
                    fontWeight: FontWeight.w900,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  _modeHint(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: p.text.withOpacity(0.62),
                    fontWeight: FontWeight.w700,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          _tinyPill(
            p,
            '${_playbackRate.toStringAsFixed(_playbackRate == _playbackRate.roundToDouble() ? 0 : 1)}x',
          ),
        ],
      ),
    );
  }

  Widget _buildProgressCard(_AudioPalette p, double totalMs, double currentMs) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: _glassDecoration(p),
      child: Column(
        children: [
          Row(
            children: [
              _compactInfoChip(p, Icons.speed_rounded, '${_playbackRate}x'),
              const SizedBox(width: 6),
              _compactInfoChip(p, Icons.repeat_rounded, _repeatShortLabel()),
              const SizedBox(width: 6),
              _compactInfoChip(
                p,
                Icons.timer_outlined,
                _sleepRemaining == null
                    ? 'Sleep Off'
                    : _format(_sleepRemaining!),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 4,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              activeTrackColor: p.accent,
              inactiveTrackColor: p.border.withOpacity(0.45),
              thumbColor: p.primary,
              overlayColor: p.primary.withOpacity(0.12),
            ),
            child: Slider(
              value: currentMs.clamp(0, totalMs),
              max: totalMs,
              onChanged: (_duration.inMilliseconds <= 0)
                  ? null
                  : (value) => _seekTo(value),
            ),
          ),
          Row(
            children: [
              Text(
                _format(_position),
                style: TextStyle(
                  color: p.text.withOpacity(0.72),
                  fontWeight: FontWeight.w800,
                  fontSize: 11,
                ),
              ),
              const Spacer(),
              Text(
                _formatRemaining(_duration, _position),
                style: TextStyle(
                  color: p.text.withOpacity(0.72),
                  fontWeight: FontWeight.w800,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTransportRow(_AudioPalette p) {
    return SizedBox(
      height: 54,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _circleButton(
            onTap: () => _jumpBySeconds(-10),
            icon: Icons.replay_10_rounded,
            background: p.soft,
            foreground: p.primary,
            size: 42,
            iconSize: 20,
          ),
          const SizedBox(width: 10),
          _circleButton(
            onTap: () => _jumpBySeconds(-5),
            icon: Icons.replay_5_rounded,
            background: p.soft,
            foreground: p.primary,
            size: 38,
            iconSize: 18,
          ),
          const SizedBox(width: 10),
          _circleButton(
            onTap: _loading ? () {} : _togglePlayPause,
            icon: _loading
                ? Icons.hourglass_top_rounded
                : _playerState == PlayerState.playing
                ? Icons.pause_rounded
                : Icons.play_arrow_rounded,
            background: p.accent,
            foreground: Colors.white,
            size: 54,
            iconSize: 28,
          ),
          const SizedBox(width: 10),
          _circleButton(
            onTap: () => _jumpBySeconds(5),
            icon: Icons.forward_5_rounded,
            background: p.soft,
            foreground: p.primary,
            size: 38,
            iconSize: 18,
          ),
          const SizedBox(width: 10),
          _circleButton(
            onTap: () => _jumpBySeconds(10),
            icon: Icons.forward_10_rounded,
            background: p.soft,
            foreground: p.primary,
            size: 42,
            iconSize: 20,
          ),
        ],
      ),
    );
  }

  Widget _buildUtilityRow(_AudioPalette p) {
    return SizedBox(
      height: 34,
      child: Row(
        children: [
          Expanded(
            child: _miniAction(
              p,
              icon: Icons.speed_rounded,
              label: 'Speed',
              onTap: _showSpeedSheet,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: _miniAction(
              p,
              icon: Icons.repeat_rounded,
              label: 'Repeat',
              onTap: _toggleRepeatMode,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: _miniAction(
              p,
              icon: Icons.timer_rounded,
              label: 'Sleep',
              onTap: _showSleepTimerSheet,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: _miniAction(
              p,
              icon: _isFavorite
                  ? Icons.favorite_rounded
                  : Icons.favorite_border_rounded,
              label: _isFavorite ? 'Saved' : 'Favorite',
              onTap: _toggleFavorite,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModeRow(_AudioPalette p) {
    return SizedBox(
      height: 34,
      child: Row(
        children: _LearningMode.values.map((mode) {
          final selected = _learningMode == mode;
          return Expanded(
            child: Padding(
              padding: EdgeInsets.only(
                right: mode == _LearningMode.review ? 0 : 6,
              ),
              child: InkWell(
                borderRadius: BorderRadius.circular(999),
                onTap: () => _setMode(mode),
                child: Container(
                  decoration: BoxDecoration(
                    color: selected
                        ? p.primary.withOpacity(0.16)
                        : p.cardBg.withOpacity(0.68),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: selected
                          ? p.primary.withOpacity(0.45)
                          : p.border.withOpacity(0.70),
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    _modeLabel(mode),
                    style: TextStyle(
                      color: p.text,
                      fontWeight: selected ? FontWeight.w900 : FontWeight.w700,
                      fontSize: 11,
                    ),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildCenterStage(_AudioPalette p, bool hasImage) {
    return Container(
      width: double.infinity,
      decoration: _glassDecoration(p),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (hasImage)
            ClipRRect(
              borderRadius: BorderRadius.circular(22),
              child: Image.network(
                widget.imageUrl.trim(),
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) =>
                    Container(color: p.soft.withOpacity(0.3)),
              ),
            )
          else
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                gradient: LinearGradient(
                  colors: [
                    p.primary.withOpacity(0.22),
                    p.accent.withOpacity(0.16),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
            ),
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              gradient: LinearGradient(
                colors: [
                  Colors.black.withOpacity(0.16),
                  Colors.black.withOpacity(0.30),
                ],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Column(
              children: [
                Row(
                  children: [
                    _overlayTag(
                      icon: Icons.graphic_eq_rounded,
                      label: _playerState == PlayerState.playing
                          ? 'Playing'
                          : 'Paused',
                    ),
                    const SizedBox(width: 6),
                    if (_isFavorite)
                      _overlayTag(icon: Icons.favorite_rounded, label: 'Saved'),
                    const Spacer(),
                    _overlayTag(
                      icon: Icons.bookmark_outline_rounded,
                      label: '${_bookmarks.length}',
                    ),
                  ],
                ),
                const Spacer(),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.28),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.white.withOpacity(0.12)),
                  ),
                  child: Text(
                    widget.title.trim().isEmpty
                        ? 'Audio Story'
                        : widget.title.trim(),
                    textAlign: TextAlign.center,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.95),
                      fontWeight: FontWeight.w900,
                      fontSize: _focusMode ? 18 : 16,
                      height: 1.2,
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

  Widget _buildBottomActionBar(_AudioPalette p) {
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          Expanded(
            child: _miniAction(
              p,
              icon: Icons.bookmark_add_rounded,
              label: 'Bookmark',
              onTap: _addBookmark,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: _miniAction(
              p,
              icon: Icons.note_add_rounded,
              label: 'Note',
              onTap: _showAddNoteSheet,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: _miniAction(
              p,
              icon: Icons.save_alt_rounded,
              label: 'Save',
              onTap: _saveMoment,
            ),
          ),
          const SizedBox(width: 6),
          PopupMenuButton<String>(
            padding: EdgeInsets.zero,
            onSelected: (value) async {
              switch (value) {
                case 'bookmarks':
                  await _showBookmarksSheet();
                  break;
                case 'saved':
                  await _showSavedItemsSheet();
                  break;
                case 'reload':
                  await _loadAudio();
                  break;
                case 'restart':
                  await _seekTo(0);
                  break;
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'bookmarks',
                child: Text('Open bookmarks'),
              ),
              const PopupMenuItem(
                value: 'saved',
                child: Text('Saved items / notes'),
              ),
              const PopupMenuItem(value: 'restart', child: Text('Restart')),
              const PopupMenuItem(value: 'reload', child: Text('Reload audio')),
            ],
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: p.cardBg.withOpacity(0.72),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: p.border.withOpacity(0.75)),
              ),
              child: Icon(Icons.more_horiz_rounded, color: p.text, size: 20),
            ),
          ),
        ],
      ),
    );
  }

  Widget _compactInfoChip(_AudioPalette p, IconData icon, String text) {
    return Expanded(
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: p.soft.withOpacity(0.58),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: p.border.withOpacity(0.65)),
        ),
        child: Row(
          children: [
            Icon(icon, color: p.primary, size: 14),
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: p.text,
                  fontWeight: FontWeight.w800,
                  fontSize: 10.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tinyPill(_AudioPalette p, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: p.primary.withOpacity(0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: p.border.withOpacity(0.65)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: p.text,
          fontWeight: FontWeight.w900,
          fontSize: 10.5,
        ),
      ),
    );
  }

  Widget _overlayTag({required IconData icon, required String label}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.28),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withOpacity(0.12)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 12),
          const SizedBox(width: 4),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: 10.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _miniAction(
    _AudioPalette p, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          height: double.infinity,
          decoration: BoxDecoration(
            color: p.cardBg.withOpacity(0.72),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: p.border.withOpacity(0.75)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: p.primary, size: 15),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: p.text,
                    fontWeight: FontWeight.w800,
                    fontSize: 10.5,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  BoxDecoration _glassDecoration(_AudioPalette p) {
    return BoxDecoration(
      color: p.cardBg.withOpacity(0.86),
      borderRadius: BorderRadius.circular(22),
      border: Border.all(color: p.border.withOpacity(0.82)),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withOpacity(0.05),
          blurRadius: 12,
          offset: const Offset(0, 6),
        ),
      ],
    );
  }

  Widget _fallbackCover() {
    return Container(
      width: 48,
      height: 48,
      color: Colors.white.withOpacity(0.12),
      child: const Icon(
        Icons.headphones_rounded,
        color: Colors.white,
        size: 24,
      ),
    );
  }

  static Widget _circleButton({
    required VoidCallback onTap,
    required IconData icon,
    required Color background,
    required Color foreground,
    double size = 44,
    double iconSize = 22,
  }) {
    return Material(
      color: background,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, color: foreground, size: iconSize),
        ),
      ),
    );
  }

  Widget _glassIconButton({
    required IconData icon,
    required VoidCallback onTap,
  }) {
    final p = palette;
    return Material(
      color: p.cardBg.withOpacity(0.72),
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 34,
          height: 34,
          child: Icon(icon, color: p.text, size: 18),
        ),
      ),
    );
  }
}

class _AudioPalette {
  const _AudioPalette({
    required this.primary,
    required this.accent,
    required this.text,
    required this.appBg,
    required this.cardBg,
    required this.border,
    required this.soft,
  });

  final Color primary;
  final Color accent;
  final Color text;
  final Color appBg;
  final Color cardBg;
  final Color border;
  final Color soft;
}
