import 'dart:async';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/widgets.dart';

class StoryPreloadService {
  StoryPreloadService._();

  static final DatabaseReference _storiesRef = FirebaseDatabase.instance.ref(
    'stories',
  );

  static const int _thumbBatchSize = 4;
  static const Duration _ttl = Duration(minutes: 5);

  static bool _isPreloading = false;
  static int _lastLoadedAtMs = 0;
  static List<MapEntry<String, Map<String, dynamic>>> _cachedStories =
      <MapEntry<String, Map<String, dynamic>>>[];
  static final Set<String> _precachedThumbUrls = <String>{};

  static int _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  static List<MapEntry<String, Map<String, dynamic>>> warmStories() {
    return List<MapEntry<String, Map<String, dynamic>>>.from(_cachedStories);
  }

  static bool get hasFreshCache {
    if (_cachedStories.isEmpty || _lastLoadedAtMs <= 0) return false;
    final age = DateTime.now().millisecondsSinceEpoch - _lastLoadedAtMs;
    return age <= _ttl.inMilliseconds;
  }

  static Future<void> preloadFromHome(BuildContext context) async {
    if (_isPreloading) return;
    if (hasFreshCache) {
      if (context.mounted) {
        unawaited(_precacheThumbsInBatches(context, _cachedStories));
      }
      return;
    }

    _isPreloading = true;
    try {
      final snap = await _storiesRef.get();
      final value = snap.value;
      if (value is! Map) return;

      final raw = Map<dynamic, dynamic>.from(value);
      final items = raw.entries
          .map((entry) {
            final storyId = entry.key.toString();
            final storyValue = entry.value;
            final story = storyValue is Map
                ? Map<String, dynamic>.from(storyValue)
                : <String, dynamic>{};
            story['storyId'] = storyId;
            return MapEntry(storyId, story);
          })
          .where((entry) {
            final status = (entry.value['status'] ?? '')
                .toString()
                .trim()
                .toLowerCase();
            return status == 'ready';
          })
          .toList();

      items.sort((a, b) {
        final aUpdated = _toInt(a.value['updatedAt']);
        final bUpdated = _toInt(b.value['updatedAt']);
        return bUpdated.compareTo(aUpdated);
      });

      _cachedStories = items;
      _lastLoadedAtMs = DateTime.now().millisecondsSinceEpoch;
      if (context.mounted) {
        unawaited(_precacheThumbsInBatches(context, items));
      }
    } catch (_) {
      return;
    } finally {
      _isPreloading = false;
    }
  }

  static Future<void> _precacheThumbsInBatches(
    BuildContext context,
    List<MapEntry<String, Map<String, dynamic>>> stories,
  ) async {
    final deduped = <String>[];
    final seen = <String>{};
    for (final item in stories) {
      final url = (item.value['thumbnail'] ?? '').toString().trim();
      if (url.isEmpty) continue;
      if (seen.add(url) && !_precachedThumbUrls.contains(url)) {
        deduped.add(url);
      }
    }

    for (var i = 0; i < deduped.length; i += _thumbBatchSize) {
      final end = (i + _thumbBatchSize < deduped.length)
          ? i + _thumbBatchSize
          : deduped.length;
      final batch = deduped.sublist(i, end);

      await Future.wait(
        batch.map((url) async {
          _precachedThumbUrls.add(url);
          try {
            await precacheImage(NetworkImage(url), context);
          } catch (_) {}
        }),
      );
    }
  }
}
