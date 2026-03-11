import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

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

class _MaterialWebViewScreenState extends State<MaterialWebViewScreen> {
  late final WebViewController _controller;

  int _progress = 0;
  bool _isLoading = true;
  bool _canGoBack = false;
  bool _canGoForward = false;
  String? _currentUrl;
  String? _pageTitle;
  String? _lastError;

  @override
  void initState() {
    super.initState();
    _setupController();
    unawaited(_loadInitialContent());
  }

  void _setupController() {
    _controller = WebViewController()
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
        ),
      );
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
    });
    await _controller.reload();
  }

  Future<void> _copyLink() async {
    final url = _currentUrl ?? widget.url;
    if (url == null || url.trim().isEmpty) {
      _showSnack('No link available to copy.');
      return;
    }

    await Clipboard.setData(ClipboardData(text: url));
    _showSnack('Link copied.');
  }

  Future<void> _shareLink() async {
    final url = _currentUrl ?? widget.url;
    if (url == null || url.trim().isEmpty) {
      _showSnack('No link available to share.');
      return;
    }

    await Share.share('$url');
  }

  Future<void> _openInBrowser() async {
    final url = _currentUrl ?? widget.url;
    if (url == null || url.trim().isEmpty) {
      _showSnack('No link available to open.');
      return;
    }

    final uri = Uri.tryParse(url);
    if (uri == null) {
      _showSnack('Invalid link.');
      return;
    }

    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok) {
      _showSnack('Could not open browser.');
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  void _showToolsSheet() {
    final url = _currentUrl ?? widget.url ?? '';

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _SheetAction(
                  icon: Icons.refresh_rounded,
                  title: 'Reload',
                  onTap: () {
                    Navigator.pop(context);
                    unawaited(_reload());
                  },
                ),
                _SheetAction(
                  icon: Icons.copy_rounded,
                  title: 'Copy link',
                  onTap: () {
                    Navigator.pop(context);
                    unawaited(_copyLink());
                  },
                ),
                _SheetAction(
                  icon: Icons.share_rounded,
                  title: 'Share link',
                  onTap: () {
                    Navigator.pop(context);
                    unawaited(_shareLink());
                  },
                ),
                _SheetAction(
                  icon: Icons.open_in_browser_rounded,
                  title: 'Open in browser',
                  onTap: () {
                    Navigator.pop(context);
                    unawaited(_openInBrowser());
                  },
                ),
                if (url.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      url,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
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
                    onPressed: () => unawaited(_loadInitialContent()),
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('Try again'),
                  ),
                  if (widget.url != null && widget.url!.trim().isNotEmpty)
                    OutlinedButton.icon(
                      onPressed: () => unawaited(_openInBrowser()),
                      icon: const Icon(Icons.open_in_browser_rounded),
                      label: const Text('Open in browser'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomBar() {
    return SafeArea(
      top: false,
      child: Container(
        height: 58,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border(
            top: BorderSide(color: Colors.grey.shade300),
          ),
        ),
        child: Row(
          children: [
            IconButton(
              tooltip: 'Back',
              onPressed: _canGoBack
                  ? () async {
                await _controller.goBack();
                unawaited(_refreshNavState());
              }
                  : null,
              icon: const Icon(Icons.arrow_back_ios_new_rounded),
            ),
            IconButton(
              tooltip: 'Forward',
              onPressed: _canGoForward
                  ? () async {
                await _controller.goForward();
                unawaited(_refreshNavState());
              }
                  : null,
              icon: const Icon(Icons.arrow_forward_ios_rounded),
            ),
            IconButton(
              tooltip: 'Reload',
              onPressed: () => unawaited(_reload()),
              icon: const Icon(Icons.refresh_rounded),
            ),
            const Spacer(),
            IconButton(
              tooltip: 'Share',
              onPressed: () => unawaited(_shareLink()),
              icon: const Icon(Icons.share_rounded),
            ),
            IconButton(
              tooltip: 'More',
              onPressed: _showToolsSheet,
              icon: const Icon(Icons.more_vert_rounded),
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
    final shownUrl = _currentUrl ?? widget.url ?? '';

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        titleSpacing: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _screenTitle(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (shownUrl.isNotEmpty)
              Text(
                shownUrl,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Copy link',
            onPressed: () => unawaited(_copyLink()),
            icon: const Icon(Icons.copy_rounded),
          ),
          IconButton(
            tooltip: 'Open in browser',
            onPressed: () => unawaited(_openInBrowser()),
            icon: const Icon(Icons.open_in_browser_rounded),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(3),
          child: _isLoading
              ? LinearProgressIndicator(value: _progress / 100)
              : const SizedBox(height: 3),
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: _lastError != null
                ? _buildErrorState()
                : Stack(
              children: [
                WebViewWidget(controller: _controller),
                if (_isLoading && _progress < 15)
                  const Center(
                    child: CircularProgressIndicator(),
                  ),
              ],
            ),
          ),
          _buildBottomBar(),
        ],
      ),
    );
  }
}

class _SheetAction extends StatelessWidget {
  const _SheetAction({
    required this.icon,
    required this.title,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(
        title,
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
      onTap: onTap,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
    );
  }
}