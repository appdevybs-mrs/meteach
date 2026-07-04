import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import 'app_feedback.dart';
import 'material_webview_screen.dart';
import 'media_download.dart';
import 'shared_pdf_reader_screen.dart';

enum MailPreviewKind {
  image,
  pdf,
  video,
  audio,
  web,
  office,
  text,
  archive,
  file,
}

MailPreviewKind mailPreviewKindFor(String nameOrUrl) {
  final clean = nameOrUrl.toLowerCase().split('?').first.split('#').first;
  bool hasAny(List<String> exts) => exts.any(clean.endsWith);

  if (hasAny(['.jpg', '.jpeg', '.png', '.webp', '.gif'])) {
    return MailPreviewKind.image;
  }
  if (hasAny(['.pdf'])) return MailPreviewKind.pdf;
  if (hasAny(['.mp4', '.m4v', '.mov', '.webm', '.mkv', '.avi'])) {
    return MailPreviewKind.video;
  }
  if (hasAny(['.mp3', '.m4a', '.aac', '.wav', '.ogg'])) {
    return MailPreviewKind.audio;
  }
  if (hasAny(['.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx'])) {
    return MailPreviewKind.office;
  }
  if (hasAny(['.txt', '.csv', '.json', '.xml', '.html', '.htm'])) {
    return MailPreviewKind.text;
  }
  if (hasAny(['.zip', '.rar', '.7z', '.tar', '.gz'])) {
    return MailPreviewKind.archive;
  }
  return MailPreviewKind.file;
}

bool mailLooksLikeImage(String nameOrUrl) =>
    mailPreviewKindFor(nameOrUrl) == MailPreviewKind.image;

bool mailLooksLikePdf(String nameOrUrl) =>
    mailPreviewKindFor(nameOrUrl) == MailPreviewKind.pdf;

bool mailLooksLikeVideo(String nameOrUrl) =>
    mailPreviewKindFor(nameOrUrl) == MailPreviewKind.video;

bool mailLooksLikeAudio(String nameOrUrl) =>
    mailPreviewKindFor(nameOrUrl) == MailPreviewKind.audio;

Future<void> openMailUrlInBrowser(BuildContext context, String rawUrl) async {
  final url = rawUrl.trim();
  if (url.isEmpty) return;
  final uri = Uri.tryParse(url);
  if (uri == null) return;
  final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
  if (!ok && context.mounted) {
    AppToast.fromSnackBar(
      context,
      const SnackBar(content: Text('Could not open this link.')),
    );
  }
}

Future<void> openMailLinkPreview(
  BuildContext context, {
  required String url,
  String? title,
}) async {
  final cleanUrl = url.trim();
  if (cleanUrl.isEmpty || !context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => MaterialWebViewScreen.fromUrl(
        title: (title ?? Uri.tryParse(cleanUrl)?.host ?? 'Link').trim(),
        url: cleanUrl,
        viewerMode: MaterialViewerMode.document,
      ),
    ),
  );
}

Future<void> openMailFilePreview(
  BuildContext context, {
  required String url,
  required String name,
}) async {
  final cleanUrl = url.trim();
  final cleanName = name.trim().isEmpty ? 'Attachment' : name.trim();
  if (cleanUrl.isEmpty || !context.mounted) return;

  final kindByName = mailPreviewKindFor(cleanName);
  final kindByUrl = mailPreviewKindFor(cleanUrl);
  final kind = kindByName == MailPreviewKind.file ? kindByUrl : kindByName;

  Widget screen;
  switch (kind) {
    case MailPreviewKind.image:
      screen = _MailImagePreviewScreen(url: cleanUrl, title: cleanName);
      break;
    case MailPreviewKind.pdf:
      screen = SharedPdfReaderScreen(title: cleanName, pdfUrl: cleanUrl);
      break;
    case MailPreviewKind.video:
      screen = _MailVideoPreviewScreen(url: cleanUrl, title: cleanName);
      break;
    case MailPreviewKind.text:
    case MailPreviewKind.web:
      screen = MaterialWebViewScreen.fromUrl(
        title: cleanName,
        url: cleanUrl,
        viewerMode: MaterialViewerMode.document,
      );
      break;
    case MailPreviewKind.audio:
    case MailPreviewKind.office:
    case MailPreviewKind.archive:
    case MailPreviewKind.file:
      screen = _MailUnsupportedPreviewScreen(url: cleanUrl, title: cleanName);
      break;
  }

  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
}

Widget buildMailFileActions({
  required BuildContext context,
  required String url,
  required String name,
  required Color foregroundColor,
  bool compact = true,
}) {
  final cleanUrl = url.trim();
  if (cleanUrl.isEmpty) return const SizedBox.shrink();
  final safeName = name.trim().isEmpty ? 'attachment' : name.trim();

  Widget actionButton({
    required String tooltip,
    required IconData icon,
    required Color color,
    required VoidCallback onPressed,
  }) {
    final size = compact ? 32.0 : 38.0;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onPressed,
            customBorder: const CircleBorder(),
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    color.withValues(alpha: 0.24),
                    color.withValues(alpha: 0.10),
                  ],
                ),
                border: Border.all(
                  color: color.withValues(alpha: 0.36),
                  width: 1.1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: color.withValues(alpha: 0.16),
                    blurRadius: 8,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: Icon(
                icon,
                size: compact ? 17 : 19,
                color: Color.alphaBlend(
                  foregroundColor.withValues(alpha: 0.18),
                  color,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  return Padding(
    padding: const EdgeInsets.only(top: 2, bottom: 8),
    child: Wrap(
      spacing: 7,
      runSpacing: 7,
      children: [
        actionButton(
          tooltip: 'Preview attachment',
          icon: Icons.visibility_rounded,
          color: const Color(0xFF6366F1),
          onPressed: () =>
              openMailFilePreview(context, url: cleanUrl, name: safeName),
        ),
        actionButton(
          tooltip: 'Open in browser',
          icon: Icons.travel_explore_rounded,
          color: const Color(0xFF0891B2),
          onPressed: () => openMailUrlInBrowser(context, cleanUrl),
        ),
        actionButton(
          tooltip: 'Download attachment',
          icon: Icons.download_for_offline_rounded,
          color: const Color(0xFFEC740A),
          onPressed: () => MediaDownload.downloadUrl(
            context,
            url: cleanUrl,
            suggestedName: safeName,
            askFolder: false,
          ),
        ),
      ],
    ),
  );
}

class _MailImagePreviewScreen extends StatelessWidget {
  const _MailImagePreviewScreen({required this.url, required this.title});

  final String url;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Open in browser',
            onPressed: () => openMailUrlInBrowser(context, url),
            icon: const Icon(Icons.open_in_new_rounded),
          ),
          IconButton(
            tooltip: 'Download',
            onPressed: () => MediaDownload.downloadUrl(
              context,
              url: url,
              suggestedName: title,
              askFolder: false,
            ),
            icon: const Icon(Icons.download_rounded),
          ),
        ],
      ),
      body: InteractiveViewer(
        minScale: 0.6,
        maxScale: 4,
        child: Center(
          child: Image.network(
            url,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => const Text(
              'Could not load image.',
              style: TextStyle(color: Colors.white),
            ),
            loadingBuilder: (_, child, progress) => progress == null
                ? child
                : const Center(child: CircularProgressIndicator()),
          ),
        ),
      ),
    );
  }
}

class _MailVideoPreviewScreen extends StatefulWidget {
  const _MailVideoPreviewScreen({required this.url, required this.title});

  final String url;
  final String title;

  @override
  State<_MailVideoPreviewScreen> createState() =>
      _MailVideoPreviewScreenState();
}

class _MailVideoPreviewScreenState extends State<_MailVideoPreviewScreen> {
  late final VideoPlayerController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    unawaited(_init());
  }

  Future<void> _init() async {
    try {
      await _controller.initialize();
      if (!mounted) return;
      setState(() {});
      await _controller.play();
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Could not play this video in the app.');
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: 'Open in browser',
            onPressed: () => openMailUrlInBrowser(context, widget.url),
            icon: const Icon(Icons.open_in_new_rounded),
          ),
          IconButton(
            tooltip: 'Download',
            onPressed: () => MediaDownload.downloadUrl(
              context,
              url: widget.url,
              suggestedName: widget.title,
              askFolder: false,
              isVideo: true,
            ),
            icon: const Icon(Icons.download_rounded),
          ),
        ],
      ),
      body: Center(
        child: _error != null
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white),
                ),
              )
            : !_controller.value.isInitialized
            ? const CircularProgressIndicator()
            : AspectRatio(
                aspectRatio: _controller.value.aspectRatio,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    VideoPlayer(_controller),
                    IconButton.filled(
                      onPressed: () {
                        setState(() {
                          _controller.value.isPlaying
                              ? _controller.pause()
                              : _controller.play();
                        });
                      },
                      icon: Icon(
                        _controller.value.isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                      ),
                    ),
                    Positioned(
                      left: 12,
                      right: 12,
                      bottom: 12,
                      child: VideoProgressIndicator(
                        _controller,
                        allowScrubbing: true,
                        colors: const VideoProgressColors(
                          playedColor: Colors.white,
                          bufferedColor: Colors.white38,
                          backgroundColor: Colors.white24,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

class _MailUnsupportedPreviewScreen extends StatelessWidget {
  const _MailUnsupportedPreviewScreen({required this.url, required this.title});

  final String url;
  final String title;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.insert_drive_file_rounded,
                  size: 56,
                  color: scheme.primary,
                ),
                const SizedBox(height: 14),
                Text(
                  'Preview not available',
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 8),
                Text(
                  'This file type cannot be displayed reliably inside the app. You can open it in a browser or download it.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: scheme.onSurface.withValues(alpha: 0.7),
                  ),
                ),
                const SizedBox(height: 22),
                FilledButton.icon(
                  onPressed: () => openMailUrlInBrowser(context, url),
                  icon: const Icon(Icons.open_in_new_rounded),
                  label: const Text('Open in browser'),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: () => MediaDownload.downloadUrl(
                    context,
                    url: url,
                    suggestedName: title,
                    askFolder: false,
                  ),
                  icon: const Icon(Icons.download_rounded),
                  label: const Text('Download'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
