import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class _PreviewData {
  final String? title;
  final String? description;
  final String? imageUrl;
  _PreviewData({this.title, this.description, this.imageUrl});
}

class LinkPreviewWidget extends StatefulWidget {
  const LinkPreviewWidget({
    super.key,
    required this.url,
    required this.onTap,
    this.heroColor = const Color(0xFFEC740A),
  });

  final String url;
  final VoidCallback onTap;
  final Color heroColor;

  @override
  State<LinkPreviewWidget> createState() => _LinkPreviewWidgetState();
}

class _LinkPreviewWidgetState extends State<LinkPreviewWidget> {
  static final Map<String, _PreviewData> _cache = {};

  bool _loading = true;
  _PreviewData? _data;
  bool _errored = false;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  String get _domain {
    try {
      final u = Uri.parse(widget.url);
      return u.host.replaceFirst('www.', '');
    } catch (_) {
      return widget.url;
    }
  }

  Future<void> _fetch() async {
    final cached = _cache[widget.url];
    if (cached != null) {
      if (mounted) setState(() { _data = cached; _loading = false; });
      return;
    }

    try {
      final response = await http.get(
        Uri.parse(widget.url),
        headers: {'User-Agent': 'Mozilla/5.0 (compatible; LinkPreview/1.0)'},
      ).timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) {
        if (mounted) setState(() { _loading = false; _errored = true; });
        return;
      }

      final body = response.body;
      final title = _og(body, 'og:title') ?? _titleTag(body);
      final description = _og(body, 'og:description');
      final imageUrl = _og(body, 'og:image');

      final data = _PreviewData(title: title, description: description, imageUrl: imageUrl);
      _cache[widget.url] = data;
      if (mounted) setState(() { _data = data; _loading = false; });
    } catch (_) {
      if (mounted) setState(() { _loading = false; _errored = true; });
    }
  }

  String? _og(String html, String property) {
    final patterns = [
      RegExp('''<meta\\s+[^>]*property=["']$property["']\\s+content=["']([^"']+)["']''', caseSensitive: false, dotAll: true),
      RegExp('''<meta\\s+[^>]*content=["']([^"']+)["']\\s+property=["']$property["']''', caseSensitive: false, dotAll: true),
      RegExp('''<meta\\s+[^>]*name=["']$property["']\\s+content=["']([^"']+)["']''', caseSensitive: false, dotAll: true),
      RegExp('''<meta\\s+[^>]*content=["']([^"']+)["']\\s+name=["']$property["']''', caseSensitive: false, dotAll: true),
    ];
    for (final p in patterns) {
      final m = p.firstMatch(html);
      if (m != null) {
        return m.group(1)!
            .replaceAll('&amp;', '&')
            .replaceAll('&lt;', '<')
            .replaceAll('&gt;', '>')
            .replaceAll('&quot;', '"')
            .replaceAll('&#39;', "'");
      }
    }
    return null;
  }

  String? _titleTag(String html) {
    final m = RegExp(r'<title[^>]*>([^<]+)</title>', caseSensitive: false, dotAll: true).firstMatch(html);
    if (m != null) return m.group(1)!.trim();
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return GestureDetector(
      onTap: widget.onTap,
      child: Container(
        margin: const EdgeInsets.only(top: 8),
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.black.withValues(alpha: 0.08)),
        ),
        clipBehavior: Clip.antiAlias,
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildThumbnail(scheme),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_loading)
                        _buildShimmer(scheme)
                      else if (_errored)
                        _buildFallback(scheme)
                      else ...[
                        if (_data!.title != null && _data!.title!.isNotEmpty)
                          Text(
                            _data!.title!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                              color: scheme.onSurface,
                              height: 1.25,
                            ),
                          ),
                        if (_data!.description != null && _data!.description!.isNotEmpty) ...[
                          if (_data!.title != null && _data!.title!.isNotEmpty)
                            const SizedBox(height: 4),
                          Text(
                            _data!.description!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: scheme.onSurface.withValues(alpha: 0.65),
                              height: 1.25,
                            ),
                          ),
                        ],
                      ],
                      const Spacer(),
                      Row(
                        children: [
                          Icon(Icons.link_rounded, size: 13, color: widget.heroColor),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              _domain,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: widget.heroColor,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildThumbnail(ColorScheme scheme) {
    if (_loading) {
      return Container(
        width: 80,
        color: scheme.surfaceContainerHighest,
        child: const Center(child: Icon(Icons.link_rounded, size: 28, color: Colors.black26)),
      );
    }
    if (_errored || _data?.imageUrl == null || _data!.imageUrl!.isEmpty) {
      return Container(
        width: 80,
        color: widget.heroColor.withValues(alpha: 0.08),
        child: Icon(Icons.open_in_new_rounded, size: 28, color: widget.heroColor),
      );
    }
    return SizedBox(
      width: 80,
      child: Image.network(
        _data!.imageUrl!,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => Container(
          color: widget.heroColor.withValues(alpha: 0.08),
          child: Icon(Icons.open_in_new_rounded, size: 28, color: widget.heroColor),
        ),
      ),
    );
  }

  Widget _buildShimmer(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          height: 12,
          width: 180,
          decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(4)),
        ),
        const SizedBox(height: 6),
        Container(
          height: 10,
          width: 140,
          decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(4)),
        ),
        const SizedBox(height: 4),
        Container(
          height: 10,
          width: 100,
          decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(4)),
        ),
      ],
    );
  }

  Widget _buildFallback(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _domain,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: widget.heroColor),
        ),
        const SizedBox(height: 2),
        Text(
          widget.url,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 11, color: scheme.onSurface.withValues(alpha: 0.5)),
        ),
      ],
    );
  }
}

List<String> extractUrls(String text) {
  if (text.isEmpty) return [];
  final regex = RegExp("https?://[^\\s)<>\"']+", caseSensitive: false);
  final matches = regex.allMatches(text);
  final urls = <String>{};
  for (final m in matches) {
    var url = m.group(0)!;
    while (url.isNotEmpty && '.,;!?:"\''.contains(url[url.length - 1])) {
      url = url.substring(0, url.length - 1);
    }
    if (url.isNotEmpty) urls.add(url);
  }
  return urls.toList();
}

String safePreviewUrl(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return '';
  s = s.replaceAll('\\', '/');
  if (s.startsWith('//')) s = 'https:$s';
  final u = Uri.tryParse(s);
  if (u == null || !u.hasScheme) {
    s = 'https://$s';
  }
  return s;
}
