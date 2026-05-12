import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'app_theme.dart';

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
  int? _pdfProgress;
  String? _localPdfPath;

  WebViewController? _htmlController;
  bool _htmlLoading = true;
  String? _htmlError;
  int _htmlProgress = 0;

  bool _readerExpanded = false;

  bool get _hasAudio => widget.audioUrl.trim().isNotEmpty;
  bool get _hasPdf => widget.pdfUrl.trim().isNotEmpty;
  bool get _hasHtml => widget.htmlUrl.trim().isNotEmpty;

  _StudyPalette get palette => _toStudyPalette(appThemeController.palette);

  static const Duration _audioLoadTimeout = Duration(seconds: 30);

  @override
  void initState() {
    super.initState();
    _bindAudio();
    if (_hasAudio) {
      unawaited(_loadAudio());
    }
    if (_hasHtml && !kIsWeb) {
      _setupInlineHtml();
    }
    if (_hasPdf) {
      unawaited(_preparePdf());
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
      await _player
          .setSourceUrl(widget.audioUrl.trim())
          .timeout(_audioLoadTimeout);
      await _player.setPlaybackRate(_speed).timeout(const Duration(seconds: 8));
      await _player
          .setReleaseMode(ReleaseMode.stop)
          .timeout(const Duration(seconds: 8));
      if (!mounted) return;
      setState(() {
        _audioLoading = false;
      });
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        _audioLoading = false;
        _audioError =
            'Audio is taking too long to load. Check your internet and try again.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _audioLoading = false;
        _audioError = _humanAudioError(e);
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
        _audioError = _humanAudioError(e, fallback: 'Could not play audio.');
      });
    }
  }

  String _humanAudioError(Object error, {String? fallback}) {
    final raw = error.toString();
    final low = raw.toLowerCase();

    if (low.contains('timeoutexception') || low.contains('timeout')) {
      return 'Audio is taking too long to load. Check your internet and try again.';
    }
    if (low.contains('socket') || low.contains('network')) {
      return 'Network issue while loading audio. Please try again.';
    }
    if (low.contains('source') || low.contains('url') || low.contains('404')) {
      return 'Audio file is not available right now.';
    }

    return fallback ?? 'Could not load audio. Please try again.';
  }

  String _humanPdfError(String raw) {
    final low = raw.toLowerCase();
    if (low.contains('timeout')) {
      return 'Loading is taking too long. Check your internet and try again.';
    }
    if (low.contains('socket') || low.contains('network')) {
      return 'Network issue while loading the file. Please try again.';
    }
    if (low.contains('404') || low.contains('not found')) {
      return 'This file is not available right now.';
    }
    return 'Could not open this file. Please try again.';
  }

  String _humanHtmlError(String raw) {
    final low = raw.toLowerCase();
    if (low.contains('timeout')) {
      return 'Loading is taking too long. Check your internet and try again.';
    }
    if (low.contains('socket') || low.contains('network')) {
      return 'Network issue while loading the page. Please try again.';
    }
    if (low.contains('404') || low.contains('not found')) {
      return 'This page is not available right now.';
    }
    return 'Could not open this page. Please try again.';
  }

  Color _thumbAccent(_StudyPalette p) {
    final seed = widget.thumbnailUrl.trim().isEmpty
        ? widget.title
        : widget.thumbnailUrl.trim();
    final hue = seed.hashCode.abs() % 360;
    return HSVColor.fromAHSV(1, hue.toDouble(), 0.74, 0.92).toColor();
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

  Future<void> _preparePdf({bool forceRefresh = false}) async {
    final url = widget.pdfUrl.trim();
    if (url.isEmpty) return;
    try {
      final cacheDir = await getTemporaryDirectory();
      final digest = sha1.convert(utf8.encode(url)).toString();
      final file = File('${cacheDir.path}/story_pdf_$digest.pdf');

      if (!forceRefresh && await file.exists()) {
        if (!mounted) return;
        setState(() {
          _localPdfPath = file.path;
          _pdfLoading = false;
          _pdfError = null;
          _pdfProgress = 100;
        });
        return;
      }

      if (!mounted) return;
      setState(() {
        _pdfLoading = true;
        _pdfError = null;
        _pdfProgress = 0;
      });

      final request = http.Request('GET', Uri.parse(url));
      final response = await http.Client().send(request);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('status ${response.statusCode}');
      }
      final sink = file.openWrite();
      final total = response.contentLength ?? 0;
      var received = 0;

      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0 && mounted) {
          setState(() {
            _pdfProgress = ((received / total) * 100).clamp(0, 100).round();
          });
        }
      }
      await sink.flush();
      await sink.close();

      if (!mounted) return;
      setState(() {
        _localPdfPath = file.path;
        _pdfLoading = false;
        _pdfError = null;
        _pdfProgress = 100;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _pdfLoading = false;
        _pdfError = _humanPdfError(e.toString());
      });
    }
  }

  void _setupInlineHtml() {
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..enableZoom(true)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (!mounted) return;
            setState(() {
              _htmlLoading = true;
              _htmlError = null;
              _htmlProgress = 0;
            });
          },
          onProgress: (progress) {
            if (!mounted) return;
            setState(() {
              _htmlProgress = progress;
            });
          },
          onPageFinished: (_) {
            if (!mounted) return;
            setState(() {
              _htmlLoading = false;
              _htmlError = null;
              _htmlProgress = 100;
            });
          },
          onWebResourceError: (error) {
            if (!mounted) return;
            setState(() {
              _htmlLoading = false;
              _htmlError = _humanHtmlError(error.description);
            });
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.htmlUrl.trim()));

    _htmlController = controller;
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
    final accent = _thumbAccent(p);
    final width = MediaQuery.sizeOf(context).width;
    final compact = width < 390;
    final pdfHeight = _readerExpanded
        ? MediaQuery.sizeOf(context).height - 130
        : (compact ? 360.0 : 480.0);
    final title = widget.title.trim().isEmpty
        ? 'Story Study'
        : widget.title.trim();

    return PopScope(
      canPop: !_readerExpanded,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || !_readerExpanded) return;
        setState(() {
          _readerExpanded = false;
        });
      },
      child: Scaffold(
        backgroundColor: p.appBg,
        appBar: AppBar(
          backgroundColor: accent.withValues(alpha: 0.45),
          surfaceTintColor: accent.withValues(alpha: 0.45),
          leading: _readerExpanded
              ? IconButton(
                  icon: const Icon(Icons.arrow_back_rounded),
                  onPressed: () {
                    setState(() {
                      _readerExpanded = false;
                    });
                  },
                )
              : null,
          title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        body: SafeArea(
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [accent.withValues(alpha: 0.12), p.appBg],
              ),
            ),
            child: ListView(
              physics: _readerExpanded
                  ? const NeverScrollableScrollPhysics()
                  : const BouncingScrollPhysics(),
              padding: EdgeInsets.fromLTRB(
                compact ? 10 : 12,
                12,
                compact ? 10 : 12,
                _readerExpanded ? 0 : 20,
              ),
              children: [
                if (_hasAudio && !_readerExpanded) ...[
                  _buildAudioCard(p, compact),
                  const SizedBox(height: 12),
                ],
                if (_hasHtml) ...[_buildHtmlViewerCard(p, pdfHeight, compact)],
                if (!_hasHtml && _hasPdf) ...[
                  _buildPdfCard(p, pdfHeight, compact),
                ],
                if (!_hasHtml && !_hasPdf) _buildEmptyCard(p, compact),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyCard(_StudyPalette p, bool compact) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: p.border.withValues(alpha: 0.9)),
      ),
      child: Text(
        'No readable content available.',
        style: TextStyle(color: p.text, fontSize: compact ? 12 : 14),
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
      padding: EdgeInsets.all(_readerExpanded ? 0 : 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!_readerExpanded)
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 6,
              children: [
                Icon(Icons.picture_as_pdf_rounded, color: p.accent),
                Text(
                  _pageCount > 0
                      ? 'Page $_pageNumber of $_pageCount'
                      : (_pdfProgress == null
                            ? 'Loading'
                            : 'Loading ${_pdfProgress!}%'),
                  style: TextStyle(
                    color: p.primary,
                    fontWeight: FontWeight.w800,
                    fontSize: compact ? 12 : 14,
                  ),
                ),
                const Spacer(),
                IconButton(
                  onPressed: () {
                    setState(() {
                      _readerExpanded = true;
                    });
                  },
                  icon: Icon(Icons.fullscreen_rounded, color: p.primary),
                ),
              ],
            ),
          if (!_readerExpanded) const SizedBox(height: 8),
          SizedBox(
            height: pdfHeight,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: _localPdfPath == null
                  ? Container(
                      color: p.soft,
                      alignment: Alignment.center,
                      child: Text(
                        _pdfProgress == null
                            ? 'Loading'
                            : 'Loading ${_pdfProgress!}%',
                        style: TextStyle(
                          color: p.text,
                          fontWeight: FontWeight.w700,
                          fontSize: compact ? 12 : 14,
                        ),
                      ),
                    )
                  : SfPdfViewer.file(
                      File(_localPdfPath!),
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
                          _pdfProgress = 100;
                        });
                      },
                      onDocumentLoadFailed: (details) {
                        if (!mounted) return;
                        setState(() {
                          _pdfLoading = false;
                          _pdfError = _humanPdfError(details.description);
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
                'Loading',
                style: TextStyle(color: p.text, fontSize: compact ? 12 : 14),
              ),
            ),
          if (_pdfError != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _pdfError!,
                      style: TextStyle(
                        color: p.accent,
                        fontWeight: FontWeight.w700,
                        fontSize: compact ? 12 : 14,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: () {
                      unawaited(_preparePdf(forceRefresh: true));
                    },
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          if (!_readerExpanded && _pageCount > 0) ...[
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pageNumber > 1
                        ? () => _pdfController.previousPage()
                        : null,
                    icon: const Icon(Icons.chevron_left_rounded),
                    label: const Text('Back'),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    '$_pageNumber / $_pageCount',
                    style: TextStyle(
                      color: p.primary,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _pageNumber < _pageCount
                        ? () => _pdfController.nextPage()
                        : null,
                    icon: const Icon(Icons.chevron_right_rounded),
                    label: const Text('Next'),
                  ),
                ),
              ],
            ),
          ],
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
      padding: EdgeInsets.all(compact ? 10 : 12),
      child: Column(
        children: [
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
          const SizedBox(height: 4),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _iconControl(
                  icon: _playerState == PlayerState.playing
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  onTap: _togglePlayPause,
                  color: _playerState == PlayerState.playing
                      ? const Color(0xFFEF6C00)
                      : p.primary,
                ),
                const SizedBox(width: 8),
                _iconControl(
                  icon: Icons.repeat_rounded,
                  onTap: () {
                    setState(() {
                      _repeatMode = _repeatMode == _RepeatMode.off
                          ? _RepeatMode.one
                          : _RepeatMode.off;
                    });
                  },
                  color: _repeatMode == _RepeatMode.one
                      ? p.accent
                      : p.text.withValues(alpha: 0.70),
                ),
                const SizedBox(width: 8),
                for (final speed in const <double>[0.75, 1.0, 1.25]) ...[
                  _iconControl(
                    icon: speed < 1
                        ? Icons.keyboard_double_arrow_left_rounded
                        : speed > 1
                        ? Icons.keyboard_double_arrow_right_rounded
                        : Icons.speed_rounded,
                    onTap: () => _setSpeed(speed),
                    color: _speed == speed
                        ? p.accent
                        : p.text.withValues(alpha: 0.70),
                  ),
                  const SizedBox(width: 8),
                ],
              ],
            ),
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
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _audioError!,
                      style: TextStyle(
                        color: p.accent,
                        fontSize: compact ? 12 : 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(onPressed: _loadAudio, child: const Text('Retry')),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _iconControl({
    required IconData icon,
    required VoidCallback onTap,
    required Color color,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Container(
        width: 46,
        height: 40,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.44)),
        ),
        child: Icon(icon, color: color, size: 22),
      ),
    );
  }

  Widget _buildHtmlViewerCard(
    _StudyPalette p,
    double viewerHeight,
    bool compact,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: p.cardBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: p.border.withValues(alpha: 0.9)),
      ),
      padding: EdgeInsets.all(_readerExpanded ? 0 : 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!_readerExpanded)
            Row(
              children: [
                Icon(Icons.language_rounded, color: p.accent),
                const SizedBox(width: 8),
                Text(
                  _htmlLoading
                      ? (_htmlProgress > 0
                            ? 'Loading $_htmlProgress%'
                            : 'Loading')
                      : 'Reading',
                  style: TextStyle(
                    color: p.primary,
                    fontWeight: FontWeight.w800,
                    fontSize: compact ? 12 : 14,
                  ),
                ),
                const Spacer(),
                IconButton(
                  onPressed: () {
                    setState(() {
                      _readerExpanded = true;
                    });
                  },
                  icon: Icon(Icons.fullscreen_rounded, color: p.primary),
                ),
              ],
            ),
          if (!_readerExpanded) const SizedBox(height: 8),
          SizedBox(
            height: viewerHeight,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: kIsWeb
                  ? Container(
                      color: p.soft,
                      alignment: Alignment.center,
                      child: Text(
                        'Loading',
                        style: TextStyle(
                          color: p.text,
                          fontWeight: FontWeight.w700,
                          fontSize: compact ? 12 : 14,
                        ),
                      ),
                    )
                  : (_htmlController == null
                        ? Container(
                            color: p.soft,
                            alignment: Alignment.center,
                            child: Text(
                              'Loading',
                              style: TextStyle(
                                color: p.text,
                                fontWeight: FontWeight.w700,
                                fontSize: compact ? 12 : 14,
                              ),
                            ),
                          )
                        : WebViewWidget(controller: _htmlController!)),
            ),
          ),
          if (_htmlLoading)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Loading',
                style: TextStyle(color: p.text, fontSize: compact ? 12 : 14),
              ),
            ),
          if (_htmlError != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _htmlError!,
                      style: TextStyle(
                        color: p.accent,
                        fontSize: compact ? 12 : 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: () {
                      if (_hasHtml && !_hasPdf && !kIsWeb) {
                        setState(() {
                          _htmlLoading = true;
                          _htmlError = null;
                          _htmlProgress = 0;
                        });
                        _setupInlineHtml();
                      }
                    },
                    child: const Text('Retry'),
                  ),
                ],
              ),
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
