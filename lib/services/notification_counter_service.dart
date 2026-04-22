class NotificationCounterService {
  NotificationCounterService._();

  static int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  static bool _isHomeworkThreadMeta(Map<String, dynamic> m) {
    final type = (m['type'] ?? '').toString().trim().toLowerCase();
    if (type == 'homework') return true;

    final homeworkRef = (m['homeworkRef'] ?? '').toString().trim();
    if (homeworkRef.isNotEmpty) return true;

    final subject = (m['subject'] ?? '').toString().trim().toLowerCase();
    return subject.startsWith('[hw]');
  }

  static int mailUnread(dynamic snapshotValue, {bool excludeHomework = false}) {
    if (snapshotValue is! Map) return 0;
    int total = 0;

    snapshotValue.forEach((_, raw) {
      if (raw is! Map) return;
      final m = raw.map((k, v) => MapEntry(k.toString(), v));
      if (m['deletedAt'] != null) return;
      if (excludeHomework && _isHomeworkThreadMeta(m)) return;
      total += _toInt(m['unreadCount'] ?? m['unread']);
    });

    return total;
  }

  static ({int newCount, int pendingCount}) reminderCounts(
    dynamic snapshotValue,
  ) {
    if (snapshotValue is! Map) {
      return (newCount: 0, pendingCount: 0);
    }

    int newCount = 0;
    int pendingCount = 0;

    snapshotValue.forEach((_, raw) {
      if (raw is! Map) return;
      final m = raw.map((k, v) => MapEntry(k.toString(), v));
      final status = (m['status'] ?? 'new').toString().trim().toLowerCase();

      if (status == 'new') {
        newCount += 1;
      }
      if (status != 'done') {
        pendingCount += 1;
      }
    });

    return (newCount: newCount, pendingCount: pendingCount);
  }

  static ({int unseen, int today}) flashAlertCounts(
    dynamic root,
    DateTime now,
  ) {
    int unseen = 0;
    int today = 0;

    if (root is! Map) {
      return (unseen: unseen, today: today);
    }

    root.forEach((_, userNode) {
      if (userNode is! Map) return;
      final alerts = Map<dynamic, dynamic>.from(userNode);
      alerts.forEach((_, rawAlert) {
        if (rawAlert is! Map) return;
        final m = rawAlert.map((k, v) => MapEntry(k.toString(), v));
        final archivedAt = _toInt(m['archivedAt']);
        if (archivedAt > 0) return;
        final status = (m['status'] ?? '').toString().trim().toLowerCase();
        final seenAt = _toInt(m['seenAt'] ?? m['seenAtMs']);
        if (status != 'seen' && seenAt <= 0) unseen += 1;

        final createdAt = _toInt(m['createdAt'] ?? m['createdAtMs']);
        if (createdAt > 0) {
          final d = DateTime.fromMillisecondsSinceEpoch(createdAt);
          if (d.year == now.year && d.month == now.month && d.day == now.day) {
            today += 1;
          }
        }
      });
    });

    return (unseen: unseen, today: today);
  }
}
