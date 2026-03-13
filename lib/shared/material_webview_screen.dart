import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

class MaterialWebViewScreen extends StatefulWidget {
  const MaterialWebViewScreen.fromUrl({
    super.key,
    required this.title,
    required this.url,
    this.headers = const <String, String>{},
  })  : htmlString = null,
        assetPath = null;

  const MaterialWebViewScreen.fromAsset({
    super.key,
    required this.title,
    required this.assetPath,
  })  : url = null,
        htmlString = null,
        headers = const <String, String>{};

  const MaterialWebViewScreen.fromHtmlString({
    super.key,
    required this.title,
    required this.htmlString,
  })  : url = null,
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
  late final WebViewController _controller;

  int _progress = 0;
  bool _isLoading = true;
  String? _currentUrl;
  String? _pageTitle;
  String? _lastError;
  bool _didApplyInitialEnhancements = false;
  bool _isPageReady = false;
  String? _lastJsMessage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _setupController();
    unawaited(_enterFullscreen());
    unawaited(_loadInitialContent());
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
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
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
      ..enableZoom(false)
      ..setBackgroundColor(const Color(0xFF000000))
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
              _isPageReady = false;
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
              _isPageReady = true;
            });

            await _applyGameEnhancementsIfNeeded();
            await _notifyViewportChanged();
            await _notifyGameLifecycle('resumed');
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
        await _controller.loadRequest(uri, headers: widget.headers);
      } else if (widget.isAsset) {
        await _controller.loadFlutterAsset(widget.assetPath!.trim());
      } else if (widget.isHtmlString) {
        await _controller.loadHtmlString(widget.htmlString!.trim());
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
    try {
      return await _controller.getTitle();
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
      _isPageReady = false;
    });

    await _controller.reload();
  }

  void _handleJsMessage(String message) {
    if (!mounted) return;

    setState(() {
      _lastJsMessage = message;
    });

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
      'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover'
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
        background: #000 !important;
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

      .reveal,
      .reveal .slides {
        width: 100% !important;
        height: 100% !important;
        max-width: 100% !important;
        max-height: 100% !important;
      }

      .reveal .slides section {
        width: 100% !important;
        height: 100% !important;
      }

      canvas,
      [data-game-canvas],
      .game-surface,
      .draw-surface,
      .drag-surface {
        touch-action: none !important;
      }
    `;

    document.documentElement.style.backgroundColor = '#000000';
    document.body.style.backgroundColor = '#000000';

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

    var relayoutReveal = function () {
      try {
        if (window.Reveal) {
          if (typeof window.Reveal.layout === 'function') {
            window.Reveal.layout();
          }
          if (typeof window.Reveal.sync === 'function') {
            window.Reveal.sync();
          }
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
        emitViewport();
        sendMessage('revealReady');
      });
    }

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
    final String safeState = state.replaceAll("'", "\\'");

    final String script = '''
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
                'Could not open game',
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

  Widget _buildOverlayLoading() {
    final double? progressValue =
    (_progress <= 0 || _progress > 100) ? null : _progress / 100;

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
                _pageTitle?.trim().isNotEmpty == true ? _pageTitle!.trim() : widget.title,
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

  Widget _buildDebugCorner() {
    return Positioned(
      right: 10,
      bottom: 10,
      child: IgnorePointer(
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 180),
          opacity: _lastError == null && _isPageReady && _lastJsMessage != null ? 0.14 : 0,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              _lastJsMessage ?? '',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
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
                Positioned.fill(
                  child: _lastError != null
                      ? _buildErrorState()
                      : WebViewWidget(controller: _controller),
                ),
                if (_isLoading) Positioned.fill(child: _buildOverlayLoading()),
                _buildDebugCorner(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}