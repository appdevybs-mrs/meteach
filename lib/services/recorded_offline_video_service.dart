import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum RecordedDownloadStatus {
  notDownloaded,
  queued,
  downloading,
  downloaded,
  failed,
  cancelled,
}

class RecordedVideoDownloadRequest {
  const RecordedVideoDownloadRequest({
    required this.uid,
    required this.courseKey,
    required this.courseId,
    required this.sessionId,
    required this.sessionTitle,
    required this.videoUrl,
    required this.expiresAt,
    this.materialsUrl = '',
  });

  final String uid;
  final String courseKey;
  final String courseId;
  final String sessionId;
  final String sessionTitle;
  final String videoUrl;
  final int expiresAt;
  final String materialsUrl;
}

class RecordedVideoDownloadInfo {
  const RecordedVideoDownloadInfo({
    required this.uid,
    required this.courseKey,
    required this.courseId,
    required this.sessionId,
    required this.sessionTitle,
    required this.videoUrl,
    required this.status,
    this.filePath = '',
    this.bytesDownloaded = 0,
    this.bytesTotal = 0,
    this.downloadedAt = 0,
    this.expiresAt = 0,
    this.error = '',
    this.materialsUrl = '',
    this.materialsFilePath = '',
  });

  final String uid;
  final String courseKey;
  final String courseId;
  final String sessionId;
  final String sessionTitle;
  final String videoUrl;
  final RecordedDownloadStatus status;
  final String filePath;
  final int bytesDownloaded;
  final int bytesTotal;
  final int downloadedAt;
  final int expiresAt;
  final String error;
  final String materialsUrl;
  final String materialsFilePath;

  double get progress {
    if (status == RecordedDownloadStatus.downloaded) return 1;
    if (bytesTotal <= 0) return 0;
    return (bytesDownloaded / bytesTotal).clamp(0.0, 1.0).toDouble();
  }

  bool get isDownloaded => status == RecordedDownloadStatus.downloaded;

  RecordedVideoDownloadInfo copyWith({
    RecordedDownloadStatus? status,
    String? filePath,
    int? bytesDownloaded,
    int? bytesTotal,
    int? downloadedAt,
    int? expiresAt,
    String? error,
    String? videoUrl,
    String? sessionTitle,
    String? materialsUrl,
    String? materialsFilePath,
  }) {
    return RecordedVideoDownloadInfo(
      uid: uid,
      courseKey: courseKey,
      courseId: courseId,
      sessionId: sessionId,
      sessionTitle: sessionTitle ?? this.sessionTitle,
      videoUrl: videoUrl ?? this.videoUrl,
      status: status ?? this.status,
      filePath: filePath ?? this.filePath,
      bytesDownloaded: bytesDownloaded ?? this.bytesDownloaded,
      bytesTotal: bytesTotal ?? this.bytesTotal,
      downloadedAt: downloadedAt ?? this.downloadedAt,
      expiresAt: expiresAt ?? this.expiresAt,
      error: error ?? this.error,
      materialsUrl: materialsUrl ?? this.materialsUrl,
      materialsFilePath: materialsFilePath ?? this.materialsFilePath,
    );
  }

  Map<String, dynamic> toJson() => {
    'uid': uid,
    'courseKey': courseKey,
    'courseId': courseId,
    'sessionId': sessionId,
    'sessionTitle': sessionTitle,
    'videoUrl': videoUrl,
    'status': status.name,
    'filePath': filePath,
    'bytesDownloaded': bytesDownloaded,
    'bytesTotal': bytesTotal,
    'downloadedAt': downloadedAt,
    'expiresAt': expiresAt,
    'error': error,
    'materialsUrl': materialsUrl,
    'materialsFilePath': materialsFilePath,
  };

  factory RecordedVideoDownloadInfo.fromJson(Map<String, dynamic> json) {
    final rawStatus = (json['status'] ?? '').toString();
    final status = RecordedDownloadStatus.values.firstWhere(
      (item) => item.name == rawStatus,
      orElse: () => RecordedDownloadStatus.notDownloaded,
    );
    return RecordedVideoDownloadInfo(
      uid: (json['uid'] ?? '').toString(),
      courseKey: (json['courseKey'] ?? '').toString(),
      courseId: (json['courseId'] ?? '').toString(),
      sessionId: (json['sessionId'] ?? '').toString(),
      sessionTitle: (json['sessionTitle'] ?? '').toString(),
      videoUrl: (json['videoUrl'] ?? '').toString(),
      status: status,
      filePath: (json['filePath'] ?? '').toString(),
      bytesDownloaded: _asInt(json['bytesDownloaded']),
      bytesTotal: _asInt(json['bytesTotal']),
      downloadedAt: _asInt(json['downloadedAt']),
      expiresAt: _asInt(json['expiresAt']),
      error: (json['error'] ?? '').toString(),
      materialsUrl: (json['materialsUrl'] ?? '').toString(),
      materialsFilePath: (json['materialsFilePath'] ?? '').toString(),
    );
  }

  static int _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse((value ?? '').toString()) ?? 0;
  }
}

class RecordedOfflineVideoService extends ChangeNotifier {
  RecordedOfflineVideoService._();

  static final RecordedOfflineVideoService instance =
      RecordedOfflineVideoService._();

  static const String _prefsKey = 'recorded_offline_video_manifest_v1';

  final Map<String, RecordedVideoDownloadInfo> _items =
      <String, RecordedVideoDownloadInfo>{};
  final List<RecordedVideoDownloadRequest> _queue =
      <RecordedVideoDownloadRequest>[];

  bool _loaded = false;
  bool _running = false;
  bool _cancelCurrent = false;

  String keyFor({
    required String uid,
    required String courseKey,
    required String sessionId,
  }) => '$uid|$courseKey|$sessionId';

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw != null && raw.trim().isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          for (final entry in decoded.entries) {
            final value = entry.value;
            if (value is Map) {
              _items[entry.key.toString()] = RecordedVideoDownloadInfo.fromJson(
                Map<String, dynamic>.from(value),
              );
            }
          }
        }
      } catch (_) {}
    }
    _loaded = true;
    await cleanupMissingFiles();
  }

  RecordedVideoDownloadInfo? infoFor({
    required String uid,
    required String courseKey,
    required String sessionId,
  }) {
    return _items[keyFor(uid: uid, courseKey: courseKey, sessionId: sessionId)];
  }

  List<RecordedVideoDownloadInfo> infosForCourse({
    required String uid,
    required String courseKey,
  }) {
    return _items.values
        .where((item) => item.uid == uid && item.courseKey == courseKey)
        .toList(growable: false);
  }

  Future<String?> localPathFor({
    required String uid,
    required String courseKey,
    required String sessionId,
    required String videoUrl,
  }) async {
    await ensureLoaded();
    final info = infoFor(uid: uid, courseKey: courseKey, sessionId: sessionId);
    if (info == null || !info.isDownloaded || info.videoUrl != videoUrl) {
      return null;
    }
    final path = info.filePath.trim();
    if (path.isEmpty) return null;
    final file = File(path);
    if (await file.exists()) return path;
    await delete(uid: uid, courseKey: courseKey, sessionId: sessionId);
    return null;
  }

  Future<String?> localMaterialsPathFor({
    required String uid,
    required String courseKey,
    required String sessionId,
  }) async {
    await ensureLoaded();
    final info = infoFor(uid: uid, courseKey: courseKey, sessionId: sessionId);
    if (info == null || !info.isDownloaded) return null;
    final path = info.materialsFilePath.trim();
    if (path.isEmpty) return null;
    final file = File(path);
    if (await file.exists()) return path;
    return null;
  }

  Future<void> enqueueAll(List<RecordedVideoDownloadRequest> requests) async {
    await ensureLoaded();
    for (final request in requests) {
      if (request.uid.trim().isEmpty ||
          request.courseKey.trim().isEmpty ||
          request.sessionId.trim().isEmpty ||
          request.videoUrl.trim().isEmpty) {
        continue;
      }
      final key = keyFor(
        uid: request.uid,
        courseKey: request.courseKey,
        sessionId: request.sessionId,
      );
      final current = _items[key];
      if (current?.status == RecordedDownloadStatus.downloaded &&
          current?.videoUrl == request.videoUrl) {
        continue;
      }
      if (_queue.any(
        (item) =>
            item.uid == request.uid &&
            item.courseKey == request.courseKey &&
            item.sessionId == request.sessionId,
      )) {
        continue;
      }
      _items[key] = RecordedVideoDownloadInfo(
        uid: request.uid,
        courseKey: request.courseKey,
        courseId: request.courseId,
        sessionId: request.sessionId,
        sessionTitle: request.sessionTitle,
        videoUrl: request.videoUrl,
        status: RecordedDownloadStatus.queued,
        expiresAt: request.expiresAt,
        materialsUrl: request.materialsUrl,
      );
      _queue.add(request);
    }
    await _save();
    notifyListeners();
    unawaited(_runQueue());
  }

  void cancelCurrent() {
    _cancelCurrent = true;
  }

  Future<void> delete({
    required String uid,
    required String courseKey,
    required String sessionId,
  }) async {
    await ensureLoaded();
    final key = keyFor(uid: uid, courseKey: courseKey, sessionId: sessionId);
    final info = _items.remove(key);
    _queue.removeWhere(
      (item) =>
          item.uid == uid &&
          item.courseKey == courseKey &&
          item.sessionId == sessionId,
    );
    if (info != null) {
      await _deleteFileIfExists(info.filePath);
      await _deleteFileIfExists('${info.filePath}.part');
      if (info.materialsFilePath.trim().isNotEmpty) {
        await _deleteFileIfExists(info.materialsFilePath);
      }
    }
    await _save();
    notifyListeners();
  }

  Future<void> deleteMany(
    Iterable<RecordedVideoDownloadRequest> requests,
  ) async {
    for (final request in requests) {
      await delete(
        uid: request.uid,
        courseKey: request.courseKey,
        sessionId: request.sessionId,
      );
    }
  }

  Future<void> cleanupMissingFiles() async {
    final stale = <String>[];
    for (final entry in _items.entries) {
      final info = entry.value;
      if (!info.isDownloaded) continue;
      final path = info.filePath.trim();
      if (path.isEmpty || !await File(path).exists()) stale.add(entry.key);
    }
    if (stale.isEmpty) return;
    for (final key in stale) {
      final info = _items[key];
      if (info == null) continue;
      _items[key] = info.copyWith(
        status: RecordedDownloadStatus.notDownloaded,
        filePath: '',
        bytesDownloaded: 0,
        error: '',
      );
    }
    await _save();
    notifyListeners();
  }

  Future<void> _runQueue() async {
    if (_running) return;
    _running = true;
    try {
      while (_queue.isNotEmpty) {
        final next = _queue.removeAt(0);
        await _download(next);
      }
    } finally {
      _running = false;
      _cancelCurrent = false;
    }
  }

  Future<void> _download(RecordedVideoDownloadRequest request) async {
    final key = keyFor(
      uid: request.uid,
      courseKey: request.courseKey,
      sessionId: request.sessionId,
    );
    http.Client? client;
    IOSink? sink;
    File? partFile;
    try {
      final uri = Uri.tryParse(request.videoUrl.trim());
      if (uri == null || !uri.hasScheme) {
        throw Exception('Invalid video URL.');
      }

      final out = await _targetFile(request);
      partFile = File('${out.path}.part');
      if (!await out.parent.exists()) {
        await out.parent.create(recursive: true);
      }
      if (await partFile.exists()) await partFile.delete();

      _items[key] = (_items[key] ?? _infoFromRequest(request)).copyWith(
        status: RecordedDownloadStatus.downloading,
        filePath: out.path,
        bytesDownloaded: 0,
        bytesTotal: 0,
        error: '',
      );
      await _save();
      notifyListeners();

      client = http.Client();
      final response = await client
          .send(http.Request('GET', uri))
          .timeout(const Duration(seconds: 30));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('HTTP ${response.statusCode}');
      }

      final total = response.contentLength ?? 0;
      var received = 0;
      sink = partFile.openWrite();
      await for (final chunk in response.stream) {
        if (_cancelCurrent) {
          throw const _RecordedDownloadCancelled();
        }
        sink.add(chunk);
        received += chunk.length;
        _items[key] = (_items[key] ?? _infoFromRequest(request)).copyWith(
          status: RecordedDownloadStatus.downloading,
          filePath: out.path,
          bytesDownloaded: received,
          bytesTotal: total,
          error: '',
        );
        notifyListeners();
      }
      await sink.flush();
      await sink.close();
      sink = null;

      if (total > 0 && received < total) {
        throw Exception('Download interrupted.');
      }
      if (await out.exists()) await out.delete();
      await partFile.rename(out.path);

      String? materialsFilePath;
      if (request.materialsUrl.trim().isNotEmpty) {
        final matOut = await _materialsTargetFile(request);
        if (matOut != null) {
          if (!await matOut.parent.exists()) {
            await matOut.parent.create(recursive: true);
          }
          final matUri = Uri.tryParse(request.materialsUrl.trim());
          if (matUri != null && matUri.hasScheme) {
            final matClient = http.Client();
            try {
              final matResponse = await matClient
                  .send(http.Request('GET', matUri))
                  .timeout(const Duration(seconds: 30));
              if (matResponse.statusCode >= 200 && matResponse.statusCode < 300) {
                final matSink = matOut.openWrite();
                try {
                  await matSink.addStream(matResponse.stream);
                  await matSink.flush();
                } finally {
                  await matSink.close();
                }
                materialsFilePath = matOut.path;
              }
            } finally {
              matClient.close();
            }
          }
        }
      }

      _items[key] = (_items[key] ?? _infoFromRequest(request)).copyWith(
        status: RecordedDownloadStatus.downloaded,
        filePath: out.path,
        bytesDownloaded: received,
        bytesTotal: total > 0 ? total : received,
        downloadedAt: DateTime.now().millisecondsSinceEpoch,
        expiresAt: request.expiresAt,
        error: '',
        materialsFilePath: materialsFilePath ?? '',
      );
      await _save();
      notifyListeners();
    } on _RecordedDownloadCancelled {
      _items[key] = (_items[key] ?? _infoFromRequest(request)).copyWith(
        status: RecordedDownloadStatus.cancelled,
        error: 'Download cancelled.',
      );
      await _save();
      notifyListeners();
    } catch (e) {
      _items[key] = (_items[key] ?? _infoFromRequest(request)).copyWith(
        status: RecordedDownloadStatus.failed,
        error: e.toString(),
      );
      await _save();
      notifyListeners();
    } finally {
      await sink?.close();
      client?.close();
      if (partFile != null && await partFile.exists()) {
        try {
          await partFile.delete();
        } catch (_) {}
      }
      _cancelCurrent = false;
    }
  }

  RecordedVideoDownloadInfo _infoFromRequest(
    RecordedVideoDownloadRequest request,
  ) {
    return RecordedVideoDownloadInfo(
      uid: request.uid,
      courseKey: request.courseKey,
      courseId: request.courseId,
      sessionId: request.sessionId,
      sessionTitle: request.sessionTitle,
      videoUrl: request.videoUrl,
      status: RecordedDownloadStatus.notDownloaded,
      expiresAt: request.expiresAt,
      materialsUrl: request.materialsUrl,
    );
  }

  Future<File> _targetFile(RecordedVideoDownloadRequest request) async {
    final base = await getApplicationSupportDirectory();
    final ext = _extensionFromUrl(request.videoUrl);
    final dir = Directory(
      '${base.path}/recorded_videos/${_safePart(request.uid)}/${_safePart(request.courseKey)}/${_safePart(request.sessionId)}',
    );
    return File('${dir.path}/video.$ext');
  }

  Future<File?> _materialsTargetFile(RecordedVideoDownloadRequest request) async {
    final url = request.materialsUrl.trim();
    if (url.isEmpty) return null;
    final base = await getApplicationSupportDirectory();
    final ext = _extensionFromUrl(url);
    final dir = Directory(
      '${base.path}/recorded_videos/${_safePart(request.uid)}/${_safePart(request.courseKey)}/${_safePart(request.sessionId)}',
    );
    return File('${dir.path}/materials.$ext');
  }

  String _extensionFromUrl(String raw) {
    final uri = Uri.tryParse(raw.trim());
    final segment = uri == null || uri.pathSegments.isEmpty
        ? ''
        : uri.pathSegments.last;
    final index = segment.lastIndexOf('.');
    if (index > 0 && index < segment.length - 1) {
      final ext = segment.substring(index + 1).toLowerCase();
      if (RegExp(r'^[a-z0-9]{2,5}$').hasMatch(ext)) return ext;
    }
    return 'mp4';
  }

  String _safePart(String raw) {
    final safe = raw
        .trim()
        .replaceAll(RegExp(r'[^a-zA-Z0-9._-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    return safe.isEmpty ? 'item' : safe;
  }

  Future<void> _deleteFileIfExists(String path) async {
    if (path.trim().isEmpty) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode(_items.map((key, value) => MapEntry(key, value.toJson()))),
    );
  }
}

class _RecordedDownloadCancelled implements Exception {
  const _RecordedDownloadCancelled();
}
