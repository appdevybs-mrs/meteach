# Mail: Link Preview + Link Confirmation Dialog + Long-Press Selection Fix

## Overview

Adds 3 features to all 4 mail thread screens:

1. **Link Preview** – When a message contains a URL, show a rich preview card (OG image, title, description, domain)
2. **Link Click Confirmation** – Tapping a link shows a beautiful branded popup asking whether to open
3. **Fix Long-Press Selection** – Changes `MarkdownBody(selectable: true)` → `selectable: false` so the outer `GestureDetector.onLongPress` actually fires reliably for message selection

## Files to Create

### 1. `lib/shared/link_preview_widget.dart`

New shared widget. Full content:

<fileContent>
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
        errorBuilder: (_, __, ___) => Container(
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
        Container(height: 12, width: 180, decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(4))),
        const SizedBox(height: 6),
        Container(height: 10, width: 140, decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(4))),
        const SizedBox(height: 4),
        Container(height: 10, width: 100, decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(4))),
      ],
    );
  }

  Widget _buildFallback(ColorScheme scheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(_domain, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: widget.heroColor)),
        const SizedBox(height: 2),
        Text(widget.url, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: scheme.onSurface.withValues(alpha: 0.5))),
      ],
    );
  }
}

List<String> extractUrls(String text) {
  if (text.isEmpty) return [];
  final regex = RegExp(r'https?:\/\/[^\s)<>\]"\']+', caseSensitive: false);
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
</fileContent>

---

## Files to Edit

### 2. `lib/teacher/teacher_mail_thread_screen.dart`

**A) Add import** (after line 33, before the class):
```dart
import '../shared/link_preview_widget.dart';
```

**B) Add `_showLinkConfirmationDialog` method** (after `_openUrlExternal`, after line 1291):
```dart
Future<void> _showLinkConfirmationDialog(String rawUrl) async {
  final url = _safeNetworkUrl(rawUrl);
  if (url.isEmpty) return;

  final domain = Uri.tryParse(url)?.host.replaceFirst('www.', '') ?? url;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      backgroundColor: _navy,
      surfaceTintColor: Colors.transparent,
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: _orange.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.open_in_new_rounded, color: _orange, size: 40),
            ),
            const SizedBox(height: 20),
            Text(
              'Open external link?',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Colors.white),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                children: [
                  if (domain.isNotEmpty)
                    Text(domain, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: _orange)),
                  const SizedBox(height: 4),
                  Text(url, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: Colors.white70)),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text('You will be taken to your browser.', style: TextStyle(fontSize: 12, color: Colors.white54)),
            const SizedBox(height: 16),
          ],
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      actions: [
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white70,
              side: BorderSide(color: Colors.white.withValues(alpha: 0.2)),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: _orange,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Open Link', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ),
      ],
    ),
  );
  if (confirmed == true) await _openUrlExternal(url);
}
```

**C) Modify `MarkdownBody`** at line ~2845:
```dart
// BEFORE (lines 2845-2862):
return MarkdownBody(
  data: m.body,
  selectable: true,
  styleSheet: MarkdownStyleSheet(
    p: TextStyle(
      color: textColor,
      fontSize: 15,
      height: 1.30,
      fontWeight: FontWeight.w600,
    ),
    strong: TextStyle(
      color: textColor,
      fontSize: 15,
      height: 1.30,
      fontWeight: FontWeight.w900,
    ),
  ),
);

// AFTER:
return MarkdownBody(
  data: m.body,
  selectable: false,
  onTapLink: (_, href, __) {
    if (href != null && href.isNotEmpty) _showLinkConfirmationDialog(href);
  },
  styleSheet: MarkdownStyleSheet(
    p: TextStyle(
      color: textColor,
      fontSize: 15,
      height: 1.30,
      fontWeight: FontWeight.w600,
    ),
    strong: TextStyle(
      color: textColor,
      fontSize: 15,
      height: 1.30,
      fontWeight: FontWeight.w900,
    ),
    a: TextStyle(
      color: _orange,
      fontWeight: FontWeight.w700,
      decoration: TextDecoration.underline,
    ),
  ),
);
```

**D) Add `_buildLinkPreviews` method** (anywhere in the class, e.g. after `_buildMessageBubble`):
```dart
List<Widget> _buildLinkPreviews(String body, {required bool mine}) {
  final urls = extractUrls(body).take(3).toList();
  if (urls.isEmpty) return [];
  return [
    if (body.trim().isNotEmpty) const SizedBox(height: 6),
    ...urls.map((u) => LinkPreviewWidget(
      key: ValueKey(u),
      url: safePreviewUrl(u),
      heroColor: _orange,
      onTap: () => _showLinkConfirmationDialog(u),
    )),
  ];
}
```

**E) Add link previews to the message bubble** — inside `_buildMessageBubble`, in the `Column` children, after the `MarkdownBody` block (after line ~2864 closing `}` of the Builder) and before the attachments check (line ~2865):
```dart
// INSERT after line ~2864 (after the Builder closing brace):
..._buildLinkPreviews(m.body, mine: mine),
```

---

### 3. `lib/learner/learner_mail_thread_screen.dart`

Same pattern as teacher. Exact line numbers differ:

**A) Add import** after line 30.

**B) Add `_showLinkConfirmationDialog`** after `_openUrlExternal` (after line 725).

**C) Modify `MarkdownBody`** at line ~2133 — change `selectable: true` → `selectable: false`, add `onTapLink`, add `a:` style with `_orange`.

**D) Add `_buildLinkPreviews`** method.

**E) Insert `..._buildLinkPreviews(m.body, mine: mine),`** after the MarkdownBody Builder (after line ~2152) before the attachments check.

---

### 4. `lib/admin/mail_topic_thread_screen.dart`

**A) Add import** after line 27.

**B) Add `_showLinkConfirmationDialog`** after `_openUrlExternal` (after line 1103).
Note: This screen uses `Colors.orange` for selection, but for the dialog/prompt use the same `_orange = 0xFFEC740A` color — add a local `static const Color _orange = Color(0xFFEC740A);` if not already defined, or use a navy dialog. Actually this screen doesn't define `_orange` as a constant; for the dialog use navy background and define a local orange:

```dart
// Use navy from the existing bubble style
// Add at class level:
static const Color _dialogOrange = Color(0xFFEC740A);
```

**C) Modify `MarkdownBody`** at line ~2536 — `selectable: false`, `onTapLink`, add `a:` style.

**D) Add `_buildLinkPreviews`** method.

**E) Insert link previews after MarkdownBody** in the Column children.

---

### 5. `lib/admin/admin_teacher_mail_thread_screen.dart`

**A) Add import** after line 30.

**B) Add `_showLinkConfirmationDialog`** after `_openUrlExternal` (after line 1443).

**C) Modify `MarkdownBody`** at line ~2310 — `selectable: false`, `onTapLink`, add `a:` style.

**D) Add `_buildLinkPreviews`** method.

**E) Insert link previews after MarkdownBody** in the Column children.

---

## Key Design Decisions

| Aspect | Choice |
|--------|--------|
| Link detection | Regex on raw body text (extracts plain URLs, cleans trailing punctuation) |
| OG metadata fetch | `http.get` with 8s timeout, User-Agent header, regex parsing |
| Caching | Static `Map<String, _PreviewData>` in widget state |
| Preview card layout | Horizontal: thumbnail (80px) + text (title, description, domain) |
| Max previews per msg | 3 (`.take(3)`) |
| Link tap handling | `MarkdownBody.onTapLink` → confirmation dialog → `_openUrlExternal` |
| Selection fix | `selectable: false` on MarkdownBody so outer GestureDetector.onLongPress wins |
| Link style in markdown | Orange + underline via `a:` in `MarkdownStyleSheet` |
| Dialog theme | Navy background, orange accent, matching app branding |
