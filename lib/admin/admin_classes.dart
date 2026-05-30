// lib/admin/admin_classes.dart
//
// ✅ Updates (WITHOUT breaking your logic / DB structure / working features)
//
// 1) Class card order changed (as you requested):
//    - Starts with: course_level + course_title
//    - Then: course_id
//    - Then the rest
//    - Removed showing course_code everywhere in the LIST card (and also in the editor “Course:” preview)
//
// 2) Open / Closed badge improved (clear colors)
//
// 3) FIXED learner picker bug:
//    - If learner becomes NOT enrolled after you previously selected them,
//      you can NOW untick them (we only block ticking ON, not ticking OFF).
//    - Also, before saving: we auto-remove any selected learners who are no longer enrolled
//      (so the dialog can always save, and you won’t get stuck).
//
// 4) Added filter per day (Sat..Fri) + "All days"
//    - Works by checking class.schedule.sessions[].day
//
// 5) Added search per learner (optional but useful):
//    - Searching now also matches learner name/serial inside cls["learners"]
//
// 6) Extra small useful UI:
//    - Filter chips: All / Open only / Closed only
//    - Small summary line: “Showing X of Y”
//    - Keeps ALL existing create/edit/delete/status/schedule/sync logic intact.
//

import 'dart:async';
import 'dart:math';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../shared/app_feedback.dart';
import '../shared/admin_web_layout.dart';
import '../shared/human_error.dart';
import '../shared/payment_status.dart';
import '../shared/study_variant.dart';
import '../services/mail_consistency_service.dart';
import '../services/push_dispatch_service.dart';
import '../services/reminder_consistency_service.dart';
import 'admin_learner_mail_topics_screen.dart';
import 'admin_learners.dart';

enum _QuickLearnerReminder { payment, absence, late, empty }

class AdminClassesScreen extends StatefulWidget {
  final String? openClassId;
  final String? openClassSearchId;
  const AdminClassesScreen({
    super.key,
    this.openClassId,
    this.openClassSearchId,
  });

  @override
  State<AdminClassesScreen> createState() => _AdminClassesScreenState();
}

class _AdminClassesScreenState extends State<AdminClassesScreen> {
  // ====== DB NODES ======
  static const String coursesNode = "courses";
  static const String classesNode = "classes";
  static const String usersNode = "users";
  static const String syllabiNode = "syllabi";
  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  late final DatabaseReference _coursesRef = _db.child(coursesNode);
  late final DatabaseReference _classesRef = _db.child(classesNode);
  late final DatabaseReference _usersRef = _db.child(usersNode);
  late final DatabaseReference _syllabiRef = _db.child(syllabiNode);
  // ===== Courses cache =====
  bool _loadingCourses = true;
  List<Map<String, dynamic>> _courses = [];
  late final Future<void> _bootFuture;
  Future<DataSnapshot>? _classesFuture;

  // ===== Learners cache (ALL learners) =====
  bool _loadingLearners = true;
  List<Map<String, dynamic>> _allLearners =
      []; // {uid, serial, name, coursesMap}

  // ===== Teachers cache (ALL teachers) =====
  bool _loadingTeachers = true;
  Map<String, Map<String, String>> _teachersByUid =
      {}; // uid -> {uid,name,serial}
  Map<String, String> _teacherUidByName = {}; // normalizedFullName -> uid
  // ✅ Cache progress per class (so list scrolling is smooth)
  final Map<String, int> _syllabusSessionCountCache = <String, int>{};
  final Map<String, Map<int, Map<String, dynamic>>> _flexibleSyllabusCache =
      <String, Map<int, Map<String, dynamic>>>{};
  final Map<String, Map<String, _RecordedSessionMeta>>
  _recordedSessionMetaCache = <String, Map<String, _RecordedSessionMeta>>{};
  final Set<String> _expandedClassIds = <String>{};

  // ===== Pause cooldown timer & tracking =====
  Timer? _pauseCooldownTimer;
  final Set<String> _cooldownNotifiedClassIds = {};

  List<Map<String, String>> get _teachers {
    final list = _teachersByUid.values.toList();
    list.sort((a, b) => (a["name"] ?? "").compareTo(b["name"] ?? ""));
    return list;
  }

  // ===== Search =====
  final TextEditingController _searchCtrl = TextEditingController();
  String _searchQuery = "";
  Timer? _searchDebounce;

  String _flexStatusFilter = 'all';
  bool _flexUnreadOnly = false;
  bool _recordedUnreadOnly = false;
  final Set<String> _expandedFlexKeys = <String>{};
  late final Stream<Map<String, int>> _unreadByLearnerStream;
  Set<String> _flexLearnerUidsForBadge = <String>{};
  Set<String> _recordedLearnerUidsForBadge = <String>{};
  final Map<String, Future<_FlexCourseDetails>> _flexDetailsFutureByKey =
      <String, Future<_FlexCourseDetails>>{};
  final Map<String, List<Map<String, dynamic>>> _paymentsByUidCache =
      <String, List<Map<String, dynamic>>>{};
  final Map<String, Future<_ClassTabMetrics>> _classTabMetricsFutureByKey =
      <String, Future<_ClassTabMetrics>>{};

  // ===== Filters =====
  String _dayFilter = "All"; // "All" or one of week days
  bool? _openFilter; // null = all, true=open only, false=closed only
  bool _waitingStatusOnly = false;
  String _teacherFilterUid = 'all';
  String _courseFilterId = 'all';
  bool _emptyClassesOnly = false;
  bool _showClassesSearch = false;

  static const List<String> _weekDays = <String>[
    "Sat",
    "Sun",
    "Mon",
    "Tue",
    "Wed",
    "Thu",
    "Fri",
  ];

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeOpenFromTimetable();
    });

    // IMPORTANT: load teachers first, then courses
    _bootFuture = _loadTeachers().then((_) => _loadCourses());
    _classesFuture = _classesRef.get();
    _loadAllLearners();
    _unreadByLearnerStream = _unreadByLearnerMapStream();

    _searchCtrl.addListener(() {
      _searchDebounce?.cancel();
      _searchDebounce = Timer(const Duration(milliseconds: 300), () {
        if (!mounted) return;
        setState(() => _searchQuery = _normalizeSearchText(_searchCtrl.text));
      });
    });

    // ===== Pause cooldown: check immediately, then daily =====
    _checkPauseCooldowns();
    _pauseCooldownTimer = Timer.periodic(const Duration(hours: 24), (_) {
      _checkPauseCooldowns();
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    _pauseCooldownTimer?.cancel();
    super.dispose();
  }

  String _normalizeSearchText(String input) {
    return input.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
  }

  // -------------------- Notifications --------------------

  void _notify(String msg, {bool error = false}) {
    if (!mounted) return;
    AppToast.show(
      context,
      error ? humanizeUiMessage(msg) : msg,
      type: error ? AppToastType.error : AppToastType.info,
    );
  }

  Future<void> _sendLearnerQuickReminder({
    required String uid,
    required _QuickLearnerReminder type,
  }) async {
    String title = '';
    String message = '';

    switch (type) {
      case _QuickLearnerReminder.payment:
        title = 'Payment Reminder';
        message = 'Your payment is due. Please contact Your Bridge School.';
        break;
      case _QuickLearnerReminder.absence:
        title = 'Absence Reminder';
        message =
            'We noticed an absence. Please confirm with Your Bridge School.';
        break;
      case _QuickLearnerReminder.late:
        title = 'Late Arrival Reminder';
        message =
            'We noticed that you arrived late recently. Please try to come on time so you can benefit from the full lesson. We are always here to support you.';
        break;
      case _QuickLearnerReminder.empty:
        return;
    }

    final admin = FirebaseAuth.instance.currentUser;
    final reminderRef = FirebaseDatabase.instance.ref('reminders/$uid').push();
    const senderRole = 'admin';
    const targetRole = 'learner';

    try {
      await reminderRef.set(
        ReminderConsistencyService.buildReminderPayload(
          targetUid: uid,
          targetRole: targetRole,
          senderUid: admin?.uid ?? '',
          senderRole: senderRole,
          title: title,
          description: message,
          kind: type.name,
          dueAtMs: null,
          attachmentUrl: '',
          attachmentName: '',
          legacyTarget: {'uid': uid, 'name': '', 'role': 'learner'},
        ),
      );
      await ReminderConsistencyService.verifyReminderOnce(
        reminderRef: reminderRef,
        targetUid: uid,
        targetRole: targetRole,
        senderUid: admin?.uid ?? '',
        senderRole: senderRole,
      );
    } catch (e) {
      if (!mounted) return;
      _notify('RTDB write failed: $e', error: true);
      return;
    }

    try {
      await reminderRef.update({'status': 'new'});

      if (!mounted) return;
      _notify('$title saved ✅');
    } catch (e) {
      if (!mounted) return;
      _notify('Reminder saved, but final status update failed', error: true);
    }
  }

  Future<void> _sendLearnerAlert({
    required String uid,
    required String learnerName,
    required String title,
    required String message,
  }) async {
    final cleanUid = uid.trim();
    if (cleanUid.isEmpty) return;

    final cleanTitle = title.trim().isEmpty ? 'Priority alert' : title.trim();
    final cleanMessage = message.trim().isEmpty ? cleanTitle : message.trim();
    final ref = FirebaseDatabase.instance
        .ref('flash_messages/$cleanUid')
        .push();

    await ref.set({
      'title': cleanTitle,
      'message': cleanMessage,
      'tone': 'high',
      'status': 'new',
      'createdAt': ServerValue.timestamp,
      'seenAt': null,
      'resentFromId': '',
      'targetUid': cleanUid,
      'targetRole': 'learner',
      'targetName': learnerName.trim().isEmpty ? 'Learner' : learnerName.trim(),
      'targetEmail': '',
      'createdByUid': FirebaseAuth.instance.currentUser?.uid ?? '',
      'createdByName': (FirebaseAuth.instance.currentUser?.email ?? 'Admin')
          .trim(),
    });

    try {
      await PushDispatchService.dispatchToUser(
        intent: PushIntent.flashMessage,
        targetUid: cleanUid,
        title: cleanTitle,
        message: cleanMessage,
        context: const PushDispatchContext(
          screen: 'admin/admin_priority_alerts',
          action: 'learner_alert',
        ),
        eventParts: ['flash', cleanUid, ref.key ?? ''],
        data: {'targetUid': cleanUid, 'alertId': ref.key ?? ''},
        route: 'flash_messages',
      );
    } catch (_) {}
  }

  Future<void> _showLearnerAlertDialog({
    required String uid,
    required String learnerName,
  }) async {
    final titleCtrl = TextEditingController(text: 'Priority alert');
    final messageCtrl = TextEditingController();

    try {
      final sent = await showDialog<bool>(
        context: context,
        builder: (dialogContext) {
          return AlertDialog(
            title: Text(
              'Alert ${learnerName.trim().isEmpty ? 'learner' : learnerName}',
            ),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: titleCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Title',
                      prefixIcon: Icon(Icons.add_alert_rounded),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: messageCtrl,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: 'Message',
                      prefixIcon: Icon(Icons.message_rounded),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.pop(dialogContext, true),
                icon: const Icon(Icons.send_rounded),
                label: const Text('Send'),
              ),
            ],
          );
        },
      );

      if (sent != true) return;
      await _sendLearnerAlert(
        uid: uid,
        learnerName: learnerName,
        title: titleCtrl.text,
        message: messageCtrl.text,
      );
      if (!mounted) return;
      _notify('Alert sent');
    } finally {
      titleCtrl.dispose();
      messageCtrl.dispose();
    }
  }

  Future<bool> _confirmQuickAction({
    required String title,
    required String message,
    required String confirmText,
  }) async {
    return (await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(title),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(confirmText),
              ),
            ],
          ),
        )) ??
        false;
  }

  Widget _actionIconButton({
    required IconData icon,
    required Color color,
    required String tooltip,
    required Future<void> Function() onTap,
    Widget? badge,
    String? confirmTitle,
    String? confirmMessage,
    String confirmText = 'Continue',
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: () async {
          if (confirmTitle != null && confirmMessage != null) {
            final ok = await _confirmQuickAction(
              title: confirmTitle,
              message: confirmMessage,
              confirmText: confirmText,
            );
            if (!ok) return;
          }
          await onTap();
        },
        borderRadius: BorderRadius.circular(999),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color.withValues(alpha: 0.14),
                border: Border.all(color: color.withValues(alpha: 0.35)),
              ),
              child: Icon(icon, size: 16, color: color),
            ),
            if (badge != null) Positioned(right: -7, top: -7, child: badge),
          ],
        ),
      ),
    );
  }

  Widget _learnerQuickActionsBadge({
    required String uid,
    required String learnerName,
    required int unreadCount,
  }) {
    final unreadLabel = _countLabel(unreadCount);
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      alignment: WrapAlignment.end,
      children: [
        _actionIconButton(
          icon: Icons.payments_rounded,
          color: const Color(0xFF7C3AED),
          tooltip: 'Payment reminder',
          confirmTitle: 'Send payment reminder?',
          confirmMessage: 'Send a payment reminder to this learner?',
          confirmText: 'Send',
          onTap: () => _sendLearnerQuickReminder(
            uid: uid,
            type: _QuickLearnerReminder.payment,
          ),
        ),
        _actionIconButton(
          icon: Icons.event_busy_rounded,
          color: const Color(0xFFEF4444),
          tooltip: 'Absence reminder',
          confirmTitle: 'Send absence reminder?',
          confirmMessage: 'Send an absence reminder to this learner?',
          confirmText: 'Send',
          onTap: () => _sendLearnerQuickReminder(
            uid: uid,
            type: _QuickLearnerReminder.absence,
          ),
        ),
        _actionIconButton(
          icon: Icons.access_time_rounded,
          color: const Color(0xFFF97316),
          tooltip: 'Late reminder',
          confirmTitle: 'Send late reminder?',
          confirmMessage: 'Send a late reminder to this learner?',
          confirmText: 'Send',
          onTap: () => _sendLearnerQuickReminder(
            uid: uid,
            type: _QuickLearnerReminder.late,
          ),
        ),
        _actionIconButton(
          icon: Icons.add_alert_rounded,
          color: const Color(0xFF0EA5E9),
          tooltip: 'Send alert',
          onTap: () =>
              _showLearnerAlertDialog(uid: uid, learnerName: learnerName),
        ),
        _actionIconButton(
          icon: Icons.mail_rounded,
          color: const Color(0xFF2563EB),
          tooltip: unreadCount > 0 ? 'Mail ($unreadLabel)' : 'Mail',
          confirmTitle: 'Open mail?',
          confirmMessage: 'Open this learner\'s mail threads?',
          confirmText: 'Open',
          onTap: () async {
            await Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => AdminLearnerMailTopicsScreen(
                  learnerUid: uid,
                  learnerName: learnerName.trim().isEmpty
                      ? 'Learner'
                      : learnerName,
                ),
              ),
            );
          },
          badge: unreadCount > 0
              ? _countPill(unreadLabel, fontSize: 9, horizontal: 5)
              : null,
        ),
      ],
    );
  }

  // ===== Phone / SMS helpers =====

  String _learnerPhoneByUid(String uid) {
    for (final l in _allLearners) {
      if (l["uid"] == uid) return (l["phone1"] ?? "").toString().trim();
    }
    return '';
  }

  Future<void> _launchSms({required String phone, required String body}) async {
    final p = phone.trim();
    final text = body.trim();
    if (p.isEmpty) return;

    if (text.isNotEmpty) {
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) _notify('Message copied ✅');
    }

    final uri = text.isEmpty
        ? Uri.parse('sms:$p')
        : Uri.parse('sms:$p?body=${Uri.encodeComponent(text)}');

    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && mounted) {
        _notify('SMS app not available. Text is copied ✅');
      }
    } catch (_) {
      if (mounted) _notify('SMS app not available. Text is copied ✅');
    }
  }

  Future<void> _handleLearnerCall(String uid, String name) async {
    final phone = _learnerPhoneByUid(uid);
    if (phone.isEmpty) {
      _notify('No phone number available.');
      return;
    }
    final confirmed = await _confirmQuickAction(
      title: 'Call $name?',
      message: 'Call $phone?',
      confirmText: 'Call',
    );
    if (!confirmed || !mounted) return;
    final uri = Uri(scheme: 'tel', path: phone);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      _notify('Cannot open phone dialer on this device.');
    }
  }

  Future<void> _handleLearnerSms(String uid, String name) async {
    final phone = _learnerPhoneByUid(uid);
    if (phone.isEmpty) {
      _notify('No phone number available.');
      return;
    }
    final confirmed = await _confirmQuickAction(
      title: 'Send SMS',
      message: 'Send SMS to $name at $phone?',
      confirmText: 'Send',
    );
    if (!confirmed || !mounted) return;
    await _launchSms(phone: phone, body: '');
  }

  Future<void> _handleLearnerReminder(String uid, String name) async {
    final confirmed = await _confirmQuickAction(
      title: 'Send Reminder',
      message: 'Send a reminder to $name?',
      confirmText: 'Send',
    );
    if (!confirmed || !mounted) return;
    if (!mounted) return;

    final picked = await showModalBottomSheet<_QuickLearnerReminder>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 6),
            ListTile(
              leading: const Icon(Icons.payments_rounded),
              title: const Text('Payment'),
              onTap: () => Navigator.pop(ctx, _QuickLearnerReminder.payment),
            ),
            ListTile(
              leading: const Icon(Icons.event_busy_rounded),
              title: const Text('Absence'),
              onTap: () => Navigator.pop(ctx, _QuickLearnerReminder.absence),
            ),
            ListTile(
              leading: const Icon(Icons.access_time_rounded),
              title: const Text('Late'),
              onTap: () => Navigator.pop(ctx, _QuickLearnerReminder.late),
            ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );

    if (picked == null || picked == _QuickLearnerReminder.empty) return;
    await _sendLearnerQuickReminder(uid: uid, type: picked);
  }

  Future<void> _handleLearnerMail(String uid, String name) async {
    final confirmed = await _confirmQuickAction(
      title: 'Open Mail',
      message: 'Open mail for $name?',
      confirmText: 'Open',
    );
    if (!confirmed || !mounted) return;
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AdminLearnerMailTopicsScreen(
          learnerUid: uid,
          learnerName: name.isEmpty ? 'Learner' : name,
        ),
      ),
    );
  }

  Future<void> _handleMassSms(List<Map<String, String>> learners) async {
    final phones = learners
        .map((l) => _learnerPhoneByUid(l['uid'] ?? ''))
        .where((p) => p.isNotEmpty)
        .toList();

    if (phones.isEmpty) {
      _notify('No phone numbers available.');
      return;
    }

    final confirmed = await _confirmQuickAction(
      title: 'Mass SMS',
      message: 'Copy ${phones.length} learner phone number${phones.length > 1 ? 's' : ''} and open SMS?',
      confirmText: 'Copy & Open',
    );
    if (!confirmed || !mounted) return;

    final joined = phones.join(';');
    await Clipboard.setData(ClipboardData(text: joined));
    if (mounted) _notify('📋 Copied ${phones.length} phone number${phones.length > 1 ? 's' : ''} ✅');

    try {
      final uri = Uri.parse('sms:${phones.join(';')}');
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  Widget _smallActionIcon({
    required IconData icon,
    required Color color,
    required String tooltip,
    required VoidCallback onTap,
    double size = 16,
  }) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, size: size, color: color),
        ),
      ),
    );
  }

  String get _adminUid => FirebaseAuth.instance.currentUser?.uid ?? '';

  Stream<Map<String, int>> _unreadByLearnerMapStream() {
    final uid = _adminUid.trim();
    if (uid.isEmpty) {
      return Stream<Map<String, int>>.value(const <String, int>{});
    }
    final q = FirebaseDatabase.instance.ref('mail_index/$uid');
    return q.onValue.map((event) {
      final v = event.snapshot.value;
      if (v is! Map) return const <String, int>{};
      final out = <String, int>{};
      v.forEach((_, raw) {
        if (raw is! Map) return;
        final m = raw.map((k, vv) => MapEntry(k.toString(), vv));
        if (m['deletedAt'] != null) return;
        final peerUid = (m['peerUid'] ?? '').toString().trim();
        if (peerUid.isEmpty) return;
        final unread = _asInt(m['unreadCount']);
        if (unread <= 0) return;
        out[peerUid] = (out[peerUid] ?? 0) + unread;
      });
      return out;
    }).asBroadcastStream();
  }

  String _countLabel(int count) {
    if (count <= 0) return '0';
    return count > 99 ? '99+' : '$count';
  }

  Widget _countPill(
    String label, {
    double fontSize = 10,
    double horizontal = 6,
  }) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: horizontal, vertical: 1.5),
      decoration: BoxDecoration(
        color: const Color(0xFFDC2626),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white, width: 1.2),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: Colors.white,
          fontSize: fontSize,
          fontWeight: FontWeight.w900,
          height: 1.1,
        ),
      ),
    );
  }

  bool _sameUidSet(Set<String> a, Set<String> b) {
    if (a.length != b.length) return false;
    for (final uid in a) {
      if (!b.contains(uid)) return false;
    }
    return true;
  }

  void _queueFlexBadgeUidSync(List<_FlexCourseSummary> rows) {
    final next = rows
        .map((item) => item.uid.trim())
        .where((uid) => uid.isNotEmpty)
        .toSet();
    if (_sameUidSet(next, _flexLearnerUidsForBadge)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _flexLearnerUidsForBadge = next);
    });
  }

  void _queueRecordedBadgeUidSync(List<_RecordedCourseSummary> rows) {
    final next = rows
        .map((item) => item.uid.trim())
        .where((uid) => uid.isNotEmpty)
        .toSet();
    if (_sameUidSet(next, _recordedLearnerUidsForBadge)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _recordedLearnerUidsForBadge = next);
    });
  }

  int _sumUnreadFor(Set<String> learnerUids, Map<String, int> unreadByLearner) {
    var total = 0;
    for (final uid in learnerUids) {
      total += unreadByLearner[uid] ?? 0;
    }
    return total;
  }

  Widget _tabLabelWithBadge(String label, int count) {
    if (count <= 0) return Tab(text: label);
    return Tab(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label),
          const SizedBox(width: 6),
          _countPill(_countLabel(count), fontSize: 10, horizontal: 6),
        ],
      ),
    );
  }

  // -------------------- Utilities --------------------

  String _formatDate(DateTime d) => DateFormat('yyyy-MM-dd').format(d);
  String _norm(String s) => s.trim().toLowerCase();
  static int _asInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  static bool _asBool(dynamic v) {
    if (v is bool) return v;
    final s = (v ?? '').toString().trim().toLowerCase();
    return s == 'true' || s == '1';
  }

  bool _isLearnerRole(dynamic role) {
    final r = (role ?? "").toString().trim().toLowerCase();
    return r == "learner" || r == "learners" || r == "learner(s)";
  }

  List<Map<String, String>> _classLearnersList(Map<String, dynamic> cls) {
    final raw = cls['learners'];
    if (raw is! Map) return const <Map<String, String>>[];

    final out = <Map<String, String>>[];
    final learnersMap = Map<dynamic, dynamic>.from(raw);
    learnersMap.forEach((uid, learnerVal) {
      if (uid == null) return;
      final uidStr = uid.toString().trim();
      if (uidStr.isEmpty) return;
      String serial = '';
      String name = '';
      if (learnerVal is Map) {
        final m = learnerVal.map((k, v) => MapEntry(k.toString(), v));
        serial = (m['serial'] ?? '').toString().trim();
        name = (m['name'] ?? '').toString().trim();
      }
      out.add({'uid': uidStr, 'serial': serial, 'name': name});
    });

    out.sort((a, b) {
      final an = (a['name'] ?? '').toLowerCase();
      final bn = (b['name'] ?? '').toLowerCase();
      if (an.isNotEmpty || bn.isNotEmpty) return an.compareTo(bn);
      return (a['serial'] ?? '').compareTo(b['serial'] ?? '');
    });
    return out;
  }

  void _openLearnerFromClass(Map<String, String> learner) {
    final serial = (learner['serial'] ?? '').trim();
    final name = (learner['name'] ?? '').trim();
    final query = serial.isNotEmpty ? serial : name;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AdminLearnersScreen(initialSearch: query),
      ),
    );
  }

  bool _isTeacherRole(dynamic role) {
    final r = (role ?? "").toString().trim().toLowerCase();
    return r == "teacher" || r == "teachers" || r == "teacher(s)";
  }

  String _levelShort(String levelRaw) {
    final t = levelRaw.trim();
    if (t.isEmpty) return "CLS";
    return t.split(RegExp(r'\s+')).first;
  }

  String _normalizeVariantKey(String value) {
    return normalizeVariantKey(value);
  }

  String _normalizeStudyMode(String value) {
    return normalizeStudyMode(value);
  }

  String _variantLabel(String variantKey) {
    return variantLabel(_normalizeVariantKey(variantKey));
  }

  String _studyModeLabel(String studyMode) {
    return studyModeLabel(_normalizeStudyMode(studyMode));
  }

  String _classTypeLabel({
    required String variantKey,
    required String studyMode,
  }) {
    final v = _normalizeVariantKey(variantKey);
    final s = _normalizeStudyMode(studyMode);

    if (v == 'private') {
      final modeLabel = _studyModeLabel(s);
      if (modeLabel.trim().isNotEmpty) {
        return 'Private • $modeLabel';
      }
      return 'Private';
    }

    return _variantLabel(v);
  }

  bool _isScheduledClassType(String variantKey) {
    final v = _normalizeVariantKey(variantKey);
    return v == 'inclass' || v == 'private';
  }

  // Short Class ID: exactly 5 chars (human-friendly)
  String _makeShortClassId() {
    const chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // avoid 0/O/1/I
    final rnd = Random.secure();
    return List.generate(5, (_) => chars[rnd.nextInt(chars.length)]).join();
  }

  Future<String> _generateUniqueClassId() async {
    String id = _makeShortClassId();
    for (int i = 0; i < 12; i++) {
      final snap = await _classesRef.child(id).get();
      if (!snap.exists) return id;
      id = _makeShortClassId();
    }
    return id; // best effort
  }

  // -------------------- Open from timetable --------------------

  Future<void> _maybeOpenFromTimetable() async {
    final searchId = widget.openClassSearchId?.trim();
    if (searchId != null && searchId.isNotEmpty) {
      await _bootFuture;
      if (!mounted) return;
      setState(() {
        _showClassesSearch = true;
        _searchCtrl.text = searchId;
        _searchQuery = _normalizeSearchText(searchId);
      });
      return;
    }

    final id = widget.openClassId?.trim();
    if (id == null || id.isEmpty) return;

    try {
      await _bootFuture;

      final snap = await _classesRef.child(id).get();
      if (!snap.exists || snap.value is! Map) {
        _notify("Class not found: $id", error: true);
        return;
      }

      final cls = Map<String, dynamic>.from(snap.value as Map);
      cls["class_id"] = id;

      await _openClassEditor(existingClass: cls);
    } catch (e) {
      _notify("Failed to open class: $e", error: true);
    }
  }

  // -------------------- Load ALL teachers --------------------

  Future<void> _loadTeachers() async {
    if (mounted) setState(() => _loadingTeachers = true);

    try {
      final snap = await _usersRef.get();
      if (!mounted) return;

      final Map<String, Map<String, String>> byUid = {};
      final Map<String, String> uidByName = {};

      if (snap.exists && snap.value is Map) {
        final all = Map<dynamic, dynamic>.from(snap.value as Map);

        for (final entry in all.entries) {
          final uid = entry.key.toString();
          final data = (entry.value is Map)
              ? Map<String, dynamic>.from(entry.value as Map)
              : <String, dynamic>{};

          if (!_isTeacherRole(data["role"])) continue;

          final first = (data["first_name"] ?? "").toString().trim();
          final last = (data["last_name"] ?? "").toString().trim();
          final full = "$first $last".trim();

          final serial = (data["serial"] ?? "").toString().trim();

          final teacher = <String, String>{
            "uid": uid,
            "name": full.isEmpty ? uid : full,
            "serial": serial,
          };

          byUid[uid] = teacher;
          if (full.isNotEmpty) uidByName[_norm(full)] = uid;
        }
      }

      if (!mounted) return;
      setState(() {
        _teachersByUid = byUid;
        _teacherUidByName = uidByName;
        _loadingTeachers = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingTeachers = false);
      _notify("Failed to load teachers: $e", error: true);
    }
  }

  // -------------------- Load courses --------------------

  Future<void> _loadCourses() async {
    if (mounted) setState(() => _loadingCourses = true);

    try {
      final snap = await _coursesRef.get();
      if (!mounted) return;

      final List<Map<String, dynamic>> list = [];

      if (snap.exists && snap.value is Map) {
        final map = Map<dynamic, dynamic>.from(snap.value as Map);

        for (final entry in map.entries) {
          final id = entry.key.toString();
          final raw = entry.value;
          if (raw is! Map) continue;

          final data = Map<String, dynamic>.from(raw);
          final levelRaw = (data["level"] ?? "").toString();

          // instructors can be LIST (old) or MAP (new) — keep ONLY teachers
          final insRaw = data["instructors"];
          final List<Map<String, String>> instructorsList = [];

          if (insRaw is List) {
            for (final item in insRaw) {
              final name = (item ?? "").toString().trim();
              if (name.isEmpty) continue;

              final uid = _teacherUidByName[_norm(name)];
              if (uid == null) continue;

              final t = _teachersByUid[uid];
              if (t == null) continue;

              instructorsList.add({
                "uid": t["uid"] ?? uid,
                "name": t["name"] ?? name,
                "serial": t["serial"] ?? "",
              });
            }
          } else if (insRaw is Map) {
            final m = Map<dynamic, dynamic>.from(insRaw);
            m.forEach((k, v) {
              final uid = k.toString();
              final t = _teachersByUid[uid];
              if (t == null) return;
              instructorsList.add({
                "uid": t["uid"] ?? uid,
                "name": t["name"] ?? "",
                "serial": t["serial"] ?? "",
              });
            });
          }

          instructorsList.sort(
            (a, b) => (a["name"] ?? "").compareTo(b["name"] ?? ""),
          );

          list.add({
            "id": id,
            "title": (data["title"] ?? "").toString(),
            "course_code": (data["course_code"] ?? "").toString(),
            "duration": (data["duration"] ?? "").toString(),
            "category": (data["category"] ?? "").toString(),
            "level": _levelShort(levelRaw),
            "instructors": instructorsList,
          });
        }

        list.sort(
          (a, b) => (a["course_code"] as String).compareTo(
            b["course_code"] as String,
          ),
        );
      }

      if (!mounted) return;
      setState(() {
        _courses = list;
        _loadingCourses = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingCourses = false);
      _notify("Failed to load courses: $e", error: true);
    }
  }

  // -------------------- Load ALL learners --------------------

  Future<void> _loadAllLearners() async {
    if (mounted) setState(() => _loadingLearners = true);

    try {
      final snap = await _usersRef.get();
      if (!mounted) return;

      final List<Map<String, dynamic>> list = [];

      if (snap.exists && snap.value is Map) {
        final all = Map<dynamic, dynamic>.from(snap.value as Map);

        for (final entry in all.entries) {
          final uid = entry.key.toString();
          final raw = entry.value;
          if (raw is! Map) continue;

          final data = Map<String, dynamic>.from(raw);
          if (!_isLearnerRole(data["role"])) continue;

          final serial = (data["serial"] ?? "").toString().trim();
          final first = (data["first_name"] ?? "").toString().trim();
          final last = (data["last_name"] ?? "").toString().trim();
          final name = "$first $last".trim();
          final phone1 = (data["phone1"] ?? "").toString().trim();

          final coursesMap = (data["courses"] is Map)
              ? Map<String, dynamic>.from(
                  (data["courses"] as Map).map(
                    (k, v) => MapEntry(
                      k.toString(),
                      v is Map ? Map<String, dynamic>.from(v) : v,
                    ),
                  ),
                )
              : <String, dynamic>{};

          list.add({
            "uid": uid,
            "serial": serial.isEmpty ? "N/A" : serial,
            "name": name.isEmpty ? "Unnamed" : name,
            "phone1": phone1,
            "courses": coursesMap,
          });
        }
      }

      list.sort((a, b) => (a["name"] as String).compareTo(b["name"] as String));

      if (!mounted) return;
      setState(() {
        _allLearners = list;
        _loadingLearners = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingLearners = false);
      _notify("Failed to load learners: $e", error: true);
    }
  }

  // -------------------- Learner / course helpers --------------------

  Set<String> _uidsWhoMatchCourseVariant({
    required String courseId,
    required String variantKey,
    required String studyMode,
    String? currentClassId,
  }) {
    final wantedVariant = _normalizeVariantKey(variantKey);
    final wantedStudyMode = _normalizeStudyMode(studyMode);

    final set = <String>{};

    for (final l in _allLearners) {
      final courses = (l["courses"] is Map)
          ? Map<String, dynamic>.from(l["courses"] as Map)
          : <String, dynamic>{};

      bool hasMatch = false;

      for (final e in courses.entries) {
        final m = (e.value is Map)
            ? Map<String, dynamic>.from(e.value)
            : <String, dynamic>{};

        final enrolledCourseId = (m["id"] ?? "").toString().trim();
        if (enrolledCourseId != courseId) continue;

        // ✅ Migration fallback:
        // if this learner course is already linked to the same class,
        // treat it as enrolled even if the old class node has old/missing variant data.
        final linkedClassMap = (m["class"] is Map)
            ? Map<String, dynamic>.from(m["class"] as Map)
            : <String, dynamic>{};

        final linkedClassId = (linkedClassMap["class_id"] ?? "")
            .toString()
            .trim();

        if (currentClassId != null &&
            currentClassId.trim().isNotEmpty &&
            linkedClassId == currentClassId.trim()) {
          hasMatch = true;
          break;
        }

        final enrolledVariant = _normalizeVariantKey(
          (m["variantKey"] ?? m["variant"] ?? m["deliveryKey"] ?? "")
              .toString(),
        );

        final enrolledStudyMode = _normalizeStudyMode(
          (m["studyMode"] ?? "").toString(),
        );

        if (wantedVariant != enrolledVariant) {
          continue;
        }

        if (wantedVariant == 'private') {
          if (wantedStudyMode != enrolledStudyMode) {
            continue;
          }
        }

        hasMatch = true;
        break;
      }

      if (hasMatch) {
        set.add(l["uid"].toString());
      }
    }

    return set;
  }

  Future<void> _syncLearnersClassDataStrict({
    required String courseId,
    required Map<String, dynamic> classPayload,
    required Map<String, dynamic> selectedLearnersByUid,
    required Map<String, dynamic> previousLearnersByUid,
  }) async {
    final classId = (classPayload["class_id"] ?? "").toString();
    final status = (classPayload["status"] ?? "active").toString();

    // removed learners => remove class field
    final removedUids = previousLearnersByUid.keys
        .where((uid) => !selectedLearnersByUid.containsKey(uid))
        .toList();

    for (final uid in removedUids) {
      final userSnap = await _usersRef.child(uid).get();
      if (!userSnap.exists || userSnap.value is! Map) continue;

      final userData = Map<String, dynamic>.from(userSnap.value as Map);
      final courses = (userData["courses"] is Map)
          ? Map<dynamic, dynamic>.from(userData["courses"])
          : <dynamic, dynamic>{};

      String? courseKey;
      for (final entry in courses.entries) {
        final m = (entry.value is Map)
            ? Map<String, dynamic>.from(entry.value)
            : <String, dynamic>{};
        if ((m["id"] ?? "").toString() == courseId) {
          courseKey = entry.key.toString();
          break;
        }
      }
      if (courseKey == null) continue;

      await _usersRef
          .child(uid)
          .child("courses")
          .child(courseKey)
          .child("class")
          .remove();
    }

    // kept/added learners => set class field (only if enrolled)
    for (final uid in selectedLearnersByUid.keys) {
      final userSnap = await _usersRef.child(uid).get();
      if (!userSnap.exists || userSnap.value is! Map) continue;

      final userData = Map<String, dynamic>.from(userSnap.value as Map);
      final courses = (userData["courses"] is Map)
          ? Map<dynamic, dynamic>.from(userData["courses"])
          : <dynamic, dynamic>{};

      String? courseKey;
      for (final entry in courses.entries) {
        final m = (entry.value is Map)
            ? Map<String, dynamic>.from(entry.value)
            : <String, dynamic>{};
        if ((m["id"] ?? "").toString() == courseId) {
          courseKey = entry.key.toString();
          break;
        }
      }
      if (courseKey == null) continue;

      final clsMini = {
        "class_id": classId,
        "course_id": courseId,
        "course_code": (classPayload["course_code"] ?? "").toString(),
        "course_title": (classPayload["course_title"] ?? "").toString(),
        "variantKey": (classPayload["variantKey"] ?? "").toString(),
        "variantLabel": (classPayload["variantLabel"] ?? "").toString(),
        "studyMode": (classPayload["studyMode"] ?? "").toString(),
        "studyModeLabel": (classPayload["studyModeLabel"] ?? "").toString(),
        "instructor": (classPayload["instructor"] ?? "").toString(),
        "status": status,
        "updatedAt": ServerValue.timestamp,
      };

      await _usersRef
          .child(uid)
          .child("courses")
          .child(courseKey)
          .child("class")
          .set(clsMini);
    }
  }

  // -------------------- Class actions --------------------

  void _refreshClassesSnapshot() {
    if (!mounted) return;
    setState(() {
      _classesFuture = _classesRef.get();
      _classTabMetricsFutureByKey.clear();
    });
  }

  Future<_PauseWindowSelection?> _showPauseWindowDialog({
    required String classId,
    required String classTitle,
  }) async {
    DateTime? fromDate;
    DateTime? toDate;
    String errorText = '';

    Future<void> pickDate(
      BuildContext dialogContext,
      void Function(void Function()) setDialogState,
      bool isFrom,
    ) async {
      final now = DateTime.now();
      final initial = isFrom ? (fromDate ?? now) : (toDate ?? fromDate ?? now);
      final picked = await showDatePicker(
        context: dialogContext,
        initialDate: initial,
        firstDate: DateTime(now.year - 1),
        lastDate: DateTime(now.year + 3),
      );
      if (picked == null) return;
      setDialogState(() {
        if (isFrom) {
          fromDate = picked;
          if (toDate != null && toDate!.isBefore(fromDate!)) {
            toDate = fromDate;
          }
        } else {
          toDate = picked;
        }
        errorText = '';
      });
    }

    return showDialog<_PauseWindowSelection>(
      context: context,
      useRootNavigator: true,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) => AlertDialog(
            title: const Text('Pause class'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  classTitle.isEmpty ? classId : '$classTitle ($classId)',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                const Text('Pause this class and notify teacher + learners.'),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () =>
                      pickDate(dialogContext, setDialogState, true),
                  icon: const Icon(Icons.event_available_rounded),
                  label: Text(
                    fromDate == null
                        ? 'From date'
                        : 'From: ${_formatDate(fromDate!)}',
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () =>
                      pickDate(dialogContext, setDialogState, false),
                  icon: const Icon(Icons.event_busy_rounded),
                  label: Text(
                    toDate == null ? 'To date' : 'To: ${_formatDate(toDate!)}',
                  ),
                ),
                if (errorText.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    errorText,
                    style: TextStyle(
                      color: Colors.red.shade700,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, null),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  if (fromDate == null || toDate == null) {
                    setDialogState(
                      () => errorText = 'Please choose both from and to dates.',
                    );
                    return;
                  }
                  if (toDate!.isBefore(fromDate!)) {
                    setDialogState(
                      () =>
                          errorText = 'To date must be on or after from date.',
                    );
                    return;
                  }
                  Navigator.pop(
                    dialogContext,
                    _PauseWindowSelection(fromDate: fromDate!, toDate: toDate!),
                  );
                },
                child: const Text('Pause and notify'),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<bool> _sendClassPauseMailToUser({
    required String recipientUid,
    required String recipientName,
    required String recipientRoleSeed,
    required String subject,
    required String body,
  }) async {
    final meUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final meName = (FirebaseAuth.instance.currentUser?.email ?? 'Admin').trim();
    if (meUid.trim().isEmpty || recipientUid.trim().isEmpty) return false;

    final db = FirebaseDatabase.instance;
    final indexRef = db.ref('mail_index');
    final threadsRef = db.ref('mail_threads');
    final stateRef = db.ref('mail_state');

    final now = DateTime.now().millisecondsSinceEpoch;
    final cleanRecipientName = recipientName.trim().isEmpty
        ? 'User'
        : recipientName.trim();
    final cleanSenderName = meName.isEmpty ? 'Admin' : meName;
    final preview80 = body.length > 80 ? body.substring(0, 80) : body;

    final myRole = await MailConsistencyService.resolveUserRole(
      db,
      meUid,
      seedRole: 'admin',
    );
    final peerRole = await MailConsistencyService.resolveUserRole(
      db,
      recipientUid,
      seedRole: recipientRoleSeed,
    );

    String? threadId;
    final myIndexSnap = await indexRef.child(meUid).get();
    final myIndexRaw = myIndexSnap.value;

    if (myIndexRaw is Map) {
      for (final entry in myIndexRaw.entries) {
        final tid = entry.key.toString();
        final rowRaw = entry.value;
        if (rowRaw is! Map) continue;
        final row = rowRaw.map((k, v) => MapEntry(k.toString(), v));
        final peerUid = (row['peerUid'] ?? '').toString().trim();
        final rowSubject = (row['subject'] ?? '').toString().trim();
        final deletedAt = row['deletedAt'];
        if (deletedAt != null) continue;
        if (peerUid == recipientUid && rowSubject == subject) {
          threadId = tid;
          break;
        }
      }
    }

    if (threadId == null) {
      threadId = threadsRef.push().key!;
      await threadsRef.child(threadId).set({
        'subject': subject,
        'type': 'mail',
        'createdAt': now,
        'updatedAt': now,
        'lastMessage': '',
        'participants': {meUid: true, recipientUid: true},
      });

      await indexRef.child(meUid).child(threadId).set({
        'subject': subject,
        'type': 'mail',
        'updatedAt': now,
        'lastMessage': '',
        'unreadCount': 0,
        'peerUid': recipientUid,
        'peerName': cleanRecipientName,
        'peerRole': peerRole,
        'deletedAt': null,
      });

      await indexRef.child(recipientUid).child(threadId).set({
        'subject': subject,
        'type': 'mail',
        'updatedAt': now,
        'lastMessage': '',
        'unreadCount': 0,
        'peerUid': meUid,
        'peerName': cleanSenderName,
        'peerRole': myRole,
        'deletedAt': null,
      });
    }

    final msgRef = db.ref('mail_messages/$threadId').push();
    await msgRef.set({
      'fromUid': meUid,
      'body': body,
      'toUids': {recipientUid: true},
      'ccUids': {},
      'bccUids': {},
      'attachments': [],
      'createdAt': now,
      'deletedFor': {},
    });

    await db.ref('mail_threads/$threadId').update({
      'updatedAt': now,
      'lastMessage': preview80,
      'participants/$meUid': true,
      'participants/$recipientUid': true,
    });

    await indexRef.child(meUid).child(threadId).update({
      'subject': subject,
      'type': 'mail',
      'updatedAt': now,
      'lastMessage': preview80,
      'unreadCount': 0,
      'peerUid': recipientUid,
      'peerName': cleanRecipientName,
      'peerRole': peerRole,
      'deletedAt': null,
    });

    await indexRef.child(recipientUid).child(threadId).runTransaction((cur) {
      final m = (cur as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
      final oldUnread = (m['unreadCount'] is num)
          ? (m['unreadCount'] as num).toInt()
          : 0;
      m['subject'] = subject;
      m['type'] = 'mail';
      m['updatedAt'] = now;
      m['lastMessage'] = preview80;
      m['unreadCount'] = oldUnread + 1;
      m['peerUid'] = meUid;
      m['peerName'] = cleanSenderName;
      m['peerRole'] = myRole;
      m['deletedAt'] = null;
      return Transaction.success(m);
    });

    await stateRef.child(meUid).child(threadId).update({
      'lastReadAt': now,
      'lastDeliveredAt': now,
    });
    await stateRef.child(recipientUid).child(threadId).update({
      'lastDeliveredAt': now,
    });

    await MailConsistencyService.verifyMailWriteOnce(
      db: db,
      threadId: threadId,
      senderUid: meUid,
      receiverUid: recipientUid,
      senderName: cleanSenderName,
      receiverName: cleanRecipientName,
      senderRole: myRole,
      receiverRole: peerRole,
      subject: subject,
      lastMessage: preview80,
      now: now,
      type: 'mail',
    );
    return true;
  }

  Future<void> _pauseClassWithWindow(Map<String, dynamic> cls) async {
    final classId = (cls['class_id'] ?? '').toString().trim();
    if (classId.isEmpty) {
      _notify('Could not pause class: missing class id.', error: true);
      return;
    }

    final classTitle = (cls['course_title'] ?? '').toString().trim();
    final picked = await _showPauseWindowDialog(
      classId: classId,
      classTitle: classTitle,
    );
    if (picked == null) return;

    final fromYmd = _formatDate(picked.fromDate);
    final toYmd = _formatDate(picked.toDate);

    try {
      await _classesRef.child(classId).update({
        'status': 'paused',
        'pause_window': {
          'from': fromYmd,
          'to': toYmd,
          'updated_at': ServerValue.timestamp,
          'updated_by': FirebaseAuth.instance.currentUser?.uid ?? '',
        },
        'pause_cooldown_notified': null,
        'pause_cooldown_notified_at': null,
        'updated_at': ServerValue.timestamp,
      });
      _refreshClassesSnapshot();
    } catch (e) {
      _notify('Failed to pause class: $e', error: true);
      return;
    }

    final recipientRoleByUid = <String, String>{};
    final recipientNameByUid = <String, String>{};

    final teacherUid = _classInstructorUid(cls).trim();
    if (teacherUid.isNotEmpty) {
      recipientRoleByUid[teacherUid] = 'teacher';
      recipientNameByUid[teacherUid] = (cls['instructor'] ?? '')
          .toString()
          .trim();
    }

    final learners = _classLearnersList(cls);
    for (final learner in learners) {
      final uid = (learner['uid'] ?? '').trim();
      if (uid.isEmpty) continue;
      recipientRoleByUid[uid] = 'learner';
      recipientNameByUid[uid] = (learner['name'] ?? '').trim();
    }

    final meUid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (meUid.isNotEmpty) {
      recipientRoleByUid.remove(meUid);
      recipientNameByUid.remove(meUid);
    }

    final totalRecipients = recipientRoleByUid.length;
    if (totalRecipients == 0) {
      _notify('Class paused from $fromYmd to $toYmd. No recipients found.');
      return;
    }

    final effectiveTitle = classTitle.isEmpty ? classId : classTitle;
    final subject = 'Class paused notice';
    final body =
        'Class pause notice\n'
        'Class: $effectiveTitle\n'
        'Class ID: $classId\n'
        'Paused from: $fromYmd\n'
        'Paused to: $toYmd\n'
        'Please follow the updated schedule from the admin.';

    var sentCount = 0;
    for (final entry in recipientRoleByUid.entries) {
      final uid = entry.key;
      final seedRole = entry.value;
      final receiverName = (recipientNameByUid[uid] ?? '').trim().isEmpty
          ? (seedRole == 'teacher' ? 'Teacher' : 'Learner')
          : (recipientNameByUid[uid] ?? '').trim();
      try {
        final ok = await _sendClassPauseMailToUser(
          recipientUid: uid,
          recipientName: receiverName,
          recipientRoleSeed: seedRole,
          subject: subject,
          body: body,
        );
        if (ok) sentCount += 1;
      } catch (_) {}
    }

    if (sentCount == totalRecipients) {
      _notify(
        'Class paused from $fromYmd to $toYmd. Mail sent to $sentCount recipient(s).',
      );
    } else {
      _notify(
        'Class paused from $fromYmd to $toYmd. Mail sent to $sentCount/$totalRecipients recipient(s).',
        error: true,
      );
    }

    // ===== Send push notifications to all recipients =====
    for (final entry in recipientRoleByUid.entries) {
      final uid = entry.key;
      final role = entry.value;
      try {
        await PushDispatchService.dispatchToUser(
          intent: PushIntent.reminder,
          targetUid: uid,
          title: 'Class Paused',
          message: 'Class $effectiveTitle paused from $fromYmd to $toYmd.',
          context: const PushDispatchContext(
            screen: 'admin/admin_classes',
            action: 'class_pause_push',
          ),
          eventParts: ['class_pause', classId, uid],
          data: {'classId': classId, 'pauseFrom': fromYmd, 'pauseTo': toYmd},
          route: role == 'teacher' ? 'teacher' : 'learner',
        );
      } catch (_) {}
    }
  }

  // ===== Pause Cooldown: check paused classes near/at expiry =====

  Future<void> _checkPauseCooldowns() async {
    try {
      final snap = await _classesRef.get();
      if (!snap.exists || snap.value is! Map) return;
      final classes = Map<dynamic, dynamic>.from(snap.value as Map);

      final now = DateTime.now();

      for (final entry in classes.entries) {
        final classId = entry.key.toString().trim();
        if (classId.isEmpty) continue;

        final raw = entry.value;
        if (raw is! Map) continue;
        final cls = Map<String, dynamic>.from(raw);

        final status = (cls['status'] ?? '').toString().trim().toLowerCase();
        if (status != 'paused') continue;

        final alreadyNotified = cls['pause_cooldown_notified'] == true;
        if (alreadyNotified) continue;

        final pauseWindow = cls['pause_window'];
        if (pauseWindow is! Map) continue;

        final toDateStr = (pauseWindow['to'] ?? '').toString().trim();
        if (toDateStr.isEmpty) continue;

        // Parse to-date and check if it's today or in the past
        DateTime toDate;
        try {
          toDate = DateTime.parse(toDateStr);
        } catch (_) {
          continue;
        }

        final todayDate = DateTime(now.year, now.month, now.day);
        final toDateTime = DateTime(toDate.year, toDate.month, toDate.day);

        // Notify when pause period ends (toDate <= today)
        if (toDateTime.isAfter(todayDate)) continue;

        // Already notified in this session?
        if (_cooldownNotifiedClassIds.contains(classId)) continue;

        await _triggerPauseCooldown(classId, cls);
      }
    } catch (_) {}
  }

  Future<void> _triggerPauseCooldown(
    String classId,
    Map<String, dynamic> cls,
  ) async {
    _cooldownNotifiedClassIds.add(classId);

    final courseTitle = (cls['course_title'] ?? '').toString().trim();
    final effectiveTitle = courseTitle.isEmpty ? classId : courseTitle;
    final pauseWindow = cls['pause_window'] is Map
        ? (cls['pause_window'] as Map).map((k, v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};
    final pauseTo = (pauseWindow['to'] ?? '').toString().trim();

    // 1. Notify admin(s) via admin topic
    try {
      await PushDispatchService.dispatchAdminTopic(
        intent: PushIntent.adminTodo,
        title: 'Class Pause Ending',
        message:
            'Class $effectiveTitle (ID: $classId) pause period ended on $pauseTo. Review if class should be reactivated.',
        context: const PushDispatchContext(
          screen: 'admin/admin_classes',
          action: 'pause_cooldown_admin_notify',
        ),
        eventParts: ['pause_cooldown', classId],
        data: {'classId': classId, 'action': 'pause_ended'},
        route: 'admin_classes',
      );
    } catch (_) {}

    // 2. Email learners asking them to contact the school
    final learners = _classLearnersList(cls);

    for (final learner in learners) {
      final uid = (learner['uid'] ?? '').toString().trim();
      if (uid.isEmpty) continue;
      final name = (learner['name'] ?? 'Learner').toString().trim();

      try {
        await _sendClassPauseMailToUser(
          recipientUid: uid,
          recipientName: name,
          recipientRoleSeed: 'learner',
          subject: 'Class Pause Ended - Contact Us',
          body:
              'Dear $name,\n\nThe pause period for class $effectiveTitle has ended.\n\nPlease contact Your Bridge School to resume your classes.\n\nThank you.',
        );
      } catch (_) {}
    }

    // 3. Mark as notified in DB to prevent repeats
    try {
      await _classesRef.child(classId).update({
        'pause_cooldown_notified': true,
        'pause_cooldown_notified_at': ServerValue.timestamp,
      });
    } catch (_) {}
  }

  Future<void> _setClassStatus(String classId, String status) async {
    try {
      final normalizedStatus = status.trim().toLowerCase();
      final updates = <String, dynamic>{
        "status": status,
        "updated_at": ServerValue.timestamp,
      };
      if (normalizedStatus != 'paused') {
        updates['pause_window'] = null;
      }
      await _classesRef.child(classId).update(updates);
      _refreshClassesSnapshot();
      _notify("Updated $classId → $status");
    } catch (e) {
      _notify("Failed to update: $e", error: true);
    }
  }

  Future<void> _deleteClass(String classId) async {
    final ok = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (_) => AlertDialog(
        title: const Text("Delete class?"),
        content: Text("This will permanently delete:\n$classId"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text("Cancel"),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text("Delete"),
          ),
        ],
      ),
    );

    if (ok != true) return;

    try {
      final clsSnap = await _classesRef.child(classId).get();
      if (clsSnap.exists && clsSnap.value is Map) {
        final cls = Map<String, dynamic>.from(clsSnap.value as Map);
        final courseId = (cls["course_id"] ?? "").toString();

        final prevLearners = (cls["learners"] is Map)
            ? Map<String, dynamic>.from(
                (cls["learners"] as Map).map(
                  (k, v) => MapEntry(k.toString(), v),
                ),
              )
            : <String, dynamic>{};

        await _syncLearnersClassDataStrict(
          courseId: courseId,
          classPayload: {"class_id": classId, "course_id": courseId},
          selectedLearnersByUid: const <String, dynamic>{},
          previousLearnersByUid: prevLearners,
        );
      }

      await _classesRef.child(classId).remove();
      _notify("Deleted: $classId");
    } catch (e) {
      _notify("Failed to delete: $e", error: true);
    }
  }

  // -------------------- Filters / Search helpers --------------------

  bool _matchesDayFilter(Map<String, dynamic> cls) {
    if (_dayFilter == "All") return true;

    final sched = (cls["schedule"] is Map)
        ? Map<String, dynamic>.from(cls["schedule"])
        : <String, dynamic>{};
    final sessions = (sched["sessions"] is List)
        ? List<dynamic>.from(sched["sessions"])
        : <dynamic>[];
    if (sessions.isEmpty) return false;

    for (final s in sessions) {
      final m = (s is Map) ? Map<String, dynamic>.from(s) : <String, dynamic>{};
      final day = (m["day"] ?? "").toString().trim();
      if (day == _dayFilter) return true;
    }
    return false;
  }

  bool _matchesOpenFilter(Map<String, dynamic> cls) {
    if (_openFilter == null) return true;
    final isOpen = (cls["is_open"] ?? true) == true;
    return _openFilter == isOpen;
  }

  bool _matchesWaitingStatusFilter(Map<String, dynamic> cls) {
    if (!_waitingStatusOnly) return true;
    final status = (cls['status'] ?? '').toString().trim().toLowerCase();
    return status == 'waiting';
  }

  String _classInstructorUid(Map<String, dynamic> cls) {
    final current = cls['instructor_current'];
    if (current is Map) {
      final m = current.map((k, v) => MapEntry(k.toString(), v));
      final uid = (m['uid'] ?? m['teacher_uid'] ?? m['id'] ?? '')
          .toString()
          .trim();
      if (uid.isNotEmpty) return uid;
    }
    final asString = (current ?? '').toString().trim();
    return asString;
  }

  bool _matchesTeacherFilter(Map<String, dynamic> cls) {
    if (_teacherFilterUid == 'all') return true;

    final uid = _classInstructorUid(cls);
    if (uid.isNotEmpty) return uid == _teacherFilterUid;

    final expectedName = (_teachersByUid[_teacherFilterUid]?['name'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    if (expectedName.isEmpty) return true;

    final instructor = (cls['instructor'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    return instructor == expectedName;
  }

  bool _matchesCourseFilter(Map<String, dynamic> cls) {
    if (_courseFilterId == 'all') return true;
    final courseId = (cls['course_id'] ?? '').toString().trim();
    return courseId == _courseFilterId;
  }

  bool _matchesEmptyClassesFilter(Map<String, dynamic> cls) {
    if (!_emptyClassesOnly) return true;
    final learners = cls['learners'];
    if (learners is Map) return learners.isEmpty;
    if (learners is List) return learners.isEmpty;
    return true;
  }

  bool _matchesSearch(Map<String, dynamic> cls) {
    if (_searchQuery.isEmpty) return true;

    final q = _searchQuery;
    String norm(dynamic v) => _normalizeSearchText(v.toString());

    final id = norm(cls["class_id"]);
    final title = norm(cls["course_title"]);
    final level = norm(cls["course_level"]);
    final courseId = norm(cls["course_id"]);
    final inst = norm(cls["instructor"]);
    final status = norm(cls["status"]);

    bool hit =
        id.contains(q) ||
        title.contains(q) ||
        level.contains(q) ||
        courseId.contains(q) ||
        inst.contains(q) ||
        status.contains(q);

    if (hit) return true;

    // ✅ Search by learners (name / serial) inside cls["learners"]
    final learners = (cls["learners"] is Map)
        ? Map<dynamic, dynamic>.from(cls["learners"])
        : null;
    if (learners == null || learners.isEmpty) return false;

    for (final entry in learners.entries) {
      final v = entry.value;
      if (v is Map) {
        final m = Map<String, dynamic>.from(v);
        final name = norm(m["name"]);
        final serial = norm(m["serial"]);
        if (name.contains(q) || serial.contains(q)) {
          return true;
        }
      }
    }

    return false;
  }

  Color _statusColor(String status) {
    switch (status) {
      case 'waiting':
        return Colors.amber.shade700;
      case "paused":
        return Colors.orange;
      case "blocked":
        return Colors.red;
      default:
        return Colors.green;
    }
  }

  // Cleaner schedule line: "Sat 10:00 (90m) • Tue 18:00 (60m)"

  String _prettySessions(Map<String, dynamic> cls) {
    final variantKey = (cls["variantKey"] ?? "").toString();
    final sched = (cls["schedule"] is Map)
        ? Map<String, dynamic>.from(cls["schedule"])
        : <String, dynamic>{};
    final sessions = (sched["sessions"] is List)
        ? List<dynamic>.from(sched["sessions"])
        : <dynamic>[];

    if (sessions.isEmpty) {
      final v = _normalizeVariantKey(variantKey);

      if (v == 'flexible') return "Flexible schedule";
      if (v == 'recorded') return "On-demand access";

      return "No schedule";
    }

    final parts = sessions.map((s) {
      final m = (s is Map) ? Map<String, dynamic>.from(s) : <String, dynamic>{};
      final day = (m["day"] ?? "").toString().trim();
      final time = (m["start_time"] ?? "").toString().trim();
      final dur = (m["duration_min"] ?? "").toString().trim();
      final dd = day.isEmpty ? "Day" : day;
      final tt = time.isEmpty ? "--:--" : time;
      final du = dur.isEmpty ? "?" : dur;
      return "$dd $tt (${du}m)";
    }).toList();

    return parts.join(" • ");
  }

  String _classMetricsKey(Map<String, dynamic> cls, int index) {
    final id = (cls['class_id'] ?? '').toString().trim();
    if (id.isNotEmpty) return id;
    final courseId = (cls['course_id'] ?? '').toString().trim();
    return 'idx_$index|$courseId';
  }

  Future<_ClassTabMetrics> _classTabMetricsFor({
    required Map<String, dynamic> cls,
    required int index,
  }) {
    final key = _classMetricsKey(cls, index);
    return _classTabMetricsFutureByKey.putIfAbsent(
      key,
      () => _loadClassTabMetrics(cls),
    );
  }

  int _parseSessionsCountFromDurationText(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return 0;
    final match = RegExp(r'(\d+)').firstMatch(t);
    if (match == null) return 0;
    final n = int.tryParse(match.group(1) ?? '') ?? 0;
    return n > 0 ? n : 0;
  }

  int _classHeldSessionsCount(Map<String, dynamic> cls) {
    final attendanceRaw = cls['attendance'];
    if (attendanceRaw is! Map) return 0;
    final att = Map<dynamic, dynamic>.from(attendanceRaw);
    var held = 0;
    for (final v in att.values) {
      if (v is Map) held += 1;
    }
    return held;
  }

  Set<String> _classCoveredSessionIds(Map<String, dynamic> cls) {
    final attendanceRaw = cls['attendance'];
    if (attendanceRaw is! Map) return <String>{};

    final out = <String>{};
    final att = Map<dynamic, dynamic>.from(attendanceRaw);
    for (final value in att.values) {
      if (value is! Map) continue;
      final rec = Map<String, dynamic>.from(value);

      final taughtItems = rec['taughtItems'];
      if (taughtItems is List) {
        for (final itemRaw in taughtItems) {
          if (itemRaw is! Map) continue;
          final item = Map<String, dynamic>.from(itemRaw);
          final type = (item['type'] ?? '').toString().trim().toLowerCase();
          if (type.isNotEmpty && type != 'syllabus') continue;
          final sid = (item['sessionId'] ?? '').toString().trim();
          if (sid.isNotEmpty) out.add(sid);
        }
      }

      if (rec['taught'] is Map) {
        final taught = Map<String, dynamic>.from(rec['taught'] as Map);
        final sid = (taught['sessionId'] ?? '').toString().trim();
        if (sid.isNotEmpty) out.add(sid);
      }
    }

    return out;
  }

  int _classTotalSessionsFromScheduleOrCourse(Map<String, dynamic> cls) {
    final schedule = (cls['schedule'] is Map)
        ? Map<String, dynamic>.from(cls['schedule'])
        : <String, dynamic>{};
    final bySchedule = _asInt(schedule['sessions_count']);
    if (bySchedule > 0) return bySchedule;

    final byClass = _asInt(cls['sessions_count']);
    if (byClass > 0) return byClass;

    final durationText = (cls['course_duration'] ?? '').toString();
    final byDuration = _parseSessionsCountFromDurationText(durationText);
    if (byDuration > 0) return byDuration;

    return 0;
  }

  int _classConsumedFromCourseMap({
    required Map<String, dynamic> courseMap,
    required String variantKey,
  }) {
    final v = _normalizeVariantKey(variantKey);
    final attendance = courseMap['attendance'];
    final linkedClass = courseMap['class'];
    final linkedClassMap = linkedClass is Map
        ? linkedClass.map((k, v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};
    final classId = (linkedClassMap['class_id'] ?? courseMap['class_id'] ?? '')
        .toString()
        .trim();
    switch (v) {
      case 'inclass':
        return countHeldAttendanceRecords(attendance);
      case 'private':
        return countPrivateConsumedAttendanceRecords(
          attendance,
          classId: classId,
        );
      case 'flexible':
        final directOnline = countConsumedOnlineAttendance(
          courseMap['online_attendance'],
        );
        if (directOnline > 0) return directOnline;
        final bookingProgress = courseMap['booking_progress'];
        if (bookingProgress is Map) {
          final bp = bookingProgress.map((k, v) => MapEntry(k.toString(), v));
          final nestedOnline = countConsumedOnlineAttendance(
            bp['online_attendance'],
          );
          if (nestedOnline > 0) return nestedOnline;
        }
        return countHeldUniqueAttendanceDates(attendance);
      default:
        return countPresentUniqueAttendanceDates(attendance);
    }
  }

  bool _hasPaymentHistory(Map<String, dynamic> summaryMap) {
    return _asInt(summaryMap['totalPaid']) > 0 ||
        _asInt(summaryMap['lastAmount']) > 0 ||
        _asInt(summaryMap['lastPaymentAt']) > 0;
  }

  Map<String, dynamic>? _resolveLearnerCourseForClass({
    required Map<String, dynamic> learner,
    required String classId,
    required String courseId,
    required String variantKey,
    required String studyMode,
  }) {
    final coursesRaw = learner['courses'];
    if (coursesRaw is! Map) return null;
    final courses = Map<dynamic, dynamic>.from(coursesRaw);

    final wantedVariant = _normalizeVariantKey(variantKey);
    final wantedStudyMode = _normalizeStudyMode(studyMode);

    for (final entry in courses.entries) {
      if (entry.value is! Map) continue;
      final courseMap = Map<String, dynamic>.from(entry.value as Map);

      final linkedClass = (courseMap['class'] is Map)
          ? Map<String, dynamic>.from(courseMap['class'] as Map)
          : <String, dynamic>{};
      final linkedClassId = (linkedClass['class_id'] ?? '').toString().trim();
      if (classId.isNotEmpty && linkedClassId == classId) {
        return courseMap;
      }

      final enrolledCourseId =
          (courseMap['id'] ??
                  courseMap['courseId'] ??
                  courseMap['course_id'] ??
                  '')
              .toString()
              .trim();
      if (courseId.isEmpty || enrolledCourseId != courseId) continue;

      final enrolledVariant = _normalizeVariantKey(
        (courseMap['variantKey'] ?? courseMap['variant'] ?? '').toString(),
      );
      if (wantedVariant.isNotEmpty && enrolledVariant != wantedVariant) {
        continue;
      }

      if (enrolledVariant == 'private') {
        final enrolledStudyMode = _normalizeStudyMode(
          (courseMap['studyMode'] ?? '').toString(),
        );
        if (wantedStudyMode.isNotEmpty &&
            enrolledStudyMode != wantedStudyMode) {
          continue;
        }
      }

      return courseMap;
    }

    return null;
  }

  Future<_ClassTabMetrics> _loadClassTabMetrics(
    Map<String, dynamic> cls,
  ) async {
    final classId = (cls['class_id'] ?? '').toString().trim();
    final courseId = (cls['course_id'] ?? '').toString().trim();
    final variantKey = _normalizeVariantKey(
      (cls['variantKey'] ?? '').toString(),
    );
    final studyMode = _normalizeStudyMode((cls['studyMode'] ?? '').toString());

    final heldSessions = _classHeldSessionsCount(cls);
    final coveredSessions = _classCoveredSessionIds(cls).length;
    final currentSessions = max(heldSessions, coveredSessions);

    var totalSessions = _classTotalSessionsFromScheduleOrCourse(cls);
    if (totalSessions <= 0 && courseId.isNotEmpty) {
      totalSessions = await _loadSyllabusSessionCount(
        courseId: courseId,
        syllabusVariant: syllabusVariantForScheduledAttendance(variantKey),
      );
    }

    final learnerUids = _classLearnersList(cls)
        .map((e) => (e['uid'] ?? '').trim())
        .where((uid) => uid.isNotEmpty)
        .toList();
    final learnerByUid = <String, Map<String, dynamic>>{};
    for (final learner in _allLearners) {
      final uid = (learner['uid'] ?? '').toString().trim();
      if (uid.isNotEmpty) learnerByUid[uid] = learner;
    }

    final packageFreq = <int, int>{};
    final consumedFreqByPackage = <int, Map<int, int>>{};

    for (final uid in learnerUids) {
      final learner = learnerByUid[uid];
      if (learner == null) continue;

      final courseMap = _resolveLearnerCourseForClass(
        learner: learner,
        classId: classId,
        courseId: courseId,
        variantKey: variantKey,
        studyMode: studyMode,
      );
      if (courseMap == null) continue;
      if (courseIsFreeBilling(courseMap)) continue;

      final summaryMap = (courseMap['payment_summary'] is Map)
          ? Map<String, dynamic>.from(courseMap['payment_summary'])
          : <String, dynamic>{};
      final sessionsPaidRaw = _asInt(summaryMap['sessionsPaidTotal']);
      final effectivePaid = sessionsPaidRaw > 0
          ? sessionsPaidRaw
          : (_hasPaymentHistory(summaryMap) &&
                    (variantKey == 'inclass' || variantKey == 'private')
                ? 8
                : 0);
      if (effectivePaid <= 0) continue;

      final consumed = _classConsumedFromCourseMap(
        courseMap: courseMap,
        variantKey: variantKey,
      );

      packageFreq[effectivePaid] = (packageFreq[effectivePaid] ?? 0) + 1;
      final bucket = consumedFreqByPackage.putIfAbsent(
        effectivePaid,
        () => <int, int>{},
      );
      bucket[consumed] = (bucket[consumed] ?? 0) + 1;
    }

    var paidSessions = 0;
    var consumedSessions = 0;
    var paymentVariesAcrossLearners = false;

    if (packageFreq.isNotEmpty) {
      final sorted = packageFreq.entries.toList()
        ..sort((a, b) {
          final byFreq = b.value.compareTo(a.value);
          if (byFreq != 0) return byFreq;
          return a.key.compareTo(b.key);
        });

      paidSessions = sorted.first.key;
      paymentVariesAcrossLearners = sorted.length > 1;

      final consumedFreq =
          consumedFreqByPackage[paidSessions] ?? const <int, int>{};
      if (consumedFreq.isNotEmpty) {
        final consumedSorted = consumedFreq.entries.toList()
          ..sort((a, b) {
            final byFreq = b.value.compareTo(a.value);
            if (byFreq != 0) return byFreq;
            return a.key.compareTo(b.key);
          });
        consumedSessions = consumedSorted.first.key;
      }
    }

    final courseProgressValue = totalSessions > 0
        ? (currentSessions / totalSessions).clamp(0.0, 1.0)
        : 0.0;
    final paymentProgressValue = paidSessions > 0
        ? (consumedSessions / paidSessions).clamp(0.0, 1.0)
        : 0.0;

    return _ClassTabMetrics(
      currentSessions: currentSessions,
      totalSessions: totalSessions,
      courseProgressValue: courseProgressValue,
      consumedSessions: consumedSessions,
      paidSessions: paidSessions,
      paymentProgressValue: paymentProgressValue,
      paymentVariesAcrossLearners: paymentVariesAcrossLearners,
    );
  }

  // -------------------- Learner Picker (STRICT ENROLLMENT) --------------------
  Future<void> _openLearnersPickerStrict({
    required String currentClassId,
    required String selectedCourseId,
    required String selectedVariantKey,
    required String selectedStudyMode,
    required Map<String, dynamic> selectedLearnersByUid,
    required StateSetter setModalState,
  }) async {
    // ✅ Always refresh learners before opening the picker,
    // so recently changed enrollments are detected.
    await _loadAllLearners();

    if (_loadingLearners) {
      _notify("Learners are still loading...");
      return;
    }

    final enrolledUids = _uidsWhoMatchCourseVariant(
      courseId: selectedCourseId,
      variantKey: selectedVariantKey,
      studyMode: selectedStudyMode,
      currentClassId: currentClassId,
    );
    String q = "";
    Timer? pickerSearchDebounce;

    if (!mounted) return;
    await showDialog(
      context: context,
      useRootNavigator: true,
      builder: (_) {
        return StatefulBuilder(
          builder: (context, setDState) {
            final filtered = _allLearners.where((l) {
              if (q.isEmpty) return true;
              final serial = (l["serial"] ?? "").toString().toLowerCase();
              final name = (l["name"] ?? "").toString().toLowerCase();
              return serial.contains(q) || name.contains(q);
            }).toList();

            // ✅ ORDER: Enrolled first, then Not enrolled. (Optional: selected first inside each group)
            filtered.sort((a, b) {
              final auid = a["uid"].toString();
              final buid = b["uid"].toString();

              final aEnrolled = enrolledUids.contains(auid);
              final bEnrolled = enrolledUids.contains(buid);

              if (aEnrolled != bEnrolled) return aEnrolled ? -1 : 1;

              final aSelected = selectedLearnersByUid.containsKey(auid);
              final bSelected = selectedLearnersByUid.containsKey(buid);

              if (aSelected != bSelected) return aSelected ? -1 : 1;

              final an = (a["name"] ?? "").toString();
              final bn = (b["name"] ?? "").toString();
              return an.compareTo(bn);
            });

            return AlertDialog(
              title: const Text("Pick learners"),
              content: SizedBox(
                width: double.maxFinite,
                height: 460,
                child: Column(
                  children: [
                    TextField(
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        hintText: "Search by full name",
                      ),
                      onChanged: (v) {
                        pickerSearchDebounce?.cancel();
                        pickerSearchDebounce = Timer(
                          const Duration(milliseconds: 250),
                          () {
                            if (!context.mounted) return;
                            setDState(() => q = v.trim().toLowerCase());
                          },
                        );
                      },
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: ListView.builder(
                        itemCount: filtered.length,
                        itemBuilder: (_, i) {
                          final l = filtered[i];
                          final uid = l["uid"].toString();
                          final name = l["name"].toString();

                          final isEnrolled = enrolledUids.contains(uid);
                          final isSelected = selectedLearnersByUid.containsKey(
                            uid,
                          );

                          return CheckboxListTile(
                            value: isSelected,
                            onChanged: (val) {
                              // ✅ FIX:
                              // - Block ONLY when trying to tick ON while not enrolled.
                              // - Always allow untick OFF (so you can remove if they got unenrolled later).
                              if (val == true && !isEnrolled) {
                                _notify(
                                  "Not enrolled in this course. Assign course first.",
                                  error: true,
                                );
                                return;
                              }

                              setDState(() {
                                if (val == true) {
                                  selectedLearnersByUid[uid] = {"name": name};
                                } else {
                                  selectedLearnersByUid.remove(uid);
                                }
                              });
                              setModalState(() {});

                              // ✅ Popup notification (shows even above the dialog)
                              if (val == true) {
                                _notify("Added: $name");
                              } else {
                                _notify("Removed: $name");
                              }
                            },
                            title: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                Container(
                                  margin: const EdgeInsets.only(left: 8),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 3,
                                  ),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(999),
                                    color: isEnrolled
                                        ? Colors.blue.withValues(alpha: 0.12)
                                        : Colors.orange.withValues(alpha: 0.12),
                                    border: Border.all(
                                      color: isEnrolled
                                          ? Colors.blue.withValues(alpha: 0.35)
                                          : Colors.orange.withValues(
                                              alpha: 0.35,
                                            ),
                                    ),
                                  ),
                                  child: Text(
                                    isEnrolled ? "Enrolled" : "Not enrolled",
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w900,
                                      color: isEnrolled
                                          ? Colors.blue
                                          : Colors.orange.shade800,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text("Done"),
                ),
              ],
            );
          },
        );
      },
    );

    pickerSearchDebounce?.cancel();
  }

  // -------------------- Full Create/Edit Bottom Sheet --------------------

  Future<void> _openClassEditor({Map<String, dynamic>? existingClass}) async {
    if (_loadingCourses) return _notify("Courses are still loading...");
    if (_courses.isEmpty) return _notify("No courses found.", error: true);

    if (_loadingTeachers) return _notify("Teachers are still loading...");

    final bool isEdit = existingClass != null;

    final String classId = isEdit
        ? (existingClass["class_id"] ?? "").toString()
        : await _generateUniqueClassId();

    Map<String, dynamic> selectedCourse = _courses.first;
    if (isEdit) {
      final courseId = (existingClass["course_id"] ?? "").toString();
      final found = _courses.where((c) => c["id"] == courseId).toList();
      if (found.isNotEmpty) selectedCourse = found.first;
    }
    String selectedVariantKey = isEdit
        ? _normalizeVariantKey((existingClass["variantKey"] ?? "").toString())
        : "inclass";

    String selectedStudyMode = isEdit
        ? _normalizeStudyMode((existingClass["studyMode"] ?? "").toString())
        : "";

    if (selectedVariantKey.isEmpty) {
      selectedVariantKey = "inclass";
    }

    bool isOpen = isEdit ? ((existingClass["is_open"] ?? true) == true) : true;

    // Instructors list with explicit waiting option (no teacher yet)
    List<Map<String, String>> instructors = [
      {'uid': '', 'name': 'Waiting', 'serial': ''},
      ...List<Map<String, String>>.from(_teachers),
    ];
    String instKey(Map<String, String> t) => (t["uid"] ?? "").trim();

    Map<String, String>? selectedInstructorObj = instructors.isNotEmpty
        ? instructors.first
        : null;

    if (isEdit) {
      final cur = existingClass["instructor_current"];
      if (cur is Map) {
        final curMap = Map<String, dynamic>.from(cur);
        final curUid = (curMap["uid"] ?? "").toString().trim();
        final curName = (curMap["name"] ?? "").toString().trim().toLowerCase();

        if (curUid.isNotEmpty) {
          final found = instructors
              .where((t) => (t["uid"] ?? "") == curUid)
              .toList();
          if (found.isNotEmpty) selectedInstructorObj = found.first;
        }

        if ((selectedInstructorObj == null ||
                instKey(selectedInstructorObj).isEmpty) &&
            curName.isNotEmpty) {
          final found = instructors
              .where(
                (t) =>
                    (t["name"] ?? "").toString().trim().toLowerCase() ==
                    curName,
              )
              .toList();
          if (found.isNotEmpty) selectedInstructorObj = found.first;
        }
      } else {
        final exName = (existingClass["instructor"] ?? "")
            .toString()
            .trim()
            .toLowerCase();
        if (exName.isNotEmpty) {
          final found = instructors
              .where(
                (t) =>
                    (t["name"] ?? "").toString().trim().toLowerCase() == exName,
              )
              .toList();
          if (found.isNotEmpty) selectedInstructorObj = found.first;
        }
      }
    }

    final String status = isEdit
        ? (existingClass["status"] ?? "active").toString()
        : "active";

    final schedule = (isEdit && existingClass["schedule"] is Map)
        ? Map<String, dynamic>.from(existingClass["schedule"])
        : <String, dynamic>{};

    final sessionsCountCtrl = TextEditingController(
      text: isEdit ? (schedule["sessions_count"] ?? "12").toString() : "12",
    );

    DateTime? firstSessionDate;
    if (isEdit) {
      final first = (schedule["first_session_date"] ?? "").toString();
      if (first.isNotEmpty) {
        try {
          firstSessionDate = DateTime.parse(first);
        } catch (_) {}
      }
    }

    final List<_ScheduleRow> scheduleRows = [];
    if (isEdit && schedule["sessions"] is List) {
      final list = List<dynamic>.from(schedule["sessions"]);
      for (final item in list) {
        final m = (item is Map)
            ? Map<String, dynamic>.from(item)
            : <String, dynamic>{};
        final row = _ScheduleRow(day: (m["day"] ?? "Mon").toString());
        row.startTime = (m["start_time"] ?? "").toString().isEmpty
            ? null
            : (m["start_time"] ?? "").toString();
        row.durationCtrl.text = (m["duration_min"] ?? "90").toString();
        scheduleRows.add(row);
      }
    }
    if (scheduleRows.isEmpty) {
      scheduleRows.add(_ScheduleRow(day: "Sat"));
      scheduleRows.add(_ScheduleRow(day: "Tue"));
    }

    Map<String, dynamic> previousLearnersByUid = {};
    Map<String, dynamic> selectedLearnersByUid = {};

    if (isEdit && existingClass["learners"] is Map) {
      previousLearnersByUid = Map<String, dynamic>.from(
        (existingClass["learners"] as Map).map(
          (k, v) => MapEntry(k.toString(), v),
        ),
      );
      selectedLearnersByUid = Map<String, dynamic>.from(previousLearnersByUid);
    }

    Future<void> pickDate(StateSetter setModalState) async {
      final now = DateTime.now();
      final picked = await showDatePicker(
        context: context,
        useRootNavigator: true,
        firstDate: DateTime(now.year - 1),
        lastDate: DateTime(now.year + 3),
        initialDate: firstSessionDate ?? now,
      );
      if (picked != null) setModalState(() => firstSessionDate = picked);
    }

    Future<void> pickTime(StateSetter setModalState, _ScheduleRow row) async {
      final picked = await showTimePicker(
        context: context,
        useRootNavigator: true,
        initialTime: TimeOfDay.now(),
      );
      if (picked != null) {
        final hh = picked.hour.toString().padLeft(2, '0');
        final mm = picked.minute.toString().padLeft(2, '0');
        setModalState(() => row.startTime = "$hh:$mm");
      }
    }

    bool saving = false;

    if (!mounted) return;
    final sheetFuture = showModalBottomSheet(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      enableDrag: false,
      isDismissible: false,
      showDragHandle: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            void setSaving(bool v) {
              saving = v;
              setModalState(() {});
            }

            final bool requiresFixedSchedule = _isScheduledClassType(
              selectedVariantKey,
            );
            final selectedInstructorUid = (selectedInstructorObj?["uid"] ?? '')
                .trim();
            final selectedInstructorName =
                (selectedInstructorObj?["name"] ?? '').trim().toLowerCase();
            final bool isWaitingInstructorSelected =
                selectedInstructorUid.isEmpty ||
                selectedInstructorName == 'waiting';
            final learnersCount = selectedLearnersByUid.length;
            final courseId = selectedCourse["id"].toString();

            final courseTitle = (selectedCourse["title"] ?? "").toString();
            final courseLevel = (selectedCourse["level"] ?? "").toString();

            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                  left: 16,
                  right: 16,
                  top: 10,
                  bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              isEdit ? "Edit class" : "Add class",
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(999),
                              color: Colors.black.withValues(alpha: 0.06),
                            ),
                            child: Text(
                              "ID: $classId",
                              style: const TextStyle(
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),

                      if (isEdit)
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: Colors.grey.withValues(alpha: 0.35),
                            ),
                            color: Colors.grey.withValues(alpha: 0.06),
                          ),
                          child: Text(
                            // ✅ Removed course_code in preview
                            "${courseLevel.isEmpty ? "" : "$courseLevel  "} ${courseTitle.isEmpty ? "-" : courseTitle}"
                                .trim(),
                            style: const TextStyle(fontWeight: FontWeight.w800),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        )
                      else
                        DropdownButtonFormField<Map<String, dynamic>>(
                          isExpanded: true,
                          initialValue: selectedCourse,
                          decoration: const InputDecoration(
                            labelText: "Course",
                            border: OutlineInputBorder(),
                          ),
                          selectedItemBuilder: (context) {
                            return _courses.map((c) {
                              final lv = (c["level"] ?? "").toString();
                              final tt = (c["title"] ?? "").toString();
                              final label = "${lv.isEmpty ? "" : "$lv  "}$tt"
                                  .trim();
                              return Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              );
                            }).toList();
                          },
                          items: _courses.map((c) {
                            final lv = (c["level"] ?? "").toString();
                            final tt = (c["title"] ?? "").toString();
                            final label = "${lv.isEmpty ? "" : "$lv  "}$tt"
                                .trim();
                            return DropdownMenuItem<Map<String, dynamic>>(
                              value: c,
                              child: SizedBox(
                                width: double.infinity,
                                child: Text(
                                  label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            );
                          }).toList(),
                          onChanged: saving
                              ? null
                              : (val) {
                                  if (val == null) return;
                                  setModalState(() {
                                    selectedCourse = val;
                                    instructors = [
                                      {
                                        'uid': '',
                                        'name': 'Waiting',
                                        'serial': '',
                                      },
                                      ...List<Map<String, String>>.from(
                                        _teachers,
                                      ),
                                    ];
                                    selectedInstructorObj =
                                        instructors.isNotEmpty
                                        ? instructors.first
                                        : null;
                                    selectedLearnersByUid.clear();
                                  });
                                },
                        ),

                      const SizedBox(height: 12),

                      DropdownButtonFormField<String>(
                        isExpanded: true,
                        initialValue: selectedInstructorObj == null
                            ? null
                            : instKey(selectedInstructorObj!),
                        decoration: const InputDecoration(
                          labelText: "Instructor",
                          border: OutlineInputBorder(),
                        ),
                        items: instructors.map((t) {
                          final uid = (t["uid"] ?? "").toString();
                          final name = (t["name"] ?? "").toString();
                          final serial = (t["serial"] ?? "").toString();
                          final waiting = uid.trim().isEmpty;
                          final label = waiting
                              ? 'Waiting (no teacher yet)'
                              : "$name${serial.isEmpty ? "" : " ($serial)"}";
                          return DropdownMenuItem<String>(
                            value: uid,
                            child: Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          );
                        }).toList(),
                        onChanged: saving
                            ? null
                            : (uid) {
                                final t = instructors.firstWhere(
                                  (x) => (x["uid"] ?? "") == (uid ?? ""),
                                  orElse: () => {
                                    "uid": "",
                                    "name": "",
                                    "serial": "",
                                  },
                                );
                                setModalState(() => selectedInstructorObj = t);
                              },
                      ),

                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        initialValue: selectedVariantKey,
                        decoration: const InputDecoration(
                          labelText: "Class type",
                          border: OutlineInputBorder(),
                        ),
                        items: const [
                          DropdownMenuItem(
                            value: 'inclass',
                            child: Text('In-Class'),
                          ),
                          DropdownMenuItem(
                            value: 'flexible',
                            child: Text('Flexible'),
                          ),
                          DropdownMenuItem(
                            value: 'private',
                            child: Text('Private'),
                          ),
                          DropdownMenuItem(
                            value: 'recorded',
                            child: Text('Recorded'),
                          ),
                        ],
                        onChanged: saving
                            ? null
                            : (v) {
                                if (v == null) return;
                                setModalState(() {
                                  selectedVariantKey = _normalizeVariantKey(v);

                                  if (selectedVariantKey != 'private') {
                                    selectedStudyMode = '';
                                  } else if (selectedStudyMode.isEmpty) {
                                    selectedStudyMode = 'online';
                                  }

                                  selectedLearnersByUid.clear();
                                });
                              },
                      ),

                      if (selectedVariantKey == 'private') ...[
                        const SizedBox(height: 12),
                        DropdownButtonFormField<String>(
                          initialValue: selectedStudyMode.isEmpty
                              ? 'online'
                              : selectedStudyMode,
                          decoration: const InputDecoration(
                            labelText: "Private mode",
                            border: OutlineInputBorder(),
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: 'online',
                              child: Text('Online'),
                            ),
                            DropdownMenuItem(
                              value: 'inclass',
                              child: Text('In-Class'),
                            ),
                          ],
                          onChanged: saving
                              ? null
                              : (v) {
                                  if (v == null) return;
                                  setModalState(() {
                                    selectedStudyMode = _normalizeStudyMode(v);
                                    selectedLearnersByUid.clear();
                                  });
                                },
                        ),
                      ],
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Colors.grey.withValues(alpha: 0.35),
                          ),
                          color: Colors.grey.withValues(alpha: 0.06),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                isOpen ? "Class is OPEN" : "Class is CLOSED",
                                style: const TextStyle(
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                            ),
                            Switch(
                              value: isOpen,
                              onChanged: saving
                                  ? null
                                  : (v) => setModalState(() => isOpen = v),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 12),

                      TextField(
                        controller: sessionsCountCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: "Number of sessions",
                          border: OutlineInputBorder(),
                        ),
                        enabled: !saving,
                      ),

                      const SizedBox(height: 12),

                      if (requiresFixedSchedule &&
                          !isWaitingInstructorSelected) ...[
                        OutlinedButton.icon(
                          onPressed: saving
                              ? null
                              : () => pickDate(setModalState),
                          icon: const Icon(Icons.event),
                          label: Text(
                            firstSessionDate == null
                                ? "Pick first session date"
                                : "First session: ${_formatDate(firstSessionDate!)}",
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(height: 12),
                      ],

                      OutlinedButton.icon(
                        onPressed: saving
                            ? null
                            : (!isOpen
                                  ? null
                                  : () => _openLearnersPickerStrict(
                                      currentClassId: classId,
                                      selectedCourseId: courseId,
                                      selectedVariantKey: selectedVariantKey,
                                      selectedStudyMode: selectedStudyMode,
                                      selectedLearnersByUid:
                                          selectedLearnersByUid,
                                      setModalState: setModalState,
                                    )),
                        icon: const Icon(Icons.people_alt_rounded),
                        label: Text(
                          _loadingLearners
                              ? "Loading learners..."
                              : isOpen
                              ? (learnersCount == 0
                                    ? "Pick learners"
                                    : "Learners selected: $learnersCount")
                              : (learnersCount == 0
                                    ? "Learners (Closed)"
                                    : "Learners: $learnersCount (Closed)"),
                        ),
                      ),

                      if (requiresFixedSchedule &&
                          !isWaitingInstructorSelected) ...[
                        const SizedBox(height: 16),
                        const Text(
                          "Weekly schedule",
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 8),

                        ...scheduleRows.map((row) {
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Row(
                              children: [
                                SizedBox(
                                  width: 110,
                                  child: InputDecorator(
                                    decoration: const InputDecoration(
                                      labelText: "Day",
                                      border: OutlineInputBorder(),
                                      isDense: true,
                                      contentPadding: EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 10,
                                      ),
                                    ),
                                    child: DropdownButtonHideUnderline(
                                      child: DropdownButton<String>(
                                        value: _weekDays.contains(row.day)
                                            ? row.day
                                            : "Mon",
                                        isExpanded: true,
                                        items: _weekDays
                                            .map(
                                              (d) => DropdownMenuItem<String>(
                                                value: d,
                                                child: Text(
                                                  d,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    fontWeight: FontWeight.w800,
                                                  ),
                                                ),
                                              ),
                                            )
                                            .toList(),
                                        onChanged: saving
                                            ? null
                                            : (v) {
                                                if (v == null) return;
                                                setModalState(
                                                  () => row.day = v,
                                                );
                                              },
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: OutlinedButton(
                                    onPressed: saving
                                        ? null
                                        : () => pickTime(setModalState, row),
                                    child: Text(
                                      row.startTime == null
                                          ? "Start time"
                                          : row.startTime!,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                SizedBox(
                                  width: 120,
                                  child: TextField(
                                    controller: row.durationCtrl,
                                    keyboardType: TextInputType.number,
                                    decoration: const InputDecoration(
                                      labelText: "Minutes",
                                      border: OutlineInputBorder(),
                                      isDense: true,
                                      contentPadding: EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 10,
                                      ),
                                    ),
                                    enabled: !saving,
                                  ),
                                ),
                                IconButton(
                                  tooltip: "Remove",
                                  onPressed: saving
                                      ? null
                                      : () {
                                          if (scheduleRows.length <= 1) return;
                                          setModalState(
                                            () => scheduleRows.remove(row),
                                          );
                                        },
                                  icon: const Icon(Icons.close),
                                ),
                              ],
                            ),
                          );
                        }),

                        OutlinedButton.icon(
                          onPressed: saving
                              ? null
                              : () => setModalState(
                                  () => scheduleRows.add(
                                    _ScheduleRow(day: "Mon"),
                                  ),
                                ),
                          icon: const Icon(Icons.add),
                          label: const Text("Add another day"),
                        ),
                      ],

                      const SizedBox(height: 18),

                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: saving
                              ? null
                              : () async {
                                  final pickedUid =
                                      (selectedInstructorObj?["uid"] ?? "")
                                          .trim();
                                  final pickedNameRaw =
                                      (selectedInstructorObj?["name"] ?? "")
                                          .trim();
                                  final isWaitingInstructor =
                                      pickedUid.isEmpty ||
                                      pickedNameRaw.toLowerCase() == 'waiting';
                                  final shouldRequireSchedule =
                                      requiresFixedSchedule &&
                                      !isWaitingInstructor;
                                  final pickedName = isWaitingInstructor
                                      ? 'Waiting'
                                      : pickedNameRaw;

                                  if (pickedName.isEmpty) {
                                    return _notify(
                                      "Pick an instructor.",
                                      error: true,
                                    );
                                  }

                                  final sessionsCount = int.tryParse(
                                    sessionsCountCtrl.text.trim(),
                                  );
                                  if (sessionsCount == null ||
                                      sessionsCount <= 0) {
                                    return _notify(
                                      "Sessions count invalid.",
                                      error: true,
                                    );
                                  }

                                  if (shouldRequireSchedule &&
                                      firstSessionDate == null) {
                                    return _notify(
                                      "Pick the first session date.",
                                      error: true,
                                    );
                                  }

                                  final sessions = <Map<String, dynamic>>[];

                                  if (shouldRequireSchedule) {
                                    for (final row in scheduleRows) {
                                      if (row.startTime == null) {
                                        return _notify(
                                          "Pick start time for ${row.day}.",
                                          error: true,
                                        );
                                      }
                                      final dur = int.tryParse(
                                        row.durationCtrl.text.trim(),
                                      );
                                      if (dur == null || dur <= 0) {
                                        return _notify(
                                          "Duration invalid for ${row.day}.",
                                          error: true,
                                        );
                                      }
                                      sessions.add({
                                        "day": row.day,
                                        "start_time": row.startTime,
                                        "duration_min": dur,
                                      });
                                    }
                                  }

                                  final courseId = selectedCourse["id"]
                                      .toString();

                                  // ✅ FIX (so you NEVER get stuck):
                                  // Auto-remove selected learners who are no longer enrolled.
                                  final enrolledUids =
                                      _uidsWhoMatchCourseVariant(
                                        courseId: courseId,
                                        variantKey: selectedVariantKey,
                                        studyMode: selectedStudyMode,
                                      );
                                  final removedAuto = <String>[];
                                  final selectedUids = selectedLearnersByUid
                                      .keys
                                      .toList();
                                  for (final uid in selectedUids) {
                                    if (!enrolledUids.contains(uid)) {
                                      selectedLearnersByUid.remove(uid);
                                      removedAuto.add(uid);
                                    }
                                  }
                                  if (removedAuto.isNotEmpty) {
                                    _notify(
                                      "Removed ${removedAuto.length} learner(s) (not enrolled anymore).",
                                    );
                                  }

                                  final courseCode =
                                      (selectedCourse["course_code"] ?? "")
                                          .toString();
                                  final courseTitle =
                                      (selectedCourse["title"] ?? "")
                                          .toString();
                                  final courseDuration =
                                      (selectedCourse["duration"] ?? "")
                                          .toString();
                                  final courseLevel =
                                      (selectedCourse["level"] ?? "")
                                          .toString();
                                  final courseCategory =
                                      (selectedCourse["category"] ?? "")
                                          .toString();

                                  final oldCurrent = (isEdit)
                                      ? (existingClass["instructor_current"]
                                                is Map
                                            ? Map<String, dynamic>.from(
                                                existingClass["instructor_current"],
                                              )
                                            : {
                                                "uid": "",
                                                "name":
                                                    (existingClass["instructor"] ??
                                                            "")
                                                        .toString(),
                                                "serial": "",
                                                "assignedAt":
                                                    (existingClass["updated_at"]),
                                              })
                                      : null;

                                  final newCurrent = <String, dynamic>{
                                    "uid": pickedUid,
                                    "name": pickedName,
                                    "serial":
                                        (selectedInstructorObj?["serial"] ?? "")
                                            .toString(),
                                    "assignedAt": ServerValue.timestamp,
                                  };

                                  final effectiveStatus = isWaitingInstructor
                                      ? 'waiting'
                                      : (status.toLowerCase() == 'waiting'
                                            ? 'active'
                                            : status);

                                  final payload = <String, dynamic>{
                                    "class_id": classId,
                                    "status": effectiveStatus,
                                    "is_open": isOpen,

                                    "course_id": courseId,
                                    "course_code": courseCode,
                                    "course_title": courseTitle,
                                    "course_duration": courseDuration,
                                    "course_level": courseLevel,
                                    "category": courseCategory,
                                    "variantKey": selectedVariantKey,
                                    "variantLabel": _variantLabel(
                                      selectedVariantKey,
                                    ),
                                    "studyMode": selectedVariantKey == 'private'
                                        ? selectedStudyMode
                                        : "",
                                    "studyModeLabel":
                                        selectedVariantKey == 'private'
                                        ? _studyModeLabel(selectedStudyMode)
                                        : "",

                                    "instructor": pickedName,
                                    "instructor_current": newCurrent,

                                    "schedule": {
                                      "first_session_date":
                                          shouldRequireSchedule &&
                                              firstSessionDate != null
                                          ? _formatDate(firstSessionDate!)
                                          : "",
                                      "sessions_count": sessionsCount,
                                      "sessions": sessions,
                                    },
                                    "learners": selectedLearnersByUid,
                                    "updated_at": ServerValue.timestamp,
                                    if (!isEdit)
                                      "created_at": ServerValue.timestamp,
                                  };

                                  try {
                                    setSaving(true);

                                    await _classesRef
                                        .child(classId)
                                        .update(payload);

                                    if (isEdit && oldCurrent != null) {
                                      final oldUid = (oldCurrent["uid"] ?? "")
                                          .toString()
                                          .trim();
                                      final newUid = (newCurrent["uid"] ?? "")
                                          .toString()
                                          .trim();

                                      if (oldUid.isNotEmpty &&
                                          oldUid != newUid) {
                                        final histRef = _classesRef
                                            .child(classId)
                                            .child("instructor_history")
                                            .push();
                                        await histRef.set({
                                          ...oldCurrent,
                                          "unassignedAt": ServerValue.timestamp,
                                          "replacedBy": {
                                            "uid": newCurrent["uid"],
                                            "name": newCurrent["name"],
                                            "serial": newCurrent["serial"],
                                          },
                                        });
                                      }
                                    }

                                    await _syncLearnersClassDataStrict(
                                      courseId: courseId,
                                      classPayload: payload,
                                      selectedLearnersByUid:
                                          selectedLearnersByUid,
                                      previousLearnersByUid:
                                          previousLearnersByUid,
                                    );

                                    if (!mounted) return;
                                    if (!context.mounted) return;
                                    Navigator.pop(context);
                                    _notify(
                                      isEdit
                                          ? "Saved: $classId"
                                          : "Class created: $classId",
                                    );
                                  } catch (e) {
                                    _notify(toHumanError(e), error: true);
                                    setSaving(false);
                                  }
                                },
                          child: Text(isEdit ? "Save changes" : "Create class"),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );

    await sheetFuture;
  }

  // -------------------- ✅ Class progress (attendance taught.sessionId vs syllabi sessions) --------------------

  Future<int> _loadSyllabusSessionCount({
    required String courseId,
    required String syllabusVariant,
  }) async {
    if (courseId.isEmpty) return 0;

    final key = '$courseId|$syllabusVariant';
    final cached = _syllabusSessionCountCache[key];
    if (cached != null) return cached;

    int totalSessions = 0;
    var sSnap = await _syllabiRef.child(courseId).child(syllabusVariant).get();
    if ((!sSnap.exists || sSnap.value is! Map) &&
        syllabusVariant == 'private') {
      sSnap = await _syllabiRef.child(courseId).child('inclass').get();
    }

    if (sSnap.exists && sSnap.value is Map) {
      final s = Map<String, dynamic>.from(sSnap.value as Map);
      final modules = s['modules'];
      if (modules is List) {
        for (final m in modules) {
          if (m is! Map) continue;
          final module = Map<String, dynamic>.from(m);
          final units = module['units'];
          if (units is! List) continue;
          for (final u in units) {
            if (u is! Map) continue;
            final unit = Map<String, dynamic>.from(u);
            final lessons = unit['lessons'];
            if (lessons is List) totalSessions += lessons.length;
          }
        }
      } else {
        final units = s['units'];
        if (units is List) {
          for (final u in units) {
            if (u is! Map) continue;
            final unit = Map<String, dynamic>.from(u);
            final sessions = unit['sessions'];
            if (sessions is List) totalSessions += sessions.length;
          }
        }
      }
    }

    _syllabusSessionCountCache[key] = totalSessions;
    return totalSessions;
  }

  Future<Map<int, Map<String, dynamic>>> _loadFlexibleSyllabusSessions(
    String courseId,
  ) async {
    final cid = courseId.trim();
    if (cid.isEmpty) return const <int, Map<String, dynamic>>{};

    final cached = _flexibleSyllabusCache[cid];
    if (cached != null) return cached;

    final out = <int, Map<String, dynamic>>{};
    try {
      final snap = await _syllabiRef.child(cid).child('flexible').get();
      if (!snap.exists || snap.value is! Map) {
        _flexibleSyllabusCache[cid] = out;
        return out;
      }

      final root = Map<dynamic, dynamic>.from(snap.value as Map);
      final units = root['units'];
      int fallbackNo = 1;

      if (units is List) {
        for (final u in units) {
          if (u is! Map) continue;
          final um = Map<dynamic, dynamic>.from(u);
          final sessions = um['sessions'];
          if (sessions is! List) continue;

          for (final s in sessions) {
            if (s is! Map) continue;
            final sm = Map<String, dynamic>.from(s);
            int no = _asInt(sm['sessionNo']);
            if (no <= 0) no = _asInt(sm['sessionNumber']);
            if (no <= 0) no = _asInt(sm['order']);
            if (no <= 0) no = fallbackNo;

            out[no] = {
              'sessionNo': no,
              'sessionTitle': (sm['sessionTitle'] ?? sm['title'] ?? '')
                  .toString()
                  .trim(),
              'title': (sm['title'] ?? '').toString().trim(),
              'objective': (sm['objective'] ?? '').toString().trim(),
              'content': (sm['content'] ?? '').toString().trim(),
              'homework': (sm['homework'] ?? '').toString().trim(),
              'durationMinutes': _asInt(sm['durationMinutes']),
              'source': 'syllabi/flexible',
            };

            fallbackNo += 1;
          }
        }
      }

      if (out.isEmpty) {
        for (final entry in root.entries) {
          final keyNo = int.tryParse(entry.key.toString()) ?? 0;
          final raw = entry.value;
          if (raw is! Map) continue;
          final sm = Map<String, dynamic>.from(raw);
          int no = _asInt(sm['sessionNo']);
          if (no <= 0) no = _asInt(sm['sessionNumber']);
          if (no <= 0) no = _asInt(sm['order']);
          if (no <= 0) no = keyNo;
          if (no <= 0) continue;

          out[no] = {
            'sessionNo': no,
            'sessionTitle': (sm['sessionTitle'] ?? sm['title'] ?? '')
                .toString()
                .trim(),
            'title': (sm['title'] ?? '').toString().trim(),
            'objective': (sm['objective'] ?? '').toString().trim(),
            'content': (sm['content'] ?? '').toString().trim(),
            'homework': (sm['homework'] ?? '').toString().trim(),
            'durationMinutes': _asInt(sm['durationMinutes']),
            'source': 'syllabi/flexible',
          };
        }
      }
    } catch (_) {}

    _flexibleSyllabusCache[cid] = out;
    return out;
  }

  Future<Map<String, dynamic>?> _loadFlexibleSessionInfoByNo(
    String courseId,
    int sessionNo,
  ) async {
    if (courseId.trim().isEmpty || sessionNo <= 0) return null;

    final syllabus = await _loadFlexibleSyllabusSessions(courseId);
    final fromSyllabus = syllabus[sessionNo];
    if (fromSyllabus != null) return fromSyllabus;

    try {
      final snap = await _db
          .child('booking_curriculum/$courseId/sessions/$sessionNo')
          .get();
      if (snap.exists && snap.value is Map) {
        final m = Map<String, dynamic>.from(snap.value as Map);
        return {
          'sessionNo': sessionNo,
          'sessionTitle': (m['sessionTitle'] ?? m['title'] ?? '')
              .toString()
              .trim(),
          'title': (m['title'] ?? '').toString().trim(),
          'objective': (m['objective'] ?? '').toString().trim(),
          'content': (m['content'] ?? '').toString().trim(),
          'homework': (m['homework'] ?? '').toString().trim(),
          'durationMinutes': _asInt(m['durationMinutes']),
          'source': 'booking_curriculum',
        };
      }
    } catch (_) {}

    return null;
  }

  Future<void> _openFlexibleSessionDetailsSheet({
    required String courseId,
    required _FlexAttendanceRow row,
  }) async {
    if (row.sessionNo <= 0) return;

    final info = await _loadFlexibleSessionInfoByNo(courseId, row.sessionNo);
    if (!mounted) return;

    final title = (info?['sessionTitle'] ?? info?['title'] ?? row.lessonTitle)
        .toString()
        .trim();
    final objective = (info?['objective'] ?? '').toString().trim();
    final content = (info?['content'] ?? '').toString().trim();
    final teacherComment = row.teacherComment.trim();
    final source = (info?['source'] ?? 'not_found').toString().trim();

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title.isEmpty
                        ? 'Session ${row.sessionNo}'
                        : 'Session ${row.sessionNo} — $title',
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF1A2B48),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Teacher: ${row.teacherName.isEmpty ? '-' : row.teacherName}',
                    style: TextStyle(
                      color: Colors.grey.shade800,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Source: $source',
                    style: TextStyle(
                      color: Colors.grey.shade700,
                      fontWeight: FontWeight.w700,
                      fontSize: 12,
                    ),
                  ),
                  if (row.taughtTitle.isNotEmpty &&
                      title.isNotEmpty &&
                      row.taughtTitle.toLowerCase() != title.toLowerCase()) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Teacher taught title: ${row.taughtTitle}',
                      style: TextStyle(
                        color: Colors.orange.shade800,
                        fontWeight: FontWeight.w700,
                        fontSize: 12,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  _detailsBlock('Objective', objective),
                  const SizedBox(height: 10),
                  _detailsBlock('Content', content),
                  const SizedBox(height: 10),
                  _detailsBlock('Teacher Comment', teacherComment),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _detailsBlock(String title, String body) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontWeight: FontWeight.w900,
            color: Color(0xFF1A2B48),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          body.isEmpty ? '-' : body,
          style: TextStyle(
            color: Colors.grey.shade800,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }

  Future<List<Map<String, dynamic>>> _loadClassSyllabusFlat({
    required String courseId,
    required String variantKey,
  }) async {
    if (courseId.trim().isEmpty) return const <Map<String, dynamic>>[];

    final syllabusVariant = syllabusVariantForScheduledAttendance(
      _normalizeVariantKey(variantKey),
    );
    var sSnap = await _syllabiRef.child(courseId).child(syllabusVariant).get();
    if ((!sSnap.exists || sSnap.value == null || sSnap.value is! Map) &&
        syllabusVariant == 'private') {
      sSnap = await _syllabiRef.child(courseId).child('inclass').get();
    }
    if (!sSnap.exists || sSnap.value == null || sSnap.value is! Map) {
      return const <Map<String, dynamic>>[];
    }

    final s = Map<String, dynamic>.from(sSnap.value as Map);
    final flat = <Map<String, dynamic>>[];

    final modules = s['modules'];
    if (modules is List) {
      for (final m in modules) {
        if (m is! Map) continue;
        final module = Map<String, dynamic>.from(m);
        final units = module['units'];
        if (units is! List) continue;
        for (final u in units) {
          if (u is! Map) continue;
          final unit = Map<String, dynamic>.from(u);
          final unitTitle = ((unit['title'] ?? '').toString().trim().isNotEmpty)
              ? (unit['title'] ?? '').toString()
              : (unit['description'] ?? '').toString();
          final unitOrder = _asInt(unit['order']);
          final lessons = unit['lessons'];
          if (lessons is! List) continue;
          for (final ss in lessons) {
            if (ss is! Map) continue;
            final sess = Map<String, dynamic>.from(ss);
            flat.add({
              'unitOrder': unitOrder,
              'unitTitle': unitTitle,
              'order': _asInt(sess['order']),
              'sessionId': (sess['id'] ?? '').toString(),
              'title': (sess['title'] ?? '').toString(),
              'objective': (sess['objective'] ?? '').toString(),
            });
          }
        }
      }
    } else {
      final units = s['units'];
      if (units is List) {
        for (final u in units) {
          if (u is! Map) continue;
          final unit = Map<String, dynamic>.from(u);
          final unitTitle = ((unit['title'] ?? '').toString().trim().isNotEmpty)
              ? (unit['title'] ?? '').toString()
              : (unit['description'] ?? '').toString();
          final unitOrder = _asInt(unit['order']);
          final sessions = unit['sessions'];
          if (sessions is! List) continue;
          for (final ss in sessions) {
            if (ss is! Map) continue;
            final sess = Map<String, dynamic>.from(ss);
            flat.add({
              'unitOrder': unitOrder,
              'unitTitle': unitTitle,
              'order': _asInt(sess['order']),
              'sessionId': (sess['id'] ?? '').toString(),
              'title': (sess['title'] ?? '').toString(),
              'objective': (sess['objective'] ?? '').toString(),
            });
          }
        }
      }
    }

    flat.sort((a, b) {
      final uo = _asInt(a['unitOrder']).compareTo(_asInt(b['unitOrder']));
      if (uo != 0) return uo;
      return _asInt(a['order']).compareTo(_asInt(b['order']));
    });
    return flat;
  }

  Set<String> _coveredSessionIdsForLearner({
    required Map<String, dynamic> cls,
    required String learnerUid,
  }) {
    final attendanceRaw = cls['attendance'];
    if (attendanceRaw is! Map) return <String>{};

    final out = <String>{};
    final att = Map<dynamic, dynamic>.from(attendanceRaw);
    for (final value in att.values) {
      if (value is! Map) continue;
      final rec = Map<String, dynamic>.from(value);

      bool isPresent = false;
      final presentRaw = rec['present'];
      if (presentRaw is Map) {
        final present = Map<String, dynamic>.from(presentRaw);
        if (present[learnerUid] == true) isPresent = true;
      }
      if (!isPresent) continue;

      final taughtItems = rec['taughtItems'];
      if (taughtItems is List) {
        for (final itemRaw in taughtItems) {
          if (itemRaw is! Map) continue;
          final item = Map<String, dynamic>.from(itemRaw);
          final type = (item['type'] ?? '').toString().trim().toLowerCase();
          if (type.isNotEmpty && type != 'syllabus') continue;
          final sid = (item['sessionId'] ?? '').toString().trim();
          if (sid.isNotEmpty) out.add(sid);
        }
      }

      final taught = rec['taught'];
      if (taught is Map) {
        final tm = Map<String, dynamic>.from(taught);
        final sid = (tm['sessionId'] ?? '').toString().trim();
        if (sid.isNotEmpty) out.add(sid);
      }
    }

    return out;
  }

  Future<_ClassSyllabusProgressDetails> _loadClassSyllabusProgressDetails(
    Map<String, dynamic> cls,
  ) async {
    final courseId = (cls['course_id'] ?? '').toString().trim();
    final variantKey = (cls['variantKey'] ?? '').toString();
    final syllabus = await _loadClassSyllabusFlat(
      courseId: courseId,
      variantKey: variantKey,
    );
    final classCovered = _classCoveredSessionIds(cls);
    final learners = _classLearnersList(cls);

    final rows = <_ClassLearnerProgressRow>[];
    final topCovered = <String>{};

    for (final learner in learners) {
      final uid = (learner['uid'] ?? '').trim();
      if (uid.isEmpty) continue;
      final covered = _coveredSessionIdsForLearner(cls: cls, learnerUid: uid);
      if (covered.length > topCovered.length) {
        topCovered
          ..clear()
          ..addAll(covered);
      }
      rows.add(
        _ClassLearnerProgressRow(
          uid: uid,
          learnerName: (learner['name'] ?? '').trim(),
          serial: (learner['serial'] ?? '').trim(),
          covered: covered,
        ),
      );
    }

    final comparedRows =
        rows.map((row) {
          final missing = topCovered.difference(row.covered);
          final extra = row.covered.difference(topCovered);
          return row.copyWith(missingFromTop: missing, extraVsTop: extra);
        }).toList()..sort((a, b) {
          final byMissing = b.missingFromTop.length.compareTo(
            a.missingFromTop.length,
          );
          if (byMissing != 0) return byMissing;
          final an = a.displayName.toLowerCase();
          final bn = b.displayName.toLowerCase();
          return an.compareTo(bn);
        });

    return _ClassSyllabusProgressDetails(
      syllabus: syllabus,
      classCovered: classCovered,
      learnerRows: comparedRows,
      topCoveredCount: topCovered.length,
    );
  }

  Future<void> _openClassSyllabusProgressSheet(Map<String, dynamic> cls) async {
    final classId = (cls['class_id'] ?? '').toString().trim();
    final title = (cls['course_title'] ?? '').toString().trim();

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: FutureBuilder<_ClassSyllabusProgressDetails>(
              future: _loadClassSyllabusProgressDetails(cls),
              builder: (context, snap) {
                if (!snap.hasData) {
                  return const SizedBox(
                    height: 300,
                    child: Center(child: CircularProgressIndicator()),
                  );
                }

                final data = snap.data!;
                final total = data.syllabus.length;
                final classDone = data.classCovered.length;

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title.isEmpty ? 'Class Progress' : title,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF1A2B48),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      classId.isEmpty ? '-' : 'Class ID: $classId',
                      style: TextStyle(
                        color: Colors.grey.shade700,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      total > 0
                          ? 'Class taught lessons: $classDone / $total'
                          : 'Class taught lessons: -',
                      style: TextStyle(
                        color: Colors.grey.shade800,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Expanded(
                      child: ListView(
                        children: [
                          ...data.syllabus.asMap().entries.map((entry) {
                            final idx = entry.key + 1;
                            final s = entry.value;
                            final sid = (s['sessionId'] ?? '')
                                .toString()
                                .trim();
                            final taught =
                                sid.isNotEmpty &&
                                data.classCovered.contains(sid);
                            final stitle = (s['title'] ?? '').toString().trim();
                            final objective = (s['objective'] ?? '')
                                .toString()
                                .trim();
                            return Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                color: taught
                                    ? const Color(0xFFECFDF5)
                                    : Colors.grey.shade50,
                                border: Border.all(
                                  color: taught
                                      ? const Color(0xFF86EFAC)
                                      : Colors.grey.shade300,
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Icon(
                                        taught
                                            ? Icons.check_circle_rounded
                                            : Icons
                                                  .radio_button_unchecked_rounded,
                                        color: taught
                                            ? const Color(0xFF16A34A)
                                            : Colors.grey.shade500,
                                        size: 18,
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(
                                          '$idx. ${stitle.isEmpty ? 'Lesson' : stitle}',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w800,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  if (objective.isNotEmpty) ...[
                                    const SizedBox(height: 6),
                                    Text(
                                      objective,
                                      style: TextStyle(
                                        color: Colors.grey.shade700,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            );
                          }),
                          const SizedBox(height: 8),
                          const Divider(height: 1),
                          const SizedBox(height: 10),
                          Text(
                            'Learner alignment',
                            style: TextStyle(
                              color: Colors.grey.shade900,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 8),
                          ...data.learnerRows.map((row) {
                            final isBehind = row.missingFromTop.isNotEmpty;
                            final isDifferent =
                                !isBehind && row.extraVsTop.isNotEmpty;
                            final pct = total > 0
                                ? ((row.covered.length / total) * 100)
                                      .round()
                                      .clamp(0, 100)
                                : 0;
                            final bg = isBehind
                                ? const Color(0xFFFEF2F2)
                                : (isDifferent
                                      ? const Color(0xFFFFFBEB)
                                      : const Color(0xFFECFDF5));
                            final border = isBehind
                                ? const Color(0xFFFCA5A5)
                                : (isDifferent
                                      ? const Color(0xFFFCD34D)
                                      : const Color(0xFF86EFAC));
                            final badgeText = isBehind
                                ? 'Behind'
                                : (isDifferent ? 'Different path' : 'On track');
                            final badgeColor = isBehind
                                ? const Color(0xFFB91C1C)
                                : (isDifferent
                                      ? const Color(0xFFB45309)
                                      : const Color(0xFF166534));

                            return Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                color: bg,
                                border: Border.all(color: border),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          row.displayName,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w900,
                                          ),
                                        ),
                                      ),
                                      Text(
                                        '$pct%',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w900,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '${row.covered.length} / $total lessons',
                                    style: TextStyle(
                                      color: Colors.grey.shade800,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    badgeText,
                                    style: TextStyle(
                                      color: badgeColor,
                                      fontWeight: FontWeight.w900,
                                      fontSize: 12,
                                    ),
                                  ),
                                  if (isBehind)
                                    InkWell(
                                      onTap: () {
                                        _openMissingLessonsSheet(
                                          learnerName: row.displayName,
                                          missingSessionIds: row.missingFromTop,
                                          syllabus: data.syllabus,
                                        );
                                      },
                                      borderRadius: BorderRadius.circular(8),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          vertical: 2,
                                        ),
                                        child: Text(
                                          'Missing ${row.missingFromTop.length} lesson(s) vs top learner (${data.topCoveredCount}). Tap to view.',
                                          style: TextStyle(
                                            color: Colors.red.shade700,
                                            fontWeight: FontWeight.w700,
                                            fontSize: 12,
                                            decoration:
                                                TextDecoration.underline,
                                            decorationColor:
                                                Colors.red.shade700,
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            );
                          }),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  Future<void> _openMissingLessonsSheet({
    required String learnerName,
    required Set<String> missingSessionIds,
    required List<Map<String, dynamic>> syllabus,
  }) async {
    if (missingSessionIds.isEmpty) return;

    final byId = <String, Map<String, dynamic>>{};
    for (final s in syllabus) {
      final sid = (s['sessionId'] ?? '').toString().trim();
      if (sid.isEmpty) continue;
      byId[sid] = s;
    }

    final rows = <Map<String, dynamic>>[];
    for (final sid in missingSessionIds) {
      final item = byId[sid];
      if (item != null) {
        rows.add(item);
      } else {
        rows.add({
          'sessionId': sid,
          'title': 'Lesson $sid',
          'objective': '',
          'order': 999999,
          'unitOrder': 999999,
        });
      }
    }

    rows.sort((a, b) {
      final uo = _asInt(a['unitOrder']).compareTo(_asInt(b['unitOrder']));
      if (uo != 0) return uo;
      return _asInt(a['order']).compareTo(_asInt(b['order']));
    });

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  learnerName,
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 17,
                    color: Color(0xFF1A2B48),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Missing lessons (${rows.length})',
                  style: TextStyle(
                    color: Colors.red.shade700,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: ListView.separated(
                    itemCount: rows.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (_, i) {
                      final s = rows[i];
                      final title = (s['title'] ?? '').toString().trim();
                      final objective = (s['objective'] ?? '')
                          .toString()
                          .trim();
                      return Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFEF2F2),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFFCA5A5)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title.isEmpty ? 'Lesson' : title,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            if (objective.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                objective,
                                style: TextStyle(
                                  color: Colors.grey.shade800,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // -------------------- Classes List UI --------------------

  Future<void> _openClassesFiltersSheet() async {
    final teacherIds = _teachers.map((t) => (t['uid'] ?? '').trim()).toSet();
    final courseIds = _courses
        .map((c) => (c['id'] ?? '').toString().trim())
        .toSet();
    var dayValue = _dayFilter;
    var statusValue = _openFilter == null
        ? 'all'
        : (_openFilter! ? 'open' : 'closed');
    if (_waitingStatusOnly) statusValue = 'waiting';
    var teacherValue = teacherIds.contains(_teacherFilterUid)
        ? _teacherFilterUid
        : 'all';
    var courseValue = courseIds.contains(_courseFilterId)
        ? _courseFilterId
        : 'all';
    var emptyOnlyValue = _emptyClassesOnly;

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Class filters',
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        color: Color(0xFF1A2B48),
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String>(
                      initialValue: dayValue,
                      decoration: const InputDecoration(
                        isDense: true,
                        labelText: 'Day',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        const DropdownMenuItem(
                          value: 'All',
                          child: Text('All days'),
                        ),
                        ..._weekDays.map(
                          (d) => DropdownMenuItem(value: d, child: Text(d)),
                        ),
                      ],
                      onChanged: (v) {
                        if (v == null) return;
                        setSheetState(() => dayValue = v);
                      },
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      initialValue: statusValue,
                      decoration: const InputDecoration(
                        isDense: true,
                        labelText: 'Status',
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(value: 'all', child: Text('All')),
                        DropdownMenuItem(
                          value: 'open',
                          child: Text('Open only'),
                        ),
                        DropdownMenuItem(
                          value: 'closed',
                          child: Text('Closed only'),
                        ),
                        DropdownMenuItem(
                          value: 'waiting',
                          child: Text('Waiting status'),
                        ),
                      ],
                      onChanged: (v) {
                        if (v == null) return;
                        setSheetState(() => statusValue = v);
                      },
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      initialValue: teacherValue,
                      decoration: const InputDecoration(
                        isDense: true,
                        labelText: 'Teacher',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        const DropdownMenuItem(
                          value: 'all',
                          child: Text('All teachers'),
                        ),
                        ..._teachers.map(
                          (t) => DropdownMenuItem(
                            value: (t['uid'] ?? '').trim(),
                            child: Text((t['name'] ?? '-').trim()),
                          ),
                        ),
                      ],
                      onChanged: (v) {
                        if (v == null || v.trim().isEmpty) return;
                        setSheetState(() => teacherValue = v);
                      },
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      initialValue: courseValue,
                      decoration: const InputDecoration(
                        isDense: true,
                        labelText: 'Course',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        const DropdownMenuItem(
                          value: 'all',
                          child: Text('All courses'),
                        ),
                        ..._courses.map((c) {
                          final id = (c['id'] ?? '').toString().trim();
                          final title = (c['title'] ?? '').toString().trim();
                          final level = (c['level'] ?? '').toString().trim();
                          final labelBase = [
                            if (level.isNotEmpty) level,
                            if (title.isNotEmpty) title,
                          ].join(' - ');
                          final label = labelBase.isEmpty
                              ? id
                              : '$labelBase (${id.isEmpty ? '-' : id})';
                          return DropdownMenuItem(
                            value: id,
                            child: Text(label),
                          );
                        }),
                      ],
                      onChanged: (v) {
                        if (v == null) return;
                        setSheetState(() => courseValue = v);
                      },
                    ),
                    const SizedBox(height: 6),
                    SwitchListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Empty classes only'),
                      value: emptyOnlyValue,
                      onChanged: (v) => setSheetState(() => emptyOnlyValue = v),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        TextButton(
                          onPressed: () {
                            setSheetState(() {
                              dayValue = 'All';
                              statusValue = 'all';
                              teacherValue = 'all';
                              courseValue = 'all';
                              emptyOnlyValue = false;
                            });
                          },
                          child: const Text('Reset'),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('Cancel'),
                        ),
                        const SizedBox(width: 6),
                        FilledButton(
                          onPressed: () {
                            setState(() {
                              _dayFilter = dayValue;
                              _teacherFilterUid = teacherValue;
                              _courseFilterId = courseValue;
                              _emptyClassesOnly = emptyOnlyValue;
                              if (statusValue == 'waiting') {
                                _waitingStatusOnly = true;
                                _openFilter = null;
                              } else if (statusValue == 'all') {
                                _waitingStatusOnly = false;
                                _openFilter = null;
                              } else if (statusValue == 'open') {
                                _waitingStatusOnly = false;
                                _openFilter = true;
                              } else {
                                _waitingStatusOnly = false;
                                _openFilter = false;
                              }
                            });
                            Navigator.of(context).pop();
                          },
                          child: const Text('Apply'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildClassesList() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: FutureBuilder<DataSnapshot>(
            future: _classesFuture,
            builder: (context, snap) {
              if (snap.hasError) {
                return Center(
                  child: Text(
                    'Could not load classes right now.',
                    style: TextStyle(
                      color: Colors.red.shade700,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                );
              }
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }

              final data = snap.data?.value;
              if (data == null || data is! Map) {
                return const Center(child: Text("No classes yet."));
              }

              final map = Map<dynamic, dynamic>.from(data);

              final allClasses = map.values
                  .whereType<dynamic>()
                  .map((e) => Map<String, dynamic>.from(e as Map))
                  .toList();

              final filtered = allClasses
                  .where(_matchesSearch)
                  .where(_matchesDayFilter)
                  .where(_matchesOpenFilter)
                  .where(_matchesWaitingStatusFilter)
                  .where(_matchesTeacherFilter)
                  .where(_matchesCourseFilter)
                  .where(_matchesEmptyClassesFilter)
                  .toList();

              filtered.sort((a, b) {
                final aa = (a["created_at"] ?? 0) is int
                    ? (a["created_at"] as int)
                    : 0;
                final bb = (b["created_at"] ?? 0) is int
                    ? (b["created_at"] as int)
                    : 0;
                return bb.compareTo(aa);
              });

              // Summary line
              final summary =
                  "Showing ${filtered.length} of ${allClasses.length} classes";

              if (filtered.isEmpty) {
                return Center(
                  child: Text(
                    "No matching classes.\n$summary",
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                );
              }

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          summary,
                          style: TextStyle(
                            color: Colors.grey.shade700,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Refresh classes',
                        onPressed: _refreshClassesSnapshot,
                        icon: const Icon(Icons.refresh_rounded),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: ListView.separated(
                      padding: const EdgeInsets.only(bottom: 90),
                      itemCount: filtered.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, i) {
                        final cls = filtered[i];

                        final id = (cls["class_id"] ?? "").toString();
                        final classKey = id.isEmpty ? 'class_$i' : id;
                        final expanded = _expandedClassIds.contains(classKey);
                        final status = (cls["status"] ?? "active").toString();
                        final isPaused = status.toLowerCase() == 'paused';
                        final pauseWindowRaw = cls['pause_window'];
                        final pauseWindow = pauseWindowRaw is Map
                            ? pauseWindowRaw.map((k, v) => MapEntry('$k', v))
                            : <String, dynamic>{};
                        final pauseFrom = (pauseWindow['from'] ?? '')
                            .toString()
                            .trim();
                        final pauseTo = (pauseWindow['to'] ?? '')
                            .toString()
                            .trim();

                        final courseTitle = (cls["course_title"] ?? "")
                            .toString();
                        final variantKey = (cls["variantKey"] ?? "").toString();
                        final studyMode = (cls["studyMode"] ?? "").toString();
                        final classTypeLabel = _classTypeLabel(
                          variantKey: variantKey,
                          studyMode: studyMode,
                        );
                        final metricsFuture = _classTabMetricsFor(
                          cls: cls,
                          index: i,
                        );

                        final instructor = (cls["instructor"] ?? "").toString();

                        final sched = (cls["schedule"] is Map)
                            ? Map<String, dynamic>.from(cls["schedule"])
                            : <String, dynamic>{};
                        final firstDate = (sched["first_session_date"] ?? "")
                            .toString();
                        final learners = _classLearnersList(cls);

                        return Card(
                          color: isPaused ? const Color(0xFFFFF3E0) : null,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                            side: BorderSide(
                              color: isPaused
                                  ? Colors.orange.shade300
                                  : Colors.grey.withValues(alpha: 0.25),
                              width: isPaused ? 1.4 : 1,
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        courseTitle.isEmpty
                                            ? (id.isEmpty ? '-' : id)
                                            : courseTitle,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w900,
                                          fontSize: 16,
                                        ),
                                      ),
                                    ),
                                    PopupMenuButton<String>(
                                      tooltip: 'Class actions',
                                      onSelected: (value) {
                                        if (value == 'edit') {
                                          _openClassEditor(existingClass: cls);
                                          return;
                                        }
                                        if (value == 'pause') {
                                          _pauseClassWithWindow(cls);
                                          return;
                                        }
                                        if (value == 'block') {
                                          _setClassStatus(id, 'blocked');
                                          return;
                                        }
                                        if (value == 'activate') {
                                          _setClassStatus(id, 'active');
                                          return;
                                        }
                                        if (value == 'waiting') {
                                          _setClassStatus(id, 'waiting');
                                          return;
                                        }
                                        if (value == 'delete') {
                                          _deleteClass(id);
                                        }
                                      },
                                      itemBuilder: (context) => [
                                        const PopupMenuItem(
                                          value: 'edit',
                                          child: Text('Edit'),
                                        ),
                                        const PopupMenuDivider(),
                                        PopupMenuItem(
                                          value: 'activate',
                                          enabled: status != 'active',
                                          child: const Text('Activate'),
                                        ),
                                        PopupMenuItem(
                                          value: 'pause',
                                          enabled: status != 'paused',
                                          child: const Text('Pause'),
                                        ),
                                        PopupMenuItem(
                                          value: 'block',
                                          enabled: status != 'blocked',
                                          child: const Text('Block'),
                                        ),
                                        PopupMenuItem(
                                          value: 'waiting',
                                          enabled: status != 'waiting',
                                          child: const Text('Set waiting'),
                                        ),
                                        const PopupMenuDivider(),
                                        const PopupMenuItem(
                                          value: 'delete',
                                          child: Text('Delete'),
                                        ),
                                      ],
                                      icon: const Icon(Icons.more_vert_rounded),
                                    ),
                                    IconButton(
                                      tooltip: 'Mass SMS',
                                      icon: Icon(
                                        Icons.sms_rounded,
                                        size: 20,
                                        color: Colors.blueGrey.shade400,
                                      ),
                                      onPressed: learners.isEmpty
                                          ? null
                                          : () => _handleMassSms(learners),
                                    ),
                                    IconButton(
                                      tooltip: expanded
                                          ? 'Collapse learners'
                                          : 'Expand learners',
                                      onPressed: learners.isEmpty
                                          ? null
                                          : () {
                                              setState(() {
                                                if (expanded) {
                                                  _expandedClassIds.remove(
                                                    classKey,
                                                  );
                                                } else {
                                                  _expandedClassIds.add(
                                                    classKey,
                                                  );
                                                }
                                              });
                                            },
                                      icon: Icon(
                                        expanded
                                            ? Icons.keyboard_arrow_up_rounded
                                            : Icons.keyboard_arrow_down_rounded,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                if (classTypeLabel.trim().isNotEmpty) ...[
                                  Text(
                                    'Variant: $classTypeLabel',
                                    style: TextStyle(
                                      color: Colors.grey.shade800,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                ],
                                Text(
                                  instructor.isEmpty
                                      ? "Instructor: -"
                                      : "Instructor: $instructor",
                                  style: TextStyle(
                                    color: Colors.grey.shade700,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'Status: ${status.toUpperCase()}',
                                  style: TextStyle(
                                    color: _statusColor(status),
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                if (isPaused &&
                                    pauseFrom.isNotEmpty &&
                                    pauseTo.isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    'Paused: $pauseFrom → $pauseTo',
                                    style: TextStyle(
                                      color: Colors.orange.shade900,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],

                                const SizedBox(height: 6),
                                Text(
                                  firstDate.isEmpty
                                      ? _prettySessions(cls)
                                      : 'Start: $firstDate • ${_prettySessions(cls)}',
                                  style: TextStyle(
                                    color: Colors.grey.shade800,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'Learners: ${learners.length}',
                                  style: TextStyle(
                                    color: Colors.grey.shade700,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 10),
                                FutureBuilder<_ClassTabMetrics>(
                                  future: metricsFuture,
                                  builder: (context, metricsSnap) {
                                    if (!metricsSnap.hasData) {
                                      return const LinearProgressIndicator(
                                        minHeight: 2,
                                      );
                                    }

                                    final metrics = metricsSnap.data!;
                                    return Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                metrics.totalSessions > 0
                                                    ? 'Course progress: ${metrics.currentSessions} / ${metrics.totalSessions}'
                                                    : 'Course progress: ${metrics.currentSessions} / -',
                                                style: TextStyle(
                                                  color: Colors.grey.shade800,
                                                  fontWeight: FontWeight.w700,
                                                  fontSize: 12,
                                                ),
                                              ),
                                            ),
                                            Tooltip(
                                              message:
                                                  'Syllabus lesson details',
                                              child: InkWell(
                                                onTap: () {
                                                  _openClassSyllabusProgressSheet(
                                                    cls,
                                                  );
                                                },
                                                borderRadius:
                                                    BorderRadius.circular(999),
                                                child: Container(
                                                  width: 22,
                                                  height: 22,
                                                  alignment: Alignment.center,
                                                  decoration: BoxDecoration(
                                                    shape: BoxShape.circle,
                                                    color: const Color(
                                                      0xFFFEF3C7,
                                                    ),
                                                    border: Border.all(
                                                      color: const Color(
                                                        0xFFF59E0B,
                                                      ),
                                                    ),
                                                  ),
                                                  child: const Text(
                                                    '!',
                                                    style: TextStyle(
                                                      color: Color(0xFF92400E),
                                                      fontSize: 13,
                                                      fontWeight:
                                                          FontWeight.w900,
                                                      height: 1,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 4),
                                        ClipRRect(
                                          borderRadius: BorderRadius.circular(
                                            999,
                                          ),
                                          child: LinearProgressIndicator(
                                            value: metrics.courseProgressValue,
                                            minHeight: 9,
                                            backgroundColor: const Color(
                                              0xFFE5E7EB,
                                            ),
                                            valueColor:
                                                const AlwaysStoppedAnimation<
                                                  Color
                                                >(Color(0xFF2563EB)),
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        Text(
                                          metrics.paidSessions > 0
                                              ? 'Payment progress: ${metrics.consumedSessions} / ${metrics.paidSessions}'
                                              : 'Payment progress: no package total',
                                          style: TextStyle(
                                            color: Colors.grey.shade800,
                                            fontWeight: FontWeight.w700,
                                            fontSize: 12,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        ClipRRect(
                                          borderRadius: BorderRadius.circular(
                                            999,
                                          ),
                                          child: LinearProgressIndicator(
                                            value: metrics.paymentProgressValue,
                                            minHeight: 9,
                                            backgroundColor: const Color(
                                              0xFFE5E7EB,
                                            ),
                                            valueColor:
                                                AlwaysStoppedAnimation<Color>(
                                                  metrics.paidSessions > 0
                                                      ? const Color(0xFFD97706)
                                                      : Colors
                                                            .blueGrey
                                                            .shade500,
                                                ),
                                          ),
                                        ),
                                        const SizedBox(height: 6),
                                        Text(
                                          metrics.totalSessions > 0
                                              ? 'Current sessions: ${metrics.currentSessions} / ${metrics.totalSessions}'
                                              : 'Current sessions: ${metrics.currentSessions}',
                                          style: TextStyle(
                                            color: Colors.grey.shade700,
                                            fontWeight: FontWeight.w700,
                                            fontSize: 12,
                                          ),
                                        ),
                                        if (metrics.paymentVariesAcrossLearners)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              top: 4,
                                            ),
                                            child: Text(
                                              'Payment package varies across learners.',
                                              style: TextStyle(
                                                color: Colors.grey.shade700,
                                                fontWeight: FontWeight.w600,
                                                fontSize: 11,
                                              ),
                                            ),
                                          ),
                                      ],
                                    );
                                  },
                                ),
                                if (expanded) ...[
                                  const SizedBox(height: 6),
                                  if (learners.isEmpty)
                                    Text(
                                      'No learners in this class.',
                                      style: TextStyle(
                                        color: Colors.grey.shade600,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    )
                                  else
                                    Column(
                                      children: learners.asMap().entries.map((
                                        entry,
                                      ) {
                                        final idx = entry.key;
                                        final l = entry.value;
                                        final serial = (l['serial'] ?? '')
                                            .trim();
                                        final name = (l['name'] ?? '').trim();
                                        final title = name.isNotEmpty
                                            ? name
                                            : (serial.isNotEmpty
                                                  ? serial
                                                  : l['uid'] ?? '-');
                                        final subtitle = serial.isNotEmpty
                                            ? 'Serial: $serial'
                                            : null;
                                        final learnerUid =
                                            (l['uid'] ?? '').toString();

                                        return Column(
                                          children: [
                                            ListTile(
                                              dense: true,
                                              contentPadding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 6,
                                                  ),
                                              leading: const Icon(
                                                Icons.person_rounded,
                                              ),
                                              title: Text(
                                                title,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              subtitle: subtitle == null
                                                  ? null
                                                  : Text(subtitle),
                                              trailing: Row(
                                                mainAxisSize:
                                                    MainAxisSize.min,
                                                children: [
                                                  _smallActionIcon(
                                                    icon: Icons
                                                        .phone_rounded,
                                                    color: Colors.green,
                                                    tooltip: 'Call',
                                                    onTap: () =>
                                                        _handleLearnerCall(
                                                      learnerUid,
                                                      title,
                                                    ),
                                                  ),
                                                  _smallActionIcon(
                                                    icon: Icons.sms_rounded,
                                                    color: AdminLearnersScreen
                                                        .accentCyan,
                                                    tooltip: 'Send SMS',
                                                    onTap: () =>
                                                        _handleLearnerSms(
                                                      learnerUid,
                                                      title,
                                                    ),
                                                  ),
                                                  _smallActionIcon(
                                                    icon: Icons
                                                        .notifications_active_rounded,
                                                    color: AdminLearnersScreen
                                                        .actionOrange,
                                                    tooltip: 'Send Reminder',
                                                    onTap: () =>
                                                        _handleLearnerReminder(
                                                      learnerUid,
                                                      title,
                                                    ),
                                                  ),
                                                  _smallActionIcon(
                                                    icon: Icons.mail_rounded,
                                                    color: Colors.purple,
                                                    tooltip: 'Open Mail',
                                                    onTap: () =>
                                                        _handleLearnerMail(
                                                      learnerUid,
                                                      title,
                                                    ),
                                                  ),
                                                  GestureDetector(
                                                    onTap: () =>
                                                        _openLearnerFromClass(
                                                            l),
                                                    child: const Padding(
                                                      padding: EdgeInsets.all(
                                                          4),
                                                      child: Icon(
                                                        Icons
                                                            .open_in_new_rounded,
                                                        size: 16,
                                                        color: Colors.grey,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            if (idx != learners.length - 1)
                                              const Divider(height: 1),
                                          ],
                                        );
                                      }).toList(),
                                    ),
                                ],
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  bool _isNearExpiryMs(int expiresAt, {int days = 7}) {
    if (expiresAt <= 0) return false;
    final now = DateTime.now().millisecondsSinceEpoch;
    final diff = expiresAt - now;
    if (diff < 0) return false;
    return diff <= Duration(days: days).inMilliseconds;
  }

  String _fmtDateOnlyMs(int ms) {
    if (ms <= 0) return 'No deadline';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    return '${d.year}-$mm-$dd';
  }

  int _effectiveFlexReminder({
    required int sessionsPaidTotal,
    required int remindBeforeSession,
  }) {
    final fallback = remindBeforeSession > 0 ? remindBeforeSession : 2;
    return normalizeReminderForSessions(
      sessionsPaidTotal: sessionsPaidTotal,
      remindBeforeSession: fallback,
    );
  }

  String _flexPaymentStatusLabel({
    required int sessionsPaidTotal,
    required int sessionsPresent,
    required int remindBeforeSession,
    required int expiresAt,
  }) {
    if (sessionsPaidTotal <= 0) return 'No session package';
    if (expiresAt > 0 && DateTime.now().millisecondsSinceEpoch >= expiresAt) {
      return 'Expired';
    }
    if (isPaymentDueBySessions(
      sessionsPaidTotal: sessionsPaidTotal,
      sessionsPresent: sessionsPresent,
    )) {
      return 'Due now';
    }
    if (expiresAt > 0 && _isNearExpiryMs(expiresAt, days: 10)) {
      return 'Near expiry';
    }
    if (isPaymentWarningBySessions(
      sessionsPaidTotal: sessionsPaidTotal,
      sessionsPresent: sessionsPresent,
      remindBeforeSession: _effectiveFlexReminder(
        sessionsPaidTotal: sessionsPaidTotal,
        remindBeforeSession: remindBeforeSession,
      ),
    )) {
      return 'Due soon';
    }
    return 'OK';
  }

  Color _flexStatusColor(String status) {
    switch (status) {
      case 'Due now':
      case 'Expired':
        return Colors.red.shade700;
      case 'Due soon':
      case 'Near expiry':
        return Colors.orange.shade700;
      case 'No session package':
        return Colors.blueGrey.shade700;
      default:
        return Colors.green.shade700;
    }
  }

  String _flexSummaryKey(_FlexCourseSummary item) {
    return '${item.uid}|${item.courseKey}|${item.courseId}';
  }

  Future<List<Map<String, dynamic>>> _loadPaymentsForUidCached(
    String uid,
  ) async {
    final cached = _paymentsByUidCache[uid];
    if (cached != null) return cached;

    final list = <Map<String, dynamic>>[];
    try {
      final snap = await _db
          .child('payments')
          .orderByChild('uid')
          .equalTo(uid)
          .get();
      if (snap.exists && snap.value is Map) {
        final raw = Map<dynamic, dynamic>.from(snap.value as Map);
        for (final entry in raw.entries) {
          if (entry.value is! Map) continue;
          final m = Map<String, dynamic>.from(entry.value as Map);
          m['paymentId'] = entry.key.toString();
          list.add(m);
        }
      }
    } catch (_) {}

    if (list.isEmpty) {
      try {
        final allSnap = await _db.child('payments').get();
        if (allSnap.exists && allSnap.value is Map) {
          final raw = Map<dynamic, dynamic>.from(allSnap.value as Map);
          for (final entry in raw.entries) {
            final v = entry.value;
            if (v is! Map) continue;
            final m = Map<String, dynamic>.from(v);
            final payUid = (m['uid'] ?? '').toString().trim();
            if (payUid == uid) {
              m['paymentId'] = entry.key.toString();
              list.add(m);
            }
          }
        }
      } catch (_) {}
    }

    _paymentsByUidCache[uid] = list;
    return list;
  }

  int _latestFlexibleExpiryFromPayments({
    required List<Map<String, dynamic>> payments,
    required String courseKey,
    required String courseId,
    required String courseTitle,
    required String courseCode,
  }) {
    String norm(String s) => s.trim().toLowerCase();
    final wantedKey = norm(courseKey);
    final wantedId = norm(courseId);

    int ymdToMs(String ymd) {
      final t = ymd.trim();
      if (t.isEmpty) return 0;
      final parts = t.split('-');
      if (parts.length != 3) return 0;
      final y = int.tryParse(parts[0]);
      final m = int.tryParse(parts[1]);
      final d = int.tryParse(parts[2]);
      if (y == null || m == null || d == null) return 0;
      return DateTime(y, m, d).millisecondsSinceEpoch;
    }

    int addMonthsToMs(int baseMs, int months) {
      if (baseMs <= 0 || months <= 0) return 0;
      final d = DateTime.fromMillisecondsSinceEpoch(baseMs);
      return DateTime(d.year, d.month + months, d.day).millisecondsSinceEpoch;
    }

    var latestStamp = 0;
    var latestExpiresAt = 0;
    for (final p in payments) {
      final payVariant = _normalizeVariantKey(
        (p['variantKey'] ?? p['variant'] ?? '').toString(),
      );
      if (payVariant != 'flexible') continue;

      final payCourseKey = (p['courseKey'] ?? '').toString().trim();
      final payCourseId = (p['course_id'] ?? p['courseId'] ?? '')
          .toString()
          .trim();
      final keyMatch = wantedKey.isNotEmpty && norm(payCourseKey) == wantedKey;
      final idMatch = wantedId.isNotEmpty && norm(payCourseId) == wantedId;

      if (!(keyMatch || idMatch)) continue;

      final paidAt = _asInt(p['paidAt']);
      final startDate = (p['startDate'] ?? '').toString();
      final expiryMonths = _asInt(p['expiryMonths']);

      var expiresAt = _asInt(p['expiresAt']);
      if (expiresAt <= 0 && startDate.trim().isNotEmpty && expiryMonths > 0) {
        final baseMs = ymdToMs(startDate);
        expiresAt = addMonthsToMs(baseMs, expiryMonths);
      }
      if (expiresAt <= 0) continue;

      final stamp = paidAt > 0 ? paidAt : _asInt(p['createdAt']);
      if (stamp >= latestStamp) {
        latestStamp = stamp;
        latestExpiresAt = expiresAt;
      }
    }

    return latestExpiresAt;
  }

  bool _paymentMatchesFlexible({
    required Map<String, dynamic> payment,
    required _FlexCourseSummary item,
  }) {
    final payVariant = _normalizeVariantKey(
      (payment['variantKey'] ?? payment['variant'] ?? '').toString(),
    );
    if (payVariant != 'flexible') return false;

    final payCourseKey = (payment['courseKey'] ?? '').toString().trim();
    final payCourseId = (payment['course_id'] ?? payment['courseId'] ?? '')
        .toString()
        .trim();
    return (payCourseKey.isNotEmpty && payCourseKey == item.courseKey) ||
        (payCourseId.isNotEmpty && payCourseId == item.courseId);
  }

  Future<_FlexCourseDetails> _loadFlexCourseDetails(
    _FlexCourseSummary item,
  ) async {
    final syllabusBySession = await _loadFlexibleSyllabusSessions(
      item.courseId,
    );
    final syllabusTitleBySession = <int, String>{};
    for (final e in syllabusBySession.entries) {
      final title = (e.value['sessionTitle'] ?? e.value['title'] ?? '')
          .toString();
      if (title.trim().isNotEmpty) {
        syllabusTitleBySession[e.key] = title.trim();
      }
    }

    final learnerReviewBySessionNo = <int, int>{};
    try {
      final reviewSnap = await _db
          .child(
            'booking_progress/${item.uid}/${item.courseId}/session_reviews',
          )
          .get();
      if (reviewSnap.exists && reviewSnap.value is Map) {
        final reviews = Map<dynamic, dynamic>.from(reviewSnap.value as Map);
        for (final entry in reviews.entries) {
          if (entry.value is! Map) continue;
          final rm = Map<String, dynamic>.from(entry.value as Map);
          var sessionNo = _asInt(rm['sessionNo']);
          if (sessionNo <= 0) {
            sessionNo = _asInt(entry.key);
          }
          if (sessionNo <= 0) continue;
          final rating = _asInt(rm['rating']);
          if (rating >= 1 && rating <= 5) {
            learnerReviewBySessionNo[sessionNo] = rating;
          }
        }
      }
    } catch (_) {}

    final rows = <_FlexAttendanceRow>[];
    try {
      final progressSnap = await _db
          .child(
            'booking_progress/${item.uid}/${item.courseId}/online_attendance',
          )
          .get();
      if (progressSnap.exists && progressSnap.value is Map) {
        final att = Map<dynamic, dynamic>.from(progressSnap.value as Map);
        att.forEach((key, value) {
          if (value is! Map) return;
          final m = Map<String, dynamic>.from(value);
          final isPresent = m['present'] == true;

          final tsRaw = m['startAt'] ?? m['updatedAt'] ?? m['createdAt'];
          int ts = 0;
          if (tsRaw is int) {
            ts = tsRaw;
          } else if (tsRaw is num) {
            ts = tsRaw.toInt();
          } else {
            ts = int.tryParse(tsRaw?.toString() ?? '') ?? 0;
          }

          final sessionNo = _asInt(m['sessionNo']);
          final teacherRating = _asInt(m['teacherRating']);
          final teacherComment = (m['teacherComment'] ?? '').toString().trim();
          String taughtTitle = '';
          final taughtItems = m['taughtItems'];
          if (taughtItems is List) {
            for (final itemRaw in taughtItems) {
              if (itemRaw is! Map) continue;
              final tm = Map<String, dynamic>.from(itemRaw);
              final taughtNo = _asInt(tm['sessionNumber']);
              if (sessionNo > 0 && taughtNo > 0 && taughtNo != sessionNo) {
                continue;
              }
              final title = (tm['title'] ?? '').toString().trim();
              if (title.isNotEmpty) {
                taughtTitle = title;
                break;
              }
            }
          }

          rows.add(
            _FlexAttendanceRow(
              bookingKey: key.toString(),
              present: isPresent,
              sessionNo: sessionNo,
              dayKey: (m['dayKey'] ?? '').toString().trim(),
              time: (m['time'] ?? '').toString().trim(),
              startAt: ts,
              teacherName:
                  (m['teacherName'] ?? m['teacherNameFromBooking'] ?? 'Teacher')
                      .toString()
                      .trim(),
              lessonTitle: syllabusTitleBySession[sessionNo] ?? taughtTitle,
              taughtTitle: taughtTitle,
              learnerReviewRating: isPresent
                  ? (learnerReviewBySessionNo[sessionNo] ?? 0)
                  : 0,
              teacherReviewRating: teacherRating >= 1 && teacherRating <= 5
                  ? teacherRating
                  : 0,
              teacherComment: teacherComment,
            ),
          );
        });
      }
    } catch (_) {}

    rows.sort((a, b) => b.sortTs.compareTo(a.sortTs));
    final presentRows = rows.where((row) => row.present).toList();

    final paymentsForUser = await _loadPaymentsForUidCached(item.uid);
    final matchedPayments =
        paymentsForUser
            .where((p) => _paymentMatchesFlexible(payment: p, item: item))
            .toList()
          ..sort((a, b) {
            final ta = _asInt(a['paidAt']) > 0
                ? _asInt(a['paidAt'])
                : _asInt(a['createdAt']);
            final tb = _asInt(b['paidAt']) > 0
                ? _asInt(b['paidAt'])
                : _asInt(b['createdAt']);
            return ta.compareTo(tb);
          });

    final attendanceAsc = [...presentRows]
      ..sort((a, b) => a.sortTs.compareTo(b.sortTs));
    int ptr = 0;
    final paymentBlocks = <_FlexPaymentBlock>[];
    for (final p in matchedPayments) {
      final sessionsPaid = _asInt(p['sessionsPaid']);
      final amount = _asInt(p['amount']);
      final paidAt = _asInt(p['paidAt']) > 0
          ? _asInt(p['paidAt'])
          : _asInt(p['createdAt']);
      final expiresAtPay = _asInt(p['expiresAt']);
      final expiryMonthsPay = _asInt(p['expiryMonths']);

      final allocated = <_FlexAttendanceRow>[];
      var quota = sessionsPaid > 0 ? sessionsPaid : 0;
      while (ptr < attendanceAsc.length && quota > 0) {
        allocated.add(attendanceAsc[ptr]);
        ptr += 1;
        quota -= 1;
      }

      paymentBlocks.add(
        _FlexPaymentBlock(
          paymentId: (p['paymentId'] ?? '').toString(),
          paidAt: paidAt,
          amount: amount,
          sessionsPaid: sessionsPaid,
          expiresAt: expiresAtPay,
          expiryMonths: expiryMonthsPay,
          rows: allocated,
        ),
      );
    }

    if (ptr < attendanceAsc.length) {
      final unallocated = attendanceAsc.sublist(ptr);
      if (paymentBlocks.isNotEmpty) {
        final last = paymentBlocks.removeLast();
        paymentBlocks.add(
          _FlexPaymentBlock(
            paymentId: last.paymentId,
            paidAt: last.paidAt,
            amount: last.amount,
            sessionsPaid: last.sessionsPaid,
            expiresAt: last.expiresAt,
            expiryMonths: last.expiryMonths,
            rows: [...last.rows, ...unallocated],
          ),
        );
      } else {
        paymentBlocks.add(
          _FlexPaymentBlock(
            paymentId: '',
            paidAt: 0,
            amount: 0,
            sessionsPaid: 0,
            expiresAt: item.expiresAt,
            expiryMonths: 0,
            rows: unallocated,
          ),
        );
      }
    }

    return _FlexCourseDetails(rows: rows, paymentBlocks: paymentBlocks);
  }

  Future<_FlexCourseDetails> _flexDetailsFor(_FlexCourseSummary item) {
    final key = _flexSummaryKey(item);
    return _flexDetailsFutureByKey.putIfAbsent(
      key,
      () => _loadFlexCourseDetails(item),
    );
  }

  Future<List<_FlexCourseSummary>> _loadFlexibleAttendanceSummaries() async {
    final usersSnap = await _usersRef.get();
    if (!usersSnap.exists || usersSnap.value is! Map) return const [];

    final courseTitleById = <String, String>{};
    for (final c in _courses) {
      final cid = (c['id'] ?? '').toString().trim();
      if (cid.isEmpty) continue;
      courseTitleById[cid] = (c['title'] ?? '').toString().trim();
    }

    final allUsers = Map<dynamic, dynamic>.from(usersSnap.value as Map);
    final out = <_FlexCourseSummary>[];

    for (final userEntry in allUsers.entries) {
      final uid = userEntry.key.toString();
      final raw = userEntry.value;
      if (raw is! Map) continue;

      final user = Map<String, dynamic>.from(raw);
      if (!_isLearnerRole(user['role'])) continue;

      final first = (user['first_name'] ?? '').toString().trim();
      final last = (user['last_name'] ?? '').toString().trim();
      final fullName = '$first $last'.trim().isEmpty
          ? 'Learner'
          : '$first $last'.trim();
      final courses = (user['courses'] is Map)
          ? Map<dynamic, dynamic>.from(user['courses'])
          : <dynamic, dynamic>{};

      for (final cEntry in courses.entries) {
        final courseKey = cEntry.key.toString();
        final cRaw = cEntry.value;
        if (cRaw is! Map) continue;

        final cm = Map<String, dynamic>.from(cRaw);
        final variantKey = _normalizeVariantKey(
          (cm['variantKey'] ?? cm['variant'] ?? '').toString(),
        );
        if (variantKey != 'flexible') continue;

        final courseId = (cm['id'] ?? cm['courseId'] ?? cm['course_id'] ?? '')
            .toString()
            .trim();
        if (courseId.isEmpty) continue;

        final courseTitleRaw = (cm['title'] ?? '').toString().trim();
        final courseCodeRaw = (cm['course_code'] ?? '').toString().trim();
        final mappedTitle = (courseTitleById[courseId] ?? '').trim();
        final courseTitle = courseTitleRaw.isNotEmpty
            ? courseTitleRaw
            : (mappedTitle.isNotEmpty ? mappedTitle : 'Unknown course');

        final syllabusBySession = await _loadFlexibleSyllabusSessions(courseId);
        int syllabusSessionsTotal = await _loadSyllabusSessionCount(
          courseId: courseId,
          syllabusVariant: 'flexible',
        );
        if (syllabusSessionsTotal <= 0) {
          syllabusSessionsTotal = syllabusBySession.length;
        }

        var consumed = 0;
        var latestTs = 0;
        final coveredNos = <int>{};
        try {
          final progressSnap = await _db
              .child('booking_progress/$uid/$courseId/online_attendance')
              .get();
          if (progressSnap.exists && progressSnap.value is Map) {
            final att = Map<dynamic, dynamic>.from(progressSnap.value as Map);
            for (final value in att.values) {
              if (value is! Map) continue;
              final m = Map<String, dynamic>.from(value);
              if (m['present'] != true) continue;
              consumed += 1;
              final sessionNo = _asInt(m['sessionNo']);
              if (sessionNo > 0) coveredNos.add(sessionNo);
              final ts = _asInt(m['startAt']) > 0
                  ? _asInt(m['startAt'])
                  : (_asInt(m['updatedAt']) > 0
                        ? _asInt(m['updatedAt'])
                        : _asInt(m['createdAt']));
              if (ts > latestTs) latestTs = ts;
            }
          }
        } catch (_) {}

        final summaryMap = (cm['payment_summary'] is Map)
            ? Map<String, dynamic>.from(cm['payment_summary'])
            : <String, dynamic>{};
        final isFreeCourse = courseIsFreeBilling(cm, summaryMap);
        final sessionsPaidTotal = _asInt(summaryMap['sessionsPaidTotal']);
        final remindBeforeSession = _asInt(summaryMap['remindBeforeSession']);

        final accessMap = (cm['flexible_access'] is Map)
            ? Map<String, dynamic>.from(cm['flexible_access'])
            : <String, dynamic>{};
        int expiresAt = _asInt(accessMap['expiresAt']);
        if (expiresAt <= 0) {
          final sumMap = (cm['payment_summary'] is Map)
              ? Map<String, dynamic>.from(cm['payment_summary'])
              : <String, dynamic>{};
          expiresAt = _asInt(sumMap['expiresAt']);
        }
        if (expiresAt <= 0) {
          final payments = await _loadPaymentsForUidCached(uid);
          expiresAt = _latestFlexibleExpiryFromPayments(
            payments: payments,
            courseKey: courseKey,
            courseId: courseId,
            courseTitle: courseTitle,
            courseCode: courseCodeRaw,
          );
        }

        final coveredSessionNumbers = coveredNos.length;

        final statusLabel = _flexPaymentStatusLabel(
          sessionsPaidTotal: sessionsPaidTotal,
          sessionsPresent: consumed,
          remindBeforeSession: remindBeforeSession,
          expiresAt: expiresAt,
        );

        out.add(
          _FlexCourseSummary(
            uid: uid,
            learnerName: fullName,
            learnerSerial: '',
            assignedCourses: const <String>[],
            courseKey: courseKey,
            courseId: courseId,
            courseTitle: courseTitle,
            courseCode: courseCodeRaw,
            sessionsPaidTotal: sessionsPaidTotal,
            consumed: consumed,
            coveredSessionNumbers: coveredSessionNumbers,
            syllabusSessionsTotal: syllabusSessionsTotal,
            expiresAt: expiresAt,
            statusLabel: statusLabel,
            rows: const <_FlexAttendanceRow>[],
            paymentBlocks: const <_FlexPaymentBlock>[],
            latestTs: latestTs,
            isFree: isFreeCourse,
          ),
        );
      }
    }

    out.sort((a, b) {
      final ta = a.latestTs;
      final tb = b.latestTs;
      if (ta != tb) return tb.compareTo(ta);
      return a.learnerName.compareTo(b.learnerName);
    });

    return out;
  }

  Future<Map<String, _RecordedSessionMeta>> _loadRecordedSessionMeta(
    String courseId,
  ) async {
    final cid = courseId.trim();
    if (cid.isEmpty) return const <String, _RecordedSessionMeta>{};

    final cached = _recordedSessionMetaCache[cid];
    if (cached != null) return cached;

    final out = <String, _RecordedSessionMeta>{};
    try {
      final snap = await _syllabiRef.child(cid).child('recorded').get();
      if (snap.exists && snap.value is Map) {
        final root = Map<dynamic, dynamic>.from(snap.value as Map);

        void addSession(dynamic raw) {
          if (raw is! Map) return;
          final m = Map<String, dynamic>.from(raw);
          final sessionId = (m['id'] ?? '').toString().trim();
          if (sessionId.isEmpty) return;
          final hasVideo = (m['videoUrl'] ?? '').toString().trim().isNotEmpty;
          final hasMaterials = (m['materialsUrl'] ?? '')
              .toString()
              .trim()
              .isNotEmpty;
          out[sessionId] = _RecordedSessionMeta(
            hasVideo: hasVideo,
            hasMaterials: hasMaterials,
          );
        }

        final modulesRaw = root['modules'];
        if (modulesRaw is List) {
          for (final module in modulesRaw) {
            if (module is! Map) continue;
            final moduleMap = Map<dynamic, dynamic>.from(module);
            final unitsRaw = moduleMap['units'];
            if (unitsRaw is! List) continue;
            for (final unit in unitsRaw) {
              if (unit is! Map) continue;
              final unitMap = Map<dynamic, dynamic>.from(unit);
              final lessonsRaw = unitMap['lessons'];
              if (lessonsRaw is! List) continue;
              for (final lesson in lessonsRaw) {
                addSession(lesson);
              }
            }
          }
        } else {
          final unitsRaw = root['units'];
          if (unitsRaw is List) {
            for (final unit in unitsRaw) {
              if (unit is! Map) continue;
              final unitMap = Map<dynamic, dynamic>.from(unit);
              final sessionsRaw = unitMap['sessions'];
              if (sessionsRaw is! List) continue;
              for (final session in sessionsRaw) {
                addSession(session);
              }
            }
          }
        }
      }
    } catch (_) {}

    _recordedSessionMetaCache[cid] = out;
    return out;
  }

  Future<List<_RecordedCourseSummary>> _loadRecordedProgressSummaries() async {
    final usersSnap = await _usersRef.get();
    if (!usersSnap.exists || usersSnap.value is! Map) return const [];

    final courseTitleById = <String, String>{};
    for (final c in _courses) {
      final cid = (c['id'] ?? '').toString().trim();
      if (cid.isEmpty) continue;
      final title = (c['title'] ?? '').toString().trim();
      if (title.isNotEmpty) {
        courseTitleById[cid] = title;
      }
    }

    final usersMap = Map<dynamic, dynamic>.from(usersSnap.value as Map);
    final out = <_RecordedCourseSummary>[];

    for (final userEntry in usersMap.entries) {
      final uid = userEntry.key.toString().trim();
      if (uid.isEmpty) continue;
      if (userEntry.value is! Map) continue;

      final user = Map<String, dynamic>.from(userEntry.value as Map);
      if (!_isLearnerRole(user['role'])) continue;

      final first = (user['first_name'] ?? '').toString().trim();
      final last = (user['last_name'] ?? '').toString().trim();
      final fullName = '$first $last'.trim();
      final email = (user['email'] ?? '').toString().trim();
      final learnerName = fullName.isNotEmpty
          ? fullName
          : (email.isNotEmpty ? email : 'Learner');

      final coursesRaw = user['courses'];
      if (coursesRaw is! Map) continue;
      final courses = Map<dynamic, dynamic>.from(coursesRaw);

      for (final cEntry in courses.entries) {
        final courseKey = cEntry.key.toString().trim();
        if (courseKey.isEmpty || cEntry.value is! Map) continue;

        final courseNode = Map<String, dynamic>.from(cEntry.value as Map);
        final variantKey = _normalizeVariantKey(
          (courseNode['variantKey'] ?? courseNode['variant'] ?? '').toString(),
        );
        if (variantKey != 'recorded') continue;

        final courseId =
            (courseNode['id'] ??
                    courseNode['courseId'] ??
                    courseNode['course_id'] ??
                    '')
                .toString()
                .trim();
        if (courseId.isEmpty) continue;

        final titleRaw = (courseNode['title'] ?? '').toString().trim();
        final courseTitle = titleRaw.isNotEmpty
            ? titleRaw
            : (courseTitleById[courseId] ?? 'Unknown course');
        final summaryMap = (courseNode['payment_summary'] is Map)
            ? Map<String, dynamic>.from(courseNode['payment_summary'])
            : <String, dynamic>{};
        final isFreeCourse = courseIsFreeBilling(courseNode, summaryMap);
        final accessMap = (courseNode['recorded_access'] is Map)
            ? Map<String, dynamic>.from(courseNode['recorded_access'])
            : <String, dynamic>{};

        final expiresAt = _asInt(accessMap['expiresAt']) > 0
            ? _asInt(accessMap['expiresAt'])
            : _asInt(summaryMap['expiresAt']);
        final durationMonths = _asInt(accessMap['durationMonths']) > 0
            ? _asInt(accessMap['durationMonths'])
            : _asInt(summaryMap['durationMonths']);
        final lastPaymentAt = _asInt(summaryMap['lastPaymentAt']);

        final progressRaw = courseNode['recorded_progress'];
        final recordedProgress = progressRaw is Map
            ? progressRaw.map((k, v) => MapEntry(k.toString(), v))
            : <String, dynamic>{};

        final sessionMeta = await _loadRecordedSessionMeta(courseId);

        int totalSessions = sessionMeta.length;
        int completedSessions = 0;

        if (sessionMeta.isNotEmpty) {
          for (final sessionEntry in sessionMeta.entries) {
            final progressAny = recordedProgress[sessionEntry.key];
            if (progressAny is! Map) continue;
            final progress = progressAny.map((k, v) => MapEntry('$k', v));

            final videoDone = _asBool(progress['videoCompleted']);
            final materialsDone = _asBool(progress['materialsCompleted']);

            final hasVideo = sessionEntry.value.hasVideo;
            final hasMaterials = sessionEntry.value.hasMaterials;

            bool done = false;
            if (hasVideo && hasMaterials) {
              done = videoDone || materialsDone;
            } else if (hasVideo) {
              done = videoDone;
            } else if (hasMaterials) {
              done = materialsDone;
            }
            if (done) completedSessions += 1;
          }
        } else if (recordedProgress.isNotEmpty) {
          totalSessions = recordedProgress.length;
          for (final value in recordedProgress.values) {
            if (value is! Map) continue;
            final progress = value.map((k, v) => MapEntry('$k', v));
            if (_asBool(progress['videoCompleted']) ||
                _asBool(progress['materialsCompleted'])) {
              completedSessions += 1;
            }
          }
        }

        final progressPct = totalSessions > 0
            ? ((completedSessions / totalSessions) * 100).round().clamp(0, 100)
            : 0;

        out.add(
          _RecordedCourseSummary(
            uid: uid,
            learnerName: learnerName,
            courseKey: courseKey,
            courseId: courseId,
            courseTitle: courseTitle,
            completedSessions: completedSessions,
            totalSessions: totalSessions,
            progressPct: progressPct,
            expiresAt: expiresAt,
            durationMonths: durationMonths,
            lastPaymentAt: lastPaymentAt,
            isFree: isFreeCourse,
          ),
        );
      }
    }

    out.sort((a, b) {
      final n = a.learnerName.toLowerCase().compareTo(
        b.learnerName.toLowerCase(),
      );
      if (n != 0) return n;
      return a.courseTitle.toLowerCase().compareTo(b.courseTitle.toLowerCase());
    });
    return out;
  }

  _FlexCourseSummary _summaryWithDetails({
    required _FlexCourseSummary item,
    required _FlexCourseDetails details,
  }) {
    return _FlexCourseSummary(
      uid: item.uid,
      learnerName: item.learnerName,
      learnerSerial: item.learnerSerial,
      assignedCourses: item.assignedCourses,
      courseKey: item.courseKey,
      courseId: item.courseId,
      courseTitle: item.courseTitle,
      courseCode: item.courseCode,
      sessionsPaidTotal: item.sessionsPaidTotal,
      consumed: item.consumed,
      coveredSessionNumbers: item.coveredSessionNumbers,
      syllabusSessionsTotal: item.syllabusSessionsTotal,
      expiresAt: item.expiresAt,
      statusLabel: item.statusLabel,
      rows: details.rows,
      paymentBlocks: details.paymentBlocks,
      latestTs: item.latestTs,
      isFree: item.isFree,
    );
  }

  double _recordedPaymentProgress(_RecordedCourseSummary item) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final end = item.expiresAt;
    if (end <= 0) return 0;

    var start = item.lastPaymentAt;
    if (start <= 0 && item.durationMonths > 0) {
      final e = DateTime.fromMillisecondsSinceEpoch(end);
      start = DateTime(
        e.year,
        e.month - item.durationMonths,
        e.day,
      ).millisecondsSinceEpoch;
    }

    if (start <= 0) return now >= end ? 1 : 0;
    final span = end - start;
    if (span <= 0) return now >= end ? 1 : 0;

    final progress = (now - start) / span;
    return progress.clamp(0.0, 1.0);
  }

  Widget _buildFlexibleAttendanceTab(Map<String, int> unreadByLearner) {
    return FutureBuilder<List<_FlexCourseSummary>>(
      future: _loadFlexibleAttendanceSummaries(),
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(
            child: Text(
              'Could not load flexible attendance.',
              style: TextStyle(
                color: Colors.red.shade700,
                fontWeight: FontWeight.w800,
              ),
            ),
          );
        }
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final all = snap.data ?? const <_FlexCourseSummary>[];
        _queueFlexBadgeUidSync(all);
        final shown = all.where((item) {
          final statusOk =
              _flexStatusFilter == 'all' ||
              item.statusLabel.toLowerCase() == _flexStatusFilter;
          if (!statusOk) return false;

          if (_flexUnreadOnly) {
            final unread = unreadByLearner[item.uid.trim()] ?? 0;
            if (unread <= 0) return false;
          }

          if (_searchQuery.isEmpty) return true;
          final q = _searchQuery;
          final learner = _normalizeSearchText(item.learnerName);
          return learner.contains(q);
        }).toList();

        final consumedCount = shown.fold<int>(
          0,
          (sum, item) => sum + item.consumed,
        );

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final item in const <String>[
                    'all',
                    'due now',
                    'due soon',
                    'near expiry',
                    'expired',
                    'no session package',
                  ]) ...[
                    ChoiceChip(
                      label: Text(
                        item == 'all'
                            ? 'All'
                            : item[0].toUpperCase() + item.substring(1),
                      ),
                      selected: _flexStatusFilter == item,
                      onSelected: (_) {
                        setState(() => _flexStatusFilter = item);
                      },
                    ),
                    const SizedBox(width: 8),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                ChoiceChip(
                  label: const Text('All learners'),
                  selected: !_flexUnreadOnly,
                  onSelected: (_) {
                    if (_flexUnreadOnly) {
                      setState(() => _flexUnreadOnly = false);
                    }
                  },
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('Unread only'),
                  selected: _flexUnreadOnly,
                  onSelected: (_) {
                    if (!_flexUnreadOnly) {
                      setState(() => _flexUnreadOnly = true);
                    }
                  },
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Showing ${shown.length} learner-course items • $consumedCount consumed sessions',
                    style: TextStyle(
                      color: Colors.grey.shade700,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Refresh flexible',
                  onPressed: () {
                    setState(() {
                      _paymentsByUidCache.clear();
                      _flexDetailsFutureByKey.clear();
                    });
                  },
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Expanded(
              child: shown.isEmpty
                  ? const Center(child: Text('No flexible attendance found.'))
                  : ListView.separated(
                      itemCount: shown.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, i) {
                        final item = shown[i];
                        final progressValue = item.syllabusSessionsTotal > 0
                            ? (item.coveredSessionNumbers /
                                      item.syllabusSessionsTotal)
                                  .clamp(0.0, 1.0)
                            : 0.0;
                        final paymentValue = item.sessionsPaidTotal > 0
                            ? (item.consumed / item.sessionsPaidTotal).clamp(
                                0.0,
                                1.0,
                              )
                            : 0.0;
                        final isExpired =
                            item.expiresAt > 0 &&
                            DateTime.now().millisecondsSinceEpoch >=
                                item.expiresAt;
                        final nearExpiry =
                            !isExpired &&
                            _isNearExpiryMs(item.expiresAt, days: 7);
                        final nearFinish = progressValue >= 0.85;
                        final key = _flexSummaryKey(item);
                        final expanded = _expandedFlexKeys.contains(key);
                        final unreadCount =
                            unreadByLearner[item.uid.trim()] ?? 0;

                        return Card(
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                            side: BorderSide(
                              color: Colors.grey.withValues(alpha: 0.25),
                            ),
                          ),
                          child: ExpansionTile(
                            key: ValueKey(key),
                            tilePadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 4,
                            ),
                            childrenPadding: const EdgeInsets.fromLTRB(
                              12,
                              0,
                              12,
                              12,
                            ),
                            initiallyExpanded: expanded,
                            onExpansionChanged: (value) {
                              setState(() {
                                if (value) {
                                  _expandedFlexKeys.add(key);
                                } else {
                                  _expandedFlexKeys.remove(key);
                                }
                              });
                            },
                            title: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        item.learnerName,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w900,
                                          color: Color(0xFF1A2B48),
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    _learnerQuickActionsBadge(
                                      uid: item.uid,
                                      learnerName: item.learnerName,
                                      unreadCount: unreadCount,
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'Course: ${item.courseTitle}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Colors.grey.shade800,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                if (item.isFree) ...[
                                  const SizedBox(height: 8),
                                  _smallCue('Free', Colors.green.shade700),
                                ],
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 4,
                                      ),
                                      decoration: BoxDecoration(
                                        color: _flexStatusColor(
                                          item.statusLabel,
                                        ).withValues(alpha: 0.14),
                                        borderRadius: BorderRadius.circular(
                                          999,
                                        ),
                                        border: Border.all(
                                          color: _flexStatusColor(
                                            item.statusLabel,
                                          ).withValues(alpha: 0.35),
                                        ),
                                      ),
                                      child: Text(
                                        item.statusLabel,
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: _flexStatusColor(
                                            item.statusLabel,
                                          ),
                                          fontWeight: FontWeight.w900,
                                        ),
                                      ),
                                    ),
                                    if (nearExpiry)
                                      _smallCue(
                                        'Expiry soon',
                                        Colors.orange.shade700,
                                      ),
                                    if (isExpired)
                                      _smallCue('Expired', Colors.red.shade700),
                                    if (nearFinish)
                                      _smallCue(
                                        'Near finish',
                                        const Color(0xFFD97706),
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  item.syllabusSessionsTotal > 0
                                      ? 'Course progress: ${item.coveredSessionNumbers} / ${item.syllabusSessionsTotal}'
                                      : 'Course progress: -',
                                  style: TextStyle(
                                    color: Colors.grey.shade800,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 12,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(999),
                                  child: LinearProgressIndicator(
                                    value: progressValue,
                                    minHeight: 9,
                                    backgroundColor: const Color(0xFFE5E7EB),
                                    valueColor:
                                        const AlwaysStoppedAnimation<Color>(
                                          Color(0xFF2563EB),
                                        ),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                if (!item.isFree) ...[
                                  Text(
                                    item.sessionsPaidTotal > 0
                                        ? 'Payment progress: ${item.consumed} / ${item.sessionsPaidTotal}'
                                        : 'Payment progress: no package total',
                                    style: TextStyle(
                                      color: Colors.grey.shade800,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 12,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(999),
                                    child: LinearProgressIndicator(
                                      value: paymentValue,
                                      minHeight: 9,
                                      backgroundColor: const Color(0xFFE5E7EB),
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                        _flexStatusColor(item.statusLabel),
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            children: [
                              if (expanded)
                                FutureBuilder<_FlexCourseDetails>(
                                  future: _flexDetailsFor(item),
                                  builder: (context, detailSnap) {
                                    if (!detailSnap.hasData) {
                                      return const Padding(
                                        padding: EdgeInsets.symmetric(
                                          vertical: 8,
                                        ),
                                        child: LinearProgressIndicator(
                                          minHeight: 2,
                                        ),
                                      );
                                    }

                                    final detailed = _summaryWithDetails(
                                      item: item,
                                      details: detailSnap.data!,
                                    );

                                    return Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const SizedBox(height: 6),
                                        Text(
                                          'Deadline: ${_fmtDateOnlyMs(item.expiresAt)}',
                                          style: TextStyle(
                                            color: Colors.grey.shade800,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        const SizedBox(height: 10),
                                        _FlexLearnerDetailsTabs(
                                          item: detailed,
                                          fmtDateOnlyMs: _fmtDateOnlyMs,
                                          onOpenSessionDetails: (row) {
                                            return _openFlexibleSessionDetailsSheet(
                                              courseId: item.courseId,
                                              row: row,
                                            );
                                          },
                                        ),
                                      ],
                                    );
                                  },
                                ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _smallCue(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w900,
          color: color,
        ),
      ),
    );
  }

  Widget _buildRecordedProgressTab(Map<String, int> unreadByLearner) {
    return FutureBuilder<List<_RecordedCourseSummary>>(
      future: _loadRecordedProgressSummaries(),
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(
            child: Text(
              'Could not load recorded progress.',
              style: TextStyle(
                color: Colors.red.shade700,
                fontWeight: FontWeight.w800,
              ),
            ),
          );
        }
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final rows = snap.data ?? const <_RecordedCourseSummary>[];
        _queueRecordedBadgeUidSync(rows);
        final filteredBySearch = _searchQuery.isEmpty
            ? rows
            : rows
                  .where(
                    (item) => _normalizeSearchText(
                      item.learnerName,
                    ).contains(_searchQuery),
                  )
                  .toList();
        final shown = _recordedUnreadOnly
            ? filteredBySearch
                  .where((item) => (unreadByLearner[item.uid.trim()] ?? 0) > 0)
                  .toList()
            : filteredBySearch;
        final totalCompleted = shown.fold<int>(
          0,
          (sum, item) => sum + item.completedSessions,
        );
        final totalSessions = shown.fold<int>(
          0,
          (sum, item) => sum + item.totalSessions,
        );

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Showing ${shown.length} recorded learner-course items • $totalCompleted / $totalSessions sessions completed',
                    style: TextStyle(
                      color: Colors.grey.shade700,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Refresh recorded progress',
                  onPressed: () => setState(() {}),
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                ChoiceChip(
                  label: const Text('All learners'),
                  selected: !_recordedUnreadOnly,
                  onSelected: (_) {
                    if (_recordedUnreadOnly) {
                      setState(() => _recordedUnreadOnly = false);
                    }
                  },
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('Unread only'),
                  selected: _recordedUnreadOnly,
                  onSelected: (_) {
                    if (!_recordedUnreadOnly) {
                      setState(() => _recordedUnreadOnly = true);
                    }
                  },
                ),
              ],
            ),
            const SizedBox(height: 10),
            Expanded(
              child: shown.isEmpty
                  ? const Center(child: Text('No recorded progress found.'))
                  : ListView.separated(
                      itemCount: shown.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, i) {
                        final item = shown[i];
                        final progressValue = item.totalSessions > 0
                            ? (item.completedSessions / item.totalSessions)
                                  .clamp(0.0, 1.0)
                            : 0.0;
                        final paymentValue = _recordedPaymentProgress(item);
                        final expired =
                            item.expiresAt > 0 &&
                            DateTime.now().millisecondsSinceEpoch >=
                                item.expiresAt;
                        final nearExpiry =
                            !expired &&
                            _isNearExpiryMs(item.expiresAt, days: 7);
                        final nearFinish = progressValue >= 0.85;
                        final almostFinish = progressValue >= 0.95;
                        final courseColor = almostFinish
                            ? const Color(0xFF16A34A)
                            : (nearFinish
                                  ? const Color(0xFFD97706)
                                  : const Color(0xFF2563EB));
                        final paymentColor = expired
                            ? Colors.red.shade700
                            : (nearExpiry
                                  ? Colors.orange.shade700
                                  : const Color(0xFF0EA5E9));
                        final unreadCount =
                            unreadByLearner[item.uid.trim()] ?? 0;

                        return Card(
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                            side: BorderSide(
                              color: Colors.grey.withValues(alpha: 0.25),
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        item.learnerName,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w900,
                                          color: Color(0xFF1A2B48),
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    _learnerQuickActionsBadge(
                                      uid: item.uid,
                                      learnerName: item.learnerName,
                                      unreadCount: unreadCount,
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'Course: ${item.courseTitle}',
                                  style: TextStyle(
                                    color: Colors.grey.shade800,
                                    fontWeight: FontWeight.w700,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                if (item.isFree) ...[
                                  const SizedBox(height: 8),
                                  _smallCue('Free', Colors.green.shade700),
                                ],
                                const SizedBox(height: 4),
                                Text(
                                  'Recorded progress: ${item.completedSessions} / ${item.totalSessions}',
                                  style: TextStyle(
                                    color: Colors.grey.shade800,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  item.expiresAt > 0
                                      ? 'Access expires: ${_fmtDateOnlyMs(item.expiresAt)}'
                                      : 'Access expires: -',
                                  style: TextStyle(
                                    color: Colors.grey.shade800,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Progress: ${item.progressPct}%',
                                  style: TextStyle(
                                    color: Colors.grey.shade800,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: [
                                    if (nearExpiry)
                                      _smallCue(
                                        'Expiry soon',
                                        Colors.orange.shade700,
                                      ),
                                    if (expired)
                                      _smallCue('Expired', Colors.red.shade700),
                                    if (nearFinish && !almostFinish)
                                      _smallCue(
                                        'Near finish',
                                        const Color(0xFFD97706),
                                      ),
                                    if (almostFinish)
                                      _smallCue(
                                        'Almost finished',
                                        const Color(0xFF16A34A),
                                      ),
                                  ],
                                ),
                                if (nearExpiry || expired || nearFinish)
                                  const SizedBox(height: 8),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(999),
                                  child: LinearProgressIndicator(
                                    value: progressValue,
                                    minHeight: 10,
                                    backgroundColor: const Color(0xFFE5E7EB),
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      courseColor,
                                    ),
                                  ),
                                ),
                                if (!item.isFree) ...[
                                  const SizedBox(height: 8),
                                  Text(
                                    'Payment duration progress',
                                    style: TextStyle(
                                      color: Colors.grey.shade800,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(999),
                                    child: LinearProgressIndicator(
                                      value: paymentValue,
                                      minHeight: 10,
                                      backgroundColor: const Color(0xFFE5E7EB),
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                        paymentColor,
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  void _toggleClassesSearch() {
    setState(() {
      if (_showClassesSearch) {
        _searchCtrl.clear();
        _searchQuery = '';
      }
      _showClassesSearch = !_showClassesSearch;
    });
  }

  Widget _buildClassesAppBarTitle() {
    if (!_showClassesSearch) return const Text('Classes');

    return TextField(
      controller: _searchCtrl,
      autofocus: true,
      onChanged: (_) => setState(() {}),
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        isDense: true,
        hintText: 'Search ID / course / learner',
        border: InputBorder.none,
        suffixIcon: _searchCtrl.text.trim().isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear search',
                icon: const Icon(Icons.close_rounded, size: 18),
                onPressed: () {
                  _searchCtrl.clear();
                  setState(() => _searchQuery = '');
                },
              ),
      ),
    );
  }

  List<Widget> _buildClassesAppBarActions() {
    return [
      IconButton(
        tooltip: _showClassesSearch ? 'Hide search' : 'Search classes',
        onPressed: _toggleClassesSearch,
        icon: Icon(
          _showClassesSearch ? Icons.close_rounded : Icons.search_rounded,
        ),
      ),
      IconButton(
        tooltip: 'Filters',
        onPressed: _openClassesFiltersSheet,
        icon: const Icon(Icons.filter_alt_rounded),
      ),
    ];
  }

  // -------------------- Build --------------------

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Map<String, int>>(
      stream: _unreadByLearnerStream,
      builder: (context, unreadSnap) {
        final unreadByLearner = unreadSnap.data ?? const <String, int>{};
        final flexibleUnread = _sumUnreadFor(
          _flexLearnerUidsForBadge,
          unreadByLearner,
        );
        final recordedUnread = _sumUnreadFor(
          _recordedLearnerUidsForBadge,
          unreadByLearner,
        );

        return DefaultTabController(
          length: 3,
          child: Scaffold(
            appBar: AppBar(
              title: _buildClassesAppBarTitle(),
              actions: _buildClassesAppBarActions(),
              bottom: TabBar(
                tabs: [
                  const Tab(text: 'Classes'),
                  _tabLabelWithBadge('Flexible', flexibleUnread),
                  _tabLabelWithBadge('Recorded', recordedUnread),
                ],
              ),
            ),
            body: adminWebBodyFrame(
              context: context,
              maxWidth: 1560,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: TabBarView(
                  children: [
                    _buildClassesList(),
                    _buildFlexibleAttendanceTab(unreadByLearner),
                    _buildRecordedProgressTab(unreadByLearner),
                  ],
                ),
              ),
            ),
            floatingActionButton: FloatingActionButton(
              onPressed: () => _openClassEditor(existingClass: null),
              child: const Icon(Icons.add),
            ),
          ),
        );
      },
    );
  }
}

// -------------------- Helpers --------------------

class _FlexLearnerDetailsTabs extends StatefulWidget {
  const _FlexLearnerDetailsTabs({
    required this.item,
    required this.fmtDateOnlyMs,
    required this.onOpenSessionDetails,
  });

  final _FlexCourseSummary item;
  final String Function(int) fmtDateOnlyMs;
  final Future<void> Function(_FlexAttendanceRow row) onOpenSessionDetails;

  @override
  State<_FlexLearnerDetailsTabs> createState() =>
      _FlexLearnerDetailsTabsState();
}

class _FlexLearnerDetailsTabsState extends State<_FlexLearnerDetailsTabs> {
  int _tabIndex = 0;

  Color _reviewBg(int rating) {
    switch (rating) {
      case 5:
        return const Color(0xFFE8F5E9);
      case 4:
        return const Color(0xFFF1F8E9);
      case 3:
        return const Color(0xFFFFF8E1);
      case 2:
        return const Color(0xFFFFF3E0);
      case 1:
        return const Color(0xFFFFEBEE);
      default:
        return const Color(0xFFF8FAFB);
    }
  }

  Color _reviewBorder(int rating) {
    switch (rating) {
      case 5:
        return const Color(0xFF66BB6A);
      case 4:
        return const Color(0xFF9CCC65);
      case 3:
        return const Color(0xFFFBC02D);
      case 2:
        return const Color(0xFFFFA726);
      case 1:
        return const Color(0xFFEF5350);
      default:
        return Colors.grey.withValues(alpha: 0.25);
    }
  }

  Widget _reviewStars(int rating, {required String label}) {
    if (rating < 1 || rating > 5) {
      return Text(
        '$label: Not rated',
        style: TextStyle(
          color: Colors.grey.shade700,
          fontWeight: FontWeight.w700,
          fontSize: 12,
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$label: ',
          style: TextStyle(
            color: Colors.grey.shade700,
            fontWeight: FontWeight.w700,
            fontSize: 12,
          ),
        ),
        ...List.generate(5, (i) {
          final on = i < rating;
          return Icon(
            on ? Icons.star_rounded : Icons.star_border_rounded,
            size: 15,
            color: const Color(0xFFF59E0B),
          );
        }),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final paidAmount = item.paymentBlocks.fold<int>(
      0,
      (sum, p) => sum + p.amount,
    );
    final sessionsLeft = (item.sessionsPaidTotal - item.consumed).clamp(
      0,
      9999,
    );

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFB),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ChoiceChip(
                label: const Text('Payment'),
                selected: _tabIndex == 0,
                onSelected: (_) => setState(() => _tabIndex = 0),
              ),
              const SizedBox(width: 8),
              ChoiceChip(
                label: const Text('Attendance'),
                selected: _tabIndex == 1,
                onSelected: (_) => setState(() => _tabIndex = 1),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (_tabIndex == 0) ...[
            Text(
              'Amount $paidAmount   Session paid ${item.sessionsPaidTotal}   Left $sessionsLeft',
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                color: Color(0xFF1A2B48),
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 8),
            if (item.paymentBlocks.isEmpty)
              Text(
                'No payment rows found for this course yet.',
                style: TextStyle(
                  color: Colors.grey.shade700,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              )
            else
              ...item.paymentBlocks.asMap().entries.map((e) {
                final idx = e.key;
                final block = e.value;
                final paidDate = block.paidAt > 0
                    ? widget.fmtDateOnlyMs(block.paidAt)
                    : '-';
                final blockDeadline = block.expiresAt > 0
                    ? widget.fmtDateOnlyMs(block.expiresAt)
                    : widget.fmtDateOnlyMs(item.expiresAt);
                final blockLeft = (block.sessionsPaid - block.rows.length)
                    .clamp(0, 9999);

                return Container(
                  margin: const EdgeInsets.only(top: 8),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: Colors.grey.withValues(alpha: 0.25),
                    ),
                  ),
                  child: Text(
                    'Payment ${idx + 1} | Paid: $paidDate | Amount: ${block.amount} | Studied: ${block.rows.length}${block.sessionsPaid > 0 ? ' / ${block.sessionsPaid}' : ''} | Left: ${block.sessionsPaid > 0 ? blockLeft : '-'} | Deadline: $blockDeadline',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF1A2B48),
                      fontSize: 12,
                    ),
                  ),
                );
              }),
          ] else ...[
            if (item.rows.isEmpty)
              Text(
                'No attendance rows found.',
                style: TextStyle(
                  color: Colors.grey.shade700,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              )
            else
              ...item.rows.asMap().entries.map((entry) {
                final i = entry.key + 1;
                final row = entry.value;
                final lesson = row.lessonTitle.isEmpty ? '-' : row.lessonTitle;
                final teacher = row.teacherName.isEmpty
                    ? 'Teacher'
                    : row.teacherName;
                final statusLabel = row.present ? 'Present' : 'Absent';
                final statusColor = row.present
                    ? const Color(0xFF166534)
                    : const Color(0xFFB91C1C);
                final learnerReviewLabel =
                    row.learnerReviewRating >= 1 && row.learnerReviewRating <= 5
                    ? '${row.learnerReviewRating}/5'
                    : '-';
                final teacherReviewLabel =
                    row.teacherReviewRating >= 1 && row.teacherReviewRating <= 5
                    ? '${row.teacherReviewRating}/5'
                    : '-';
                final rowRating = row.learnerReviewRating > 0
                    ? row.learnerReviewRating
                    : row.teacherReviewRating;

                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: _reviewBg(rowRating),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: _reviewBorder(rowRating)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              '$i) S${row.sessionNo <= 0 ? '-' : row.sessionNo} • $lesson',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Color(0xFF1A2B48),
                                fontWeight: FontWeight.w900,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              _reviewStars(
                                row.teacherReviewRating,
                                label: 'Teacher',
                              ),
                              const SizedBox(height: 2),
                              _reviewStars(
                                row.learnerReviewRating,
                                label: 'Learner',
                              ),
                            ],
                          ),
                          const SizedBox(width: 4),
                          IconButton(
                            tooltip: 'Session details',
                            onPressed: row.sessionNo <= 0
                                ? null
                                : () => widget.onOpenSessionDetails(row),
                            icon: const Icon(
                              Icons.error_outline_rounded,
                              size: 18,
                            ),
                            visualDensity: VisualDensity.compact,
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Teacher: $teacher',
                        style: TextStyle(
                          color: Colors.grey.shade800,
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        row.whenLabel,
                        style: TextStyle(
                          color: Colors.grey.shade700,
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Status: $statusLabel',
                        style: TextStyle(
                          color: statusColor,
                          fontWeight: FontWeight.w900,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Learner review: $learnerReviewLabel • Teacher review: $teacherReviewLabel',
                        style: TextStyle(
                          color: Colors.grey.shade800,
                          fontWeight: FontWeight.w800,
                          fontSize: 12,
                        ),
                      ),
                      if (row.teacherComment.trim().isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          'Teacher comment: ${row.teacherComment.trim()}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.grey.shade800,
                            fontWeight: FontWeight.w700,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ],
                  ),
                );
              }),
          ],
        ],
      ),
    );
  }
}

class _ScheduleRow {
  _ScheduleRow({required this.day});
  String day;
  String? startTime;
  final TextEditingController durationCtrl = TextEditingController(text: "90");
}

class _FlexAttendanceRow {
  final String bookingKey;
  final bool present;
  final int sessionNo;
  final String dayKey;
  final String time;
  final int startAt;
  final String teacherName;
  final String lessonTitle;
  final String taughtTitle;
  final int learnerReviewRating;
  final int teacherReviewRating;
  final String teacherComment;

  const _FlexAttendanceRow({
    required this.bookingKey,
    required this.present,
    required this.sessionNo,
    required this.dayKey,
    required this.time,
    required this.startAt,
    required this.teacherName,
    required this.lessonTitle,
    required this.taughtTitle,
    required this.learnerReviewRating,
    required this.teacherReviewRating,
    required this.teacherComment,
  });

  int get sortTs {
    if (startAt > 0) return startAt;
    final parsed = DateTime.tryParse('$dayKey $time');
    if (parsed == null) return 0;
    return parsed.millisecondsSinceEpoch;
  }

  String get whenLabel {
    if (dayKey.isNotEmpty && time.isNotEmpty) return '$dayKey $time';
    if (dayKey.isNotEmpty) return dayKey;
    if (startAt > 0) {
      final d = DateTime.fromMillisecondsSinceEpoch(startAt);
      final mm = d.month.toString().padLeft(2, '0');
      final dd = d.day.toString().padLeft(2, '0');
      final hh = d.hour.toString().padLeft(2, '0');
      final mi = d.minute.toString().padLeft(2, '0');
      return '${d.year}-$mm-$dd $hh:$mi';
    }
    return '-';
  }
}

class _FlexCourseSummary {
  final String uid;
  final String learnerName;
  final String learnerSerial;
  final List<String> assignedCourses;
  final String courseKey;
  final String courseId;
  final String courseTitle;
  final String courseCode;
  final int sessionsPaidTotal;
  final int consumed;
  final int coveredSessionNumbers;
  final int syllabusSessionsTotal;
  final int expiresAt;
  final String statusLabel;
  final List<_FlexAttendanceRow> rows;
  final List<_FlexPaymentBlock> paymentBlocks;
  final int latestTs;
  final bool isFree;

  const _FlexCourseSummary({
    required this.uid,
    required this.learnerName,
    required this.learnerSerial,
    required this.assignedCourses,
    required this.courseKey,
    required this.courseId,
    required this.courseTitle,
    required this.courseCode,
    required this.sessionsPaidTotal,
    required this.consumed,
    required this.coveredSessionNumbers,
    required this.syllabusSessionsTotal,
    required this.expiresAt,
    required this.statusLabel,
    required this.rows,
    required this.paymentBlocks,
    required this.latestTs,
    required this.isFree,
  });
}

class _FlexCourseDetails {
  final List<_FlexAttendanceRow> rows;
  final List<_FlexPaymentBlock> paymentBlocks;

  const _FlexCourseDetails({required this.rows, required this.paymentBlocks});
}

class _FlexPaymentBlock {
  final String paymentId;
  final int paidAt;
  final int amount;
  final int sessionsPaid;
  final int expiresAt;
  final int expiryMonths;
  final List<_FlexAttendanceRow> rows;

  const _FlexPaymentBlock({
    required this.paymentId,
    required this.paidAt,
    required this.amount,
    required this.sessionsPaid,
    required this.expiresAt,
    required this.expiryMonths,
    required this.rows,
  });
}

class _RecordedSessionMeta {
  final bool hasVideo;
  final bool hasMaterials;

  const _RecordedSessionMeta({
    required this.hasVideo,
    required this.hasMaterials,
  });
}

class _RecordedCourseSummary {
  final String uid;
  final String learnerName;
  final String courseKey;
  final String courseId;
  final String courseTitle;
  final int completedSessions;
  final int totalSessions;
  final int progressPct;
  final int expiresAt;
  final int durationMonths;
  final int lastPaymentAt;
  final bool isFree;

  const _RecordedCourseSummary({
    required this.uid,
    required this.learnerName,
    required this.courseKey,
    required this.courseId,
    required this.courseTitle,
    required this.completedSessions,
    required this.totalSessions,
    required this.progressPct,
    required this.expiresAt,
    required this.durationMonths,
    required this.lastPaymentAt,
    required this.isFree,
  });
}

class _ClassSyllabusProgressDetails {
  final List<Map<String, dynamic>> syllabus;
  final Set<String> classCovered;
  final List<_ClassLearnerProgressRow> learnerRows;
  final int topCoveredCount;

  const _ClassSyllabusProgressDetails({
    required this.syllabus,
    required this.classCovered,
    required this.learnerRows,
    required this.topCoveredCount,
  });
}

class _ClassLearnerProgressRow {
  final String uid;
  final String learnerName;
  final String serial;
  final Set<String> covered;
  final Set<String> missingFromTop;
  final Set<String> extraVsTop;

  const _ClassLearnerProgressRow({
    required this.uid,
    required this.learnerName,
    required this.serial,
    required this.covered,
    this.missingFromTop = const <String>{},
    this.extraVsTop = const <String>{},
  });

  String get displayName {
    final n = learnerName.trim();
    if (n.isNotEmpty) return n;
    final s = serial.trim();
    if (s.isNotEmpty) return 'Serial: $s';
    return uid;
  }

  _ClassLearnerProgressRow copyWith({
    Set<String>? missingFromTop,
    Set<String>? extraVsTop,
  }) {
    return _ClassLearnerProgressRow(
      uid: uid,
      learnerName: learnerName,
      serial: serial,
      covered: covered,
      missingFromTop: missingFromTop ?? this.missingFromTop,
      extraVsTop: extraVsTop ?? this.extraVsTop,
    );
  }
}

class _ClassTabMetrics {
  final int currentSessions;
  final int totalSessions;
  final double courseProgressValue;
  final int consumedSessions;
  final int paidSessions;
  final double paymentProgressValue;
  final bool paymentVariesAcrossLearners;

  const _ClassTabMetrics({
    required this.currentSessions,
    required this.totalSessions,
    required this.courseProgressValue,
    required this.consumedSessions,
    required this.paidSessions,
    required this.paymentProgressValue,
    required this.paymentVariesAcrossLearners,
  });
}

class _PauseWindowSelection {
  final DateTime fromDate;
  final DateTime toDate;

  const _PauseWindowSelection({required this.fromDate, required this.toDate});
}
