import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';

import 'app_theme.dart';
import 'material_webview_screen.dart';

class SharedStoryStudyScreen extends StatefulWidget {
  const SharedStoryStudyScreen({
    super.key,
    required this.title,
    this.thumbnailUrl = '',
    this.audioUrl = '',
    this.pdfUrl = '',
    this.htmlUrl = '',
  });

  final String title;
  final String thumbnailUrl;
  final String audioUrl;
  final String pdfUrl;
  final String htmlUrl;

  @override
  State<SharedStoryStudyScreen> createState() => _SharedStoryStudyScreenState();
}

enum _RepeatMode { off, one }

class _SharedStoryStudyScreenState extends State<SharedStoryStudyScreen> {
  final AudioPlayer _player = AudioPlayer();
  final PdfViewerController _pdfController = PdfViewerController();

  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<void>? _completeSub;

  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  PlayerState _playerState = PlayerState.stopped;
  double _speed = 1.0;
  _RepeatMode _repeatMode = _RepeatMode.off;

  bool _audioLoading = false;
  String? _audioError;

  bool _pdfLoading = true;
  String? _pdfError;
  int _pageNumber = 1;
  int _pageCount = 0;

  bool get _hasAudio => widget.audioUrl.trim().isNotEmpty;
  bool get _hasPdf => widget.pdfUrl.trim().isNotEmpty;
  bool get _hasHtml => widget.htmlUrl.trim().isNotEmpty;

  _StudyPalette get palette => _toStudyPalette(appThemeController.palette);

  @override
  void initState() {
    super.initState();
    _bindAudio();
    if (_hasAudio) {
      unawaited(_loadAudio());
    }
  }

  @override
  void dispose() {
    _durationSub?.cancel();
    _positionSub?.cancel();
    _stateSub?.cancel();
    _completeSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  _StudyPalette _toStudyPalette(AppPalette p) {
    return _StudyPalette(
      primary: p.primary,
      accent: p.accent,
      text: p.text,
      appBg: p.appBg,
      cardBg: p.cardBg,
      border: p.border,
      soft: p.soft,
    );
  }

  void _bindAudio() {
    _durationSub = _player.onDurationChanged.listen((d) {
      if (!mounted) return;
      setState(() {
        _duration = d;
      });
    });

    _positionSub = _player.onPositionChanged.listen((p) {
      if (!mounted) return;
      setState(() {
        _position = p;
      });
    });

    _stateSub = _player.onPlayerStateChanged.listen((s) {
      if (!mounted) return;
      setState(() {
        _playerState = s;
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
        _audioLoading = true;
        _audioError = null;
      });
      await _player.setSourceUrl(widget.audioUrl.trim());
      await _player.setPlaybackRate(_speed);
      await _player.setReleaseMode(ReleaseMode.stop);
      if (!mounted) return;
      setState(() {
        _audioLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _audioLoading = false;
        _audioError = 'Could not load audio.\n$e';
      });
    }
  }

  Future<void> _togglePlayPause() async {
    if (!_hasAudio || _audioLoading) return;
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
        _audioError = 'Playback failed.\n$e';
      });
    }
  }

  Future<void> _setSpeed(double speed) async {
    try {
      await _player.setPlaybackRate(speed);
      if (!mounted) return;
      setState(() {
        _speed = speed;
      });
    } catch (_) {}
  }

  Future<void> _seekTo(double ms) async {
    await _player.seek(Duration(milliseconds: ms.round()));
  }

  Future<void> _openHtmlInsideApp() async {
    if (!_hasHtml) return;
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MaterialWebViewScreen.fromUrl(
          title: widget.title.trim().isEmpty ? 'Story Material' : widget.title,
          url: widget.htmlUrl.trim(),
        ),
      ),
    );
  }

  String _format(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (h > 0) return '$h:$m:$s';
    return '${d.inMinutes}:$s';
  }

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final width = MediaQuery.sizeOf(context).width;
    final compact = width < 390;
    final thumbnailHeight = compact ? 152.0 : 180.0;
    final pdfHeight = compact ? 360.0 : 480.0;
    final title = widget.title.trim().isEmpty
        ? 'Story Study'
        : widget.title.trim();

    return Scaffold(
      backgroundColor: p.appBg,
      appBar: AppBar(
        backgroundColor: p.cardBg,
        surfaceTintColor: p.cardBg,
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: SafeArea(
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            compact ? 10 : 12,
            12,
            compact ? 10 : 12,
            20,
          ),
          children: [
            _buildThumbnailCard(p, title, thumbnailHeight, compact),
            if (_hasPdf) ...[
              const SizedBox(height: 12),
              _buildPdfCard(p, pdfHeight, compact),
            ],
            if (_hasAudio) ...[
              const SizedBox(height: 12),
              _buildAudioCard(p, compact),
            ],
            if (!_hasPdf && !_hasAudio && _hasHtml) ...[
              const SizedBox(height: 12),
              _buildHtmlCard(p),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildThumbnailCard(
    _StudyPalette p,
    String title,
    double height,
    bool compact,
  ) {
    final hasImage = widget.thumbnailUrl.trim().isNotEmpty;
    return Container(
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: p.border.withValues(alpha: 0.85)),
        gradient: LinearGradient(
          colors: [
            p.primary.withValues(alpha: 0.25),
            p.accent.withValues(alpha: 0.22),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (hasImage)
            Image.network(
              widget.thumbnailUrl.trim(),
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          Container(color: Colors.black.withValues(alpha: 0.28)),
          Align(
            alignment: Alignment.bottomLeft,
            child: Padding(
              padding: EdgeInsets.all(compact ? 10 : 14),
              child: Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: compact ? 16 : 18,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPdfCard(_StudyPalette p, double pdfHeight, bool compact) {
    return Container(
      decoration: BoxDecoration(
        color: p.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: p.border.withValues(alpha: 0.9)),
      ),
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 6,
            children: [
              Icon(Icons.picture_as_pdf_rounded, color: p.accent),
              Text(
                _pageCount > 0
                    ? 'Page $_pageNumber / $_pageCount'
                    : 'Loading PDF...',
                style: TextStyle(
                  color: p.primary,
                  fontWeight: FontWeight.w800,
                  fontSize: compact ? 12 : 14,
                ),
              ),
              if (_hasHtml)
                TextButton.icon(
                  onPressed: _openHtmlInsideApp,
                  icon: const Icon(Icons.open_in_browser_rounded),
                  label: Text(
                    'HTML',
                    style: TextStyle(fontSize: compact ? 11 : 13),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: pdfHeight,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: SfPdfViewer.network(
                widget.pdfUrl.trim(),
                controller: _pdfController,
                canShowPaginationDialog: false,
                canShowScrollHead: false,
                canShowScrollStatus: false,
                enableDoubleTapZooming: true,
                pageLayoutMode: PdfPageLayoutMode.single,
                scrollDirection: PdfScrollDirection.horizontal,
                onDocumentLoaded: (details) {
                  if (!mounted) return;
                  setState(() {
                    _pdfLoading = false;
                    _pdfError = null;
                    _pageCount = details.document.pages.count;
                    _pageNumber = _pageCount > 0 ? 1 : 0;
                  });
                },
                onDocumentLoadFailed: (details) {
                  if (!mounted) return;
                  setState(() {
                    _pdfLoading = false;
                    _pdfError = details.description;
                  });
                },
                onPageChanged: (details) {
                  if (!mounted) return;
                  setState(() {
                    _pageNumber = details.newPageNumber;
                  });
                },
              ),
            ),
          ),
          if (_pdfLoading)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Opening PDF...',
                style: TextStyle(color: p.text, fontSize: compact ? 12 : 14),
              ),
            ),
          if (_pdfError != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _pdfError!,
                style: TextStyle(
                  color: p.accent,
                  fontWeight: FontWeight.w700,
                  fontSize: compact ? 12 : 14,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildAudioCard(_StudyPalette p, bool compact) {
    return Container(
      decoration: BoxDecoration(
        color: p.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: p.border.withValues(alpha: 0.9)),
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 6,
            children: [
              Icon(Icons.headphones_rounded, color: p.primary),
              Text(
                'Listening',
                style: TextStyle(
                  color: p.primary,
                  fontWeight: FontWeight.w900,
                  fontSize: compact ? 13 : 15,
                ),
              ),
              Text(
                _repeatMode == _RepeatMode.one ? 'Repeat: One' : 'Repeat: Off',
                style: TextStyle(color: p.text, fontSize: compact ? 12 : 14),
              ),
            ],
          ),
          Slider(
            value: _position.inMilliseconds.toDouble().clamp(
              0,
              _duration.inMilliseconds > 0
                  ? _duration.inMilliseconds.toDouble()
                  : 1,
            ),
            max: _duration.inMilliseconds > 0
                ? _duration.inMilliseconds.toDouble()
                : 1,
            onChanged: (value) => _seekTo(value),
          ),
          Row(
            children: [
              Text(
                _format(_position),
                style: TextStyle(color: p.text, fontSize: compact ? 12 : 14),
              ),
              const Spacer(),
              Text(
                _format(_duration),
                style: TextStyle(color: p.text, fontSize: compact ? 12 : 14),
              ),
            ],
          ),
          const SizedBox(height: 8),
          compact
              ? Column(
                  children: [
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _togglePlayPause,
                        icon: Icon(
                          _playerState == PlayerState.playing
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                        ),
                        label: Text(
                          _playerState == PlayerState.playing
                              ? 'Pause'
                              : 'Play',
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () {
                          setState(() {
                            _repeatMode = _repeatMode == _RepeatMode.off
                                ? _RepeatMode.one
                                : _RepeatMode.off;
                          });
                        },
                        icon: const Icon(Icons.repeat_rounded),
                        label: Text(
                          _repeatMode == _RepeatMode.off
                              ? 'Repeat Off'
                              : 'Repeat One',
                        ),
                      ),
                    ),
                  ],
                )
              : Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _togglePlayPause,
                        icon: Icon(
                          _playerState == PlayerState.playing
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                        ),
                        label: Text(
                          _playerState == PlayerState.playing
                              ? 'Pause'
                              : 'Play',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          setState(() {
                            _repeatMode = _repeatMode == _RepeatMode.off
                                ? _RepeatMode.one
                                : _RepeatMode.off;
                          });
                        },
                        icon: const Icon(Icons.repeat_rounded),
                        label: Text(
                          _repeatMode == _RepeatMode.off
                              ? 'Repeat Off'
                              : 'Repeat One',
                        ),
                      ),
                    ),
                  ],
                ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final speed in const <double>[0.75, 1.0, 1.25])
                ChoiceChip(
                  label: Text(
                    '${speed}x',
                    style: TextStyle(fontSize: compact ? 11 : 13),
                  ),
                  selected: _speed == speed,
                  onSelected: (_) => _setSpeed(speed),
                ),
            ],
          ),
          if (_audioLoading)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Loading audio...',
                style: TextStyle(color: p.text, fontSize: compact ? 12 : 14),
              ),
            ),
          if (_audioError != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _audioError!,
                style: TextStyle(color: p.accent, fontSize: compact ? 12 : 14),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildHtmlCard(_StudyPalette p) {
    return Container(
      decoration: BoxDecoration(
        color: p.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: p.border.withValues(alpha: 0.9)),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'This story is HTML material.',
            style: TextStyle(color: p.primary, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          FilledButton.icon(
            onPressed: _openHtmlInsideApp,
            icon: const Icon(Icons.open_in_browser_rounded),
            label: const Text('Open Material'),
          ),
        ],
      ),
    );
  }
}

class _StudyPalette {
  const _StudyPalette({
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
