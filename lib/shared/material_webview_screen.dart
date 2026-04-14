import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

class MaterialWebViewScreen extends StatefulWidget {
  const MaterialWebViewScreen.fromUrl({
    super.key,
    required this.title,
    required this.url,
    this.headers = const <String, String>{},
  }) : htmlString = null,
       assetPath = null;

  const MaterialWebViewScreen.fromAsset({
    super.key,
    required this.title,
    required this.assetPath,
  }) : url = null,
       htmlString = null,
       headers = const <String, String>{};

  const MaterialWebViewScreen.fromHtmlString({
    super.key,
    required this.title,
    required this.htmlString,
  }) : url = null,
       assetPath = null,
       headers = const <String, String>{};

  final String title;
  final String? url;
  final String? assetPath;
  final String? htmlString;
  final Map<String, String> headers;

  bool get isUrl => url != null && url!.trim().isNotEmpty;
  bool get isAsset => assetPath != null && assetPath!.trim().isNotEmpty;
  bool get isHtmlString => htmlString != null && htmlString!.trim().isNotEmpty;

  @override
  State<MaterialWebViewScreen> createState() => _MaterialWebViewScreenState();
}

class _MaterialWebViewScreenState extends State<MaterialWebViewScreen>
    with WidgetsBindingObserver {
  WebViewController? _controller;

  int _progress = 0;
  bool _isLoading = true;
  String? _currentUrl;
  String? _pageTitle;
  String? _lastError;
  bool _didApplyInitialEnhancements = false;
  bool _openedWebUrl = false;

  bool get _isWebRuntime => kIsWeb;
  bool get _hasController => _controller != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    if (!_isWebRuntime) {
      _setupController();
      unawaited(_loadInitialContent());
    } else {
      unawaited(_handleWebStartup());
    }

    unawaited(_enterFullscreen());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        unawaited(_enterFullscreen());
        unawaited(_notifyGameLifecycle('resumed'));
        break;
      case AppLifecycleState.inactive:
        unawaited(_notifyGameLifecycle('inactive'));
        break;
      case AppLifecycleState.paused:
        unawaited(_notifyGameLifecycle('paused'));
        break;
      case AppLifecycleState.detached:
        unawaited(_notifyGameLifecycle('detached'));
        break;
      case AppLifecycleState.hidden:
        unawaited(_notifyGameLifecycle('hidden'));
        break;
    }
  }

  Future<void> _enterFullscreen() async {
    try {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } catch (_) {}
  }

  Future<void> _handleWebStartup() async {
    try {
      if (widget.isUrl) {
        final Uri? uri = Uri.tryParse(widget.url!.trim());
        if (uri == null) {
          if (!mounted) return;
          setState(() {
            _lastError = 'Invalid URL.';
            _isLoading = false;
          });
          return;
        }

        final bool launched = await launchUrl(uri, webOnlyWindowName: '_self');

        if (!mounted) return;
        setState(() {
          _openedWebUrl = launched;
          _currentUrl = uri.toString();
          _pageTitle = widget.title;
          _isLoading = false;
          if (!launched) {
            _lastError = 'Could not open this page in the browser.';
          }
        });
        return;
      }

      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _lastError = widget.isAsset || widget.isHtmlString
            ? 'This content type is not supported on Flutter web in this screen yet.\nUse a URL for web, or keep using mobile WebView.'
            : 'No content source was provided.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _lastError = 'Failed to open content.\n$e';
        _isLoading = false;
      });
    }
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
      ..addJavaScriptChannel(
        'GameHost',
        onMessageReceived: (JavaScriptMessage message) {
          _handleJsMessage(message.message);
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (String url) {
            if (!mounted) return;
            setState(() {
              _isLoading = true;
              _lastError = null;
              _currentUrl = url;
              _didApplyInitialEnhancements = false;
            });
          },
          onProgress: (int progress) {
            if (!mounted) return;
            setState(() {
              _progress = progress.clamp(0, 100);
            });
          },
          onPageFinished: (String url) async {
            final String? title = await _safeGetTitle();

            if (!mounted) return;
            setState(() {
              _isLoading = false;
              _progress = 100;
              _currentUrl = url;
              _pageTitle = title;
            });

            await _applyGameEnhancementsIfNeeded();
            await _notifyViewportChanged();
            await _notifyGameLifecycle('resumed');
            _scheduleStabilityRelayouts();
          },
          onWebResourceError: (WebResourceError error) {
            if (!mounted) return;
            setState(() {
              _isLoading = false;
              _lastError = error.description.isEmpty
                  ? 'Failed to load content.'
                  : 'Failed to load content.\n${error.description}';
            });
          },
          onNavigationRequest: (NavigationRequest request) {
            final String url = request.url.trim();
            final Uri? uri = Uri.tryParse(url);

            if (uri == null) {
              return NavigationDecision.navigate;
            }

            final String scheme = uri.scheme.toLowerCase();

            if (scheme == 'http' ||
                scheme == 'https' ||
                scheme == 'file' ||
                scheme == 'about' ||
                scheme == 'data' ||
                scheme == 'blob') {
              return NavigationDecision.navigate;
            }

            return NavigationDecision.prevent;
          },
        ),
      );

    if (controller.platform is AndroidWebViewController) {
      final AndroidWebViewController androidController =
          controller.platform as AndroidWebViewController;

      AndroidWebViewController.enableDebugging(true);
      androidController.setMediaPlaybackRequiresUserGesture(false);
    }

    _controller = controller;
  }

  Future<void> _loadInitialContent() async {
    if (!_hasController) return;

    try {
      if (widget.isUrl) {
        final Uri? uri = Uri.tryParse(widget.url!.trim());
        if (uri == null) {
          if (!mounted) return;
          setState(() {
            _lastError = 'Invalid URL.';
            _isLoading = false;
          });
          return;
        }
        await _controller!.loadRequest(uri, headers: widget.headers);
      } else if (widget.isAsset) {
        await _controller!.loadFlutterAsset(widget.assetPath!.trim());
      } else if (widget.isHtmlString) {
        await _controller!.loadHtmlString(widget.htmlString!.trim());
      } else {
        if (!mounted) return;
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
    if (!_hasController) return null;

    try {
      return await _controller!.getTitle();
    } catch (_) {
      return null;
    }
  }

  Future<void> _reload() async {
    if (!mounted) return;

    setState(() {
      _lastError = null;
      _isLoading = true;
      _progress = 0;
      _didApplyInitialEnhancements = false;
    });

    if (_isWebRuntime) {
      await _handleWebStartup();
      return;
    }

    if (!_hasController) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _lastError = 'WebView controller is not available.';
      });
      return;
    }

    await _controller!.reload();
  }

  void _handleJsMessage(String message) {
    if (!mounted) return;

    if (message == 'requestFullscreen') {
      unawaited(_enterFullscreen());
      unawaited(_notifyViewportChanged());
      return;
    }

    if (message == 'reload') {
      unawaited(_reload());
      return;
    }
  }

  Future<void> _applyGameEnhancementsIfNeeded() async {
    if (_isWebRuntime || !_hasController) return;
    if (_didApplyInitialEnhancements) return;

    _didApplyInitialEnhancements = true;

    await _injectBaseGameSupport();
    await _injectRevealAndViewportHooks();
    await _notifyViewportChanged();
  }

  Future<void> _injectBaseGameSupport() async {
    const String script = '''
(function () {
  try {
    var existingViewport = document.querySelector('meta[name="viewport"]');
    if (!existingViewport) {
      existingViewport = document.createElement('meta');
      existingViewport.name = 'viewport';
      document.head.appendChild(existingViewport);
    }
    existingViewport.setAttribute(
      'content',
      'width=device-width, initial-scale=1.0, minimum-scale=1.0, maximum-scale=5.0, user-scalable=yes, viewport-fit=cover'
    );

    var styleId = 'dea_game_host_style';
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
        width: 100% !important;
        height: 100% !important;
        min-width: 100% !important;
        min-height: 100% !important;
        background: #fff !important;
        color-scheme: light !important;
        overflow: hidden !important;
        overscroll-behavior: none !important;
        -webkit-text-size-adjust: 100% !important;
        text-size-adjust: 100% !important;
        -webkit-user-select: none !important;
        user-select: none !important;
        -webkit-touch-callout: none !important;
        touch-action: manipulation !important;
      }

      * {
        -webkit-tap-highlight-color: transparent !important;
        box-sizing: border-box !important;
      }

      iframe, video {
        border: 0 !important;
      }

      video {
        playsinline: true;
      }

      .reveal {
        visibility: visible !important;
        opacity: 1 !important;
      }

      canvas,
      [data-game-canvas],
      .game-surface,
      .draw-surface,
      .drag-surface {
        touch-action: none !important;
      }
    `;

    document.documentElement.style.backgroundColor = '#ffffff';
    document.body.style.backgroundColor = '#ffffff';

    var videos = document.querySelectorAll('video');
    for (var i = 0; i < videos.length; i++) {
      videos[i].setAttribute('playsinline', 'true');
      videos[i].setAttribute('webkit-playsinline', 'true');
      videos[i].controls = true;
    }

    var notifyReady = function () {
      try {
        if (window.GameHost && typeof window.GameHost.postMessage === 'function') {
          window.GameHost.postMessage('gameReady');
        }
      } catch (_) {}
    };

    if (document.readyState === 'complete' || document.readyState === 'interactive') {
      notifyReady();
    } else {
      document.addEventListener('DOMContentLoaded', notifyReady, { once: true });
    }

    return true;
  } catch (e) {
    try {
      if (window.GameHost && typeof window.GameHost.postMessage === 'function') {
        window.GameHost.postMessage('injectBaseGameSupportError:' + String(e));
      }
    } catch (_) {}
    return false;
  }
})();
''';

    await _runJavascriptSafely(script);
  }

  Future<void> _injectRevealAndViewportHooks() async {
    const String script = '''
(function () {
  try {
    if (window.__deaGameHostHooksInstalled) {
      return true;
    }
    window.__deaGameHostHooksInstalled = true;

    var sendMessage = function (value) {
      try {
        if (window.GameHost && typeof window.GameHost.postMessage === 'function') {
          window.GameHost.postMessage(value);
        }
      } catch (_) {}
    };

    var emitViewport = function () {
      try {
        var payload = JSON.stringify({
          type: 'viewport',
          width: window.innerWidth || 0,
          height: window.innerHeight || 0,
          devicePixelRatio: window.devicePixelRatio || 1,
          pageTitle: document.title || ''
        });
        sendMessage(payload);
      } catch (_) {}
    };

    var raf = function (cb) {
      if (typeof window.requestAnimationFrame === 'function') {
        window.requestAnimationFrame(cb);
      } else {
        setTimeout(cb, 16);
      }
    };

    var relayoutReveal = function () {
      try {
        var root = document.querySelector('.reveal');
        if (root) {
          root.style.opacity = '1';
          root.style.visibility = 'visible';
        }

        if (window.Reveal) {
          raf(function () {
            try {
              if (typeof window.Reveal.layout === 'function') {
                window.Reveal.layout();
              }
              if (typeof window.Reveal.sync === 'function') {
                window.Reveal.sync();
              }
            } catch (_) {}
          });

          setTimeout(function () {
            try {
              if (typeof window.Reveal.layout === 'function') {
                window.Reveal.layout();
              }
              if (typeof window.Reveal.sync === 'function') {
                window.Reveal.sync();
              }
            } catch (_) {}
          }, 90);
        }
      } catch (_) {}
    };

    window.addEventListener('resize', function () {
      relayoutReveal();
      emitViewport();
    }, { passive: true });

    window.addEventListener('orientationchange', function () {
      setTimeout(function () {
        relayoutReveal();
        emitViewport();
      }, 100);
    }, { passive: true });

    document.addEventListener('fullscreenchange', function () {
      relayoutReveal();
      emitViewport();
      sendMessage('fullscreenChanged');
    });

    if (window.Reveal && typeof window.Reveal.on === 'function') {
      window.Reveal.on('slidechanged', function () {
        relayoutReveal();
        setTimeout(relayoutReveal, 140);
        sendMessage('slideChanged');
      });

      window.Reveal.on('fragmentshown', function () {
        sendMessage('fragmentShown');
      });

      window.Reveal.on('fragmenthidden', function () {
        sendMessage('fragmentHidden');
      });

      window.Reveal.on('ready', function () {
        relayoutReveal();
        setTimeout(relayoutReveal, 120);
        emitViewport();
        sendMessage('revealReady');
      });
    }

    window.addEventListener('load', function () {
      setTimeout(function () {
        relayoutReveal();
        emitViewport();
      }, 40);
      setTimeout(function () {
        relayoutReveal();
        emitViewport();
      }, 180);
      setTimeout(function () {
        relayoutReveal();
        emitViewport();
      }, 520);
    }, { passive: true });

    try {
      if (document.fonts && typeof document.fonts.ready !== 'undefined') {
        document.fonts.ready.then(function () {
          relayoutReveal();
          emitViewport();
        });
      }
    } catch (_) {}

    try {
      var imgs = document.querySelectorAll('.reveal img');
      for (var i = 0; i < imgs.length; i++) {
        imgs[i].addEventListener('load', function () {
          relayoutReveal();
        }, { passive: true });
      }
    } catch (_) {}

    setTimeout(function () {
      relayoutReveal();
      emitViewport();
    }, 50);

    return true;
  } catch (e) {
    try {
      if (window.GameHost && typeof window.GameHost.postMessage === 'function') {
        window.GameHost.postMessage('injectRevealAndViewportHooksError:' + String(e));
      }
    } catch (_) {}
    return false;
  }
})();
''';

    await _runJavascriptSafely(script);
  }

  Future<void> _notifyGameLifecycle(String state) async {
    if (_isWebRuntime || !_hasController) return;

    final String safeState = state.replaceAll("'", "\\'");

    final String script =
        '''
(function () {
  try {
    var eventName = 'flutter-game-lifecycle';
    var detail = { state: '$safeState' };

    if (typeof window.dispatchEvent === 'function') {
      window.dispatchEvent(new CustomEvent(eventName, { detail: detail }));
    }

    if (window.GameApp && typeof window.GameApp.onLifecycleChange === 'function') {
      window.GameApp.onLifecycleChange(detail);
    }

    if (window.Reveal) {
      if ('$safeState' === 'paused' || '$safeState' === 'hidden' || '$safeState' === 'inactive') {
        if (typeof window.Reveal.pause === 'function') {
          window.Reveal.pause();
        }
      } else if ('$safeState' === 'resumed') {
        if (typeof window.Reveal.resume === 'function') {
          window.Reveal.resume();
        }
        if (typeof window.Reveal.layout === 'function') {
          window.Reveal.layout();
        }
      }
    }

    return true;
  } catch (e) {
    return false;
  }
})();
''';

    await _runJavascriptSafely(script);
  }

  Future<void> _notifyViewportChanged() async {
    if (_isWebRuntime || !_hasController) return;

    const String script = '''
(function () {
  try {
    var detail = {
      width: window.innerWidth || 0,
      height: window.innerHeight || 0,
      devicePixelRatio: window.devicePixelRatio || 1,
      title: document.title || ''
    };

    if (typeof window.dispatchEvent === 'function') {
      window.dispatchEvent(new CustomEvent('flutter-game-viewport', { detail: detail }));
      window.dispatchEvent(new Event('resize'));
    }

    if (window.GameApp && typeof window.GameApp.onViewportChanged === 'function') {
      window.GameApp.onViewportChanged(detail);
    }

    if (window.Reveal) {
      if (typeof window.Reveal.layout === 'function') {
        window.Reveal.layout();
      }
      if (typeof window.Reveal.sync === 'function') {
        window.Reveal.sync();
      }
    }

    return true;
  } catch (e) {
    return false;
  }
})();
''';

    await _runJavascriptSafely(script);
  }

  Future<void> _runJavascriptSafely(String script) async {
    if (_isWebRuntime || !_hasController) return;

    try {
      await _controller!.runJavaScript(script);
    } catch (_) {}
  }

  void _scheduleStabilityRelayouts() {
    if (_isWebRuntime || !_hasController) return;

    Future<void>.delayed(
      const Duration(milliseconds: 80),
      _notifyViewportChanged,
    );
    Future<void>.delayed(
      const Duration(milliseconds: 220),
      _notifyViewportChanged,
    );
    Future<void>.delayed(
      const Duration(milliseconds: 520),
      _notifyViewportChanged,
    );
  }

  Future<void> _openUrlAgain() async {
    if (!widget.isUrl) return;

    final Uri? uri = Uri.tryParse(widget.url!.trim());
    if (uri == null) return;

    await launchUrl(uri, webOnlyWindowName: '_self');
  }

  bool _looksLikeMissingContentError(String raw) {
    final lower = raw.toLowerCase();
    return lower.contains('404') ||
        lower.contains('410') ||
        lower.contains('not found') ||
        lower.contains('err_file_not_found') ||
        lower.contains('file not found');
  }

  String _displayErrorMessage() {
    final raw = (_lastError ?? '').trim();
    if (raw.isEmpty) return 'Unknown error';
    if (_looksLikeMissingContentError(raw)) {
      final title = widget.title.trim();
      final sessionPart = title.isEmpty ? '' : ' Session: "$title".';
      return 'This lesson file is currently unavailable. '
          'Please contact Your Bridge School support and share your course title + session number.$sessionPart';
    }
    return raw;
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
                'Could not open content',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 10),
              Text(
                _displayErrorMessage(),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  height: 1.45,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 14),
              ElevatedButton.icon(
                onPressed: () => unawaited(_reload()),
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Try again'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildWebOpenedState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 560),
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.open_in_browser_rounded,
                size: 44,
                color: Colors.black87,
              ),
              const SizedBox(height: 12),
              Text(
                widget.title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'This page was opened directly in the browser for web support.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  height: 1.45,
                  fontWeight: FontWeight.w600,
                  color: Colors.grey.shade800,
                ),
              ),
              if ((_currentUrl ?? '').trim().isNotEmpty) ...[
                const SizedBox(height: 10),
                SelectableText(
                  _currentUrl!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.blueGrey.shade700,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              const SizedBox(height: 14),
              ElevatedButton.icon(
                onPressed: () => unawaited(_openUrlAgain()),
                icon: const Icon(Icons.open_in_new_rounded),
                label: const Text('Open again'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOverlayLoading() {
    final double? progressValue = (_progress <= 0 || _progress > 100)
        ? null
        : _progress / 100;

    return IgnorePointer(
      child: Container(
        color: Colors.black,
        alignment: Alignment.center,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 280),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(color: Colors.white),
              const SizedBox(height: 18),
              Text(
                _pageTitle?.trim().isNotEmpty == true
                    ? _pageTitle!.trim()
                    : widget.title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: progressValue,
                  minHeight: 8,
                  backgroundColor: Colors.white24,
                  valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_lastError != null) {
      return _buildErrorState();
    }

    if (_isWebRuntime) {
      if (_openedWebUrl) {
        return _buildWebOpenedState();
      }

      return _buildErrorState();
    }

    if (!_hasController) {
      return _buildErrorState();
    }

    return WebViewWidget(controller: _controller!);
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.white,
        body: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () => unawaited(_enterFullscreen()),
          onDoubleTap: () => unawaited(_notifyViewportChanged()),
          child: SafeArea(
            top: false,
            bottom: false,
            left: false,
            right: false,
            child: Stack(
              children: [
                Positioned.fill(child: _buildBody()),
                if (_isLoading) Positioned.fill(child: _buildOverlayLoading()),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
