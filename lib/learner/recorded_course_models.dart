part of 'recorded_course_study_screen.dart';

int _asInt(dynamic v) {
  if (v == null) return 0;
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse(v.toString()) ?? 0;
}

List<Map<String, dynamic>> _asListOfMaps(dynamic node) {
  final out = <Map<String, dynamic>>[];

  if (node is List) {
    for (final item in node) {
      if (item is Map) {
        out.add(Map<String, dynamic>.from(item));
      }
    }
    return out;
  }

  if (node is Map) {
    for (final entry in node.entries) {
      final value = entry.value;
      if (value is Map) {
        out.add(Map<String, dynamic>.from(value));
      }
    }
  }

  return out;
}

class _ExpiryStyle {
  const _ExpiryStyle({
    required this.bg,
    required this.border,
    required this.fg,
    required this.label,
    required this.icon,
  });

  final Color bg;
  final Color border;
  final Color fg;
  final String label;
  final IconData icon;
}

class _SessionRef {
  const _SessionRef({
    required this.unitIndex,
    required this.sessionIndex,
    required this.unit,
    required this.session,
  });

  final int unitIndex;
  final int sessionIndex;
  final _RecordedUnit unit;
  final _RecordedSession session;
}

class _DownloadSummary {
  const _DownloadSummary({
    this.total = 0,
    this.downloaded = 0,
    this.failed = 0,
    this.active = 0,
    this.bytesDownloaded = 0,
    this.bytesTotal = 0,
  });

  final int total;
  final int downloaded;
  final int failed;
  final int active;
  final int bytesDownloaded;
  final int bytesTotal;

  double get progress {
    if (total <= 0) return 0;
    if (bytesTotal > 0) {
      return (bytesDownloaded / bytesTotal).clamp(0.0, 1.0).toDouble();
    }
    return (downloaded / total).clamp(0.0, 1.0).toDouble();
  }

  bool get allDownloaded => total > 0 && downloaded == total;
}

class _RecordedProgress {
  const _RecordedProgress({
    this.videoCompleted = false,
    this.materialsCompleted = false,
    this.completed = false,
    this.videoCompletedAt = 0,
    this.materialsCompletedAt = 0,
  });

  final bool videoCompleted;
  final bool materialsCompleted;
  final bool completed;
  final int videoCompletedAt;
  final int materialsCompletedAt;

  _RecordedProgress copyWith({
    bool? videoCompleted,
    bool? materialsCompleted,
    bool? completed,
    int? videoCompletedAt,
    int? materialsCompletedAt,
  }) {
    return _RecordedProgress(
      videoCompleted: videoCompleted ?? this.videoCompleted,
      materialsCompleted: materialsCompleted ?? this.materialsCompleted,
      completed: completed ?? this.completed,
      videoCompletedAt: videoCompletedAt ?? this.videoCompletedAt,
      materialsCompletedAt: materialsCompletedAt ?? this.materialsCompletedAt,
    );
  }

  Map<String, dynamic> toMap() => {
    'videoCompleted': videoCompleted,
    'materialsCompleted': materialsCompleted,
    'completed': completed,
    'videoCompletedAt': videoCompletedAt,
    'materialsCompletedAt': materialsCompletedAt,
  };

  factory _RecordedProgress.fromMap(Map<String, dynamic> map) {
    bool asBool(dynamic v) {
      if (v is bool) return v;
      final s = (v ?? '').toString().trim().toLowerCase();
      return s == 'true' || s == '1';
    }

    return _RecordedProgress(
      videoCompleted: asBool(map['videoCompleted']),
      materialsCompleted: asBool(map['materialsCompleted']),
      completed: asBool(map['completed']),
      videoCompletedAt: _asInt(map['videoCompletedAt']),
      materialsCompletedAt: _asInt(map['materialsCompletedAt']),
    );
  }
}

class _RecordedUnit {
  _RecordedUnit({
    required this.id,
    required this.title,
    required this.otherTitle,
    required this.description,
    required this.order,
    required this.sessions,
  });

  final String id;
  final String title;
  final String otherTitle;
  final String description;
  final int order;
  final List<_RecordedSession> sessions;

  String get displayTitle {
    final base = title.trim().isNotEmpty ? title.trim() : 'Untitled Unit';
    if (otherTitle.trim().isEmpty) return base;
    return '$base (${otherTitle.trim()})';
  }

  factory _RecordedUnit.fromMap(Map<String, dynamic> map) {
    final rawSessions = _asListOfMaps(map['sessions']);
    final sessions = rawSessions
        .map((e) => _RecordedSession.fromMap(e))
        .toList();

    return _RecordedUnit(
      id: (map['id'] ?? '').toString(),
      title: (map['title'] ?? '').toString(),
      otherTitle: (map['otherTitle'] ?? '').toString(),
      description: (map['description'] ?? '').toString(),
      order: _asInt(map['order']),
      sessions: sessions,
    );
  }
}

class _RecordedSession {
  _RecordedSession({
    required this.id,
    required this.title,
    required this.objective,
    required this.order,
    required this.sessionNumber,
    required this.videoUrl,
    required this.materialsUrl,
    this.materialsHidden = false,
  });

  final String id;
  final String title;
  final String objective;
  final int order;
  final int sessionNumber;
  final String videoUrl;
  final String materialsUrl;
  final bool materialsHidden;

  factory _RecordedSession.fromMap(Map<String, dynamic> map) {
    return _RecordedSession(
      id: (map['id'] ?? '').toString().trim(),
      title: (map['title'] ?? '').toString(),
      objective: (map['objective'] ?? '').toString(),
      order: _asInt(map['order']),
      sessionNumber: _asInt(map['sessionNumber']),
      videoUrl: (map['videoUrl'] ?? '').toString(),
      materialsUrl: (map['materialsUrl'] ?? '').toString(),
      materialsHidden: map['materialsHidden'] == true,
    );
  }
}
