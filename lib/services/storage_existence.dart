import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'backend_api.dart';

enum StorageCheckResult { exists, missing, unknown }

class StorageTarget {
  const StorageTarget({required this.root, required this.path});

  final String root;
  final String path;
}

class StorageExistence {
  static const Set<String> _knownHosts = {
    'api.yourbridgeschool.com',
    'yourbridgeschool.com',
    'www.yourbridgeschool.com',
  };

  static StorageTarget? targetFromUrl(
    String rawUrl, {
    Set<String> allowedRoots = const {
      'courses',
      'games',
      'stories',
      'shared_files',
    },
  }) {
    final trimmed = rawUrl.trim();
    if (trimmed.isEmpty) return null;

    final uri = Uri.tryParse(trimmed);
    if (uri == null) return null;

    if (uri.scheme != 'http' && uri.scheme != 'https') return null;
    if (!_knownHosts.contains(uri.host.toLowerCase())) return null;

    final segments = uri.pathSegments
        .map(Uri.decodeComponent)
        .where((s) => s.trim().isNotEmpty)
        .toList();
    if (segments.length < 2) return null;

    var rootIndex = -1;
    for (var i = 0; i < segments.length; i++) {
      if (allowedRoots.contains(segments[i].toLowerCase())) {
        rootIndex = i;
        break;
      }
    }
    if (rootIndex < 0 || rootIndex >= segments.length - 1) return null;

    final root = segments[rootIndex].toLowerCase();
    final path = segments.sublist(rootIndex + 1).join('/').trim();
    if (path.isEmpty) return null;

    return StorageTarget(root: root, path: path);
  }

  static Future<StorageCheckResult> checkUrlExistsOnManagedStorage(
    String rawUrl, {
    required String expect,
    Set<String> allowedRoots = const {
      'courses',
      'games',
      'stories',
      'shared_files',
    },
  }) async {
    final target = targetFromUrl(rawUrl, allowedRoots: allowedRoots);
    if (target == null) return StorageCheckResult.unknown;

    return checkPathExists(
      root: target.root,
      path: target.path,
      expect: expect,
    );
  }

  static Future<StorageCheckResult> checkPathExists({
    required String root,
    required String path,
    required String expect,
  }) async {
    try {
      final uri = await BackendApi.withAuthQuery(
        BackendApi.uri('check_item_exists_secure.php'),
      );
      final headers = await BackendApi.authHeaders();
      final authFields = await BackendApi.authFormFields();

      final response = await http
          .post(
            uri,
            headers: headers,
            body: {'root': root, 'path': path, 'expect': expect, ...authFields},
          )
          .timeout(const Duration(seconds: 12));

      final body = response.body.trim();
      if (!body.startsWith('{')) return StorageCheckResult.unknown;

      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) return StorageCheckResult.unknown;
      if (decoded['success'] != true) return StorageCheckResult.unknown;

      final exists = decoded['exists'] == true;
      return exists ? StorageCheckResult.exists : StorageCheckResult.missing;
    } catch (_) {
      return StorageCheckResult.unknown;
    }
  }
}
