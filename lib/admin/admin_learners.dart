import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:async/async.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

import 'payment_dialog_shared.dart';
import 'admin_payments.dart';
import '../services/push_client.dart';
import 'admin_learner_mail_topics_screen.dart';

class AdminLearnersScreen extends StatefulWidget {
  const AdminLearnersScreen({super.key});

  // Brand palette (match your style)
  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
  static const accentCyan = Color(0xFF00D4FF);
  static const mainText = Color(0xFF2D2D2D);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorders = Color(0xFFD1D9E0);

  @override
  State<AdminLearnersScreen> createState() => _AdminLearnersScreenState();
}

class _AdminLearnersScreenState extends State<AdminLearnersScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;

  final _db = FirebaseDatabase.instance;
  late final Stream<DatabaseEvent> _usersStream;
  late final Stream<DatabaseEvent> _deletedStream;
  late final Stream<DatabaseEvent> _blockedStream;

  // Nodes (match your DB)
  static const _usersPath = 'users';
  static const _deletedPath = 'users_deleted';
  static const _blockedPath = 'users_blocked';

  // UI state
  String _search = '';
  LearnerStatus? _statusFilter; // only used on Users tab

  DatabaseReference get _usersRef => _db.ref(_usersPath);
  DatabaseReference get _deletedRef => _db.ref(_deletedPath);
  DatabaseReference get _blockedRef => _db.ref(_blockedPath);

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);

    // broadcast streams once
    _usersStream = _usersRef.onValue.asBroadcastStream();
    _deletedStream = _deletedRef.onValue.asBroadcastStream();
    _blockedStream = _blockedRef.onValue.asBroadcastStream();
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    if (!mounted) return;

    Fluttertoast.cancel();
    Fluttertoast.showToast(
      msg: msg,
      toastLength: Toast.LENGTH_SHORT,
      gravity: ToastGravity.CENTER,
      backgroundColor: Colors.black.withOpacity(0.85),
      textColor: Colors.white,
      fontSize: 15,
    );
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String confirmText,
    bool danger = false,
  }) async {
    return (await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: Text(title),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: danger ? Colors.red : null,
                ),
                onPressed: () => Navigator.pop(context, true),
                child: Text(confirmText),
              ),
            ],
          ),
        )) ??
        false;
  }

  // ---------- Actions ----------

  Future<void> _pauseLearner(String uid) async {
    await _usersRef.child(uid).update({
      'status': LearnerStatus.paused.value,
      'updatedAt': ServerValue.timestamp,
    });
    _toast('Learner paused ✅');
  }

  Future<void> _activateLearner(String uid) async {
    await _usersRef.child(uid).update({
      'status': LearnerStatus.active.value,
      'updatedAt': ServerValue.timestamp,
    });
    _toast('Learner activated ✅');
  }

  Future<void> _moveToDeleted(String uid, Learner learner) async {
    final ok = await _confirm(
      title: 'Delete learner?',
      message:
          'This will move the learner to "deleted".\n\nYou can restore later.',
      confirmText: 'Move to deleted',
      danger: true,
    );
    if (!ok) return;

    final data = learner.toMap()
      ..addAll({
        'movedAt': ServerValue.timestamp,
        'movedFrom': _usersPath,

        // ✅ NEW flags for self-delete flow
        'deleteAuth': true,
        'selfDeleteDone': false,
      });

    await _deletedRef.child(uid).set(data);
    await _usersRef.child(uid).remove();

    _toast('Moved to deleted 🗑️');
  }

  Future<void> _moveToBlocked(String uid, Learner learner) async {
    final ok = await _confirm(
      title: 'Block learner?',
      message:
          'This will move the learner to "blocked".\n\nYou can restore later.',
      confirmText: 'Block',
      danger: true,
    );
    if (!ok) return;

    final data = learner.toMap()
      ..addAll({'movedAt': ServerValue.timestamp, 'movedFrom': _usersPath});

    await _blockedRef.child(uid).set(data);
    await _usersRef.child(uid).remove();
    // ✅ ALSO block by email (so admin cannot create same email again)
    final email = learner.email.trim().toLowerCase();
    final emailKey = email.replaceAll('.', ','); // RTDB safe key
    if (email.isNotEmpty) {
      await _db.ref('blocked_emails/$emailKey').set({
        'blockedAt': ServerValue.timestamp,
        'uid': uid,
      });
    }

    _toast('Moved to blocked ⛔');
  }

  Future<void> _restoreFromDeleted(String uid, Learner learner) async {
    final ok = await _confirm(
      title: 'Restore learner?',
      message: 'This will restore the learner back to users.',
      confirmText: 'Restore',
    );
    if (!ok) return;

    final data = learner.toMap()
      ..remove('movedAt')
      ..remove('movedFrom')
      ..addAll({'updatedAt': ServerValue.timestamp});

    await _usersRef.child(uid).set(data);
    await _deletedRef.child(uid).remove();

    _toast('Restored ✅');
  }

  Future<void> _restoreFromBlocked(String uid, Learner learner) async {
    final ok = await _confirm(
      title: 'Unblock learner?',
      message: 'This will restore the learner back to users.',
      confirmText: 'Unblock',
    );
    if (!ok) return;

    final data = learner.toMap()
      ..remove('movedAt')
      ..remove('movedFrom')
      ..addAll({'updatedAt': ServerValue.timestamp});

    await _usersRef.child(uid).set(data);
    await _blockedRef.child(uid).remove();
    // ✅ remove from blocked_emails
    final email = learner.email.trim().toLowerCase();
    final emailKey = email.replaceAll('.', ',');
    if (email.isNotEmpty) {
      await _db.ref('blocked_emails/$emailKey').remove();
    }

    _toast('Unblocked ✅');
  }

  Future<void> _deletePermanently(String uid, DatabaseReference fromRef) async {
    final ok = await _confirm(
      title: 'Delete permanently?',
      message: 'This cannot be undone.',
      confirmText: 'Delete forever',
      danger: true,
    );
    if (!ok) return;

    await fromRef.child(uid).remove();
    _toast('Deleted permanently ✅');
  }

  // ---------- UI ----------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AdminLearnersScreen.appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: AdminLearnersScreen.primaryBlue),
        title: const Text(
          'Learners',
          style: TextStyle(
            color: AdminLearnersScreen.primaryBlue,
            fontWeight: FontWeight.w900,
          ),
        ),
        bottom: TabBar(
          controller: _tab,
          labelColor: AdminLearnersScreen.primaryBlue,
          unselectedLabelColor: AdminLearnersScreen.primaryBlue.withOpacity(
            0.55,
          ),
          indicatorColor: AdminLearnersScreen.primaryBlue,
          tabs: const [
            Tab(text: 'Users'),
            Tab(text: 'Deleted'),
            Tab(text: 'Blocked'),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Payments',
            icon: const Icon(
              Icons.payments_rounded,
              color: AdminLearnersScreen.primaryBlue,
            ),
            onPressed: () {
              Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => AdminPaymentsScreen()));
            },
          ),
          AnimatedBuilder(
            animation: _tab,
            builder: (_, __) {
              final isUsersTab = _tab.index == 0;
              if (!isUsersTab) return const SizedBox.shrink();
              return IconButton(
                tooltip: 'Add learner',
                icon: const Icon(
                  Icons.person_add_alt_1_rounded,
                  color: AdminLearnersScreen.actionOrange,
                ),
                onPressed: () async {
                  final created = await Navigator.of(context).push<Learner?>(
                    MaterialPageRoute(
                      builder: (_) =>
                          const LearnerEditorScreen(mode: EditorMode.create),
                    ),
                  );
                  if (created != null) _toast('Learner created ✅');
                },
              );
            },
          ),
        ],
      ),
      body: TabBarView(
        controller: _tab,
        children: [
          _LearnersList(
            titleHint: 'Search learners…',
            stream: _usersStream,
            search: _search,
            statusFilter: _statusFilter,
            onSearchChanged: (v) => setState(() => _search = v),
            onStatusFilterChanged: (s) => setState(() => _statusFilter = s),
            onEdit: (uid, learner) async {
              final updated = await Navigator.of(context).push<Learner?>(
                MaterialPageRoute(
                  builder: (_) => LearnerEditorScreen(
                    mode: EditorMode.edit,
                    uid: uid,
                    initial: learner,
                  ),
                ),
              );
              if (updated != null) _toast('Learner updated ✅');
            },
            actionsBuilder: (uid, learner) => [
              PopupMenuItem(
                value: _RowAction.pause,
                child: Text(
                  learner.status == LearnerStatus.paused ? 'Activate' : 'Pause',
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: _RowAction.block,
                child: Text('Block'),
              ),
              const PopupMenuItem(
                value: _RowAction.delete,
                child: Text('Delete (move to deleted)'),
              ),
            ],
            onAction: (uid, learner, action) async {
              switch (action) {
                case _RowAction.pause:
                  if (learner.status == LearnerStatus.paused) {
                    await _activateLearner(uid);
                  } else {
                    await _pauseLearner(uid);
                  }
                  break;
                case _RowAction.block:
                  await _moveToBlocked(uid, learner);
                  break;
                case _RowAction.delete:
                  await _moveToDeleted(uid, learner);
                  break;
                default:
                  break;
              }
            },
          ),
          _LearnersList(
            titleHint: 'Search deleted…',
            stream: _deletedStream,
            search: _search,
            statusFilter: null,
            onSearchChanged: (v) => setState(() => _search = v),
            onStatusFilterChanged: (_) {},
            actionsBuilder: (_, __) => const [
              PopupMenuItem(value: _RowAction.restore, child: Text('Restore')),
              PopupMenuDivider(),
              PopupMenuItem(
                value: _RowAction.deleteForever,
                child: Text('Delete permanently'),
              ),
            ],
            onAction: (uid, learner, action) async {
              switch (action) {
                case _RowAction.restore:
                  await _restoreFromDeleted(uid, learner);
                  break;
                case _RowAction.deleteForever:
                  // ✅ Only allow permanent delete after self delete done
                  if (!learner.selfDeleteDone) {
                    _toast(
                      'Cannot delete forever yet. The learner must login once so the app can remove the Auth account.',
                    );
                    return;
                  }

                  await _deletePermanently(uid, _deletedRef);
                  break;

                default:
                  break;
              }
            },
          ),
          _LearnersList(
            titleHint: 'Search blocked…',
            stream: _blockedStream,
            search: _search,
            statusFilter: null,
            onSearchChanged: (v) => setState(() => _search = v),
            onStatusFilterChanged: (_) {},
            actionsBuilder: (_, __) => const [
              PopupMenuItem(value: _RowAction.restore, child: Text('Unblock')),
              PopupMenuDivider(),
              PopupMenuItem(
                value: _RowAction.deleteForever,
                child: Text('Delete permanently'),
              ),
            ],
            onAction: (uid, learner, action) async {
              switch (action) {
                case _RowAction.restore:
                  await _restoreFromBlocked(uid, learner);
                  break;
                case _RowAction.deleteForever:
                  await _deletePermanently(uid, _blockedRef);
                  break;
                default:
                  break;
              }
            },
          ),
        ],
      ),
    );
  }
}

enum _PayFlag { ok, yellow, red, black, noCourse }

enum _RowAction { edit, pause, delete, block, restore, deleteForever }

enum _QuickLearnerReminder { payment, absence, empty }

enum _QuickSmsTemplate { empty, welcome }

class _LearnersList extends StatefulWidget {
  const _LearnersList({
    required this.titleHint,
    required this.stream,
    required this.search,
    required this.statusFilter,
    required this.onSearchChanged,
    required this.onStatusFilterChanged,
    required this.actionsBuilder,
    required this.onAction,
    this.onEdit,
  });

  final String titleHint;
  final Stream<DatabaseEvent> stream;

  final String search;
  final LearnerStatus? statusFilter;

  final ValueChanged<String> onSearchChanged;
  final ValueChanged<LearnerStatus?> onStatusFilterChanged;

  final List<PopupMenuEntry<_RowAction>> Function(String uid, Learner learner)
  actionsBuilder;
  final Future<void> Function(String uid, Learner learner, _RowAction action)
  onAction;
  final Future<void> Function(String uid, Learner learner)? onEdit;

  @override
  State<_LearnersList> createState() => _LearnersListState();
}

class _LearnersListState extends State<_LearnersList>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  void _toast(String msg) {
    if (!mounted) return;

    Fluttertoast.cancel();
    Fluttertoast.showToast(
      msg: msg,
      toastLength: Toast.LENGTH_SHORT,
      gravity: ToastGravity.CENTER,
      backgroundColor: Colors.black.withOpacity(0.85),
      textColor: Colors.white,
      fontSize: 15,
    );
  }

  String? _expandedUid;

  Future<void> _showSmsTemplateSheet({
    required String phone,
    required Learner learner,
  }) async {
    if (!mounted) return;

    final picked = await showModalBottomSheet<_QuickSmsTemplate>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 6),
            ListTile(
              leading: const Icon(Icons.sms_rounded),
              title: const Text('Empty'),
              onTap: () => Navigator.pop(ctx, _QuickSmsTemplate.empty),
            ),
            ListTile(
              leading: const Icon(Icons.waving_hand_rounded),
              title: const Text('Welcome'),
              onTap: () => Navigator.pop(ctx, _QuickSmsTemplate.welcome),
            ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );

    if (picked == null) return;

    String body = '';
    switch (picked) {
      case _QuickSmsTemplate.empty:
        body = '';
        break;

      case _QuickSmsTemplate.welcome:
        final email = learner.email.trim();
        body = [
          'Peace be upon You',
          'Download the app "Your Bridge School"',
          'Login using',
          if (email.isNotEmpty) 'Email: $email',
          'Password: 12345678',
        ].join('\n');
        break;
    }

    await _launchSms(phone: phone, body: body);
  }

  Future<void> _launchSms({required String phone, required String body}) async {
    final p = phone.trim();
    final text = body.trim();

    if (p.isEmpty) return;

    if (text.isNotEmpty) {
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) _toast('Message copied ✅');
    }

    final uri = Uri(
      scheme: 'sms',
      path: p,
      queryParameters: text.isEmpty ? null : {'body': text},
    );

    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);

      if (!ok && mounted) {
        _toast('SMS app not available. Text is copied ✅');
      }
    } catch (_) {
      if (mounted) _toast('SMS app not available. Text is copied ✅');
    }
  }

  Future<String?> _getLearnerFcmToken(String learnerUid) async {
    final snap = await FirebaseDatabase.instance
        .ref('fcm_tokens/$learnerUid/token')
        .get();
    final token = snap.value?.toString().trim();
    if (token == null || token.isEmpty) return null;
    return token;
  }

  String get _adminUid => FirebaseAuth.instance.currentUser!.uid;

  Stream<int> _unreadForLearnerStream(String learnerUid) {
    final q = FirebaseDatabase.instance
        .ref('mail_index/$_adminUid')
        .orderByChild('peerUid')
        .equalTo(learnerUid);

    return q.onValue.map((event) {
      final v = event.snapshot.value;
      if (v is! Map) return 0;

      int sum = 0;
      v.forEach((_, raw) {
        if (raw is! Map) return;
        final m = raw.map((k, vv) => MapEntry(k.toString(), vv));

        if (m['deletedAt'] != null) return;

        final uc = m['unreadCount'];
        int toInt(dynamic x) {
          if (x is int) return x;
          if (x is num) return x.toInt();
          return int.tryParse(x?.toString() ?? '') ?? 0;
        }

        sum += toInt(uc);
      });

      return sum;
    });
  }

  Widget _badge(int count) {
    if (count <= 0) return const SizedBox.shrink();
    final label = count > 99 ? '99+' : '$count';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.red,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white, width: 2),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w900,
          fontSize: 11,
        ),
      ),
    );
  }

  Future<void> _sendLearnerQuickReminder({
    required String uid,
    required Learner learner,
    required _QuickLearnerReminder type,
  }) async {
    String title;
    String message;

    switch (type) {
      case _QuickLearnerReminder.payment:
        title = 'Payment Reminder';
        message = 'Your payment is due. Please contact the academy.';
        break;
      case _QuickLearnerReminder.absence:
        title = 'Absence Reminder';
        message = 'We noticed an absence. Please confirm with the academy.';
        break;
      case _QuickLearnerReminder.empty:
        return;
    }

    final admin = FirebaseAuth.instance.currentUser;
    final reminderRef = FirebaseDatabase.instance.ref('reminders/$uid').push();

    try {
      await reminderRef.set({
        'kind': type.name,
        'title': title,
        'description': message,
        'attachment_name': '',
        'attachment_url': '',
        'createdAt': ServerValue.timestamp,
        'createdByUid': admin?.uid ?? '',
        'teacher': {'name': 'Admin', 'email': admin?.email ?? ''},
        'status': 'queued',
        'readAt': null,
        'doneAt': null,
        'push': {'attemptedAt': null, 'sentAt': null, 'error': null},
      });
    } catch (e) {
      if (!mounted) return;
      _toast('RTDB write failed: $e');
      return;
    }

    final token = await _getLearnerFcmToken(uid);

    await reminderRef.child('push/attemptedAt').set(ServerValue.timestamp);

    if (token == null || token.isEmpty) {
      await reminderRef.update({'status': 'push_skipped_no_token'});
      if (!mounted) return;
      _toast('Reminder saved ✅ (learner offline)');
      return;
    }

    try {
      await PushClient.sendToToken(
        token: token,
        title: title,
        message: message,
        data: {
          'type': 'reminder',
          'route': 'learner',
          'learnerUid': uid,
          'kind': type.name,
          'reminderId': reminderRef.key,
        },
      );

      await reminderRef.update({
        'status': 'push_sent',
        'push/sentAt': ServerValue.timestamp,
        'push/error': null,
      });

      if (!mounted) return;
      _toast('Reminder saved & push sent ✅');
    } catch (e) {
      await reminderRef.update({
        'status': 'push_error',
        'push/error': e.toString(),
      });

      if (!mounted) return;
      _toast('Reminder saved but push failed');
    }
  }

  Future<void> _showQuickReminderSheet({
    required String uid,
    required Learner learner,
  }) async {
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
              leading: const Icon(Icons.mail_rounded),
              title: const Text('Mail'),
              onTap: () => Navigator.pop(ctx, _QuickLearnerReminder.empty),
            ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );

    if (picked == null) return;

    try {
      if (picked == _QuickLearnerReminder.empty) {
        if (!mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => AdminLearnerMailTopicsScreen(
              learnerUid: uid,
              learnerName: learner.fullName.isEmpty
                  ? 'Learner'
                  : learner.fullName,
            ),
          ),
        );
      } else {
        await _sendLearnerQuickReminder(
          uid: uid,
          learner: learner,
          type: picked,
        );
      }
    } catch (_) {
      if (!mounted) return;
      _toast('Could not send reminder. Please try again.');
    }
  }

  final _db = FirebaseDatabase.instance;
  static const List<String> _methods = ['Cash', 'Card', 'Transfer', 'Other'];

  static String _normalizeVariantKey(String key) {
    final v = key.trim().toLowerCase();
    switch (v) {
      case 'in_class':
      case 'in-class':
      case 'in class':
      case 'inclass':
        return 'inclass';
      case 'online':
      case 'flexible':
        return 'flexible';
      case 'live':
      case 'private':
        return 'private';
      case 'recorded':
        return 'recorded';
      default:
        return v;
    }
  }

  bool _variantUsesSessions(String variantKey) {
    final v = _normalizeVariantKey(variantKey);
    return v == 'inclass' || v == 'private' || v == 'flexible';
  }

  bool _variantUsesReminder(String variantKey) {
    final v = _normalizeVariantKey(variantKey);
    return v == 'inclass' || v == 'private';
  }

  bool _variantUsesExpiry(String variantKey) {
    final v = _normalizeVariantKey(variantKey);
    return v == 'flexible' || v == 'recorded';
  }

  bool _variantIsRecorded(String variantKey) {
    return _normalizeVariantKey(variantKey) == 'recorded';
  }

  bool _variantIsFlexible(String variantKey) {
    return _normalizeVariantKey(variantKey) == 'flexible';
  }

  bool _isExpiredMs(int expiresAt) {
    if (expiresAt <= 0) return false;
    return DateTime.now().millisecondsSinceEpoch >= expiresAt;
  }

  bool _isNearExpiryMs(int expiresAt, {int days = 7}) {
    if (expiresAt <= 0) return false;
    final now = DateTime.now().millisecondsSinceEpoch;
    final diff = expiresAt - now;
    if (diff < 0) return false;
    return diff <= Duration(days: days).inMilliseconds;
  }

  _PayFlag _sessionPaymentFlag({
    required int sessionsPaidTotal,
    required int sessionsDone,
    required int remindBeforeSession,
  }) {
    if (sessionsPaidTotal <= 0) return _PayFlag.black;

    final rb = remindBeforeSession > 0 ? remindBeforeSession : 1;
    final currentSession = sessionsDone + 1;

    var dueAt = sessionsPaidTotal - rb;
    if (dueAt < 1) dueAt = 1;

    final warnAt = dueAt - 1;

    if (currentSession >= dueAt) return _PayFlag.red;
    if (warnAt >= 1 && currentSession == warnAt) return _PayFlag.yellow;

    return _PayFlag.ok;
  }

  _PayFlag _variantPaymentFlag(Map<String, dynamic> courseMap) {
    final variantKey = _normalizeVariantKey(
      (courseMap['variantKey'] ?? courseMap['variant'] ?? 'inclass').toString(),
    );

    final paymentSummary = courseMap['payment_summary'];
    final summaryMap = paymentSummary is Map
        ? paymentSummary.map((k, v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};

    final attendance = courseMap['attendance'];
    final sessionsDone = _LearnerExpandedTabsState._countUniqueAttendance(
      attendance,
    );

    final sessionsPaidTotal = _LearnerExpandedTabsState._asInt(
      summaryMap['sessionsPaidTotal'],
    );
    final remindBeforeSession = _LearnerExpandedTabsState._asInt(
      summaryMap['remindBeforeSession'],
    );

    if (_variantIsRecorded(variantKey)) {
      final access = courseMap['recorded_access'];
      final accessMap = access is Map
          ? access.map((k, v) => MapEntry(k.toString(), v))
          : <String, dynamic>{};

      final expiresAt = _LearnerExpandedTabsState._asInt(
        accessMap['expiresAt'],
      );
      if (expiresAt <= 0) return _PayFlag.black;
      if (_isExpiredMs(expiresAt)) return _PayFlag.red;
      if (_isNearExpiryMs(expiresAt)) return _PayFlag.yellow;
      return _PayFlag.ok;
    }

    if (_variantIsFlexible(variantKey)) {
      final access = courseMap['flexible_access'];
      final accessMap = access is Map
          ? access.map((k, v) => MapEntry(k.toString(), v))
          : <String, dynamic>{};

      final expiresAt = _LearnerExpandedTabsState._asInt(
        accessMap['expiresAt'],
      );

      if (sessionsPaidTotal <= 0 && expiresAt <= 0) return _PayFlag.black;
      if (expiresAt > 0 && _isExpiredMs(expiresAt)) return _PayFlag.red;
      if (sessionsPaidTotal > 0 && sessionsDone >= sessionsPaidTotal)
        return _PayFlag.red;
      if (expiresAt > 0 && _isNearExpiryMs(expiresAt)) return _PayFlag.yellow;
      if (sessionsPaidTotal > 0) {
        final left = sessionsPaidTotal - sessionsDone;
        if (left <= 1) return _PayFlag.yellow;
      }
      return _PayFlag.ok;
    }

    return _sessionPaymentFlag(
      sessionsPaidTotal: sessionsPaidTotal,
      sessionsDone: sessionsDone,
      remindBeforeSession: remindBeforeSession > 0 ? remindBeforeSession : 1,
    );
  }

  Widget _withLearnerDueFlag({
    required String uid,
    required Widget Function(_PayFlag flag) builder,
  }) {
    final coursesRef = _db.ref('users/$uid/courses');

    return StreamBuilder<DatabaseEvent>(
      stream: coursesRef.onValue,
      builder: (context, snap) {
        final v = snap.data?.snapshot.value;
        if (v is! Map) return builder(_PayFlag.noCourse);

        final courseMaps = <Map<String, dynamic>>[];
        v.forEach((_, courseVal) {
          if (courseVal is! Map) return;
          courseMaps.add(
            courseVal
                .map((k, vv) => MapEntry(k.toString(), vv))
                .cast<String, dynamic>(),
          );
        });

        if (courseMaps.isEmpty) return builder(_PayFlag.noCourse);

        _PayFlag best = _PayFlag.ok;

        int rank(_PayFlag f) {
          switch (f) {
            case _PayFlag.black:
              return 4;
            case _PayFlag.red:
              return 3;
            case _PayFlag.yellow:
              return 2;
            case _PayFlag.ok:
              return 1;
            case _PayFlag.noCourse:
            default:
              return 0;
          }
        }

        for (final courseMap in courseMaps) {
          final flag = _variantPaymentFlag(courseMap);
          if (rank(flag) > rank(best)) best = flag;
          if (best == _PayFlag.black) break;
        }

        return builder(best);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    return Column(
      children: [
        _TopBar(
          hint: widget.titleHint,
          value: widget.search,
          onChanged: widget.onSearchChanged,
          filters: const <_FilterChipItem>[],
        ),
        if (widget.statusFilter != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: SizedBox(
              height: 38,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: 1 + LearnerStatus.values.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, i) {
                  if (i == 0) {
                    return ChoiceChip(
                      label: const Text('All'),
                      selected: widget.statusFilter == null,
                      onSelected: (_) => widget.onStatusFilterChanged(null),
                    );
                  }
                  final s = LearnerStatus.values[i - 1];
                  return ChoiceChip(
                    label: Text(s.label),
                    selected: widget.statusFilter == s,
                    onSelected: (_) => widget.onStatusFilterChanged(s),
                  );
                },
              ),
            ),
          ),
        Expanded(
          child: StreamBuilder<DatabaseEvent>(
            stream: widget.stream,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return const _StateCard(
                  title: 'Error',
                  message: 'Could not load learners.',
                  icon: Icons.error_outline,
                );
              }

              if (snapshot.connectionState == ConnectionState.waiting &&
                  !snapshot.hasData) {
                return const _LoadingList();
              }

              final data = snapshot.data?.snapshot.value;
              final rows = _parseLearnersMap(data);

              rows.sort((a, b) {
                final aT = a.learner.updatedAtMs ?? 0;
                final bT = b.learner.updatedAtMs ?? 0;
                return bT.compareTo(aT);
              });

              final s = widget.search.trim().toLowerCase();
              final filtered = rows.where((r) {
                final l = r.learner;

                final matchesSearch = s.isEmpty
                    ? true
                    : l.fullName.toLowerCase().contains(s) ||
                          l.email.toLowerCase().contains(s) ||
                          l.serial.toLowerCase().contains(s) ||
                          l.phone1.toLowerCase().contains(s) ||
                          l.phone2.toLowerCase().contains(s);

                final matchesStatus = widget.statusFilter == null
                    ? true
                    : (l.status == widget.statusFilter);

                return matchesSearch && matchesStatus;
              }).toList();

              if (filtered.isEmpty) {
                return const _StateCard(
                  title: 'No learners',
                  message: 'No results match your filters.',
                  icon: Icons.people_outline,
                );
              }

              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                itemCount: filtered.length,
                itemBuilder: (context, i) {
                  final row = filtered[i];
                  final l = row.learner;
                  final isExpanded = _expandedUid == row.uid;

                  return _withLearnerDueFlag(
                    uid: row.uid,
                    builder: (flag) {
                      Color avatarBg;
                      Color avatarFg;

                      switch (flag) {
                        case _PayFlag.noCourse:
                          avatarBg = Colors.blue;
                          avatarFg = Colors.white;
                          break;
                        case _PayFlag.black:
                          avatarBg = Colors.black;
                          avatarFg = Colors.white;
                          break;
                        case _PayFlag.red:
                          avatarBg = Colors.red;
                          avatarFg = Colors.white;
                          break;
                        case _PayFlag.yellow:
                          avatarBg = Colors.orange;
                          avatarFg = Colors.white;
                          break;
                        case _PayFlag.ok:
                        default:
                          avatarBg = AdminLearnersScreen.appBg;
                          avatarFg = AdminLearnersScreen.primaryBlue;
                          break;
                      }

                      String compactLine2() {
                        final parts = <String>[];
                        if (l.dob.trim().isNotEmpty) parts.add('🎂 ${l.dob}');
                        if (l.phone2.trim().isNotEmpty)
                          parts.add('📞2 ${l.phone2}');
                        return parts.join('  •  ');
                      }

                      return Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: AdminLearnersScreen.uiBorders,
                          ),
                        ),
                        child: Column(
                          children: [
                            InkWell(
                              borderRadius: BorderRadius.circular(16),
                              onTap: () {
                                setState(() {
                                  _expandedUid = isExpanded ? null : row.uid;
                                });
                              },
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Row(
                                  children: [
                                    GestureDetector(
                                      onTap: () => _showQuickReminderSheet(
                                        uid: row.uid,
                                        learner: l,
                                      ),
                                      onLongPress: () =>
                                          _showQuickReminderSheet(
                                            uid: row.uid,
                                            learner: l,
                                          ),
                                      child: StreamBuilder<int>(
                                        stream: _unreadForLearnerStream(
                                          row.uid,
                                        ),
                                        builder: (context, snapUnread) {
                                          final unread = snapUnread.data ?? 0;

                                          return Stack(
                                            clipBehavior: Clip.none,
                                            children: [
                                              CircleAvatar(
                                                backgroundColor: avatarBg,
                                                child: Text(
                                                  l.firstName.isNotEmpty
                                                      ? l.firstName[0]
                                                            .toUpperCase()
                                                      : 'L',
                                                  style: TextStyle(
                                                    fontWeight: FontWeight.w900,
                                                    color: avatarFg,
                                                  ),
                                                ),
                                              ),
                                              if (unread > 0)
                                                Positioned(
                                                  right: -6,
                                                  top: -6,
                                                  child: _badge(unread),
                                                ),
                                            ],
                                          );
                                        },
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Expanded(
                                                child: Text(
                                                  l.fullName.isEmpty
                                                      ? '(No name)'
                                                      : l.fullName,
                                                  style: const TextStyle(
                                                    fontWeight: FontWeight.w900,
                                                    color: AdminLearnersScreen
                                                        .primaryBlue,
                                                  ),
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ),
                                              const SizedBox(width: 10),
                                              if (l.status ==
                                                  LearnerStatus.paused)
                                                const _Pill(
                                                  label: 'Inactive',
                                                  bg: Color(0xFFFFF3D6),
                                                  fg: Color(0xFF9A6B00),
                                                ),
                                            ],
                                          ),
                                          const SizedBox(height: 6),
                                          if (l.phone1.trim().isNotEmpty)
                                            Row(
                                              children: [
                                                InkWell(
                                                  onTap: () async {
                                                    final phone = l.phone1
                                                        .trim();
                                                    final uri = Uri(
                                                      scheme: 'tel',
                                                      path: phone,
                                                    );
                                                    if (await canLaunchUrl(
                                                      uri,
                                                    )) {
                                                      await launchUrl(uri);
                                                    } else {
                                                      _toast(
                                                        'Cannot open phone dialer on this device.',
                                                      );
                                                    }
                                                  },
                                                  onLongPress: () async {
                                                    await _showSmsTemplateSheet(
                                                      phone: l.phone1.trim(),
                                                      learner: l,
                                                    );
                                                  },
                                                  child: Text(
                                                    '📞 ${l.phone1}',
                                                    style: TextStyle(
                                                      fontSize: 12,
                                                      fontWeight:
                                                          FontWeight.w800,
                                                      color: AdminLearnersScreen
                                                          .primaryBlue
                                                          .withOpacity(0.9),
                                                      decoration: TextDecoration
                                                          .underline,
                                                    ),
                                                  ),
                                                ),
                                                if (l.email
                                                    .trim()
                                                    .isNotEmpty) ...[
                                                  const SizedBox(width: 10),
                                                  Expanded(
                                                    child: Text(
                                                      '✉ ${l.email.trim()}',
                                                      style: TextStyle(
                                                        fontSize: 12,
                                                        fontWeight:
                                                            FontWeight.w800,
                                                        color: Colors.black
                                                            .withOpacity(0.65),
                                                      ),
                                                      maxLines: 1,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                    ),
                                                  ),
                                                ],
                                              ],
                                            )
                                          else
                                            Text(
                                              '📞 (No phone)',
                                              style: TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w700,
                                                color: Colors.black.withOpacity(
                                                  0.5,
                                                ),
                                              ),
                                            ),
                                          const SizedBox(height: 4),
                                          if (compactLine2().isNotEmpty)
                                            Text(
                                              compactLine2(),
                                              style: TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w700,
                                                color: Colors.black.withOpacity(
                                                  0.65,
                                                ),
                                              ),
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Icon(
                                      isExpanded
                                          ? Icons.expand_less_rounded
                                          : Icons.expand_more_rounded,
                                      color: AdminLearnersScreen.primaryBlue
                                          .withOpacity(0.7),
                                    ),
                                    const SizedBox(width: 4),
                                    PopupMenuButton<_RowAction>(
                                      tooltip: 'Actions',
                                      onSelected: (a) async {
                                        if (a == _RowAction.edit) {
                                          if (widget.onEdit != null) {
                                            await widget.onEdit!(row.uid, l);
                                          }
                                          return;
                                        }
                                        await widget.onAction(row.uid, l, a);
                                      },
                                      itemBuilder: (_) {
                                        final items =
                                            <PopupMenuEntry<_RowAction>>[];
                                        if (widget.onEdit != null) {
                                          items.add(
                                            const PopupMenuItem(
                                              value: _RowAction.edit,
                                              child: Text('Edit'),
                                            ),
                                          );
                                          items.add(const PopupMenuDivider());
                                        }
                                        items.addAll(
                                          widget.actionsBuilder(row.uid, l),
                                        );
                                        return items;
                                      },
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            AnimatedCrossFade(
                              firstChild: const SizedBox.shrink(),
                              secondChild: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  12,
                                  0,
                                  12,
                                  12,
                                ),
                                child: _LearnerExpandedTabs(
                                  uid: row.uid,
                                  db: _db,
                                  methods: _methods,
                                ),
                              ),
                              crossFadeState: isExpanded
                                  ? CrossFadeState.showSecond
                                  : CrossFadeState.showFirst,
                              duration: const Duration(milliseconds: 200),
                            ),
                          ],
                        ),
                      );
                    },
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.hint,
    required this.value,
    required this.onChanged,
    required this.filters,
  });

  final String hint;
  final String value;
  final ValueChanged<String> onChanged;
  final List<_FilterChipItem> filters;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Column(
        children: [
          TextField(
            onChanged: onChanged,
            decoration: InputDecoration(
              hintText: hint,
              prefixIcon: const Icon(Icons.search),
              filled: true,
              fillColor: AdminLearnersScreen.appBg,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 12,
              ),
            ),
          ),
          if (filters.isNotEmpty) ...[
            const SizedBox(height: 10),
            SizedBox(
              height: 38,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: filters.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, i) {
                  final f = filters[i];
                  return ChoiceChip(
                    label: Text(f.label),
                    selected: f.selected,
                    onSelected: (_) => f.onTap(),
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _FilterChipItem {
  const _FilterChipItem({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, this.bg, this.fg});

  final String label;
  final Color? bg;
  final Color? fg;

  @override
  Widget build(BuildContext context) {
    final background = bg ?? AdminLearnersScreen.appBg;
    final foreground = fg ?? AdminLearnersScreen.primaryBlue;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: foreground,
        ),
      ),
    );
  }
}

class _StateCard extends StatelessWidget {
  const _StateCard({
    required this.title,
    required this.message,
    required this.icon,
  });

  final String title;
  final String message;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Card(
        elevation: 0,
        margin: const EdgeInsets.all(16),
        color: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 36, color: AdminLearnersScreen.primaryBlue),
              const SizedBox(height: 10),
              Text(
                title,
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 16,
                  color: AdminLearnersScreen.primaryBlue,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.black.withOpacity(0.7)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LoadingList extends StatelessWidget {
  const _LoadingList();

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      itemCount: 6,
      itemBuilder: (context, i) => Card(
        elevation: 0,
        margin: const EdgeInsets.only(bottom: 10),
        color: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: const Padding(
          padding: EdgeInsets.all(16),
          child: Row(
            children: [
              SizedBox(
                width: 44,
                height: 44,
                child: ColoredBox(color: AdminLearnersScreen.appBg),
              ),
              SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      height: 14,
                      width: 160,
                      child: ColoredBox(color: AdminLearnersScreen.appBg),
                    ),
                    SizedBox(height: 10),
                    SizedBox(
                      height: 12,
                      width: 260,
                      child: ColoredBox(color: AdminLearnersScreen.appBg),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ----------------------------
// Editor (NO course assignment here)
// ----------------------------

enum EditorMode { create, edit }

class LearnerPrefill {
  LearnerPrefill({
    this.firstName = '',
    this.lastName = '',
    this.phone1 = '',

    this.selectedCourseIds = const <String>{},
  });

  final String firstName;
  final String lastName;
  final String phone1;
  final Set<String> selectedCourseIds;
}

class LearnerEditorScreen extends StatefulWidget {
  const LearnerEditorScreen({
    super.key,
    required this.mode,
    this.uid,
    this.initial,
    this.prefill,
  });

  final EditorMode mode;
  final String? uid;
  final Learner? initial;
  final LearnerPrefill? prefill;

  @override
  State<LearnerEditorScreen> createState() => _LearnerEditorScreenState();
}

class _LearnerEditorScreenState extends State<LearnerEditorScreen> {
  final _formKey = GlobalKey<FormState>();

  final _db = FirebaseDatabase.instance;
  DatabaseReference get _usersRef => _db.ref('users');

  late final TextEditingController firstNameC;
  late final TextEditingController lastNameC;
  late final TextEditingController dobC;
  late final TextEditingController phone1C;
  late final TextEditingController phone2C;
  late final TextEditingController emailC;
  late final TextEditingController passwordC;
  late final TextEditingController serialC;
  bool _serialUnlocked = false;

  DateTime? _dob;
  LearnerStatus _status = LearnerStatus.active;
  bool _saving = false;

  @override
  void initState() {
    super.initState();

    final initial = widget.initial;

    firstNameC = TextEditingController(text: initial?.firstName ?? '');
    lastNameC = TextEditingController(text: initial?.lastName ?? '');
    dobC = TextEditingController(text: initial?.dob ?? '');
    phone1C = TextEditingController(text: initial?.phone1 ?? '');

    // Optional prefill (create only) - stays as before
    if (widget.mode == EditorMode.create && widget.prefill != null) {
      final p = widget.prefill!;
      if (p.firstName.trim().isNotEmpty) firstNameC.text = p.firstName.trim();
      if (p.lastName.trim().isNotEmpty) lastNameC.text = p.lastName.trim();
      if (p.phone1.trim().isNotEmpty) phone1C.text = p.phone1.trim();
    }

    phone2C = TextEditingController(text: initial?.phone2 ?? '');
    emailC = TextEditingController(text: initial?.email ?? '');
    passwordC = TextEditingController(
      text: widget.mode == EditorMode.create ? '12345678' : '',
    );
    serialC = TextEditingController(text: initial?.serial ?? '');

    _status = initial?.status ?? LearnerStatus.active;

    if (dobC.text.trim().isNotEmpty) {
      final parts = dobC.text.trim().split('-');
      if (parts.length == 3) {
        final y = int.tryParse(parts[0]);
        final m = int.tryParse(parts[1]);
        final d = int.tryParse(parts[2]);
        if (y != null && m != null && d != null) {
          _dob = DateTime(y, m, d);
        }
      }
    }

    if (widget.mode == EditorMode.create) {
      _nextSerial().then((s) {
        if (!mounted) return;
        if (serialC.text.trim().isEmpty) serialC.text = s;
      });
    }
  }

  @override
  void dispose() {
    firstNameC.dispose();
    lastNameC.dispose();
    dobC.dispose();
    phone1C.dispose();
    phone2C.dispose();
    emailC.dispose();
    passwordC.dispose();
    serialC.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    if (!mounted) return;

    Fluttertoast.cancel();
    Fluttertoast.showToast(
      msg: msg,
      toastLength: Toast.LENGTH_SHORT,
      gravity: ToastGravity.CENTER,
      backgroundColor: Colors.black.withOpacity(0.85),
      textColor: Colors.white,
      fontSize: 15,
    );
  }

  Future<void> _pickDob() async {
    FocusScope.of(context).unfocus();

    final now = DateTime.now();
    final initial = _dob ?? DateTime(now.year - 12, now.month, now.day);

    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(1940),
      lastDate: DateTime(now.year + 1),
      helpText: 'Date of birth',
      initialEntryMode: DatePickerEntryMode.input,
    );

    if (picked == null) return;

    setState(() => _dob = picked);

    String two(int n) => n.toString().padLeft(2, '0');
    dobC.text = '${picked.year}-${two(picked.month)}-${two(picked.day)}';
  }

  Future<String> _nextSerial() async {
    final snap = await FirebaseDatabase.instance.ref('users').get();
    int maxNum = 0;

    final v = snap.value;
    if (v is Map) {
      for (final entry in v.entries) {
        final user = entry.value;
        if (user is Map) {
          final raw = user['serial']?.toString().trim() ?? '';
          final digits = RegExp(r'(\d+)').firstMatch(raw)?.group(1);
          final n = int.tryParse(digits ?? '');
          if (n != null && n > maxNum) maxNum = n;
        }
      }
    }

    final next = maxNum + 1;
    final padded = next.toString().padLeft(6, '0');
    return '🎓-$padded';
  }

  Future<String> _createAuthUserAndGetUid({
    required String email,
    required String password,
  }) async {
    final options = Firebase.app().options;

    final name = 'secondary_${DateTime.now().microsecondsSinceEpoch}';
    final secondary = await Firebase.initializeApp(
      name: name,
      options: options,
    );

    try {
      final secondaryAuth = FirebaseAuth.instanceFor(app: secondary);
      final cred = await secondaryAuth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );
      final uid = cred.user?.uid;
      if (uid == null) {
        throw Exception('User created but UID is null.');
      }
      await secondaryAuth.signOut();
      return uid;
    } finally {
      await secondary.delete();
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _saving = true);

    try {
      final isCreate = widget.mode == EditorMode.create;

      final first = firstNameC.text.trim();
      final last = lastNameC.text.trim();
      final email = emailC.text.trim();
      final pass = passwordC.text.trim();

      final serial = serialC.text.trim();
      final dob = dobC.text.trim();
      final phone1 = phone1C.text.trim();
      final phone2 = phone2C.text.trim();

      final nowTs = ServerValue.timestamp;

      String uid;

      if (isCreate) {
        // ✅ blocklist check by email
        final emailNorm = email.trim().toLowerCase();
        final emailKey = emailNorm.replaceAll('.', ',');
        final blockedSnap = await FirebaseDatabase.instance
            .ref('blocked_emails/$emailKey')
            .get();
        if (blockedSnap.exists) {
          _toast('This email has been blocked.');
          setState(() => _saving = false);
          return;
        }

        uid = await _createAuthUserAndGetUid(email: email, password: pass);
      } else {
        uid = widget.uid!;
      }

      final learner = Learner(
        uid: uid,
        firstName: first,
        lastName: last,
        dob: dob,
        phone1: phone1,
        phone2: phone2,
        email: email,
        serial: serial,
        role: 'learner',
        status: _status,
        updatedAtMs: null,
      );

      if (isCreate) {
        await _usersRef.child(uid).set({
          ...learner.toMap(),
          'createdAt': nowTs,
          'updatedAt': nowTs,
        });
      } else {
        await _usersRef.child(uid).update({
          ...learner.toMap(),
          'updatedAt': nowTs,
        });
      }

      if (!mounted) return;
      Navigator.of(context).pop(learner);
    } on FirebaseAuthException catch (e) {
      String msg = 'Auth error: ${e.code}';
      if (e.code == 'email-already-in-use') msg = 'Email already exists.';
      if (e.code == 'invalid-email') msg = 'Invalid email.';
      if (e.code == 'weak-password') msg = 'Password is too weak.';
      _toast(msg);
    } catch (e) {
      _toast('Save failed: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.mode == EditorMode.edit;

    return Scaffold(
      backgroundColor: AdminLearnersScreen.appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: AdminLearnersScreen.primaryBlue),
        title: Text(
          isEdit ? 'Edit Learner' : 'Add Learner',
          style: const TextStyle(
            color: AdminLearnersScreen.primaryBlue,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          child: FilledButton(
            onPressed: _saving ? null : _save,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Text(
                _saving
                    ? 'Saving…'
                    : (isEdit ? 'Save Changes' : 'Create Learner'),
              ),
            ),
          ),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 90),
        child: Form(
          key: _formKey,
          child: Column(
            children: [
              _SectionCard(
                title: 'Personal details',
                child: Column(
                  children: [
                    _TextField(
                      controller: firstNameC,
                      label: 'First name *',
                      hint: 'First name',
                      validator: (v) {
                        final t = (v ?? '').trim();
                        if (t.isEmpty) return 'First name is required';
                        if (t.length < 2) return 'First name is too short';
                        if (!RegExp(r"^[a-zA-ZÀ-ÿ\s'-]+$").hasMatch(t))
                          return 'First name has invalid characters';
                        return null;
                      },
                    ),
                    const SizedBox(height: 12),
                    _TextField(
                      controller: lastNameC,
                      label: 'Last name *',
                      hint: 'Last name',
                      validator: (v) {
                        final t = (v ?? '').trim();
                        if (t.isEmpty) return 'Last name is required';
                        if (t.length < 2) return 'Last name is too short';
                        if (!RegExp(r"^[a-zA-ZÀ-ÿ\s'-]+$").hasMatch(t))
                          return 'Last name has invalid characters';
                        return null;
                      },
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: dobC,
                      readOnly: true,
                      validator: (v) {
                        final t = (v ?? '').trim();
                        if (t.isEmpty) return 'Date of birth is required';
                        if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(t))
                          return 'Use format YYYY-MM-DD';
                        return null;
                      },

                      onTap: _pickDob,
                      decoration: InputDecoration(
                        labelText: 'Date of birth',
                        hintText: 'Tap to pick a date',
                        filled: true,
                        fillColor: AdminLearnersScreen.appBg,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                        prefixIcon: const Icon(Icons.calendar_month_rounded),
                      ),
                    ),
                    const SizedBox(height: 12),
                    GestureDetector(
                      onLongPress: () {
                        setState(() => _serialUnlocked = true);
                        _toast('Serial unlocked (you can edit it now).');
                      },
                      child: TextFormField(
                        controller: serialC,
                        readOnly: !_serialUnlocked,
                        decoration: InputDecoration(
                          labelText: 'Serial number',
                          hintText: '🎓-000001',
                          filled: true,
                          fillColor: AdminLearnersScreen.appBg,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: BorderSide.none,
                          ),
                          prefixIcon: const Icon(
                            Icons.confirmation_number_rounded,
                          ),
                          suffixIcon: _serialUnlocked
                              ? IconButton(
                                  tooltip: 'Lock',
                                  icon: const Icon(Icons.lock_open_rounded),
                                  onPressed: () {
                                    setState(() => _serialUnlocked = false);
                                    _toast('Serial locked ✅');
                                  },
                                )
                              : const Icon(Icons.lock_rounded),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _SectionCard(
                title: 'Contact',
                child: Column(
                  children: [
                    TextFormField(
                      controller: phone1C,
                      keyboardType: TextInputType.phone,
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[\d+\s-]')),
                      ],
                      validator: (v) {
                        final t = (v ?? '').trim();
                        if (t.isEmpty) return 'Phone number is required';
                        final digits = t.replaceAll(RegExp(r'[^0-9]'), '');
                        if (digits.length < 9)
                          return 'Phone number is too short';
                        return null;
                      },

                      decoration: InputDecoration(
                        labelText: 'Phone 1',
                        hintText: 'Example: 0550 00 00 00',
                        filled: true,
                        fillColor: AdminLearnersScreen.appBg,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                        prefixIcon: const Icon(Icons.phone_rounded),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: phone2C,
                      keyboardType: TextInputType.phone,
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[\d+\s-]')),
                      ],
                      decoration: InputDecoration(
                        labelText: 'Phone 2',
                        hintText: 'Optional',
                        filled: true,
                        fillColor: AdminLearnersScreen.appBg,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                        prefixIcon: const Icon(Icons.phone_rounded),
                      ),
                    ),
                    const SizedBox(height: 12),
                    GestureDetector(
                      onLongPress: () async {
                        final email = emailC.text.trim();
                        if (email.isEmpty) return;
                        await Clipboard.setData(ClipboardData(text: email));
                        _toast('Email copied ✅');
                      },
                      child: _TextField(
                        controller: emailC,
                        label: 'Email *',
                        hint: 'learner@email.com',
                        keyboardType: TextInputType.emailAddress,
                        validator: (v) {
                          final t = (v ?? '').trim();
                          if (t.isEmpty) return 'Required';
                          if (!t.contains('@')) return 'Invalid email';
                          return null;
                        },
                        enabled: !isEdit,
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (!isEdit)
                      _TextField(
                        controller: passwordC,
                        label: 'Password *',
                        hint: 'Default: 12345678 (you can change it)',
                        obscureText: false,
                        validator: (v) {
                          final t = (v ?? '').trim();
                          if (t.isEmpty) return 'Password is required';
                          if (t.length < 6)
                            return 'Password must be at least 6 characters';
                          return null;
                        },
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _SectionCard(
                title: 'Status',
                child: DropdownButtonFormField<LearnerStatus>(
                  value: _status,
                  decoration: InputDecoration(
                    labelText: 'Status',
                    filled: true,
                    fillColor: AdminLearnersScreen.appBg,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(14),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  items: LearnerStatus.values
                      .map(
                        (s) => DropdownMenuItem(value: s, child: Text(s.label)),
                      )
                      .toList(),
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() => _status = v);
                  },
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontWeight: FontWeight.w900,
                color: AdminLearnersScreen.primaryBlue,
              ),
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

class _TextField extends StatelessWidget {
  const _TextField({
    required this.controller,
    required this.label,
    required this.hint,
    this.maxLines = 1,
    this.keyboardType,
    this.validator,
    this.enabled = true,
    this.obscureText = false,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final int maxLines;
  final TextInputType? keyboardType;
  final String? Function(String?)? validator;
  final bool enabled;
  final bool obscureText;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      maxLines: maxLines,
      keyboardType: keyboardType,
      validator: validator,
      enabled: enabled,
      obscureText: obscureText,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        filled: true,
        fillColor: AdminLearnersScreen.appBg,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

// ----------------------------
// Model + Parsing
// ----------------------------

enum LearnerStatus {
  active,
  paused;

  String get value {
    switch (this) {
      case LearnerStatus.active:
        return 'active';
      case LearnerStatus.paused:
        return 'paused';
    }
  }

  String get label {
    switch (this) {
      case LearnerStatus.active:
        return 'Active';
      case LearnerStatus.paused:
        return 'Paused';
    }
  }

  static LearnerStatus fromValue(String? v) {
    switch ((v ?? '').toLowerCase().trim()) {
      case 'paused':
        return LearnerStatus.paused;
      case 'active':
      default:
        return LearnerStatus.active;
    }
  }
}

Color _statusBg(LearnerStatus s) {
  switch (s) {
    case LearnerStatus.paused:
      return const Color(0xFFFFF3D6);
    case LearnerStatus.active:
    default:
      return const Color(0xFFDFF7E8);
  }
}

Color _statusFg(LearnerStatus s) {
  switch (s) {
    case LearnerStatus.paused:
      return const Color(0xFF9A6B00);
    case LearnerStatus.active:
    default:
      return const Color(0xFF157A3D);
  }
}

class Learner {
  Learner({
    required this.uid,
    required this.firstName,
    required this.lastName,
    required this.dob,
    required this.phone1,
    required this.phone2,
    required this.email,
    required this.serial,
    required this.role,
    required this.status,
    required this.updatedAtMs,
    this.deleteAuth = false,
    this.selfDeleteDone = false,
  });

  final String uid;
  final String firstName;
  final String lastName;
  final String dob;
  final String phone1;
  final String phone2;
  final String email;
  final String serial;
  final String role;
  final LearnerStatus status;
  final int? updatedAtMs;
  final bool deleteAuth;
  final bool selfDeleteDone;

  String get fullName => '${firstName.trim()} ${lastName.trim()}'.trim();

  Map<String, dynamic> toMap() {
    return {
      'role': role,
      'first_name': firstName,
      'last_name': lastName,
      'dob': dob,
      'phone1': phone1,
      'phone2': phone2,
      'email': email,
      'serial': serial,
      'status': status.value,
      'updatedAt': updatedAtMs,
      'deleteAuth': deleteAuth,
      'selfDeleteDone': selfDeleteDone,
    };
  }

  factory Learner.fromMap(String uid, Map<dynamic, dynamic> raw) {
    final m = raw.map((k, v) => MapEntry(k.toString(), v));

    int? parseInt(dynamic v) {
      if (v == null) return null;
      if (v is int) return v;
      if (v is num) return v.toInt();
      return int.tryParse(v.toString());
    }

    return Learner(
      uid: uid,
      role: (m['role'] ?? 'learner').toString(),
      firstName: (m['first_name'] ?? m['firstName'] ?? '').toString(),
      lastName: (m['last_name'] ?? m['lastName'] ?? '').toString(),
      dob: (m['dob'] ?? '').toString(),
      phone1: (m['phone1'] ?? '').toString(),
      phone2: (m['phone2'] ?? '').toString(),
      email: (m['email'] ?? '').toString(),
      serial: (m['serial'] ?? '').toString(),
      status: LearnerStatus.fromValue(m['status']?.toString()),
      updatedAtMs: parseInt(m['updatedAt']),
      deleteAuth:
          (m['deleteAuth'] == true) || (m['deleteAuth']?.toString() == 'true'),
      selfDeleteDone:
          (m['selfDeleteDone'] == true) ||
          (m['selfDeleteDone']?.toString() == 'true'),
    );
  }
}

class _LearnerRow {
  _LearnerRow({required this.uid, required this.learner});
  final String uid;
  final Learner learner;
}

List<_LearnerRow> _parseLearnersMap(dynamic data) {
  if (data == null) return [];

  if (data is Map) {
    final out = <_LearnerRow>[];
    data.forEach((key, value) {
      if (key == null || value == null) return;
      if (value is Map) {
        final uid = key.toString();
        final learner = Learner.fromMap(uid, value);
        final role = learner.role.toLowerCase().trim();
        if (role == 'learner') {
          out.add(_LearnerRow(uid: uid, learner: learner));
        }
      }
    });
    return out;
  }

  return [];
}

// ----------------------------
// Expanded Tabs inside learner card
// ----------------------------

class _LearnerExpandedTabs extends StatefulWidget {
  const _LearnerExpandedTabs({
    required this.uid,
    required this.db,
    required this.methods,
  });

  final String uid;
  final FirebaseDatabase db;
  final List<String> methods;

  @override
  State<_LearnerExpandedTabs> createState() => _LearnerExpandedTabsState();
}

class _LearnerExpandedTabsState extends State<_LearnerExpandedTabs>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;

  String? _selectedCourseKey;
  Map<String, dynamic> _userCourses = {};

  Map<String, Map<String, dynamic>> _allCourses = {};
  bool _loadingAllCourses = false;

  static const List<String> _variantKeys = [
    'inclass',
    'flexible',
    'private',
    'recorded',
  ];

  static const List<String> _studyModeKeys = ['online', 'inclass'];

  DatabaseReference get _userCoursesRef =>
      widget.db.ref('users/${widget.uid}/courses');
  DatabaseReference get _coursesRef => widget.db.ref('courses');
  DatabaseReference get _paymentsRef => widget.db.ref('payments');

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  static String _normalizeVariantKey(String key) {
    final v = key.trim().toLowerCase();
    switch (v) {
      case 'in_class':
      case 'in-class':
      case 'in class':
      case 'inclass':
        return 'inclass';
      case 'online':
      case 'flexible':
        return 'flexible';
      case 'live':
      case 'private':
        return 'private';
      case 'recorded':
        return 'recorded';
      default:
        return v;
    }
  }

  static String _variantLabel(String key) {
    switch (_normalizeVariantKey(key)) {
      case 'inclass':
        return 'In-Class';
      case 'flexible':
        return 'Flexible';
      case 'private':
        return 'Private';
      case 'recorded':
        return 'Recorded';
      default:
        return key;
    }
  }

  static String _studyModeLabel(String key) {
    switch (key.trim().toLowerCase()) {
      case 'online':
        return 'Online';
      case 'inclass':
      case 'in_class':
      case 'in-class':
      case 'in class':
        return 'In-Class';
      default:
        return key;
    }
  }

  static bool _variantUsesTeacher(String variantKey) {
    final v = _normalizeVariantKey(variantKey);
    return v == 'inclass' || v == 'private';
  }

  static bool _variantUsesSessions(String variantKey) {
    final v = _normalizeVariantKey(variantKey);
    return v == 'inclass' || v == 'private' || v == 'flexible';
  }

  static bool _variantUsesReminder(String variantKey) {
    final v = _normalizeVariantKey(variantKey);
    return v == 'inclass' || v == 'private';
  }

  static bool _variantUsesExpiry(String variantKey) {
    final v = _normalizeVariantKey(variantKey);
    return v == 'flexible' || v == 'recorded';
  }

  static bool _variantUsesStartDate(String variantKey) {
    final v = _normalizeVariantKey(variantKey);
    return v == 'inclass' || v == 'private' || v == 'flexible';
  }

  static bool _variantIsRecorded(String variantKey) {
    return _normalizeVariantKey(variantKey) == 'recorded';
  }

  static bool _variantIsFlexible(String variantKey) {
    return _normalizeVariantKey(variantKey) == 'flexible';
  }

  static bool _variantUsesAttendance(String variantKey) {
    return !_variantIsRecorded(variantKey);
  }

  static bool _isExpiredMs(int expiresAt) {
    if (expiresAt <= 0) return false;
    return DateTime.now().millisecondsSinceEpoch >= expiresAt;
  }

  static bool _isNearExpiryMs(int expiresAt, {int days = 7}) {
    if (expiresAt <= 0) return false;
    final now = DateTime.now().millisecondsSinceEpoch;
    final diff = expiresAt - now;
    if (diff < 0) return false;
    return diff <= Duration(days: days).inMilliseconds;
  }

  int _maxCourseIndexFromExisting(dynamic v) {
    if (v is! Map) return 0;
    int maxI = 0;
    v.forEach((k, _) {
      final key = k.toString();
      final m = RegExp(r'^course_(\d+)$').firstMatch(key);
      if (m != null) {
        final n = int.tryParse(m.group(1) ?? '');
        if (n != null && n > maxI) maxI = n;
      }
    });
    return maxI;
  }

  Future<void> _ensureAllCoursesLoaded() async {
    if (_allCourses.isNotEmpty) return;

    setState(() => _loadingAllCourses = true);
    try {
      final snap = await _coursesRef.get();
      final v = snap.value;

      final out = <String, Map<String, dynamic>>{};
      if (v is Map) {
        v.forEach((k, val) {
          if (k == null || val == null) return;
          if (val is Map) {
            out[k.toString()] = val.map(
              (kk, vv) => MapEntry(kk.toString(), vv),
            );
          }
        });
      }

      if (!mounted) return;
      setState(() => _allCourses = out);
    } finally {
      if (mounted) setState(() => _loadingAllCourses = false);
    }
  }

  Map<String, String> _currentlyAssignedVariantsByCourseId() {
    final out = <String, String>{};

    _userCourses.forEach((_, nodeRaw) {
      final node = nodeRaw is Map ? nodeRaw : <dynamic, dynamic>{};
      final courseId = (node['id'] ?? '').toString().trim();
      if (courseId.isEmpty) return;

      final raw = (node['variantKey'] ?? node['variant'] ?? '')
          .toString()
          .trim();
      out[courseId] = raw.isEmpty ? 'inclass' : _normalizeVariantKey(raw);
    });

    return out;
  }

  Map<String, String> _currentlyAssignedStudyModesByCourseId() {
    final out = <String, String>{};

    _userCourses.forEach((_, nodeRaw) {
      final node = nodeRaw is Map ? nodeRaw : <dynamic, dynamic>{};
      final courseId = (node['id'] ?? '').toString().trim();
      if (courseId.isEmpty) return;

      final raw = (node['studyMode'] ?? '').toString().trim().toLowerCase();
      if (raw == 'online' || raw == 'inclass') {
        out[courseId] = raw;
      }
    });

    return out;
  }

  Set<String> _currentlyAssignedCourseIds() {
    final ids = <String>{};
    _userCourses.forEach((_, nodeRaw) {
      final node = nodeRaw is Map ? nodeRaw : <dynamic, dynamic>{};
      final id = (node['id'] ?? '').toString().trim();
      if (id.isNotEmpty) ids.add(id);
    });
    return ids;
  }

  Future<bool> _confirmRemoveAssignedCourses(
    List<Map<String, String>> removedCourses,
  ) async {
    if (removedCourses.isEmpty) return true;

    final lines = removedCourses
        .map((c) {
          final title = c['title']?.trim() ?? '';
          final code = c['code']?.trim() ?? '';
          if (title.isNotEmpty && code.isNotEmpty) return '• $title ($code)';
          if (title.isNotEmpty) return '• $title';
          if (code.isNotEmpty) return '• $code';
          return '• Course';
        })
        .join('\n');

    return (await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Remove course?'),
            content: Text(
              'This will remove the learner from the selected course(s) and permanently delete:\n'
              '- attendance/progress for that course\n'
              '- class link for that course\n\n'
              'If the learner is the last learner in a class, that class will also be deleted.\n'
              'Global payment ledger will be kept.\n\n'
              'Courses to remove:\n$lines',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Colors.red),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Remove course'),
              ),
            ],
          ),
        )) ??
        false;
  }

  Future<void> _cleanupClassAfterCourseRemoval(
    Map<String, dynamic> existingCourseNode,
  ) async {
    final classRaw = existingCourseNode['class'];
    if (classRaw is! Map) return;

    final classMap = classRaw.map((k, v) => MapEntry(k.toString(), v));
    final classId = (classMap['class_id'] ?? '').toString().trim();
    if (classId.isEmpty) return;

    final classRef = widget.db.ref('classes/$classId');
    final learnerRef = classRef.child('learners/${widget.uid}');

    await learnerRef.remove();

    final learnersSnap = await classRef.child('learners').get();

    bool hasLearnersLeft = false;
    final learnersVal = learnersSnap.value;
    if (learnersVal is Map) {
      hasLearnersLeft = learnersVal.isNotEmpty;
    }

    if (!hasLearnersLeft) {
      await classRef.remove();
    }
  }

  Future<void> _saveAssignedCourses(
    Set<String> selectedIds,
    Map<String, String> variantByCourseId,
    Map<String, String> studyModeByCourseId,
  ) async {
    final coursesRef = _userCoursesRef;

    final existingSnap = await coursesRef.get();
    final existingVal = existingSnap.value;

    final Map<String, String> idToKey = {};
    if (existingVal is Map) {
      existingVal.forEach((k, v) {
        if (k == null || v == null) return;
        final kk = k.toString();
        if (!kk.startsWith('course_')) return;

        if (v is Map) {
          final mm = v.map((kk2, vv) => MapEntry(kk2.toString(), vv));
          final existingId = (mm['id'] ?? '').toString().trim();
          if (existingId.isNotEmpty) idToKey[existingId] = kk;
        }
      });
    }

    int nextIndex = _maxCourseIndexFromExisting(existingVal) + 1;
    final Map<String, dynamic> updates = {};
    final List<Map<String, dynamic>> removedCourses = [];

    if (existingVal is Map) {
      existingVal.forEach((k, v) {
        if (k == null) return;
        final key = k.toString();
        if (!key.startsWith('course_')) return;
        if (v is! Map) return;

        final mm = v.map((kk, vv) => MapEntry(kk.toString(), vv));
        final existingId = (mm['id'] ?? '').toString().trim();

        if (existingId.isNotEmpty && !selectedIds.contains(existingId)) {
          removedCourses.add({
            'courseKey': key,
            'courseId': existingId,
            'title': (mm['title'] ?? '').toString(),
            'code': (mm['course_code'] ?? '').toString(),
            'node': Map<String, dynamic>.from(mm),
          });
        }
      });
    }

    final ok = await _confirmRemoveAssignedCourses(
      removedCourses
          .map(
            (e) => {
              'title': (e['title'] ?? '').toString(),
              'code': (e['code'] ?? '').toString(),
            },
          )
          .toList(),
    );
    if (!ok) return;

    for (final removed in removedCourses) {
      final courseKey = (removed['courseKey'] ?? '').toString();
      final node = (removed['node'] is Map<String, dynamic>)
          ? removed['node'] as Map<String, dynamic>
          : <String, dynamic>{};

      await _cleanupClassAfterCourseRemoval(node);
      updates[courseKey] = null;
    }

    final Map<String, String> keyToExistingId = {};
    if (existingVal is Map) {
      existingVal.forEach((k, v) {
        if (k == null || v == null) return;
        if (v is Map) {
          final mm = v.map((kk, vv) => MapEntry(kk.toString(), vv));
          final existingId = (mm['id'] ?? '').toString().trim();
          keyToExistingId[k.toString()] = existingId;
        }
      });
    }

    for (final courseId in selectedIds) {
      final key = idToKey[courseId] ?? 'course_${nextIndex++}';
      final existingIdOnKey = (keyToExistingId[key] ?? '').trim();

      if (existingIdOnKey.isNotEmpty && existingIdOnKey != courseId) {
        updates['$key/payment_summary'] = null;
        updates['$key/attendance'] = null;
        updates['$key/flexible_access'] = null;
        updates['$key/recorded_access'] = null;
      }

      final c = _allCourses[courseId];
      final code = (c?['course_code'] ?? '').toString().trim();
      final title = (c?['title'] ?? c?['name'] ?? '').toString().trim();
      final category = (c?['category'] ?? '').toString().trim();

      updates['$key/id'] = courseId;
      updates['$key/course_code'] = code;
      updates['$key/title'] = title;
      updates['$key/category'] = category;
      updates['$key/assignedAt'] = ServerValue.timestamp;

      final chosenVariant = _normalizeVariantKey(
        (variantByCourseId[courseId] ?? 'inclass').trim(),
      );

      updates['$key/variantKey'] = _variantKeys.contains(chosenVariant)
          ? chosenVariant
          : 'inclass';
      updates['$key/variantLabel'] = _variantLabel(chosenVariant);

      if (chosenVariant == 'private') {
        final chosenStudyMode = (studyModeByCourseId[courseId] ?? 'online')
            .trim()
            .toLowerCase();

        final safeStudyMode = _studyModeKeys.contains(chosenStudyMode)
            ? chosenStudyMode
            : 'online';

        updates['$key/studyMode'] = safeStudyMode;
        updates['$key/studyModeLabel'] = _studyModeLabel(safeStudyMode);
      } else {
        updates['$key/studyMode'] = null;
        updates['$key/studyModeLabel'] = null;
      }
    }

    await coursesRef.update(updates);
  }

  Future<void> _openAssignCoursesDialog() async {
    await _ensureAllCoursesLoaded();

    final temp = Set<String>.from(_currentlyAssignedCourseIds());
    final variantByCourseId = _currentlyAssignedVariantsByCourseId();
    final studyModeByCourseId = _currentlyAssignedStudyModesByCourseId();

    String titleOf(String id) {
      final c = _allCourses[id] ?? {};
      return (c['title'] ?? c['name'] ?? '').toString().trim();
    }

    final titleCount = <String, int>{};
    for (final id in _allCourses.keys) {
      final t = titleOf(id);
      if (t.isEmpty) continue;
      titleCount[t] = (titleCount[t] ?? 0) + 1;
    }

    String displayFor(String id) {
      final c = _allCourses[id] ?? {};
      final title = (c['title'] ?? c['name'] ?? '').toString().trim();
      final code = (c['course_code'] ?? '').toString().trim();

      if (title.isEmpty) return code.isNotEmpty ? code : id;

      final duplicate = (titleCount[title] ?? 0) > 1;
      if (duplicate && code.isNotEmpty) return '$title ($code)';
      return title;
    }

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Assign courses'),
          content: SizedBox(
            width: double.maxFinite,
            child: _loadingAllCourses
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : ListView(
                    shrinkWrap: true,
                    children: _allCourses.keys.map((id) {
                      final checked = temp.contains(id);

                      if (!variantByCourseId.containsKey(id)) {
                        variantByCourseId[id] = 'inclass';
                      }

                      if (!studyModeByCourseId.containsKey(id)) {
                        studyModeByCourseId[id] = 'online';
                      }

                      return CheckboxListTile(
                        value: checked,
                        title: Text(displayFor(id)),
                        controlAffinity: ListTileControlAffinity.leading,
                        onChanged: (v) {
                          setDialogState(() {
                            if (v == true) {
                              temp.add(id);
                              variantByCourseId[id] =
                                  variantByCourseId[id] ?? 'inclass';
                              studyModeByCourseId[id] =
                                  studyModeByCourseId[id] ?? 'online';
                            } else {
                              temp.remove(id);
                            }
                          });
                        },
                        subtitle: checked
                            ? Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Column(
                                  children: [
                                    DropdownButtonFormField<String>(
                                      value: variantByCourseId[id] ?? 'inclass',
                                      decoration: InputDecoration(
                                        labelText: 'Study type',
                                        filled: true,
                                        fillColor: AdminLearnersScreen.appBg,
                                        border: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(
                                            14,
                                          ),
                                          borderSide: BorderSide.none,
                                        ),
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                              horizontal: 12,
                                              vertical: 10,
                                            ),
                                      ),
                                      items: _variantKeys
                                          .map(
                                            (k) => DropdownMenuItem(
                                              value: k,
                                              child: Text(_variantLabel(k)),
                                            ),
                                          )
                                          .toList(),
                                      onChanged: (val) {
                                        setDialogState(() {
                                          final next = _normalizeVariantKey(
                                            val ?? 'inclass',
                                          );
                                          variantByCourseId[id] = next;

                                          if (next == 'private') {
                                            studyModeByCourseId[id] =
                                                studyModeByCourseId[id] ??
                                                'online';
                                          } else {
                                            studyModeByCourseId[id] = '';
                                          }
                                        });
                                      },
                                    ),
                                    if ((variantByCourseId[id] ?? 'inclass') ==
                                        'private') ...[
                                      const SizedBox(height: 8),
                                      DropdownButtonFormField<String>(
                                        value:
                                            (studyModeByCourseId[id] ==
                                                    'inclass' ||
                                                studyModeByCourseId[id] ==
                                                    'online')
                                            ? studyModeByCourseId[id]
                                            : 'online',
                                        decoration: InputDecoration(
                                          labelText: 'Private mode',
                                          filled: true,
                                          fillColor: AdminLearnersScreen.appBg,
                                          border: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(
                                              14,
                                            ),
                                            borderSide: BorderSide.none,
                                          ),
                                          contentPadding:
                                              const EdgeInsets.symmetric(
                                                horizontal: 12,
                                                vertical: 10,
                                              ),
                                        ),
                                        items: _studyModeKeys
                                            .map(
                                              (k) => DropdownMenuItem(
                                                value: k,
                                                child: Text(_studyModeLabel(k)),
                                              ),
                                            )
                                            .toList(),
                                        onChanged: (val) {
                                          setDialogState(() {
                                            studyModeByCourseId[id] =
                                                (val == 'inclass' ||
                                                    val == 'online')
                                                ? val!
                                                : 'online';
                                          });
                                        },
                                      ),
                                    ],
                                  ],
                                ),
                              )
                            : null,
                      );
                    }).toList(),
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                await _saveAssignedCourses(
                  temp,
                  variantByCourseId,
                  studyModeByCourseId,
                );
                if (mounted) setState(() {});
                if (mounted) Navigator.pop(dialogContext);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    String middleTabText() {
      final courseKey = _selectedCourseKey;
      if (courseKey == null) return 'Attendance';

      final courseNode = (_userCourses[courseKey] ?? {}) as Map;
      final variantKey = _normalizeVariantKey(
        (courseNode['variantKey'] ?? courseNode['variant'] ?? 'inclass')
            .toString(),
      );

      return _variantIsRecorded(variantKey) ? 'Progress' : 'Attendance';
    }

    return Column(
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonalIcon(
            onPressed: _openAssignCoursesDialog,
            icon: const Icon(Icons.school_rounded),
            label: const Text('Assign courses'),
          ),
        ),
        const SizedBox(height: 10),
        TabBar(
          controller: _tab,
          labelColor: AdminLearnersScreen.primaryBlue,
          unselectedLabelColor: AdminLearnersScreen.primaryBlue.withOpacity(
            0.55,
          ),
          indicatorColor: AdminLearnersScreen.primaryBlue,
          tabs: [
            const Tab(text: 'Payment'),
            Tab(text: middleTabText()),
            const Tab(text: 'Report'),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 320,
          child: StreamBuilder<DatabaseEvent>(
            stream: _userCoursesRef.onValue,
            builder: (context, snap) {
              final v = snap.data?.snapshot.value;

              _userCourses = {};
              if (v is Map) {
                v.forEach((k, val) {
                  if (k == null || val == null) return;
                  if (val is Map) {
                    _userCourses[k.toString()] = val.map(
                      (kk, vv) => MapEntry(kk.toString(), vv),
                    );
                  }
                });
              }

              final keys = _userCourses.keys.toList()..sort();
              if ((_selectedCourseKey == null ||
                      !_userCourses.containsKey(_selectedCourseKey)) &&
                  keys.isNotEmpty) {
                _selectedCourseKey = keys.first;
              }

              return TabBarView(
                controller: _tab,
                children: [
                  _paymentTab(context, keys),
                  _attendanceTab(context, keys),
                  _reportTab(context),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _coursePicker(List<String> keys) {
    if (keys.isEmpty) {
      return const _MiniState(text: 'No courses assigned to this learner.');
    }

    final titleCount = <String, int>{};
    for (final k in keys) {
      final m = (_userCourses[k] ?? {}) as Map;
      final t = (m['title'] ?? '').toString().trim();
      if (t.isEmpty) continue;
      titleCount[t] = (titleCount[t] ?? 0) + 1;
    }

    String labelFor(String courseKey) {
      final m = (_userCourses[courseKey] ?? {}) as Map;
      final code = (m['course_code'] ?? '').toString().trim();
      final title = (m['title'] ?? '').toString().trim();

      final variant = _normalizeVariantKey(
        (m['variantKey'] ?? m['variant'] ?? 'inclass').toString().trim(),
      );
      final vLabel = _variantLabel(variant);

      final studyMode = (m['studyMode'] ?? '').toString().trim().toLowerCase();
      final studyModeLabel = studyMode.isEmpty
          ? ''
          : _studyModeLabel(studyMode);

      final suffix = (variant == 'private' && studyModeLabel.isNotEmpty)
          ? '$vLabel • $studyModeLabel'
          : vLabel;

      if (title.isEmpty) {
        return code.isNotEmpty ? '$code • $suffix' : '$courseKey • $suffix';
      }

      final duplicate = (titleCount[title] ?? 0) > 1;
      if (duplicate && code.isNotEmpty) return '$title ($code) • $suffix';
      return '$title • $suffix';
    }

    return DropdownButtonFormField<String>(
      value: _selectedCourseKey,
      decoration: InputDecoration(
        labelText: 'Course',
        filled: true,
        fillColor: AdminLearnersScreen.appBg,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 12,
        ),
      ),
      items: keys
          .map((k) => DropdownMenuItem(value: k, child: Text(labelFor(k))))
          .toList(),
      onChanged: (v) => setState(() => _selectedCourseKey = v),
    );
  }

  bool _isSessionDue({
    required int sessionsPaidTotal,
    required int sessionsDone,
    required int remindBeforeSession,
  }) {
    if (sessionsPaidTotal <= 0) return false;
    final left = sessionsPaidTotal - sessionsDone;
    return left <= remindBeforeSession;
  }

  Widget _paymentTab(BuildContext context, List<String> keys) {
    return ListView(
      padding: const EdgeInsets.only(top: 0),
      children: [
        _coursePicker(keys),
        const SizedBox(height: 8),
        if (_selectedCourseKey == null)
          const SizedBox.shrink()
        else
          _paymentPanel(context),
      ],
    );
  }

  static String _fmtDateMs(int ms) {
    if (ms <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  Widget _paymentPanel(BuildContext context) {
    final courseKey = _selectedCourseKey!;
    final courseNode = (_userCourses[courseKey] ?? {}) as Map;
    final courseId = (courseNode['id'] ?? '').toString().trim();

    if (courseId.isEmpty) {
      return const _MiniState(
        text: 'This course has no "id" saved on learner node.',
      );
    }

    final variantKey = _normalizeVariantKey(
      (courseNode['variantKey'] ?? courseNode['variant'] ?? 'inclass')
          .toString(),
    );

    final studyMode = (courseNode['studyMode'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    final variantText = variantKey == 'private' && studyMode.isNotEmpty
        ? '${_variantLabel(variantKey)} • ${_studyModeLabel(studyMode)}'
        : _variantLabel(variantKey);

    final attendance = courseNode['attendance'];
    final sessionsDone = _countUniqueAttendance(attendance);

    final flexibleAccessRaw = courseNode['flexible_access'];
    final flexibleAccess = flexibleAccessRaw is Map
        ? flexibleAccessRaw.map((k, v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};

    final recordedAccessRaw = courseNode['recorded_access'];
    final recordedAccess = recordedAccessRaw is Map
        ? recordedAccessRaw.map((k, v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};

    return FutureBuilder<DataSnapshot>(
      key: ValueKey('payment-course-$courseId'),
      future: _coursesRef.child(courseId).get(),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Padding(
            padding: EdgeInsets.all(12),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }

        final courseMapRaw = snap.data!.value;
        final courseMap = courseMapRaw is Map
            ? courseMapRaw.map((k, v) => MapEntry(k.toString(), v))
            : <String, dynamic>{};

        final totalSessions = _parseTotalSessions(
          courseMap['duration']?.toString() ?? '',
        );
        final pricePerLevel = _asInt(courseMap['price_per_level']);
        final pricePerMonth = _asInt(courseMap['price_per_month']);

        return FutureBuilder<DataSnapshot>(
          key: ValueKey('payment-sum-$courseKey'),
          future: widget.db
              .ref('users/${widget.uid}/courses/$courseKey/payment_summary')
              .get(),
          builder: (context, sumSnap) {
            final sumRaw = sumSnap.data?.value;
            final sum = sumRaw is Map
                ? sumRaw.map((k, v) => MapEntry(k.toString(), v))
                : <String, dynamic>{};

            final sessionsPaidTotal = _asInt(sum['sessionsPaidTotal']);
            final remindBeforeSession = _asInt(sum['remindBeforeSession']);
            final totalPaid = _asInt(sum['totalPaid']);

            final flexibleExpiresAt = _asInt(flexibleAccess['expiresAt']);
            final flexibleExpiryMonths = _asInt(flexibleAccess['expiryMonths']);

            final recordedExpiresAt = _asInt(recordedAccess['expiresAt']);
            final recordedDurationMonths = _asInt(
              recordedAccess['durationMonths'],
            );

            final usesSessions = _variantUsesSessions(variantKey);
            final usesReminder = _variantUsesReminder(variantKey);
            final usesExpiry = _variantUsesExpiry(variantKey);

            final due = usesReminder
                ? _isSessionDue(
                    sessionsPaidTotal: sessionsPaidTotal,
                    sessionsDone: sessionsDone,
                    remindBeforeSession: remindBeforeSession > 0
                        ? remindBeforeSession
                        : 1,
                  )
                : false;

            final sessionsLeft = (sessionsPaidTotal - sessionsDone) < 0
                ? 0
                : (sessionsPaidTotal - sessionsDone);

            final expiresAt = _variantIsRecorded(variantKey)
                ? recordedExpiresAt
                : flexibleExpiresAt;
            final monthsValue = _variantIsRecorded(variantKey)
                ? recordedDurationMonths
                : flexibleExpiryMonths;
            final expiryText = expiresAt > 0 ? _fmtDateMs(expiresAt) : '—';
            final expired = usesExpiry ? _isExpiredMs(expiresAt) : false;
            final nearExpiry = usesExpiry ? _isNearExpiryMs(expiresAt) : false;

            return _miniCard(
              bg: Colors.white,
              borderColor: AdminLearnersScreen.uiBorders,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _miniPill('Type: $variantText'),
                      if (usesSessions)
                        _miniPill(
                          totalSessions > 0
                              ? 'Sessions: $sessionsDone / $totalSessions'
                              : 'Sessions done: $sessionsDone',
                        ),
                      if (!usesSessions && _variantIsRecorded(variantKey))
                        _miniPill('Recorded access'),
                      if (pricePerMonth > 0)
                        _miniPill('Month fee: $pricePerMonth'),
                      if (pricePerLevel > 0)
                        _miniPill('Level fee: $pricePerLevel'),
                      if (totalPaid > 0) _miniPill('Total paid: $totalPaid'),
                    ],
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () async {
                        final ck = _selectedCourseKey!;
                        final node = (_userCourses[ck] ?? {}) as Map;
                        final cid = (node['id'] ?? '').toString().trim();
                        if (cid.isEmpty) return;

                        await PaymentDialogShared.showAddFromLearnerTab(
                          context: context,
                          db: widget.db,
                          uid: widget.uid,
                          courseKey: ck,
                          courseId: cid,
                        );
                      },
                      icon: const Icon(Icons.add_card_rounded),
                      label: const Text('Add payment'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AdminLearnersScreen.appBg,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: AdminLearnersScreen.uiBorders),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Payment summary',
                          style: TextStyle(fontWeight: FontWeight.w900),
                        ),
                        const SizedBox(height: 6),
                        if (usesSessions)
                          Text(
                            'Sessions paid total: $sessionsPaidTotal',
                            style: TextStyle(
                              color: Colors.black.withOpacity(0.75),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        if (usesSessions)
                          Text(
                            'Sessions left: $sessionsLeft',
                            style: TextStyle(
                              color: Colors.black.withOpacity(0.75),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        if (usesReminder)
                          Text(
                            'Reminder when left: ${remindBeforeSession > 0 ? remindBeforeSession : 1}.',
                            style: TextStyle(
                              color: Colors.black.withOpacity(0.75),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        if (usesExpiry)
                          Text(
                            _variantIsRecorded(variantKey)
                                ? 'Duration: ${monthsValue > 0 ? monthsValue : 0} month(s)'
                                : 'Expiry window: ${monthsValue > 0 ? monthsValue : 0} month(s)',
                            style: TextStyle(
                              color: Colors.black.withOpacity(0.75),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        if (usesExpiry)
                          Text(
                            'Expires on: $expiryText',
                            style: TextStyle(
                              color: Colors.black.withOpacity(0.75),
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        if (due) ...[
                          const SizedBox(height: 8),
                          const Text(
                            '⚠️ Payment is due (near last paid session).',
                            style: TextStyle(fontWeight: FontWeight.w900),
                          ),
                        ],
                        if (expired) ...[
                          const SizedBox(height: 8),
                          const Text(
                            '⛔ Access expired.',
                            style: TextStyle(fontWeight: FontWeight.w900),
                          ),
                        ] else if (nearExpiry) ...[
                          const SizedBox(height: 8),
                          const Text(
                            '⚠️ Access is near expiry.',
                            style: TextStyle(fontWeight: FontWeight.w900),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'History',
                    style: TextStyle(fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 6),
                  SizedBox(
                    height: 160,
                    child: StreamBuilder<DatabaseEvent>(
                      stream: _paymentsRef
                          .orderByChild('uid')
                          .equalTo(widget.uid)
                          .onValue,
                      builder: (context, snap) {
                        final v = snap.data?.snapshot.value;
                        final items = <Map<String, dynamic>>[];

                        if (v is Map) {
                          v.forEach((k, val) {
                            if (val is Map) {
                              final m = val.map(
                                (kk, vv) => MapEntry(kk.toString(), vv),
                              );
                              if ((m['courseKey'] ?? '').toString() !=
                                  courseKey)
                                return;
                              items.add({'paymentId': k.toString(), ...m});
                            }
                          });
                        }

                        items.sort(
                          (a, b) => _asInt(
                            b['paidAt'],
                          ).compareTo(_asInt(a['paidAt'])),
                        );

                        if (items.isEmpty)
                          return const _MiniState(text: 'No payments yet.');

                        return ListView.builder(
                          padding: EdgeInsets.zero,
                          itemCount: items.length,
                          itemBuilder: (context, i) {
                            final p = items[i];
                            final fee = _asInt(p['amount']);
                            final method = (p['method'] ?? '').toString();
                            final notes = (p['notes'] ?? '').toString();

                            final payVariant = _normalizeVariantKey(
                              (p['variantKey'] ?? variantKey).toString(),
                            );
                            final payStudyMode = (p['studyMode'] ?? '')
                                .toString();
                            final paidAt = _fmtDateMs(_asInt(p['paidAt']));
                            final startDate = (p['startDate'] ?? '')
                                .toString()
                                .trim();
                            final expiresAt = _fmtDateMs(
                              _asInt(p['expiresAt']),
                            );
                            final sp = _asInt(p['sessionsPaid']);
                            final durationMonths = _asInt(p['durationMonths']);
                            final expiryMonths = _asInt(p['expiryMonths']);

                            final variantBadge =
                                payVariant == 'private' &&
                                    payStudyMode.trim().isNotEmpty
                                ? '${_variantLabel(payVariant)} • ${_studyModeLabel(payStudyMode)}'
                                : _variantLabel(payVariant);

                            final left = (sessionsPaidTotal - sessionsDone) < 0
                                ? 0
                                : (sessionsPaidTotal - sessionsDone);

                            return Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: _miniCard(
                                bg: Colors.white,
                                borderColor: AdminLearnersScreen.uiBorders,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 8,
                                      children: [
                                        _miniPill('Type: $variantBadge'),
                                        _miniPill('Fee: $fee'),
                                        _miniPill(
                                          'Paid: ${paidAt.isEmpty ? '-' : paidAt}',
                                        ),
                                        if (_variantUsesSessions(payVariant))
                                          _miniPill('Sessions: $sp'),
                                        if (_variantUsesReminder(payVariant))
                                          _miniPill('Left: $left'),
                                        if (_variantUsesStartDate(payVariant))
                                          _miniPill(
                                            'Start: ${startDate.isEmpty ? '-' : startDate}',
                                          ),
                                        if (_variantIsFlexible(payVariant))
                                          _miniPill(
                                            'Expires: ${expiresAt.isEmpty ? '-' : expiresAt}',
                                          ),
                                        if (_variantIsFlexible(payVariant))
                                          _miniPill(
                                            'Window: ${expiryMonths > 0 ? expiryMonths : 0} month(s)',
                                          ),
                                        if (_variantIsRecorded(payVariant))
                                          _miniPill(
                                            'Duration: ${durationMonths > 0 ? durationMonths : 0} month(s)',
                                          ),
                                        if (_variantIsRecorded(payVariant))
                                          _miniPill(
                                            'Expires: ${expiresAt.isEmpty ? '-' : expiresAt}',
                                          ),
                                      ],
                                    ),
                                    if (method.trim().isNotEmpty ||
                                        notes.trim().isNotEmpty) ...[
                                      const SizedBox(height: 6),
                                      Text(
                                        [
                                          if (method.trim().isNotEmpty) method,
                                          if (notes.trim().isNotEmpty) notes,
                                        ].join(' • '),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: Colors.black.withOpacity(0.65),
                                          fontWeight: FontWeight.w700,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _attendanceTab(BuildContext context, List<String> keys) {
    if (keys.isEmpty) return const _MiniState(text: 'No courses.');

    final courseKey = _selectedCourseKey;
    if (courseKey == null) return const _MiniState(text: 'Pick a course.');

    final courseNode = (_userCourses[courseKey] ?? {}) as Map;
    final courseId = (courseNode['id'] ?? '').toString().trim();
    final variantKey = _normalizeVariantKey(
      (courseNode['variantKey'] ?? courseNode['variant'] ?? 'inclass')
          .toString(),
    );

    if (_variantIsRecorded(variantKey)) {
      final recordedProgressRaw = courseNode['recorded_progress'];
      final recordedProgress = recordedProgressRaw is Map
          ? recordedProgressRaw.map((k, v) => MapEntry(k.toString(), v))
          : <String, dynamic>{};

      if (courseId.isEmpty) {
        return ListView(
          padding: EdgeInsets.zero,
          children: [
            _coursePicker(keys),
            const SizedBox(height: 8),
            const _MiniState(text: 'This course is missing an id.'),
          ],
        );
      }

      return FutureBuilder<DataSnapshot>(
        key: ValueKey('recorded-progress-$courseId'),
        future: widget.db.ref('syllabi/$courseId/recorded').get(),
        builder: (context, syllabusSnap) {
          if (!syllabusSnap.hasData) {
            return ListView(
              padding: EdgeInsets.zero,
              children: const [
                SizedBox(height: 8),
                Center(child: CircularProgressIndicator(strokeWidth: 2)),
              ],
            );
          }

          final syllabusRaw = syllabusSnap.data?.value;
          final root = syllabusRaw is Map
              ? syllabusRaw.map((k, v) => MapEntry(k.toString(), v))
              : <String, dynamic>{};

          final rawUnits = _asListOfMaps(root['units']);

          final sessionItems = <Map<String, dynamic>>[];
          for (final unit in rawUnits) {
            final unitTitle = (unit['title'] ?? '').toString().trim();
            final rawSessions = _asListOfMaps(unit['sessions']);

            for (final session in rawSessions) {
              sessionItems.add({'unitTitle': unitTitle, ...session});
            }
          }

          int orderOf(Map<String, dynamic> s) {
            final sessionNumber = _asInt(s['sessionNumber']);
            if (sessionNumber > 0) return sessionNumber;
            return _asInt(s['order']);
          }

          sessionItems.sort((a, b) => orderOf(a).compareTo(orderOf(b)));

          bool asBool(dynamic v) {
            if (v is bool) return v;
            final s = (v ?? '').toString().trim().toLowerCase();
            return s == 'true' || s == '1';
          }

          bool isCompleted(Map<String, dynamic> sessionMap) {
            final sessionId = (sessionMap['id'] ?? '').toString().trim();
            if (sessionId.isEmpty) return false;

            final progressRaw = recordedProgress[sessionId];
            final progress = progressRaw is Map
                ? progressRaw.map((k, v) => MapEntry(k.toString(), v))
                : <String, dynamic>{};

            final hasVideo = (sessionMap['videoUrl'] ?? '')
                .toString()
                .trim()
                .isNotEmpty;
            final hasRead = (sessionMap['materialsUrl'] ?? '')
                .toString()
                .trim()
                .isNotEmpty;

            final videoDone = asBool(progress['videoCompleted']);
            final readDone = asBool(progress['materialsCompleted']);

            if (!hasVideo && !hasRead) return false;
            if (hasVideo && hasRead) return videoDone || readDone;
            if (hasVideo) return videoDone;
            if (hasRead) return readDone;
            return false;
          }

          final totalSessions = sessionItems.length;
          final completedSessions = sessionItems
              .where((s) => isCompleted(s))
              .length;
          final progressPct = totalSessions > 0
              ? ((completedSessions / totalSessions) * 100).round()
              : 0;

          return ListView(
            padding: EdgeInsets.zero,
            children: [
              _coursePicker(keys),
              const SizedBox(height: 8),
              _miniCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Recorded progress: $completedSessions / $totalSessions',
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Progress: $progressPct%',
                      style: TextStyle(
                        color: Colors.black.withOpacity(0.75),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        value: totalSessions > 0
                            ? completedSessions / totalSessions
                            : 0,
                        minHeight: 10,
                        backgroundColor: AdminLearnersScreen.appBg,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              if (sessionItems.isEmpty)
                const _MiniState(text: 'No recorded sessions found yet.')
              else
                ...sessionItems.asMap().entries.map((entry) {
                  final i = entry.key;
                  final session = entry.value;

                  final sessionId = (session['id'] ?? '').toString().trim();
                  final title =
                      (session['title'] ?? '').toString().trim().isEmpty
                      ? 'Untitled Session'
                      : (session['title'] ?? '').toString().trim();
                  final unitTitle = (session['unitTitle'] ?? '')
                      .toString()
                      .trim();

                  final progressRaw = recordedProgress[sessionId];
                  final progress = progressRaw is Map
                      ? progressRaw.map((k, v) => MapEntry(k.toString(), v))
                      : <String, dynamic>{};

                  final hasVideo = (session['videoUrl'] ?? '')
                      .toString()
                      .trim()
                      .isNotEmpty;
                  final hasRead = (session['materialsUrl'] ?? '')
                      .toString()
                      .trim()
                      .isNotEmpty;

                  final videoDone = asBool(progress['videoCompleted']);
                  final readDone = asBool(progress['materialsCompleted']);
                  final done = isCompleted(session);

                  final bar = done
                      ? const Color(0xFF157A3D)
                      : const Color(0xFF64748B);
                  final tint = done
                      ? const Color(0xFF157A3D).withOpacity(0.08)
                      : const Color(0xFF64748B).withOpacity(0.08);

                  return Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Container(
                      decoration: BoxDecoration(
                        color: tint,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: AdminLearnersScreen.uiBorders,
                        ),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 6,
                            height: 64,
                            decoration: BoxDecoration(
                              color: bar,
                              borderRadius: const BorderRadius.only(
                                topLeft: Radius.circular(16),
                                bottomLeft: Radius.circular(16),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                vertical: 8,
                                horizontal: 6,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '#${i + 1}  $title — ${done ? 'done' : 'pending'}',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w900,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    [
                                      if (unitTitle.isNotEmpty) unitTitle,
                                      if (hasVideo)
                                        'Video: ${videoDone ? 'done' : 'pending'}',
                                      if (hasRead)
                                        'Read: ${readDone ? 'done' : 'pending'}',
                                    ].join(' • '),
                                    style: TextStyle(
                                      color: Colors.black.withOpacity(0.65),
                                      fontWeight: FontWeight.w700,
                                      fontSize: 12,
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }).toList(),
            ],
          );
        },
      );
    }

    final classId = (courseNode['class'] is Map)
        ? ((courseNode['class'] as Map)['class_id'] ?? '').toString().trim()
        : '';

    if (courseId.isEmpty) {
      return ListView(
        padding: EdgeInsets.zero,
        children: [
          _coursePicker(keys),
          const SizedBox(height: 8),
          const _MiniState(text: 'This course is missing an id.'),
        ],
      );
    }

    final learnerAttendance = courseNode['attendance'];
    final learnerBySid = _attendanceBySessionId(learnerAttendance);

    if (classId.isEmpty && _variantIsFlexible(variantKey)) {
      final learnerSessions = _mapToList(learnerAttendance);

      return FutureBuilder<DataSnapshot>(
        key: ValueKey('attendance-course-$courseId'),
        future: _coursesRef.child(courseId).get(),
        builder: (context, cs) {
          if (!cs.hasData) {
            return ListView(
              padding: EdgeInsets.zero,
              children: const [
                SizedBox(height: 8),
                Center(child: CircularProgressIndicator(strokeWidth: 2)),
              ],
            );
          }

          final cRaw = cs.data?.value;
          final cMap = cRaw is Map
              ? cRaw.map((k, v) => MapEntry(k.toString(), v))
              : <String, dynamic>{};
          final totalSessions = _parseTotalSessions(
            cMap['duration']?.toString() ?? '',
          );

          return ListView(
            padding: EdgeInsets.zero,
            children: [
              _coursePicker(keys),
              const SizedBox(height: 8),
              _miniCard(
                child: Text(
                  totalSessions > 0
                      ? 'Flexible attendance: ${learnerSessions.length} / $totalSessions'
                      : 'Flexible attendance: ${learnerSessions.length}',
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
              const SizedBox(height: 8),
              if (learnerSessions.isEmpty)
                const _MiniState(text: 'No attendance recorded yet.')
              else
                ...learnerSessions.asMap().entries.map((entry) {
                  final i = entry.key;
                  final m = entry.value;
                  final date = (m['date'] ?? '').toString();
                  final statusRaw = (m['status'] ?? '').toString().trim();
                  final status = statusRaw.toLowerCase();
                  final teacher = (m['teacherName'] ?? '').toString();
                  final taught = m['taught'] is Map
                      ? (m['taught'] as Map)
                      : null;
                  final taughtTitle = taught == null
                      ? ''
                      : (taught['title'] ?? '').toString();

                  Color bar;
                  Color tint;

                  if (status == 'present') {
                    bar = const Color(0xFF157A3D);
                    tint = const Color(0xFF157A3D).withOpacity(0.08);
                  } else if (status == 'absent') {
                    bar = Colors.red;
                    tint = Colors.red.withOpacity(0.08);
                  } else {
                    bar = const Color(0xFF64748B);
                    tint = const Color(0xFF64748B).withOpacity(0.08);
                  }

                  final shownStatus = statusRaw.isEmpty
                      ? 'not registered'
                      : statusRaw;

                  return Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Container(
                      decoration: BoxDecoration(
                        color: tint,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: AdminLearnersScreen.uiBorders,
                        ),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 6,
                            height: 58,
                            decoration: BoxDecoration(
                              color: bar,
                              borderRadius: const BorderRadius.only(
                                topLeft: Radius.circular(16),
                                bottomLeft: Radius.circular(16),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                vertical: 8,
                                horizontal: 6,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    '#${i + 1}  $date — $shownStatus',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w900,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    [
                                      if (taughtTitle.trim().isNotEmpty)
                                        taughtTitle,
                                      if (teacher.trim().isNotEmpty) teacher,
                                    ].join(' • '),
                                    style: TextStyle(
                                      color: Colors.black.withOpacity(0.65),
                                      fontWeight: FontWeight.w700,
                                      fontSize: 12,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }).toList(),
            ],
          );
        },
      );
    }

    if (classId.isEmpty) {
      return ListView(
        padding: EdgeInsets.zero,
        children: [
          _coursePicker(keys),
          const SizedBox(height: 8),
          const _MiniState(text: 'This learner course has no class_id.'),
        ],
      );
    }

    return FutureBuilder<DataSnapshot>(
      key: ValueKey('attendance-course-$courseId'),
      future: _coursesRef.child(courseId).get(),
      builder: (context, cs) {
        if (!cs.hasData) {
          return ListView(
            padding: EdgeInsets.zero,
            children: const [
              SizedBox(height: 8),
              Center(child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          );
        }

        final cRaw = cs.data?.value;
        final cMap = cRaw is Map
            ? cRaw.map((k, v) => MapEntry(k.toString(), v))
            : <String, dynamic>{};
        final totalSessions = _parseTotalSessions(
          cMap['duration']?.toString() ?? '',
        );

        return FutureBuilder<DataSnapshot>(
          key: ValueKey('class-att-$classId'),
          future: widget.db.ref('classes/$classId/attendance').get(),
          builder: (context, classSnap) {
            final classAttendanceRaw = classSnap.data?.value;
            final classSessions = _mapToList(classAttendanceRaw);

            final taughtCount = classSessions.length;
            final label = totalSessions > 0
                ? '$taughtCount / $totalSessions'
                : '$taughtCount';

            return ListView(
              padding: EdgeInsets.zero,
              children: [
                _coursePicker(keys),
                const SizedBox(height: 8),
                _miniCard(
                  child: Text(
                    'Lessons taught: $label',
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                ),
                const SizedBox(height: 8),
                if (classSessions.isEmpty)
                  const _MiniState(text: 'No class sessions recorded yet.')
                else
                  ...classSessions.asMap().entries.map((entry) {
                    final i = entry.key;
                    final classRec = entry.value;

                    final sid = (classRec['sessionId'] ?? '').toString().trim();
                    final date = (classRec['date'] ?? '').toString();

                    final learnerRec = sid.isEmpty ? null : learnerBySid[sid];
                    final statusRaw = (learnerRec?['status'] ?? '')
                        .toString()
                        .trim();
                    final status = statusRaw.toLowerCase();

                    final teacher = (classRec['teacherName'] ?? '').toString();
                    final taught = classRec['taught'] is Map
                        ? (classRec['taught'] as Map)
                        : null;
                    final taughtTitle = taught == null
                        ? ''
                        : (taught['title'] ?? '').toString();

                    Color bar;
                    Color tint;

                    if (status == 'present') {
                      bar = const Color(0xFF157A3D);
                      tint = const Color(0xFF157A3D).withOpacity(0.08);
                    } else if (status == 'absent') {
                      bar = Colors.red;
                      tint = Colors.red.withOpacity(0.08);
                    } else {
                      bar = const Color(0xFF64748B);
                      tint = const Color(0xFF64748B).withOpacity(0.08);
                    }

                    final shownStatus = statusRaw.isEmpty
                        ? 'not registered'
                        : statusRaw;

                    return Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Container(
                        decoration: BoxDecoration(
                          color: tint,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: AdminLearnersScreen.uiBorders,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 6,
                              height: 58,
                              decoration: BoxDecoration(
                                color: bar,
                                borderRadius: const BorderRadius.only(
                                  topLeft: Radius.circular(16),
                                  bottomLeft: Radius.circular(16),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                  horizontal: 6,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '#${i + 1}  $date — $shownStatus',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w900,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      [
                                        if (taughtTitle.trim().isNotEmpty)
                                          taughtTitle,
                                        if (teacher.trim().isNotEmpty) teacher,
                                      ].join(' • '),
                                      style: TextStyle(
                                        color: Colors.black.withOpacity(0.65),
                                        fontWeight: FontWeight.w700,
                                        fontSize: 12,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }).toList(),
              ],
            );
          },
        );
      },
    );
  }

  Widget _reportTab(BuildContext context) {
    return const _MiniState(
      text: 'Report tab is ready (we will build it later).',
    );
  }

  static Widget _miniCard({
    required Widget child,
    Color bg = Colors.white,
    Color borderColor = AdminLearnersScreen.uiBorders,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor),
      ),
      child: Padding(padding: const EdgeInsets.all(12), child: child),
    );
  }

  static Widget _miniPill(String t) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AdminLearnersScreen.appBg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        t,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: AdminLearnersScreen.primaryBlue,
        ),
      ),
    );
  }

  static List<Map<String, dynamic>> _uniqueAttendanceByDate(
    dynamic attendance,
  ) {
    if (attendance is! Map) return [];

    final Map<String, Map<String, dynamic>> best = {};

    attendance.forEach((_, v) {
      if (v is! Map) return;

      final m = v
          .map((kk, vv) => MapEntry(kk.toString(), vv))
          .cast<String, dynamic>();
      final date = (m['date'] ?? '').toString().trim();
      if (date.isEmpty) return;

      int ts(dynamic x) {
        if (x is int) return x;
        if (x is num) return x.toInt();
        return int.tryParse(x?.toString() ?? '') ?? 0;
      }

      final curScore = ts(m['updatedAt']) > 0
          ? ts(m['updatedAt'])
          : ts(m['createdAt']);

      final old = best[date];
      if (old == null) {
        best[date] = m;
        return;
      }

      final oldScore = ts(old['updatedAt']) > 0
          ? ts(old['updatedAt'])
          : ts(old['createdAt']);
      if (curScore >= oldScore) best[date] = m;
    });

    final out = best.values.toList();
    out.sort(
      (a, b) =>
          (a['date'] ?? '').toString().compareTo((b['date'] ?? '').toString()),
    );
    return out;
  }

  static int _countUniqueAttendance(dynamic attendance) {
    return _uniqueAttendanceByDate(attendance).length;
  }

  static List<Map<String, dynamic>> _mapToList(dynamic v) {
    if (v is! Map) return [];
    final out = <Map<String, dynamic>>[];
    v.forEach((_, val) {
      if (val is Map) {
        out.add(
          val
              .map((k, vv) => MapEntry(k.toString(), vv))
              .cast<String, dynamic>(),
        );
      }
    });
    out.sort(
      (a, b) =>
          (a['date'] ?? '').toString().compareTo((b['date'] ?? '').toString()),
    );
    return out;
  }

  static List<Map<String, dynamic>> _asListOfMaps(dynamic node) {
    final out = <Map<String, dynamic>>[];

    if (node is List) {
      for (final item in node) {
        if (item is Map) {
          out.add(
            item
                .map((k, v) => MapEntry(k.toString(), v))
                .cast<String, dynamic>(),
          );
        }
      }
      return out;
    }

    if (node is Map) {
      node.forEach((_, value) {
        if (value is Map) {
          out.add(
            value
                .map((k, v) => MapEntry(k.toString(), v))
                .cast<String, dynamic>(),
          );
        }
      });
      return out;
    }

    return out;
  }

  static Map<String, Map<String, dynamic>> _attendanceBySessionId(
    dynamic attendance,
  ) {
    final list = _mapToList(attendance);
    final out = <String, Map<String, dynamic>>{};
    for (final m in list) {
      final sid = (m['sessionId'] ?? '').toString().trim();
      if (sid.isEmpty) continue;
      out[sid] = m;
    }
    return out;
  }

  static int _asInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  static int _parseTotalSessions(String duration) {
    final m = RegExp(
      r'(\d+)\s*sessions',
      caseSensitive: false,
    ).firstMatch(duration);
    if (m == null) return 0;
    return int.tryParse(m.group(1) ?? '') ?? 0;
  }
}

class _MiniState extends StatelessWidget {
  const _MiniState({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Text(text, style: const TextStyle(fontWeight: FontWeight.w800)),
      ),
    );
  }
}

class _MinimalStaff {
  _MinimalStaff({
    required this.firstName,
    required this.lastName,
    required this.email,
  });

  final String firstName;
  final String lastName;
  final String email;

  String get fullName => '${firstName.trim()} ${lastName.trim()}'.trim();
}
