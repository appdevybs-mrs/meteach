import 'dart:async';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

class MaterialIssueReport {
  const MaterialIssueReport({
    required this.title,
    required this.originalSource,
    required this.currentUrl,
    required this.note,
    required this.pageTitle,
    required this.lastError,
    required this.createdAt,
  });

  final String title;
  final String originalSource;
  final String currentUrl;
  final String note;
  final String? pageTitle;
  final String? lastError;
  final DateTime createdAt;

  String toMessage() {
    final lines = <String>[
      'Material issue report',
      'Title: $title',
      'Original source: $originalSource',
      'Current URL: $currentUrl',
      if ((pageTitle ?? '').trim().isNotEmpty) 'Page title: ${pageTitle!.trim()}',
      if ((lastError ?? '').trim().isNotEmpty) 'Last error: ${lastError!.trim()}',
      'Time: ${createdAt.toIso8601String()}',
      '',
      'Teacher note:',
      note.trim().isEmpty ? '(No note added)' : note.trim(),
    ];
    return lines.join('\n');
  }
}

class MaterialWebViewScreen extends StatefulWidget {
  const MaterialWebViewScreen.fromUrl({
    super.key,
    required this.title,
    required this.url,
    this.headers = const <String, String>{},
    this.allowReporting = true,
    this.onReportIssue,
  })  : htmlString = null,
        assetPath = null;

  const MaterialWebViewScreen.fromAsset({
    super.key,
    required this.title,
    required this.assetPath,
    this.allowReporting = true,
    this.onReportIssue,
  })  : url = null,
        htmlString = null,
        headers = const <String, String>{};

  const MaterialWebViewScreen.fromHtmlString({
    super.key,
    required this.title,
    required this.htmlString,
    this.allowReporting = true,
    this.onReportIssue,
  })  : url = null,
        assetPath = null,
        headers = const <String, String>{};

  final String title;
  final String? url;
  final String? assetPath;
  final String? htmlString;
  final Map<String, String> headers;

  final bool allowReporting;
  final Future<void> Function(MaterialIssueReport report)? onReportIssue;

  bool get isUrl => url != null && url!.trim().isNotEmpty;
  bool get isAsset => assetPath != null && assetPath!.trim().isNotEmpty;
  bool get isHtmlString => htmlString != null && htmlString!.trim().isNotEmpty;

  @override
  State<MaterialWebViewScreen> createState() => _MaterialWebViewScreenState();
}

class _MaterialWebViewScreenState extends State<MaterialWebViewScreen> {
  late final WebViewController _controller;

  int _progress = 0;
  bool _isLoading = true;
  bool _canGoBack = false;
  bool _canGoForward = false;
  String? _currentUrl;
  String? _pageTitle;
  String? _lastError;

  bool _isFullscreen = false;
  int _fontScalePercent = 100;
  bool _didApplyInitialEnhancements = false;

  static const List<int> _fontScaleSteps = <int>[90, 100, 110, 125, 140];

  @override
  void initState() {
    super.initState();
    _setupController();
    unawaited(_loadInitialContent());
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  void _setupController() {
    late final PlatformWebViewControllerCreationParams params;

    if (WebViewPlatform.instance is WebKitWebViewPlatform) {
      params = WebKitWebViewControllerCreationParams(
        allowsInlineMediaPlayback: true,
        mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
      );
    } else {
      params = const PlatformWebViewControllerCreationParams();
    }

    final controller = WebViewController.fromPlatformCreationParams(params)
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..enableZoom(true)
      ..setBackgroundColor(const Color(0xFFFFFFFF))
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            if (!mounted) return;
            setState(() {
              _isLoading = true;
              _lastError = null;
              _currentUrl = url;
              _didApplyInitialEnhancements = false;
            });
            unawaited(_refreshNavState());
          },
          onProgress: (progress) {
            if (!mounted) return;
            setState(() {
              _progress = progress.clamp(0, 100);
            });
          },
          onPageFinished: (url) async {
            final title = await _safeGetTitle();
            if (!mounted) return;
            setState(() {
              _isLoading = false;
              _progress = 100;
              _currentUrl = url;
              _pageTitle = title;
            });

            await _applyViewerEnhancementsIfNeeded();
            unawaited(_refreshNavState());
          },
          onWebResourceError: (error) {
            if (!mounted) return;
            setState(() {
              _isLoading = false;
              _lastError = error.description.isEmpty
                  ? 'Failed to load content.'
                  : 'Failed to load content.\n${error.description}';
            });
          },
          onNavigationRequest: (request) {
            final url = request.url.trim();
            final uri = Uri.tryParse(url);

            if (uri == null) {
              return NavigationDecision.navigate;
            }

            final scheme = uri.scheme.toLowerCase();

            if (scheme == 'http' ||
                scheme == 'https' ||
                scheme == 'file' ||
                scheme == 'about' ||
                scheme == 'data') {
              return NavigationDecision.navigate;
            }

            return NavigationDecision.prevent;
          },
        ),
      );

    if (controller.platform is AndroidWebViewController) {
      (controller.platform as AndroidWebViewController)
          .setMediaPlaybackRequiresUserGesture(false);
    }

    _controller = controller;
  }

  Future<void> _loadInitialContent() async {
    try {
      if (widget.isUrl) {
        final uri = Uri.tryParse(widget.url!.trim());
        if (uri == null) {
          setState(() {
            _lastError = 'Invalid URL.';
            _isLoading = false;
          });
          return;
        }
        await _controller.loadRequest(uri, headers: widget.headers);
      } else if (widget.isAsset) {
        await _controller.loadFlutterAsset(widget.assetPath!.trim());
      } else if (widget.isHtmlString) {
        await _controller.loadHtmlString(widget.htmlString!.trim());
      } else {
        setState(() {
          _lastError = 'No content source was provided.';
          _isLoading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _lastError = 'Failed to open content.\n$e';
        _isLoading = false;
      });
    }
  }

  Future<String?> _safeGetTitle() async {
    try {
      return await _controller.getTitle();
    } catch (_) {
      return null;
    }
  }

  Future<void> _refreshNavState() async {
    try {
      final canBack = await _controller.canGoBack();
      final canForward = await _controller.canGoForward();
      final url = await _controller.currentUrl();

      if (!mounted) return;
      setState(() {
        _canGoBack = canBack;
        _canGoForward = canForward;
        _currentUrl = url;
      });
    } catch (_) {}
  }

  Future<void> _reload() async {
    setState(() {
      _lastError = null;
      _isLoading = true;
      _progress = 0;
      _didApplyInitialEnhancements = false;
    });
    await _controller.reload();
  }

  String _sourceLabel() {
    if (widget.isUrl) return widget.url!.trim();
    if (widget.isAsset) return widget.assetPath!.trim();
    if (widget.isHtmlString) return 'inline_html_string';
    return 'unknown_source';
  }

  Future<void> _showReportDialog() async {
    final noteController = TextEditingController();

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        bool sending = false;

        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              title: const Text('Report material issue'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.title,
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Use this to report a broken lesson, missing media, bad layout, or interaction problem.',
                    style: TextStyle(
                      color: Colors.grey.shade700,
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: noteController,
                    minLines: 4,
                    maxLines: 7,
                    decoration: const InputDecoration(
                      labelText: 'What is wrong?',
                      hintText: 'Example: audio does not play, buttons are hidden, slides are too small...',
                      border: OutlineInputBorder(),
                      alignLabelWithHint: true,
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: sending ? null : () => Navigator.pop(ctx, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: sending
                      ? null
                      : () async {
                    setLocal(() => sending = true);

                    try {
                      final report = MaterialIssueReport(
                        title: widget.title,
                        originalSource: _sourceLabel(),
                        currentUrl: (_currentUrl ?? widget.url ?? '').trim(),
                        note: noteController.text,
                        pageTitle: _pageTitle,
                        lastError: _lastError,
                        createdAt: DateTime.now(),
                      );

                      if (widget.onReportIssue != null) {
                        await widget.onReportIssue!(report);
                      }

                      if (!mounted) return;
                      Navigator.pop(ctx, true);
                    } catch (_) {
                      if (!mounted) return;
                      setLocal(() => sending = false);
                    }
                  },
                  child: Text(sending ? 'Sending...' : 'Send report'),
                ),
              ],
            );
          },
        );
      },
    );

    if (ok == true && mounted) {
      FocusScope.of(context).unfocus();
    }
  }

  Future<void> _applyViewerEnhancementsIfNeeded() async {
    if (_didApplyInitialEnhancements) return;
    _didApplyInitialEnhancements = true;

    await _injectBaseLessonSupport();
    await _applyFontScale(_fontScalePercent);
    await _forceLessonFit();
  }

  Future<void> _injectBaseLessonSupport() async {
    final script = '''
(function () {
  try {
    var styleId = 'dea_viewer_support_style';
    var style = document.getElementById(styleId);
    if (!style) {
      style = document.createElement('style');
      style.id = styleId;
      document.head.appendChild(style);
    }

    style.textContent = `
      html, body {
        margin: 0 !important;
        padding: 0 !important;
        min-height: 100% !important;
        max-width: 100% !important;
        overflow-x: hidden !important;
        -webkit-text-size-adjust: 100% !important;
        text-size-adjust: 100% !important;
      }

      body {
        overscroll-behavior: contain !important;
      }

      img, video, iframe, canvas, svg {
        max-width: 100% !important;
        height: auto !important;
      }

      audio {
        width: 100% !important;
        max-width: 100% !important;
      }

      table {
        max-width: 100% !important;
        display: block !important;
        overflow-x: auto !important;
      }

      input, textarea, select, button {
        font-size: inherit !important;
      }

      .reveal, .reveal .slides {
        max-width: 100% !important;
      }

      .reveal .slides section {
        box-sizing: border-box !important;
      }
    `;

    document.documentElement.style.backgroundColor = '#ffffff';
    document.body.style.backgroundColor = '#ffffff';

    var metas = document.querySelectorAll('meta[name="viewport"]');
    if (!metas || metas.length === 0) {
      var meta = document.createElement('meta');
      meta.name = 'viewport';
      meta.content = 'width=device-width, initial-scale=1.0, maximum-scale=5.0, user-scalable=yes';
      document.head.appendChild(meta);
    }

    return true;
  } catch (e) {
    return false;
  }
})();
''';

    await _runJavascriptSafely(script);
  }

  Future<void> _forceLessonFit() async {
    final script = '''
(function () {
  try {
    if (window.Reveal && typeof window.Reveal.layout === 'function') {
      window.Reveal.layout();
      if (typeof window.dispatchEvent === 'function') {
        window.dispatchEvent(new Event('resize'));
      }
    }

    var videos = document.querySelectorAll('video');
    for (var i = 0; i < videos.length; i++) {
      videos[i].setAttribute('playsinline', 'true');
      videos[i].setAttribute('webkit-playsinline', 'true');
      videos[i].controls = true;
    }

    return true;
  } catch (e) {
    return false;
  }
})();
''';

    await _runJavascriptSafely(script);
  }

  Future<void> _applyFontScale(int percent) async {
    final safe = percent.clamp(_fontScaleSteps.first, _fontScaleSteps.last);
    final scale = safe / 100.0;

    final script = '''
(function () {
  try {
    var styleId = 'dea_font_scale_style';
    var style = document.getElementById(styleId);
    if (!style) {
      style = document.createElement('style');
      style.id = styleId;
      document.head.appendChild(style);
    }

    style.textContent = `
      html {
        -webkit-text-size-adjust: ${safe}% !important;
        text-size-adjust: ${safe}% !important;
      }

      body {
        zoom: ${scale.toStringAsFixed(2)} !important;
      }

      .reveal {
        font-size: calc(28px * ${scale.toStringAsFixed(2)}) !important;
      }

      .reveal .hero-title { font-size: calc(66px * ${scale.toStringAsFixed(2)}) !important; }
      .reveal .title { font-size: calc(46px * ${scale.toStringAsFixed(2)}) !important; }
      .reveal .hero-subtitle,
      .reveal .subtitle-line,
      .reveal .card p,
      .reveal .card li,
      .reveal .sentence-card,
      .reveal .choice-card,
      .reveal .listen-box,
      .reveal .match-item,
      .reveal .drop-zone,
      .reveal .teacher-note,
      .reveal .checklist-item,
      .reveal button {
        font-size: calc(1em * ${scale.toStringAsFixed(2)}) !important;
      }
    `;

    if (window.Reveal && typeof window.Reveal.layout === 'function') {
      window.Reveal.layout();
    }

    return true;
  } catch (e) {
    return false;
  }
})();
''';

    await _runJavascriptSafely(script);

    if (!mounted) return;
    setState(() {
      _fontScalePercent = safe;
    });
  }

  Future<void> _cycleFontScale() async {
    final currentIndex = _fontScaleSteps.indexOf(_fontScalePercent);
    final safeIndex = currentIndex < 0 ? 0 : currentIndex;
    final nextIndex = (safeIndex + 1) % _fontScaleSteps.length;
    await _applyFontScale(_fontScaleSteps[nextIndex]);
  }

  Future<void> _toggleFullscreen() async {
    final next = !_isFullscreen;

    if (next) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }

    if (!mounted) return;
    setState(() {
      _isFullscreen = next;
    });
  }

  Future<void> _goBack() async {
    if (!_canGoBack) return;
    await _controller.goBack();
    unawaited(_refreshNavState());
  }

  Future<void> _goForward() async {
    if (!_canGoForward) return;
    await _controller.goForward();
    unawaited(_refreshNavState());
  }

  Future<void> _runJavascriptSafely(String script) async {
    try {
      await _controller.runJavaScript(script);
    } catch (_) {}
  }

  Widget _buildErrorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 520),
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.red.shade100),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.error_outline_rounded,
                size: 42,
                color: Colors.redAccent,
              ),
              const SizedBox(height: 12),
              const Text(
                'Could not open material',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                _lastError ?? 'Unknown error',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  height: 1.45,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                alignment: WrapAlignment.center,
                children: [
                  ElevatedButton.icon(
                    onPressed: () => unawaited(_reload()),
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Try again'),
                  ),
                  if (widget.allowReporting)
                    OutlinedButton.icon(
                      onPressed: () => unawaited(_showReportDialog()),
                      icon: const Icon(Icons.flag_outlined),
                      label: const Text('Report issue'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopLessonBar() {
    final shownUrl = _currentUrl ?? widget.url ?? '';

    return SafeArea(
      bottom: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border(
            bottom: BorderSide(color: Colors.grey.shade300),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    _screenTitle(),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                if (widget.allowReporting)
                  IconButton(
                    tooltip: 'Report issue',
                    onPressed: () => unawaited(_showReportDialog()),
                    icon: const Icon(Icons.flag_outlined),
                  ),
                IconButton(
                  tooltip: _isFullscreen ? 'Exit full screen' : 'Full screen',
                  onPressed: () => unawaited(_toggleFullscreen()),
                  icon: Icon(
                    _isFullscreen
                        ? Icons.fullscreen_exit_rounded
                        : Icons.fullscreen_rounded,
                  ),
                ),
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    shownUrl,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Colors.grey.shade700,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  'Text ${_fontScalePercent}%',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: Colors.grey.shade700,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.grey.shade300),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.06),
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          children: [
            _BottomControlButton(
              tooltip: 'Back',
              icon: Icons.arrow_back_ios_new_rounded,
              enabled: _canGoBack,
              onTap: _goBack,
            ),
            const SizedBox(width: 6),
            _BottomControlButton(
              tooltip: 'Forward',
              icon: Icons.arrow_forward_ios_rounded,
              enabled: _canGoForward,
              onTap: _goForward,
            ),
            const SizedBox(width: 6),
            _BottomControlButton(
              tooltip: 'Reload',
              icon: Icons.refresh_rounded,
              enabled: true,
              onTap: _reload,
            ),
            const SizedBox(width: 6),
            _BottomControlButton(
              tooltip: 'Change text size',
              icon: Icons.text_fields_rounded,
              enabled: true,
              onTap: _cycleFontScale,
            ),
            const Spacer(),
            if (widget.allowReporting)
              _BottomControlButton(
                tooltip: 'Report issue',
                icon: Icons.flag_outlined,
                enabled: true,
                onTap: _showReportDialog,
              ),
          ],
        ),
      ),
    );
  }

  String _screenTitle() {
    final value = (_pageTitle ?? widget.title).trim();
    if (value.isNotEmpty) return value;
    return 'Material Viewer';
  }

  @override
  Widget build(BuildContext context) {
    final progressValue = (_progress <= 0 || _progress > 100) ? null : _progress / 100;

    return Scaffold(
      backgroundColor: Colors.white,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            if (!_isFullscreen) _buildTopLessonBar(),
            if (_isLoading) LinearProgressIndicator(value: progressValue),
            Expanded(
              child: _lastError != null
                  ? _buildErrorState()
                  : Stack(
                children: [
                  Positioned.fill(
                    child: WebViewWidget(controller: _controller),
                  ),
                  if (_isLoading && _progress < 15)
                    const Center(
                      child: CircularProgressIndicator(),
                    ),
                ],
              ),
            ),
            if (!_isFullscreen) _buildBottomBar(),
          ],
        ),
      ),
    );
  }
}

class _BottomControlButton extends StatelessWidget {
  const _BottomControlButton({
    required this.tooltip,
    required this.icon,
    required this.enabled,
    required this.onTap,
  });

  final String tooltip;
  final IconData icon;
  final bool enabled;
  final Future<void> Function() onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: enabled ? () => unawaited(onTap()) : null,
      icon: Icon(icon),
      style: IconButton.styleFrom(
        backgroundColor: enabled ? Colors.grey.shade100 : Colors.grey.shade50,
        foregroundColor: enabled ? Colors.black87 : Colors.black38,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
      ),
    );
  }
}