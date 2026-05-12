import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';

import 'app_theme.dart';
import 'app_feedback.dart';
import 'story_audio_controller.dart';

class SharedPdfReaderScreen extends StatefulWidget {
  const SharedPdfReaderScreen({
    super.key,
    required this.title,
    required this.pdfUrl,
    this.audioController,
  });

  final String title;
  final String pdfUrl;
  final StoryAudioController? audioController;

  @override
  State<SharedPdfReaderScreen> createState() => _SharedPdfReaderScreenState();
}

class _SharedPdfReaderScreenState extends State<SharedPdfReaderScreen> {
  final PdfViewerController _pdfController = PdfViewerController();
  Timer? _chromeTimer;
  Orientation? _lastOrientation;
  int? _pendingRestorePage;

  bool _loading = true;
  String? _error;
  int _pageNumber = 0;
  int _pageCount = 0;
  bool _focusMode = true;
  int _viewerEpoch = 0;
  bool _audioPillExpanded = false;

  @override
  void initState() {
    super.initState();
    unawaited(_enterFullscreen());
  }

  _PdfPalette get palette => _toPdfPalette(appThemeController.palette);

  _PdfPalette _toPdfPalette(AppPalette p) {
    return _PdfPalette(
      primary: p.primary,
      accent: p.accent,
      text: p.text,
      appBg: p.appBg,
      cardBg: p.cardBg,
      border: p.border,
      soft: p.soft,
    );
  }

  bool get _hasDocument => _pageCount > 0 && _error == null;

  bool get _isChromeVisible => !_focusMode;

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

  Future<void> _showJumpToPageDialog() async {
    if (!_hasDocument) return;

    final controller = TextEditingController(
      text: _pageNumber > 0 ? '$_pageNumber' : '',
    );

    final result = await showDialog<int>(
      context: context,
      builder: (ctx) {
        final p = palette;
        return AlertDialog(
          backgroundColor: p.cardBg,
          title: Text(
            'Go to page',
            style: TextStyle(color: p.primary, fontWeight: FontWeight.w900),
          ),
          content: TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            autofocus: true,
            decoration: InputDecoration(
              hintText: 'Enter page number',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(
                'Cancel',
                style: TextStyle(
                  color: p.text.withValues(alpha: 0.75),
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            FilledButton(
              onPressed: () {
                final raw = controller.text.trim();
                final page = int.tryParse(raw);
                Navigator.of(ctx).pop(page);
              },
              child: const Text('Go'),
            ),
          ],
        );
      },
    );

    if (result == null) return;
    if (result < 1 || result > _pageCount) {
      if (!mounted) return;
      AppToast.fromSnackBar(
        context,
        SnackBar(content: Text('Enter a page between 1 and $_pageCount')),
      );
      return;
    }

    _pdfController.jumpToPage(result);
  }

  void _scheduleChromeAutoHide() {
    _chromeTimer?.cancel();
    if (!_isChromeVisible) return;
    _chromeTimer = Timer(const Duration(milliseconds: 2500), () {
      if (!mounted) return;
      setState(() {
        _focusMode = true;
      });
    });
  }

  void _toggleChrome() {
    setState(() {
      _focusMode = !_focusMode;
    });
    if (_isChromeVisible) {
      _scheduleChromeAutoHide();
    } else {
      _chromeTimer?.cancel();
    }
  }

  void _reloadPdf() {
    setState(() {
      _loading = true;
      _error = null;
      _pageNumber = 0;
      _pageCount = 0;
      _pendingRestorePage = null;
      _viewerEpoch++;
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final orientation = MediaQuery.orientationOf(context);
    if (_lastOrientation == null) {
      _lastOrientation = orientation;
      return;
    }

    if (_lastOrientation == orientation) return;
    _lastOrientation = orientation;

    _pendingRestorePage = _pageNumber > 0 ? _pageNumber : null;
    _loading = true;
    _error = null;
    _pageNumber = 0;
    _pageCount = 0;
    _viewerEpoch++;
  }

  @override
  void dispose() {
    _chromeTimer?.cancel();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Future<void> _enterFullscreen() async {
    try {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } catch (_) {}
  }

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (h > 0) return '$h:$m:$s';
    return '${d.inMinutes}:$s';
  }

  Widget _buildAudioPill(_PdfPalette p) {
    final controller = widget.audioController;
    if (controller == null || !controller.hasSource) {
      return const SizedBox.shrink();
    }

    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final isPlaying = controller.playerState.name == 'playing';
        final maxMs = controller.duration.inMilliseconds > 0
            ? controller.duration.inMilliseconds.toDouble()
            : 1.0;
        final value = controller.position.inMilliseconds
            .toDouble()
            .clamp(0, maxMs)
            .toDouble();

        return SafeArea(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              padding: EdgeInsets.fromLTRB(
                _audioPillExpanded ? 12 : 8,
                8,
                _audioPillExpanded ? 12 : 8,
                8,
              ),
              decoration: BoxDecoration(
                color: p.cardBg.withValues(alpha: 0.96),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: p.border.withValues(alpha: 0.9)),
              ),
              child: _audioPillExpanded
                  ? Row(
                      children: [
                        IconButton(
                          onPressed: controller.loading
                              ? null
                              : () => unawaited(controller.togglePlayPause()),
                          icon: Icon(
                            isPlaying
                                ? Icons.pause_circle_rounded
                                : Icons.play_circle_rounded,
                            color: p.primary,
                          ),
                        ),
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Slider(
                                value: value,
                                max: maxMs,
                                onChanged: (v) => unawaited(
                                  controller.seekTo(
                                    Duration(milliseconds: v.round()),
                                  ),
                                ),
                              ),
                              Text(
                                '${_formatDuration(controller.position)} / ${_formatDuration(controller.duration)}',
                                style: TextStyle(
                                  color: p.text,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: () {
                            setState(() {
                              _audioPillExpanded = false;
                            });
                          },
                          icon: Icon(
                            Icons.expand_more_rounded,
                            color: p.primary,
                          ),
                        ),
                      ],
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          onPressed: controller.loading
                              ? null
                              : () => unawaited(controller.togglePlayPause()),
                          icon: Icon(
                            isPlaying
                                ? Icons.pause_rounded
                                : Icons.play_arrow_rounded,
                            color: p.primary,
                          ),
                        ),
                        Text(
                          'Audio',
                          style: TextStyle(
                            color: p.primary,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        IconButton(
                          onPressed: () {
                            setState(() {
                              _audioPillExpanded = true;
                            });
                          },
                          icon: Icon(
                            Icons.expand_less_rounded,
                            color: p.primary,
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

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;

    return Scaffold(
      backgroundColor: p.appBg,
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () {
          _toggleChrome();
          unawaited(_enterFullscreen());
        },
        child: Stack(
          children: [
            Positioned.fill(
              child: SfPdfViewer.network(
                widget.pdfUrl,
                key: ValueKey('pdf_viewer_${_viewerEpoch}_${widget.pdfUrl}'),
                controller: _pdfController,
                canShowPaginationDialog: true,
                canShowScrollHead: true,
                canShowScrollStatus: true,
                enableDoubleTapZooming: true,
                pageLayoutMode: isLandscape
                    ? PdfPageLayoutMode.single
                    : PdfPageLayoutMode.continuous,
                scrollDirection: isLandscape
                    ? PdfScrollDirection.horizontal
                    : PdfScrollDirection.vertical,
                onDocumentLoaded: (details) {
                  if (!mounted) return;
                  final totalPages = details.document.pages.count;
                  final requestedPage = (_pendingRestorePage ?? 1).clamp(
                    1,
                    totalPages,
                  );
                  setState(() {
                    _loading = false;
                    _pageCount = totalPages;
                    _pageNumber = requestedPage;
                    _error = null;
                    _pendingRestorePage = null;
                  });

                  if (requestedPage > 1) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (!mounted) return;
                      _pdfController.jumpToPage(requestedPage);
                    });
                  }
                },
                onDocumentLoadFailed: (details) {
                  if (!mounted) return;
                  setState(() {
                    _loading = false;
                    _error = _humanPdfError(details.description);
                  });
                },
                onPageChanged: (details) {
                  if (!mounted) return;
                  setState(() {
                    _pageNumber = details.newPageNumber;
                  });
                  if (_isChromeVisible) {
                    _scheduleChromeAutoHide();
                  }
                },
              ),
            ),
            IgnorePointer(
              ignoring: !_isChromeVisible,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 170),
                opacity: _isChromeVisible ? 1 : 0,
                child: SafeArea(
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: Container(
                      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: p.cardBg.withValues(alpha: 0.94),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: p.border.withValues(alpha: 0.9),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Back',
                            onPressed: () => Navigator.of(context).maybePop(),
                            icon: Icon(
                              Icons.arrow_back_rounded,
                              color: p.primary,
                            ),
                          ),
                          Container(
                            margin: const EdgeInsets.symmetric(horizontal: 4),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 7,
                            ),
                            decoration: BoxDecoration(
                              color: p.soft,
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: p.border.withValues(alpha: 0.9),
                              ),
                            ),
                            child: Text(
                              _pageCount > 0
                                  ? '$_pageNumber / $_pageCount'
                                  : 'Loading',
                              style: TextStyle(
                                color: p.primary,
                                fontWeight: FontWeight.w900,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Go to page',
                            onPressed: _hasDocument
                                ? () async {
                                    _scheduleChromeAutoHide();
                                    await _showJumpToPageDialog();
                                  }
                                : null,
                            icon: Icon(
                              Icons.find_in_page_rounded,
                              color: p.primary,
                            ),
                          ),
                          IconButton(
                            tooltip: 'Refresh',
                            onPressed: _reloadPdf,
                            icon: Icon(Icons.refresh_rounded, color: p.primary),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (_loading)
              Positioned.fill(
                child: Container(
                  color: p.appBg.withValues(alpha: 0.72),
                  alignment: Alignment.center,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      color: p.cardBg,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: p.border.withValues(alpha: 0.85),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.4,
                            color: p.primary,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          'Loading',
                          style: TextStyle(
                            color: p.primary,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (_error != null)
              Positioned.fill(
                child: Container(
                  color: p.appBg.withValues(alpha: 0.9),
                  alignment: Alignment.center,
                  padding: const EdgeInsets.all(20),
                  child: Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(maxWidth: 520),
                    padding: const EdgeInsets.all(22),
                    decoration: BoxDecoration(
                      color: p.cardBg,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: p.border.withValues(alpha: 0.85),
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.error_outline_rounded,
                          size: 40,
                          color: p.accent,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Could not open PDF',
                          style: TextStyle(
                            color: p.primary,
                            fontWeight: FontWeight.w900,
                            fontSize: 18,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: p.text,
                            fontWeight: FontWeight.w700,
                            height: 1.45,
                          ),
                        ),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: _reloadPdf,
                          icon: const Icon(Icons.refresh_rounded),
                          label: const Text('Try Again'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            Positioned.fill(child: _buildAudioPill(p)),
          ],
        ),
      ),
    );
  }
}

class _PdfPalette {
  const _PdfPalette({
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
