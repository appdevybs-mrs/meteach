import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:http/http.dart' as http;
import '../shared/app_feedback.dart';
import '../shared/human_error.dart';
import '../shared/payment_status.dart';
import '../shared/profile_avatar.dart';
import '../shared/admin_web_layout.dart';
import '../shared/ybs_busy_logo.dart';

import 'payment_dialog_shared.dart';
import 'admin_payments.dart';
import '../services/reminder_consistency_service.dart';
import '../services/audit_action_keys.dart';
import '../services/audit_log_service.dart';
import '../services/backend_api.dart';
import 'admin_learner_mail_topics_screen.dart';
import 'admin_classes.dart';

class AdminLearnersScreen extends StatefulWidget {
  const AdminLearnersScreen({super.key, this.initialSearch = ''});

  final String initialSearch;

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
  Timer? _searchDebounce;
  bool _webDenseMode = false;

  DatabaseReference get _usersRef => _db.ref(_usersPath);
  DatabaseReference get _deletedRef => _db.ref(_deletedPath);
  DatabaseReference get _blockedRef => _db.ref(_blockedPath);

  @override
  void initState() {
    super.initState();
    _search = widget.initialSearch.trim();
    _tab = TabController(length: 3, vsync: this);

    // broadcast streams once
    _usersStream = _usersRef.onValue.asBroadcastStream();
    _deletedStream = _deletedRef.onValue.asBroadcastStream();
    _blockedStream = _blockedRef.onValue.asBroadcastStream();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _tab.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      setState(() => _search = value);
    });
  }

  void _toast(String msg) {
    if (!mounted) return;

    AppToast.show(context, humanizeUiMessage(msg), type: AppToastType.info);
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

    final removeFromClasses = await _confirm(
      title: 'Also remove from classes?',
      message:
          'If this learner exists in class rosters, remove them there too.\n\nEmpty classes will be deleted automatically.',
      confirmText: 'Remove from classes',
      danger: true,
    );

    int removedFromClasses = 0;
    int removedClassesCount = 0;
    if (removeFromClasses) {
      final cleanup = await _removeLearnerFromAllClasses(uid);
      removedFromClasses = cleanup.removedFromClasses;
      removedClassesCount = cleanup.deletedClasses;
    }

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

    if (removeFromClasses) {
      _toast(
        'Moved to deleted 🗑️ • Removed from $removedFromClasses class(es)${removedClassesCount > 0 ? ' • Deleted $removedClassesCount empty class(es)' : ''}',
      );
      return;
    }

    _toast('Moved to deleted 🗑️');
  }

  Future<_ClassCleanupResult> _removeLearnerFromAllClasses(String uid) async {
    final snap = await _db.ref('classes').get();
    final v = snap.value;
    if (v is! Map) {
      return const _ClassCleanupResult(
        removedFromClasses: 0,
        deletedClasses: 0,
      );
    }

    final root = v.map((k, vv) => MapEntry('$k', vv));
    int removedFromClasses = 0;
    int deletedClasses = 0;

    final updates = <String, dynamic>{};
    root.forEach((classId, clsRaw) {
      if (clsRaw is! Map) return;
      final cls = clsRaw.map((k, vv) => MapEntry('$k', vv));
      final learnersRaw = cls['learners'];
      if (learnersRaw is! Map) return;

      final learners = learnersRaw.map((k, vv) => MapEntry('$k', vv));
      if (!learners.containsKey(uid)) return;

      removedFromClasses++;
      final left = learners.length - 1;
      if (left <= 0) {
        updates['classes/$classId'] = null;
        deletedClasses++;
      } else {
        updates['classes/$classId/learners/$uid'] = null;
      }
    });

    if (updates.isNotEmpty) {
      await _db.ref().update(updates);
    }

    return _ClassCleanupResult(
      removedFromClasses: removedFromClasses,
      deletedClasses: deletedClasses,
    );
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

    var loadingShown = false;
    try {
      if (mounted) {
        loadingShown = true;
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => const PopScope(
            canPop: false,
            child: AlertDialog(
              content: Row(
                children: [
                  YbsBusyLogo(size: 28),
                  SizedBox(width: 12),
                  Expanded(child: Text('Deleting learner...')),
                ],
              ),
            ),
          ),
        );
      }

      await _deleteAuthUserOnServer(uid);
      await fromRef.child(uid).remove();

      await _usersRef.child(uid).remove();
      await _deletedRef.child(uid).remove();
      await _blockedRef.child(uid).remove();

      _toast('Deleted permanently ✅');
    } catch (e) {
      _toast(toHumanError(e));
    } finally {
      if (loadingShown && mounted) {
        try {
          Navigator.of(context, rootNavigator: true).pop();
        } catch (_) {}
      }
    }
  }

  Future<void> _deleteAuthUserOnServer(String targetUid) async {
    final uri = await BackendApi.withAuthQuery(
      BackendApi.uri('delete_auth_user_secure.php'),
    );
    final headers = await BackendApi.authHeaders();
    final authFields = await BackendApi.authFormFields();

    final response = await http
        .post(
          uri,
          headers: headers,
          body: <String, String>{...authFields, 'targetUid': targetUid},
        )
        .timeout(const Duration(seconds: 18));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Auth delete failed (HTTP ${response.statusCode}). ${response.body}',
      );
    }

    dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      throw Exception('Auth delete failed: invalid server response.');
    }

    if (decoded is! Map || decoded['success'] != true) {
      final message = decoded is Map
          ? (decoded['message']?.toString().trim() ?? 'Auth delete failed.')
          : 'Auth delete failed.';
      throw Exception(message);
    }
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
          unselectedLabelColor: AdminLearnersScreen.primaryBlue.withValues(
            alpha: 0.55,
          ),
          indicatorColor: AdminLearnersScreen.primaryBlue,
          tabs: const [
            Tab(text: 'Users'),
            Tab(text: 'Deleted'),
            Tab(text: 'Blocked'),
          ],
        ),
        actions: [
          const SizedBox.shrink(),
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
          if (kIsWeb)
            IconButton(
              tooltip: _webDenseMode ? 'Comfort mode' : 'Dense mode',
              icon: Icon(
                _webDenseMode
                    ? Icons.view_agenda_rounded
                    : Icons.density_small_rounded,
                color: AdminLearnersScreen.primaryBlue,
              ),
              onPressed: () => setState(() => _webDenseMode = !_webDenseMode),
            ),
          AnimatedBuilder(
            animation: _tab,
            builder: (_, _) {
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
      body: adminWebBodyFrame(
        context: context,
        maxWidth: 1560,
        child: TabBarView(
          controller: _tab,
          children: [
            _LearnersList(
              titleHint: 'Search learners…',
              stream: _usersStream,
              webDenseMode: _webDenseMode,
              search: _search,
              statusFilter: _statusFilter,
              onSearchChanged: _onSearchChanged,
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
                    learner.status == LearnerStatus.paused
                        ? 'Activate'
                        : 'Pause',
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
              webDenseMode: _webDenseMode,
              search: _search,
              statusFilter: null,
              onSearchChanged: _onSearchChanged,
              onStatusFilterChanged: (_) {},
              actionsBuilder: (_, _) => const [
                PopupMenuItem(
                  value: _RowAction.restore,
                  child: Text('Restore'),
                ),
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
              webDenseMode: _webDenseMode,
              search: _search,
              statusFilter: null,
              onSearchChanged: _onSearchChanged,
              onStatusFilterChanged: (_) {},
              actionsBuilder: (_, _) => const [
                PopupMenuItem(
                  value: _RowAction.restore,
                  child: Text('Unblock'),
                ),
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
      ),
    );
  }
}

enum _PayFlag { ok, yellow, red, black, exempt, noCourse }

enum _RowAction { edit, pause, delete, block, restore, deleteForever }

enum _QuickLearnerReminder { payment, absence, late, empty }

enum _QuickSmsTemplate { empty, welcome, paymentReminder, absence, schedule }

class _LearnersList extends StatefulWidget {
  const _LearnersList({
    required this.titleHint,
    required this.stream,
    required this.webDenseMode,
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
  final bool webDenseMode;

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
  late final Stream<Map<String, int>> _unreadByLearnerStream;
  final Map<String, _PayFlag> _payFlagCache = <String, _PayFlag>{};
  final Set<String> _payFlagLoading = <String>{};

  @override
  void initState() {
    super.initState();
    _unreadByLearnerStream = _unreadByLearnerMapStream();
  }

  @override
  bool get wantKeepAlive => true;

  void _toast(String msg) {
    if (!mounted) return;

    AppToast.show(context, humanizeUiMessage(msg), type: AppToastType.info);
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
            ListTile(
              leading: const Icon(Icons.payments_rounded),
              title: const Text('Payment Reminder'),
              onTap: () =>
                  Navigator.pop(ctx, _QuickSmsTemplate.paymentReminder),
            ),
            ListTile(
              leading: const Icon(Icons.favorite_outline_rounded),
              title: const Text('Absence (We miss you)'),
              onTap: () => Navigator.pop(ctx, _QuickSmsTemplate.absence),
            ),
            ListTile(
              leading: const Icon(Icons.calendar_today_rounded),
              title: const Text('Schedule'),
              onTap: () => Navigator.pop(ctx, _QuickSmsTemplate.schedule),
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
          'مرحباً ${learner.firstName.trim().isEmpty ? 'عزيزي الطالب' : learner.firstName.trim()}،',
          'أهلاً بك في تطبيق "Your Bridge School".',
          'يمكنك تسجيل الدخول باستخدام:',
          if (email.isNotEmpty) 'البريد الإلكتروني: $email',
          'كلمة المرور: 12345678',
        ].join('\n');
        break;

      case _QuickSmsTemplate.paymentReminder:
        body = [
          'مرحباً ${learner.firstName.trim().isEmpty ? 'عزيزي الطالب' : learner.firstName.trim()}،',
          'تذكير لطيف برسوم الدورة عند وقتك المناسب.',
          'إذا تم الدفع بالفعل، يرجى تجاهل هذه الرسالة. شكراً لك.',
        ].join('\n');
        break;

      case _QuickSmsTemplate.absence:
        body = [
          'مرحباً ${learner.firstName.trim().isEmpty ? 'عزيزي الطالب' : learner.firstName.trim()}،',
          'اشتقنا لوجودك في الحصة ونتمنى أنك بخير.',
          'إذا احتجت أي مساعدة للمتابعة، نحن دائماً معك.',
        ].join('\n');
        break;

      case _QuickSmsTemplate.schedule:
        if (!mounted) return;
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (_) => const Center(child: CircularProgressIndicator()),
        );
        final scheduleBody = await _buildScheduleMessage(learner);
        if (mounted) Navigator.of(context).pop();
        if (!mounted) return;
        await _launchSms(phone: phone, body: scheduleBody);
        return;
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

    final uri = text.isEmpty
        ? Uri.parse('sms:$p')
        : Uri.parse('sms:$p?body=${Uri.encodeComponent(text)}');

    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);

      if (!ok && mounted) {
        _toast('SMS app not available. Text is copied ✅');
      }
    } catch (_) {
      if (mounted) _toast('SMS app not available. Text is copied ✅');
    }
  }

  Future<String> _buildScheduleMessage(Learner learner) async {
    final fullName = learner.fullName;
    final coursesSnap = await _db.ref('users/${learner.uid}/courses').get();
    final coursesRaw = coursesSnap.value;

    final lines = <String>[];
    lines.add('الطالب: $fullName');

    if (coursesRaw is Map) {
      final courseList = <Map<String, dynamic>>[];
      coursesRaw.forEach((_, val) {
        if (val is Map) {
          courseList.add(
            val
                .map((k, v) => MapEntry(k.toString(), v))
                .cast<String, dynamic>(),
          );
        }
      });

      for (final course in courseList) {
        final variantKey = _normalizeVariantKey(
          (course['variantKey'] ?? course['variant'] ?? 'inclass').toString(),
        );

        if (variantKey != 'inclass' && variantKey != 'private') continue;

        final title = (course['title'] ?? '').toString().trim();
        final classMap = course['class'];
        if (classMap is! Map) continue;
        final classId = (classMap['class_id'] ?? '').toString().trim();
        if (classId.isEmpty) continue;

        final schedSnap = await _db.ref('classes/$classId/schedule').get();
        final schedRaw = schedSnap.value;
        if (schedRaw is! Map) continue;

        final sessionsRaw = schedRaw['sessions'];
        final sessions = <Map<String, dynamic>>[];
        if (sessionsRaw is List) {
          for (final s in sessionsRaw) {
            if (s is Map) {
              sessions.add(
                s
                    .map((k, v) => MapEntry(k.toString(), v))
                    .cast<String, dynamic>(),
              );
            }
          }
        }
        if (sessions.isEmpty) continue;

        final parts = sessions
            .map((s) {
              final day = (s['day'] ?? '').toString().trim();
              final start = (s['start_time'] ?? '').toString().trim();
              if (day.isEmpty && start.isEmpty) return '';
              if (day.isEmpty) return start;
              if (start.isEmpty) return day;
              return '$day $start';
            })
            .where((e) => e.trim().isNotEmpty)
            .toList();

        if (parts.isEmpty) continue;

        if (title.isNotEmpty) {
          lines.add(title);
        }
        lines.add(parts.join(' • '));
      }
    }

    if (lines.length <= 1) {
      lines.add('لا يوجد جدول محدد حالياً.');
    }

    return lines.join('\n');
  }

  String get _adminUid => FirebaseAuth.instance.currentUser?.uid ?? '';

  Stream<Map<String, int>> _unreadByLearnerMapStream() {
    final q = FirebaseDatabase.instance.ref('mail_index/$_adminUid');

    return q.onValue.map((event) {
      final v = event.snapshot.value;
      if (v is! Map) return const <String, int>{};

      int toInt(dynamic x) {
        if (x is int) return x;
        if (x is num) return x.toInt();
        return int.tryParse(x?.toString() ?? '') ?? 0;
      }

      final out = <String, int>{};
      v.forEach((_, raw) {
        if (raw is! Map) return;
        final m = raw.map((k, vv) => MapEntry(k.toString(), vv));
        if (m['deletedAt'] != null) return;

        final peerUid = (m['peerUid'] ?? '').toString().trim();
        if (peerUid.isEmpty) return;

        final unread = toInt(m['unreadCount']);
        if (unread <= 0) return;
        out[peerUid] = (out[peerUid] ?? 0) + unread;
      });
      return out;
    }).asBroadcastStream();
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

  Future<void> _loadPayFlagForUid(String uid) async {
    final key = uid.trim();
    if (key.isEmpty) return;
    if (_payFlagCache.containsKey(key)) return;
    if (_payFlagLoading.contains(key)) return;

    _payFlagLoading.add(key);

    try {
      final snap = await _db.ref('users/$key/courses').get();
      final v = snap.value;
      if (v is! Map) {
        if (!mounted) return;
        setState(() => _payFlagCache[key] = _PayFlag.noCourse);
        return;
      }

      final courseMaps = <Map<String, dynamic>>[];
      v.forEach((_, courseVal) {
        if (courseVal is! Map) return;
        courseMaps.add(
          courseVal
              .map((k, vv) => MapEntry(k.toString(), vv))
              .cast<String, dynamic>(),
        );
      });

      _PayFlag best = _PayFlag.ok;

      int rank(_PayFlag f) {
        switch (f) {
          case _PayFlag.black:
            return 4;
          case _PayFlag.red:
            return 3;
          case _PayFlag.yellow:
            return 2;
          case _PayFlag.exempt:
            return 1;
          case _PayFlag.ok:
          case _PayFlag.noCourse:
            return 0;
        }
      }

      for (final courseMap in courseMaps) {
        final flag = _variantPaymentFlag(courseMap);
        if (rank(flag) > rank(best)) best = flag;
        if (best == _PayFlag.black) break;
      }

      if (!mounted) return;
      setState(() => _payFlagCache[key] = best);
    } catch (_) {
      // Keep UI responsive; skip flag on transient failures.
    } finally {
      _payFlagLoading.remove(key);
    }
  }

  void _prefetchPayFlags(List<_LearnerRow> rows) {
    if (rows.isEmpty) return;
    final uids = rows.map((r) => r.uid.trim()).where((u) => u.isNotEmpty);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final uid in uids) {
        if (_payFlagCache.containsKey(uid)) continue;
        if (_payFlagLoading.contains(uid)) continue;
        unawaited(_loadPayFlagForUid(uid));
      }
    });
  }

  Future<List<_LearnerClassLink>> _loadLearnerClassLinks(String uid) async {
    final key = uid.trim();
    if (key.isEmpty) return const <_LearnerClassLink>[];

    final snap = await _db.ref('users/$key/courses').get();
    final raw = snap.value;
    if (raw is! Map) return const <_LearnerClassLink>[];

    final out = <_LearnerClassLink>[];
    final seen = <String>{};

    raw.forEach((_, value) {
      if (value is! Map) return;
      final course = value
          .map((k, v) => MapEntry(k.toString(), v))
          .cast<String, dynamic>();

      final classMap = course['class'];
      if (classMap is! Map) return;

      final classId = (classMap['class_id'] ?? '').toString().trim();
      if (classId.isEmpty) return;
      if (!seen.add(classId)) return;

      final courseTitle = (course['title'] ?? '').toString().trim();
      final courseCode = (course['course_code'] ?? '').toString().trim();

      out.add(
        _LearnerClassLink(
          classId: classId,
          courseTitle: courseTitle,
          courseCode: courseCode,
        ),
      );
    });

    for (int i = 0; i < out.length; i++) {
      final link = out[i];
      try {
        final classSnap = await _db.ref('classes/${link.classId}').get();
        if (!classSnap.exists || classSnap.value is! Map) continue;

        final cls = (classSnap.value as Map)
            .map((k, v) => MapEntry(k.toString(), v))
            .cast<String, dynamic>();

        final teacher = (cls['instructor'] ?? '').toString().trim();
        final schedule = _classSchedulePreview(cls);

        out[i] = link.copyWith(teacherName: teacher, schedulePreview: schedule);
      } catch (_) {
        // Ignore per-class fetch errors and keep base link available.
      }
    }

    return out;
  }

  String _classSchedulePreview(Map<String, dynamic> cls) {
    final schedRaw = cls['schedule'];
    if (schedRaw is! Map) return '';
    final sched = schedRaw.map((k, v) => MapEntry('$k', v));
    final sessionsRaw = sched['sessions'];
    if (sessionsRaw is! List || sessionsRaw.isEmpty) return '';

    final parts = <String>[];
    for (final s in sessionsRaw) {
      if (s is! Map) continue;
      final m = s.map((k, v) => MapEntry('$k', v));
      final day = (m['day'] ?? '').toString().trim();
      final start = (m['start_time'] ?? '').toString().trim();
      final duration = (m['duration_min'] ?? '').toString().trim();

      final chunk = [
        if (day.isNotEmpty) day,
        if (start.isNotEmpty) start,
        if (duration.isNotEmpty) '(${duration}m)',
      ].join(' ');

      if (chunk.isNotEmpty) parts.add(chunk);
      if (parts.length >= 2) break;
    }

    if (parts.isEmpty) return '';
    return parts.join(' • ');
  }

  Future<_LearnerClassLink?> _pickLearnerClass(
    String learnerName,
    List<_LearnerClassLink> links,
  ) async {
    if (!mounted) return null;

    return showDialog<_LearnerClassLink>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Choose class'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460, maxHeight: 360),
          child: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (learnerName.trim().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        learnerName,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: Colors.black.withValues(alpha: 0.7),
                        ),
                      ),
                    ),
                  ),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: links.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (ctx, i) {
                      final link = links[i];
                      final title = link.courseTitle.isNotEmpty
                          ? link.courseTitle
                          : (link.courseCode.isNotEmpty
                                ? link.courseCode
                                : 'Class');
                      final subtitleText = [
                        if (link.teacherName.isNotEmpty)
                          'Teacher: ${link.teacherName}',
                        if (link.schedulePreview.isNotEmpty)
                          link.schedulePreview,
                      ].join(' • ');
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          '$title • ${link.classId}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: subtitleText.isEmpty
                            ? null
                            : Text(
                                subtitleText,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                        onTap: () => Navigator.pop(ctx, link),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  Future<void> _openLearnerClassFromCard({
    required String uid,
    required String learnerName,
  }) async {
    try {
      final links = await _loadLearnerClassLinks(uid);
      if (!mounted) return;

      if (links.isEmpty) {
        _toast('No class linked for this learner.');
        return;
      }

      _LearnerClassLink? selected;
      if (links.length == 1) {
        selected = links.first;
      } else {
        selected = await _pickLearnerClass(learnerName, links);
      }

      if (!mounted || selected == null) return;
      final chosen = selected;

      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => AdminClassesScreen(openClassId: chosen.classId),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      _toast('Could not open class right now.');
    }
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
          legacyTarget: {
            'uid': uid,
            'name': learner.fullName,
            'email': learner.email,
            'role': 'learner',
          },
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
      _toast('RTDB write failed: $e');
      return;
    }

    try {
      await reminderRef.update({'status': 'new'});

      await AuditLogService.logSuccess(
        actionKey: AuditActionKeys.adminReminderSend,
        domain: AuditDomain.admin,
        summary: 'Admin saved ${type.name} reminder for ${learner.fullName}',
        actor: AuditActor(uid: admin?.uid, role: 'admin', name: admin?.email),
        target: AuditTarget(type: 'learner', uid: uid, name: learner.fullName),
        keywords: [uid, type.name, reminderRef.key ?? ''],
        context: {'reminderId': reminderRef.key ?? '', 'kind': type.name},
      );

      if (!mounted) return;
      _toast('$title saved ✅');
    } catch (e) {
      await AuditLogService.logFailure(
        actionKey: AuditActionKeys.adminReminderSend,
        domain: AuditDomain.admin,
        summary: 'Admin reminder save finalize failed for ${learner.fullName}',
        actor: AuditActor(uid: admin?.uid, role: 'admin', name: admin?.email),
        target: AuditTarget(type: 'learner', uid: uid, name: learner.fullName),
        keywords: [uid, type.name, reminderRef.key ?? ''],
        context: {'reminderId': reminderRef.key ?? '', 'kind': type.name},
        errorMessage: e.toString(),
      );

      if (!mounted) return;
      _toast('Reminder saved, but final status update failed');
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
              leading: const Icon(Icons.access_time_rounded),
              title: const Text('Late'),
              onTap: () => Navigator.pop(ctx, _QuickLearnerReminder.late),
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

    if (isPaymentDueBySessions(
      sessionsPaidTotal: sessionsPaidTotal,
      sessionsPresent: sessionsDone,
    )) {
      return _PayFlag.red;
    }

    if (isPaymentWarningBySessions(
      sessionsPaidTotal: sessionsPaidTotal,
      sessionsPresent: sessionsDone,
      remindBeforeSession: remindBeforeSession,
    )) {
      return _PayFlag.yellow;
    }

    return _PayFlag.ok;
  }

  int _flexibleSessionsConsumedFromCourseMap(Map<String, dynamic> courseMap) {
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

    return countHeldUniqueAttendanceDates(courseMap['attendance']);
  }

  _PayFlag _variantPaymentFlag(Map<String, dynamic> courseMap) {
    if (courseIsFreeBilling(courseMap)) return _PayFlag.exempt;

    final variantKey = _normalizeVariantKey(
      (courseMap['variantKey'] ?? courseMap['variant'] ?? 'inclass').toString(),
    );

    final paymentSummary = courseMap['payment_summary'];
    final summaryMap = paymentSummary is Map
        ? paymentSummary.map((k, v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};

    final attendance = courseMap['attendance'];
    final classInfo = courseMap['class'];
    final classMap = classInfo is Map
        ? classInfo.map((k, v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};
    final classId = (classMap['class_id'] ?? courseMap['class_id'] ?? '')
        .toString()
        .trim();
    final sessionsDone = switch (variantKey) {
      'inclass' => countHeldAttendanceRecords(attendance),
      'private' => countPrivateConsumedAttendanceRecords(
        attendance,
        classId: classId,
      ),
      'flexible' => _flexibleSessionsConsumedFromCourseMap(courseMap),
      _ => _LearnerExpandedTabsState._countUniqueAttendance(attendance),
    };

    final sessionsPaidTotal = _LearnerExpandedTabsState._asInt(
      summaryMap['sessionsPaidTotal'],
    );
    final totalPaid = _LearnerExpandedTabsState._asInt(summaryMap['totalPaid']);
    final lastAmount = _LearnerExpandedTabsState._asInt(
      summaryMap['lastAmount'],
    );
    final lastPaymentAt = _LearnerExpandedTabsState._asInt(
      summaryMap['lastPaymentAt'],
    );
    final hasPaymentHistory =
        totalPaid > 0 || lastAmount > 0 || lastPaymentAt > 0;
    final effectiveSessionsPaidTotal = sessionsPaidTotal > 0
        ? sessionsPaidTotal
        : (hasPaymentHistory &&
                  (_normalizeVariantKey(variantKey) == 'private' ||
                      _normalizeVariantKey(variantKey) == 'inclass')
              ? 8
              : 0);
    final remindBeforeSession = _LearnerExpandedTabsState._asInt(
      summaryMap['remindBeforeSession'],
    );

    if (_variantIsRecorded(variantKey)) {
      final access = courseMap['recorded_access'];
      final accessMap = access is Map
          ? access.map((k, v) => MapEntry(k.toString(), v))
          : <String, dynamic>{};

      final accessExpiresAt = _LearnerExpandedTabsState._asInt(
        accessMap['expiresAt'],
      );
      final summaryExpiresAt = _LearnerExpandedTabsState._asInt(
        summaryMap['expiresAt'],
      );
      final effectiveExpiresAt = accessExpiresAt > 0
          ? accessExpiresAt
          : summaryExpiresAt;

      if (effectiveExpiresAt <= 0) return _PayFlag.black;
      if (_isExpiredMs(effectiveExpiresAt)) return _PayFlag.red;
      if (_isNearExpiryMs(effectiveExpiresAt)) return _PayFlag.yellow;
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

      if (effectiveSessionsPaidTotal <= 0 && expiresAt <= 0) {
        return _PayFlag.black;
      }
      if (expiresAt > 0 && _isExpiredMs(expiresAt)) return _PayFlag.red;
      if (isPaymentDueBySessions(
        sessionsPaidTotal: effectiveSessionsPaidTotal,
        sessionsPresent: sessionsDone,
      )) {
        return _PayFlag.red;
      }
      if (expiresAt > 0 && _isNearExpiryMs(expiresAt, days: 10)) {
        return _PayFlag.yellow;
      }
      if (isPaymentWarningBySessions(
        sessionsPaidTotal: effectiveSessionsPaidTotal,
        sessionsPresent: sessionsDone,
        remindBeforeSession: normalizeReminderForSessions(
          sessionsPaidTotal: effectiveSessionsPaidTotal,
          remindBeforeSession: remindBeforeSession > 0
              ? remindBeforeSession
              : 2,
        ),
      )) {
        return _PayFlag.yellow;
      }
      return _PayFlag.ok;
    }

    return _sessionPaymentFlag(
      sessionsPaidTotal: effectiveSessionsPaidTotal,
      sessionsDone: sessionsDone,
      remindBeforeSession: normalizeReminderForSessions(
        sessionsPaidTotal: effectiveSessionsPaidTotal,
        remindBeforeSession: remindBeforeSession,
      ),
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
                separatorBuilder: (_, _) => const SizedBox(width: 8),
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
                          (l.gender?.value.toLowerCase() ?? '').contains(s) ||
                          l.nationalIdNumber.toLowerCase().contains(s) ||
                          l.phone1.toLowerCase().contains(s) ||
                          l.phone2.toLowerCase().contains(s);

                final matchesStatus = widget.statusFilter == null
                    ? true
                    : (l.status == widget.statusFilter);

                return matchesSearch && matchesStatus;
              }).toList();

              _prefetchPayFlags(filtered);

              if (filtered.isEmpty) {
                return const _StateCard(
                  title: 'No learners',
                  message: 'No results match your filters.',
                  icon: Icons.people_outline,
                );
              }

              return StreamBuilder<Map<String, int>>(
                stream: _unreadByLearnerStream,
                builder: (context, unreadSnap) {
                  final unreadByLearner =
                      unreadSnap.data ?? const <String, int>{};

                  return ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                    itemCount: filtered.length,
                    itemBuilder: (context, i) {
                      final row = filtered[i];
                      final l = row.learner;
                      final isExpanded = _expandedUid == row.uid;
                      final unread = unreadByLearner[row.uid] ?? 0;

                      final flag = _payFlagCache[row.uid] ?? _PayFlag.ok;

                      Color avatarBg;
                      Color avatarFg;
                      Color rowBorderColor = AdminLearnersScreen.uiBorders;
                      Color rowBgColor = Colors.white;

                      switch (flag) {
                        case _PayFlag.noCourse:
                          avatarBg = Colors.blue;
                          avatarFg = Colors.white;
                          rowBorderColor = Colors.blue.withValues(alpha: 0.45);
                          rowBgColor = Colors.blue.withValues(alpha: 0.03);
                          break;
                        case _PayFlag.exempt:
                          avatarBg = const Color(0xFF157A3D);
                          avatarFg = Colors.white;
                          rowBorderColor = const Color(
                            0xFF157A3D,
                          ).withValues(alpha: 0.50);
                          rowBgColor = const Color(
                            0xFF157A3D,
                          ).withValues(alpha: 0.06);
                          break;
                        case _PayFlag.black:
                          avatarBg = Colors.black;
                          avatarFg = Colors.white;
                          rowBorderColor = Colors.black.withValues(alpha: 0.65);
                          rowBgColor = Colors.black.withValues(alpha: 0.03);
                          break;
                        case _PayFlag.red:
                          avatarBg = Colors.red;
                          avatarFg = Colors.white;
                          rowBorderColor = Colors.red.withValues(alpha: 0.50);
                          rowBgColor = Colors.red.withValues(alpha: 0.03);
                          break;
                        case _PayFlag.yellow:
                          avatarBg = Colors.orange;
                          avatarFg = Colors.white;
                          rowBorderColor = Colors.orange.withValues(
                            alpha: 0.45,
                          );
                          rowBgColor = Colors.orange.withValues(alpha: 0.03);
                          break;
                        case _PayFlag.ok:
                          avatarBg = AdminLearnersScreen.appBg;
                          avatarFg = AdminLearnersScreen.primaryBlue;
                          break;
                      }

                      String compactLine2() {
                        final parts = <String>[];
                        if ((l.gender?.value ?? '').trim().isNotEmpty) {
                          parts.add('Gender ${l.gender!.value}');
                        }
                        if (l.dob.trim().isNotEmpty) parts.add('🎂 ${l.dob}');
                        if (l.phone2.trim().isNotEmpty) {
                          parts.add('📞2 ${l.phone2}');
                        }
                        return parts.join('  •  ');
                      }

                      final dense = widget.webDenseMode && kIsWeb;

                      return Container(
                        margin: EdgeInsets.only(bottom: dense ? 7 : 10),
                        decoration: BoxDecoration(
                          color: rowBgColor,
                          borderRadius: BorderRadius.circular(dense ? 12 : 16),
                          border: Border.all(color: rowBorderColor),
                        ),
                        child: Column(
                          children: [
                            InkWell(
                              borderRadius: BorderRadius.circular(16),
                              onTap: () {
                                final expandTo = isExpanded ? null : row.uid;
                                setState(() {
                                  _expandedUid = expandTo;
                                });
                                if (expandTo != null) {
                                  _loadPayFlagForUid(row.uid);
                                }
                              },
                              onDoubleTap: () {
                                _openLearnerClassFromCard(
                                  uid: row.uid,
                                  learnerName: l.fullName,
                                );
                              },
                              child: Padding(
                                padding: EdgeInsets.all(dense ? 9 : 12),
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
                                      child: Stack(
                                        clipBehavior: Clip.none,
                                        children: [
                                          ProfileAvatar(
                                            name: l.fullName,
                                            photoUrl: l.primaryProfilePhoto,
                                            radius: dense ? 17 : 20,
                                            fallbackBg: avatarBg,
                                            fallbackFg: avatarFg,
                                            borderColor: avatarBg.withValues(
                                              alpha: 0.45,
                                            ),
                                          ),
                                          if (unread > 0)
                                            Positioned(
                                              right: -6,
                                              top: -6,
                                              child: _badge(unread),
                                            ),
                                        ],
                                      ),
                                    ),
                                    SizedBox(width: dense ? 9 : 12),
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
                                          SizedBox(height: dense ? 4 : 6),
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
                                                      fontSize: dense ? 11 : 12,
                                                      fontWeight:
                                                          FontWeight.w800,
                                                      color: AdminLearnersScreen
                                                          .primaryBlue
                                                          .withValues(
                                                            alpha: 0.9,
                                                          ),
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
                                                        fontSize: dense
                                                            ? 11
                                                            : 12,
                                                        fontWeight:
                                                            FontWeight.w800,
                                                        color: Colors.black
                                                            .withValues(
                                                              alpha: 0.65,
                                                            ),
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
                                                color: Colors.black.withValues(
                                                  alpha: 0.5,
                                                ),
                                              ),
                                            ),
                                          if (!dense) const SizedBox(height: 4),
                                          if (!dense &&
                                              compactLine2().isNotEmpty)
                                            Text(
                                              compactLine2(),
                                              style: TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w700,
                                                color: Colors.black.withValues(
                                                  alpha: 0.65,
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
                                          .withValues(alpha: 0.7),
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
                            AnimatedSize(
                              duration: const Duration(milliseconds: 180),
                              curve: Curves.easeOut,
                              alignment: Alignment.topCenter,
                              child: isExpanded
                                  ? Padding(
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
                                    )
                                  : const SizedBox.shrink(),
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

class _LearnerClassLink {
  const _LearnerClassLink({
    required this.classId,
    required this.courseTitle,
    required this.courseCode,
    this.teacherName = '',
    this.schedulePreview = '',
  });

  final String classId;
  final String courseTitle;
  final String courseCode;
  final String teacherName;
  final String schedulePreview;

  _LearnerClassLink copyWith({String? teacherName, String? schedulePreview}) {
    return _LearnerClassLink(
      classId: classId,
      courseTitle: courseTitle,
      courseCode: courseCode,
      teacherName: teacherName ?? this.teacherName,
      schedulePreview: schedulePreview ?? this.schedulePreview,
    );
  }
}

class _TopBar extends StatefulWidget {
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
  State<_TopBar> createState() => _TopBarState();
}

class _TopBarState extends State<_TopBar> {
  late final TextEditingController _searchC;

  @override
  void initState() {
    super.initState();
    _searchC = TextEditingController(text: widget.value);
  }

  @override
  void didUpdateWidget(covariant _TopBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != _searchC.text) {
      _searchC.value = TextEditingValue(
        text: widget.value,
        selection: TextSelection.collapsed(offset: widget.value.length),
      );
    }
  }

  @override
  void dispose() {
    _searchC.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Column(
        children: [
          TextField(
            controller: _searchC,
            onChanged: widget.onChanged,
            decoration: InputDecoration(
              hintText: widget.hint,
              prefixIcon: const Icon(Icons.search),
              suffixIcon: ValueListenableBuilder<TextEditingValue>(
                valueListenable: _searchC,
                builder: (_, value, child) {
                  final hasText = value.text.trim().isNotEmpty;
                  if (!hasText) return const SizedBox.shrink();
                  return IconButton(
                    tooltip: 'Clear search',
                    icon: const Icon(Icons.close_rounded, size: 18),
                    onPressed: () {
                      _searchC.clear();
                      widget.onChanged('');
                    },
                  );
                },
              ),
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
          if (widget.filters.isNotEmpty) ...[
            const SizedBox(height: 10),
            SizedBox(
              height: 38,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: widget.filters.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, i) {
                  final f = widget.filters[i];
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
                style: TextStyle(color: Colors.black.withValues(alpha: 0.7)),
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
    this.gender = '',
    this.phone1 = '',
    this.dob = '',
    this.email = '',

    this.selectedCourseIds = const <String>{},
  });

  final String firstName;
  final String lastName;
  final String gender;
  final String phone1;
  final String dob;
  final String email;
  final Set<String> selectedCourseIds;
}

enum LearnerGender {
  male,
  female;

  String get value {
    switch (this) {
      case LearnerGender.male:
        return 'Male';
      case LearnerGender.female:
        return 'Female';
    }
  }

  static LearnerGender? fromValue(String? raw) {
    switch ((raw ?? '').trim().toLowerCase()) {
      case 'male':
        return LearnerGender.male;
      case 'female':
        return LearnerGender.female;
      default:
        return null;
    }
  }
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
  late final TextEditingController nationalIdC;
  bool _serialUnlocked = false;

  DateTime? _dob;
  LearnerGender? _gender;
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
      if (p.dob.trim().isNotEmpty) dobC.text = p.dob.trim();
    }

    phone2C = TextEditingController(text: initial?.phone2 ?? '');
    emailC = TextEditingController(text: initial?.email ?? '');
    if (widget.mode == EditorMode.create && widget.prefill != null) {
      final p = widget.prefill!;
      if (p.email.trim().isNotEmpty) emailC.text = p.email.trim();
    }
    passwordC = TextEditingController(
      text: widget.mode == EditorMode.create ? '12345678' : '',
    );
    serialC = TextEditingController(text: initial?.serial ?? '');
    nationalIdC = TextEditingController(text: initial?.nationalIdNumber ?? '');

    _gender = initial?.gender;
    if (_gender == null &&
        widget.mode == EditorMode.create &&
        widget.prefill != null) {
      _gender = LearnerGender.fromValue(widget.prefill!.gender);
    }

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
    nationalIdC.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    if (!mounted) return;

    AppToast.show(context, humanizeUiMessage(msg), type: AppToastType.info);
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
      final nationalId = nationalIdC.text.trim();
      final dob = dobC.text.trim();
      final gender = _gender;
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
        gender: gender,
        dob: dob,
        phone1: phone1,
        phone2: phone2,
        email: email,
        serial: serial,
        nationalIdNumber: nationalId,
        role: 'learner',
        status: _status,
        updatedAtMs: null,
        profilePhoto: widget.initial?.profilePhoto ?? '',
        profilePhotos: widget.initial?.profilePhotos ?? const <String>[],
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

  Widget _buildResponsiveSections(List<Widget> sections) {
    final webWide = isWebDesktop(context, minWidth: 1200);
    if (!webWide) {
      return Column(
        children: [
          for (int i = 0; i < sections.length; i++) ...[
            if (i > 0) const SizedBox(height: 12),
            sections[i],
          ],
        ],
      );
    }

    return LayoutBuilder(
      builder: (context, c) {
        final itemWidth = ((c.maxWidth - 12) / 2).clamp(300.0, 620.0);
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final section in sections)
              SizedBox(width: itemWidth, child: section),
          ],
        );
      },
    );
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
        actions: [const SizedBox.shrink()],
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
          child: adminWebBodyFrame(
            context: context,
            maxWidth: 1380,
            child: _buildResponsiveSections([
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
                        if (!RegExp(r"^[a-zA-ZÀ-ÿ\s'-]+$").hasMatch(t)) {
                          return 'First name has invalid characters';
                        }
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
                        if (!RegExp(r"^[a-zA-ZÀ-ÿ\s'-]+$").hasMatch(t)) {
                          return 'Last name has invalid characters';
                        }
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
                        if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(t)) {
                          return 'Use format YYYY-MM-DD';
                        }
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
                    DropdownButtonFormField<LearnerGender>(
                      initialValue: _gender,
                      decoration: InputDecoration(
                        labelText: isEdit ? 'Gender' : 'Gender *',
                        hintText: 'Select gender',
                        filled: true,
                        fillColor: AdminLearnersScreen.appBg,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                        prefixIcon: const Icon(Icons.wc_rounded),
                      ),
                      items: LearnerGender.values
                          .map(
                            (g) => DropdownMenuItem(
                              value: g,
                              child: Text(g.value),
                            ),
                          )
                          .toList(),
                      validator: (v) {
                        if (!isEdit && v == null) {
                          return 'Gender is required';
                        }
                        return null;
                      },
                      onChanged: (v) {
                        setState(() => _gender = v);
                      },
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
                    const SizedBox(height: 12),
                    _TextField(
                      controller: nationalIdC,
                      label: 'National ID number',
                      hint: 'Optional',
                    ),
                  ],
                ),
              ),
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
                        if (digits.length < 9) {
                          return 'Phone number is too short';
                        }
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
                          if (t.length < 6) {
                            return 'Password must be at least 6 characters';
                          }
                          return null;
                        },
                      ),
                  ],
                ),
              ),
              _SectionCard(
                title: 'Status',
                child: DropdownButtonFormField<LearnerStatus>(
                  initialValue: _status,
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
            ]),
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
    this.keyboardType,
    this.validator,
    this.enabled = true,
    this.obscureText = false,
  });

  final TextEditingController controller;
  final String label;
  final String hint;
  final TextInputType? keyboardType;
  final String? Function(String?)? validator;
  final bool enabled;
  final bool obscureText;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      maxLines: 1,
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

class _ClassCleanupResult {
  const _ClassCleanupResult({
    required this.removedFromClasses,
    required this.deletedClasses,
  });

  final int removedFromClasses;
  final int deletedClasses;
}

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

class Learner {
  Learner({
    required this.uid,
    required this.firstName,
    required this.lastName,
    required this.gender,
    required this.dob,
    required this.phone1,
    required this.phone2,
    required this.email,
    required this.serial,
    required this.nationalIdNumber,
    required this.role,
    required this.status,
    required this.updatedAtMs,
    required this.profilePhoto,
    required this.profilePhotos,
    this.deleteAuth = false,
    this.selfDeleteDone = false,
  });

  final String uid;
  final String firstName;
  final String lastName;
  final LearnerGender? gender;
  final String dob;
  final String phone1;
  final String phone2;
  final String email;
  final String serial;
  final String nationalIdNumber;
  final String role;
  final LearnerStatus status;
  final int? updatedAtMs;
  final String profilePhoto;
  final List<String> profilePhotos;
  final bool deleteAuth;
  final bool selfDeleteDone;

  String get fullName => '${firstName.trim()} ${lastName.trim()}'.trim();

  String get primaryProfilePhoto {
    if (profilePhoto.trim().isNotEmpty) return profilePhoto.trim();
    for (final p in profilePhotos) {
      if (p.trim().isNotEmpty) return p.trim();
    }
    return '';
  }

  Map<String, dynamic> toMap() {
    return {
      'role': role,
      'first_name': firstName,
      'last_name': lastName,
      'gender': gender?.value ?? '',
      'dob': dob,
      'phone1': phone1,
      'phone2': phone2,
      'email': email,
      'serial': serial,
      'national_id_number': nationalIdNumber,
      'status': status.value,
      'updatedAt': updatedAtMs,
      'profile_photo': profilePhoto,
      'profile_photos': profilePhotos,
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
      gender: LearnerGender.fromValue((m['gender'] ?? '').toString()),
      dob: (m['dob'] ?? '').toString(),
      phone1: (m['phone1'] ?? '').toString(),
      phone2: (m['phone2'] ?? '').toString(),
      email: (m['email'] ?? '').toString(),
      serial: (m['serial'] ?? '').toString(),
      nationalIdNumber: (m['national_id_number'] ?? m['nationalIdNumber'] ?? '')
          .toString(),
      status: LearnerStatus.fromValue(m['status']?.toString()),
      updatedAtMs: parseInt(m['updatedAt']),
      profilePhoto: (m['profile_photo'] ?? '').toString().trim(),
      profilePhotos: _stringList(m['profile_photos']),
      deleteAuth:
          (m['deleteAuth'] == true) || (m['deleteAuth']?.toString() == 'true'),
      selfDeleteDone:
          (m['selfDeleteDone'] == true) ||
          (m['selfDeleteDone']?.toString() == 'true'),
    );
  }

  static List<String> _stringList(dynamic raw) {
    final out = <String>[];
    if (raw is List) {
      for (final item in raw) {
        final s = item.toString().trim();
        if (s.isNotEmpty) out.add(s);
      }
      return out;
    }
    if (raw is Map) {
      final entries = raw.entries.toList()
        ..sort((a, b) {
          final ai = int.tryParse(a.key.toString()) ?? 999999;
          final bi = int.tryParse(b.key.toString()) ?? 999999;
          return ai.compareTo(bi);
        });
      for (final e in entries) {
        final s = e.value.toString().trim();
        if (s.isNotEmpty) out.add(s);
      }
      return out;
    }
    final one = raw?.toString().trim() ?? '';
    if (one.isNotEmpty) out.add(one);
    return out;
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
  final Set<int> _loadedTabIndexes = <int>{0};

  String? _selectedCourseKey;
  Map<String, dynamic> _userCourses = {};

  Map<String, Map<String, dynamic>> _allCourses = {};
  bool _loadingAllCourses = false;
  final Set<String> _summaryRepairInFlight = <String>{};
  final Set<String> _summaryRepairQueued = <String>{};

  final Map<String, Future<DataSnapshot>> _courseSnapFutureCache =
      <String, Future<DataSnapshot>>{};
  final Map<String, Future<DataSnapshot>> _recordedSyllabusFutureCache =
      <String, Future<DataSnapshot>>{};
  final Map<String, Future<DataSnapshot>> _classAttendanceFutureCache =
      <String, Future<DataSnapshot>>{};

  void _toast(String msg) {
    if (!mounted) return;
    AppToast.show(context, humanizeUiMessage(msg), type: AppToastType.info);
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

  Future<DataSnapshot> _courseSnapshotFuture(String courseId) {
    final key = courseId.trim();
    return _courseSnapFutureCache.putIfAbsent(
      key,
      () => _coursesRef.child(key).get(),
    );
  }

  Future<DataSnapshot> _recordedSyllabusFuture(String courseId) {
    final key = courseId.trim();
    return _recordedSyllabusFutureCache.putIfAbsent(
      key,
      () => widget.db.ref('syllabi/$key/recorded').get(),
    );
  }

  Future<DataSnapshot> _classAttendanceFuture(String classId) {
    final key = classId.trim();
    return _classAttendanceFutureCache.putIfAbsent(
      key,
      () => widget.db.ref('classes/$key/attendance').get(),
    );
  }

  void _scheduleSummaryRepairIfNeeded({
    required String courseKey,
    required int summarySessionsPaidTotal,
    required int summaryTotalPaid,
    required int summaryLastPaymentAt,
    required int summaryLastAmount,
    required int summaryExpiresAt,
    required int summaryExpiryMonths,
    required int summaryDurationMonths,
    required int derivedSessionsPaidTotal,
    required int derivedTotalPaid,
    required int derivedLastPaymentAt,
    required int derivedLastAmount,
    required int derivedExpiresAt,
    required int derivedExpiryMonths,
    required int derivedDurationMonths,
  }) {
    final mismatch =
        summarySessionsPaidTotal != derivedSessionsPaidTotal ||
        summaryTotalPaid != derivedTotalPaid ||
        summaryLastPaymentAt != derivedLastPaymentAt ||
        summaryLastAmount != derivedLastAmount ||
        summaryExpiresAt != derivedExpiresAt ||
        summaryExpiryMonths != derivedExpiryMonths ||
        summaryDurationMonths != derivedDurationMonths;
    if (!mismatch) {
      _summaryRepairQueued.remove(courseKey);
      return;
    }
    if (_summaryRepairQueued.contains(courseKey)) return;

    _summaryRepairQueued.add(courseKey);
    unawaited(
      _maybeRepairLearnerCourseSummary(
        courseKey: courseKey,
        summarySessionsPaidTotal: summarySessionsPaidTotal,
        summaryTotalPaid: summaryTotalPaid,
        summaryLastPaymentAt: summaryLastPaymentAt,
        summaryLastAmount: summaryLastAmount,
        derivedSessionsPaidTotal: derivedSessionsPaidTotal,
        derivedTotalPaid: derivedTotalPaid,
        derivedLastPaymentAt: derivedLastPaymentAt,
        derivedLastAmount: derivedLastAmount,
      ).whenComplete(() {
        _summaryRepairQueued.remove(courseKey);
      }),
    );
  }

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 3, vsync: this);
    _tab.addListener(() {
      if (!mounted || _tab.indexIsChanging) return;
      setState(() {
        _loadedTabIndexes.add(_tab.index);
      });
    });
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
      if (existingIdOnKey.isEmpty || existingIdOnKey != courseId) {
        updates['$key/billingMode'] = 'paid';
      }

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

    if (!mounted) return;
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
                                      initialValue:
                                          variantByCourseId[id] ?? 'inclass',
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
                                        initialValue:
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
                if (dialogContext.mounted) Navigator.pop(dialogContext);
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
          unselectedLabelColor: AdminLearnersScreen.primaryBlue.withValues(
            alpha: 0.55,
          ),
          indicatorColor: AdminLearnersScreen.primaryBlue,
          tabs: [
            const Tab(text: 'Payment'),
            const Tab(text: 'Progress'),
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
                  _loadedTabIndexes.contains(0)
                      ? _paymentTab(context, keys)
                      : const SizedBox.shrink(),
                  _loadedTabIndexes.contains(1)
                      ? _attendanceTab(context, keys)
                      : const SizedBox.shrink(),
                  _loadedTabIndexes.contains(2)
                      ? _reportTab(context)
                      : const SizedBox.shrink(),
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
      initialValue: _selectedCourseKey,
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
    return isPaymentDueBySessions(
      sessionsPaidTotal: sessionsPaidTotal,
      sessionsPresent: sessionsDone,
    );
  }

  String _normToken(String s) => s.trim().toLowerCase();

  bool _isServicePayment(Map<String, dynamic> payment) {
    final teacher = (payment['teacherName'] ?? payment['teacher_name'] ?? '')
        .toString()
        .trim()
        .toLowerCase();
    return teacher == 'service';
  }

  bool _paymentMatchesCourse({
    required Map<String, dynamic> payment,
    required String courseKey,
    required String courseId,
    required String courseTitle,
    required String courseCode,
  }) {
    final payCourseKey = (payment['courseKey'] ?? '').toString();
    final payCourseId = (payment['course_id'] ?? payment['courseId'] ?? '')
        .toString();
    final keyMatch =
        courseKey.trim().isNotEmpty &&
        _normToken(payCourseKey) == _normToken(courseKey);
    final idMatch =
        courseId.trim().isNotEmpty &&
        _normToken(payCourseId) == _normToken(courseId);

    return keyMatch || idMatch;
  }

  Future<Map<String, int>> _latestPaymentExpiryForCourse({
    required String uid,
    required String courseKey,
    required String courseId,
    required String courseTitle,
    required String courseCode,
    required String variantKey,
  }) async {
    final out = <String, int>{
      'expiresAt': 0,
      'expiryMonths': 0,
      'durationMonths': 0,
      'sessionsPaidTotal': 0,
    };

    try {
      final snap = await _paymentsRef.orderByChild('uid').equalTo(uid).get();
      if (!snap.exists || snap.value is! Map) return out;

      final raw = Map<dynamic, dynamic>.from(snap.value as Map);
      var latestStamp = 0;
      for (final entry in raw.entries) {
        if (entry.value is! Map) continue;
        final p = Map<String, dynamic>.from(entry.value as Map);
        if (!_paymentMatchesCourse(
          payment: p,
          courseKey: courseKey,
          courseId: courseId,
          courseTitle: courseTitle,
          courseCode: courseCode,
        )) {
          continue;
        }

        if (_isServicePayment(p)) continue;

        final payVariant = _normalizeVariantKey(
          (p['variantKey'] ?? p['variant'] ?? '').toString(),
        );
        final sameVariant = payVariant == variantKey;
        final maybeLegacyExpiryRow =
            payVariant.isEmpty && (_asInt(p['expiresAt']) > 0);
        if (!(sameVariant || maybeLegacyExpiryRow)) continue;

        if (_variantUsesSessions(variantKey)) {
          out['sessionsPaidTotal'] =
              (out['sessionsPaidTotal'] ?? 0) + _asInt(p['sessionsPaid']);
        }

        final paidAt = _asInt(p['paidAt']);
        final createdAt = _asInt(p['createdAt']);
        final stamp = paidAt > 0 ? paidAt : createdAt;
        if (stamp < latestStamp) continue;

        latestStamp = stamp;
        out['expiresAt'] = _asInt(p['expiresAt']);
        out['expiryMonths'] = _asInt(p['expiryMonths']);
        out['durationMonths'] = _asInt(p['durationMonths']);
      }
    } catch (_) {
      return out;
    }

    return out;
  }

  Future<List<int>> _paymentSessionBoundariesForCourse({
    required String uid,
    required String courseKey,
    required String courseId,
    required String courseTitle,
    required String courseCode,
    required String variantKey,
  }) async {
    if (!_variantUsesSessions(variantKey)) return const <int>[];

    final rows = <Map<String, int>>[];
    var sequence = 0;
    try {
      final snap = await _paymentsRef.orderByChild('uid').equalTo(uid).get();
      if (!snap.exists || snap.value is! Map) return const <int>[];

      final raw = Map<dynamic, dynamic>.from(snap.value as Map);
      raw.forEach((_, value) {
        if (value is! Map) return;

        final pay = Map<String, dynamic>.from(value);
        if (!_paymentMatchesCourse(
          payment: pay,
          courseKey: courseKey,
          courseId: courseId,
          courseTitle: courseTitle,
          courseCode: courseCode,
        )) {
          return;
        }

        if (_isServicePayment(pay)) return;

        final payVariant = _normalizeVariantKey(
          (pay['variantKey'] ?? pay['deliveryKey'] ?? pay['variant'] ?? '')
              .toString(),
        );
        final sameVariant = payVariant == variantKey;
        final maybeLegacySessionRow =
            payVariant.isEmpty &&
            (variantKey == 'inclass' || variantKey == 'private');
        if (!(sameVariant || maybeLegacySessionRow)) return;

        var sessionsPaid = _asInt(pay['sessionsPaid']);
        final amount = _asInt(pay['amount']);
        if (sessionsPaid <= 0 &&
            amount > 0 &&
            (variantKey == 'inclass' || variantKey == 'private')) {
          sessionsPaid = 8;
        }
        if (sessionsPaid <= 0) return;

        final paidAt = _asInt(pay['paidAt']);
        final createdAt = _asInt(pay['createdAt']);
        final stamp = paidAt > 0 ? paidAt : createdAt;

        rows.add({
          'stamp': stamp,
          'sessionsPaid': sessionsPaid,
          'sortId': sequence,
        });
        sequence += 1;
      });
    } catch (_) {
      return const <int>[];
    }

    if (rows.isEmpty) return const <int>[];

    rows.sort((a, b) {
      final byStamp = _asInt(a['stamp']).compareTo(_asInt(b['stamp']));
      if (byStamp != 0) return byStamp;
      return _asInt(a['sortId']).compareTo(_asInt(b['sortId']));
    });

    final boundaries = <int>[];
    var cumulative = 0;
    for (final row in rows) {
      cumulative += _asInt(row['sessionsPaid']);
      if (cumulative > 0) boundaries.add(cumulative);
    }
    return boundaries;
  }

  bool _attendanceRowConsumesPaidSession({
    required String variantKey,
    required Map<String, dynamic>? learnerRec,
  }) {
    if (learnerRec == null) return false;

    final v = _normalizeVariantKey(variantKey);
    if (v == 'inclass') return true;
    if (v == 'private') return paymentRecordIsPresent(learnerRec);
    if (v == 'flexible') {
      return onlineAttendanceRecordConsumesCredit(learnerRec);
    }
    return false;
  }

  Widget _paymentBoundaryDivider(int paymentIndex) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Divider(
              height: 1,
              thickness: 1,
              color: AdminLearnersScreen.uiBorders,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            'Next payment block (${paymentIndex + 1})',
            style: TextStyle(
              color: Colors.black.withValues(alpha: 0.62),
              fontWeight: FontWeight.w800,
              fontSize: 12,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Divider(
              height: 1,
              thickness: 1,
              color: AdminLearnersScreen.uiBorders,
            ),
          ),
        ],
      ),
    );
  }

  Future<int> _sessionsConsumedForCourse({
    required String uid,
    required String courseId,
    required String variantKey,
    required String classId,
    required dynamic attendance,
  }) async {
    if (_variantIsFlexible(variantKey) && courseId.isNotEmpty) {
      try {
        final snap = await widget.db
            .ref('booking_progress/$uid/$courseId/online_attendance')
            .get();
        return countConsumedOnlineAttendance(snap.value);
      } catch (_) {
        return 0;
      }
    }

    final v = _normalizeVariantKey(variantKey);
    if (v == 'private') {
      return countPrivateConsumedAttendanceRecords(
        attendance,
        classId: classId,
      );
    }
    if (v == 'inclass') {
      return countHeldAttendanceRecords(attendance);
    }
    return countPresentUniqueAttendanceDates(attendance);
  }

  Future<void> _maybeRepairLearnerCourseSummary({
    required String courseKey,
    required int summarySessionsPaidTotal,
    required int summaryTotalPaid,
    required int summaryLastPaymentAt,
    required int summaryLastAmount,
    required int derivedSessionsPaidTotal,
    required int derivedTotalPaid,
    required int derivedLastPaymentAt,
    required int derivedLastAmount,
  }) async {
    final needsRepair =
        summarySessionsPaidTotal != derivedSessionsPaidTotal ||
        summaryTotalPaid != derivedTotalPaid ||
        summaryLastPaymentAt != derivedLastPaymentAt ||
        summaryLastAmount != derivedLastAmount;
    if (!needsRepair) return;

    final repairKey = '${widget.uid}|$courseKey';
    if (_summaryRepairInFlight.contains(repairKey)) return;

    _summaryRepairInFlight.add(repairKey);
    try {
      await PaymentDialogShared.repairLearnerCourseSummary(
        db: widget.db,
        uid: widget.uid,
        courseKey: courseKey,
      );
    } catch (_) {
      // ignore; UI still shows derived values
    } finally {
      _summaryRepairInFlight.remove(repairKey);
    }
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
    final classInfo = courseNode['class'];
    final classMap = classInfo is Map
        ? classInfo.map((k, v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};
    final classId = (classMap['class_id'] ?? courseNode['class_id'] ?? '')
        .toString()
        .trim();
    final sessionsDoneFuture = _sessionsConsumedForCourse(
      uid: widget.uid,
      courseId: courseId,
      variantKey: variantKey,
      classId: classId,
      attendance: attendance,
    );

    final flexibleAccessRaw = courseNode['flexible_access'];
    final flexibleAccess = flexibleAccessRaw is Map
        ? flexibleAccessRaw.map((k, v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};

    final recordedAccessRaw = courseNode['recorded_access'];
    final recordedAccess = recordedAccessRaw is Map
        ? recordedAccessRaw.map((k, v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};

    return FutureBuilder<int>(
      future: sessionsDoneFuture,
      builder: (context, consumedSnap) {
        final sessionsDone = consumedSnap.data ?? 0;

        return FutureBuilder<DataSnapshot>(
          key: ValueKey('payment-course-$courseId'),
          future: _courseSnapshotFuture(courseId),
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
            final courseTitleForMatch =
                (courseNode['title'] ?? courseMap['title'] ?? '').toString();
            final courseCodeForMatch =
                (courseNode['course_code'] ?? courseMap['course_code'] ?? '')
                    .toString();
            final latestPaymentMetaFuture = _latestPaymentExpiryForCourse(
              uid: widget.uid,
              courseKey: courseKey,
              courseId: courseId,
              courseTitle: courseTitleForMatch,
              courseCode: courseCodeForMatch,
              variantKey: variantKey,
            );

            return FutureBuilder<Map<String, int>>(
              future: latestPaymentMetaFuture,
              builder: (context, payMetaSnap) {
                final payMeta = payMetaSnap.data ?? const <String, int>{};

                return StreamBuilder<DatabaseEvent>(
                  key: ValueKey('payment-sum-$courseKey'),
                  stream: widget.db
                      .ref(
                        'users/${widget.uid}/courses/$courseKey/payment_summary',
                      )
                      .onValue,
                  builder: (context, sumSnap) {
                    final sumRaw = sumSnap.data?.snapshot.value;
                    final sum = sumRaw is Map
                        ? sumRaw.map((k, v) => MapEntry(k.toString(), v))
                        : <String, dynamic>{};

                    final sessionsPaidTotal = _asInt(sum['sessionsPaidTotal']);
                    final remindBeforeSession = _asInt(
                      sum['remindBeforeSession'],
                    );
                    final totalPaid = _asInt(sum['totalPaid']);
                    final lastAmount = _asInt(sum['lastAmount']);
                    final lastPaymentAt = _asInt(sum['lastPaymentAt']);
                    final hasPaymentHistory =
                        totalPaid > 0 || lastAmount > 0 || lastPaymentAt > 0;
                    final effectiveSessionsPaidTotal = sessionsPaidTotal > 0
                        ? sessionsPaidTotal
                        : (hasPaymentHistory &&
                                  (variantKey == 'private' ||
                                      variantKey == 'inclass')
                              ? 8
                              : 0);

                    final flexibleExpiresAt = _asInt(
                      flexibleAccess['expiresAt'],
                    );
                    final flexibleExpiryMonths = _asInt(
                      flexibleAccess['expiryMonths'],
                    );

                    final recordedExpiresAt = _asInt(
                      recordedAccess['expiresAt'],
                    );
                    final recordedDurationMonths = _asInt(
                      recordedAccess['durationMonths'],
                    );

                    final summaryExpiresAt = _asInt(sum['expiresAt']);
                    final summaryExpiryMonths = _asInt(sum['expiryMonths']);
                    final summaryDurationMonths = _asInt(sum['durationMonths']);
                    final paymentExpiresAt = _asInt(payMeta['expiresAt']);
                    final paymentExpiryMonths = _asInt(payMeta['expiryMonths']);
                    final paymentDurationMonths = _asInt(
                      payMeta['durationMonths'],
                    );
                    final paymentSessionsPaidTotal = _asInt(
                      payMeta['sessionsPaidTotal'],
                    );
                    final billingMode = normalizeBillingMode(
                      courseNode['billingMode'] ?? courseMap['billingMode'],
                    );
                    final isFreeCourse = billingMode == 'free';

                    final usesSessions = _variantUsesSessions(variantKey);
                    final usesReminder = _variantUsesReminder(variantKey);
                    final usesExpiry = _variantUsesExpiry(variantKey);

                    final due = usesReminder
                        ? _isSessionDue(
                            sessionsPaidTotal: effectiveSessionsPaidTotal,
                            sessionsDone: sessionsDone,
                            remindBeforeSession: remindBeforeSession > 0
                                ? remindBeforeSession
                                : 1,
                          )
                        : false;

                    final sessionsLeft =
                        effectiveSessionsPaidTotal - sessionsDone;
                    final overSessions = sessionsLeft < 0 ? -sessionsLeft : 0;
                    final effectivePaidTotalForDisplay =
                        effectiveSessionsPaidTotal > 0
                        ? effectiveSessionsPaidTotal
                        : (paymentSessionsPaidTotal > 0
                              ? paymentSessionsPaidTotal
                              : effectiveSessionsPaidTotal);
                    final sessionUsageDenominator =
                        effectivePaidTotalForDisplay > 0
                        ? effectivePaidTotalForDisplay
                        : 0;
                    final sessionUsageRatio = sessionUsageDenominator > 0
                        ? (sessionsDone / sessionUsageDenominator).clamp(
                            0.0,
                            1.0,
                          )
                        : 0.0;
                    final sessionWarnThreshold = remindBeforeSession > 0
                        ? remindBeforeSession
                        : 1;
                    final sessionUsageColor = overSessions > 0 || due
                        ? Colors.red
                        : (sessionsLeft > 0 &&
                                  sessionsLeft <= sessionWarnThreshold
                              ? const Color(0xFFB45309)
                              : const Color(0xFF157A3D));
                    final sessionUsageValueText = overSessions > 0
                        ? '$sessionsDone / $sessionUsageDenominator • Over $overSessions'
                        : '$sessionsDone / $sessionUsageDenominator • Left $sessionsLeft';

                    final expiresAt = _variantIsRecorded(variantKey)
                        ? (recordedExpiresAt > 0
                              ? recordedExpiresAt
                              : (summaryExpiresAt > 0
                                    ? summaryExpiresAt
                                    : paymentExpiresAt))
                        : (flexibleExpiresAt > 0
                              ? flexibleExpiresAt
                              : (summaryExpiresAt > 0
                                    ? summaryExpiresAt
                                    : paymentExpiresAt));
                    final monthsValue = _variantIsRecorded(variantKey)
                        ? (recordedDurationMonths > 0
                              ? recordedDurationMonths
                              : (summaryDurationMonths > 0
                                    ? summaryDurationMonths
                                    : paymentDurationMonths))
                        : (flexibleExpiryMonths > 0
                              ? flexibleExpiryMonths
                              : (summaryExpiryMonths > 0
                                    ? summaryExpiryMonths
                                    : paymentExpiryMonths));
                    final expiryText = expiresAt > 0
                        ? _fmtDateMs(expiresAt)
                        : '—';
                    final expired = usesExpiry
                        ? _isExpiredMs(expiresAt)
                        : false;
                    final nearExpiry = usesExpiry
                        ? _isNearExpiryMs(expiresAt)
                        : false;
                    final String compactVariant = variantText.trim().isEmpty
                        ? '-'
                        : variantText.trim().toLowerCase();
                    final String compactSessions = usesSessions
                        ? (totalSessions > 0
                              ? 'S: $sessionsDone/$totalSessions'
                              : 'S: $sessionsDone')
                        : 'S: -';

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
                              _miniPill(compactVariant),
                              _miniPill(compactSessions),
                              _miniPill('Total: $totalPaid'),
                              _miniPill(
                                isFreeCourse
                                    ? 'Billing: Free'
                                    : 'Billing: Paid',
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              color: isFreeCourse
                                  ? const Color(0xFFE9F8EF)
                                  : const Color(0xFFF7F7FB),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: isFreeCourse
                                    ? const Color(0xFFB7E5C5)
                                    : AdminLearnersScreen.uiBorders,
                              ),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'Billing mode',
                                    style: TextStyle(
                                      color: AdminLearnersScreen.primaryBlue,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                ),
                                Text(
                                  isFreeCourse ? 'Free' : 'Paid',
                                  style: TextStyle(
                                    color: isFreeCourse
                                        ? const Color(0xFF157A3D)
                                        : AdminLearnersScreen.primaryBlue,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Switch.adaptive(
                                  value: isFreeCourse,
                                  onChanged: (v) async {
                                    final enableFree = v;
                                    final ok = await _confirm(
                                      title: enableFree
                                          ? 'Set course to Free?'
                                          : 'Set course to Paid?',
                                      message: enableFree
                                          ? 'This will make this learner\'s course free. Continue?'
                                          : 'This will switch this learner\'s course back to paid billing. Continue?',
                                      confirmText: enableFree
                                          ? 'Set to Free'
                                          : 'Set to Paid',
                                    );
                                    if (!ok) return;

                                    await widget.db
                                        .ref(
                                          'users/${widget.uid}/courses/$courseKey',
                                        )
                                        .update({
                                          'billingMode': enableFree
                                              ? 'free'
                                              : 'paid',
                                        });
                                  },
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 6),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: AdminLearnersScreen.appBg,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: AdminLearnersScreen.uiBorders,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (usesSessions) ...[
                                  _compactProgressMetric(
                                    title: 'Session usage',
                                    valueText: sessionUsageValueText,
                                    value: sessionUsageRatio,
                                    valueColor: sessionUsageColor,
                                  ),
                                ],
                                if (usesSessions &&
                                    sessionsPaidTotal <= 0 &&
                                    hasPaymentHistory) ...[
                                  const SizedBox(height: 6),
                                  Text(
                                    'Sessions are restored from payment history (legacy rows without sessions).',
                                    style: TextStyle(
                                      color: Colors.black.withValues(
                                        alpha: 0.62,
                                      ),
                                      fontWeight: FontWeight.w700,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                                if (usesExpiry) const SizedBox(height: 6),
                                if (usesExpiry)
                                  Text(
                                    _variantIsRecorded(variantKey)
                                        ? (monthsValue > 0
                                              ? 'Duration: $monthsValue months'
                                              : 'Duration: -')
                                        : (monthsValue > 0
                                              ? 'Expiry window: $monthsValue months'
                                              : 'Expiry window: -'),
                                    style: TextStyle(
                                      color: Colors.black.withValues(
                                        alpha: 0.75,
                                      ),
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                if (usesExpiry) const SizedBox(height: 2),
                                if (usesExpiry)
                                  Text(
                                    'Expires on: $expiryText',
                                    style: TextStyle(
                                      color: Colors.black.withValues(
                                        alpha: 0.75,
                                      ),
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                if (!isFreeCourse && due) ...[
                                  const SizedBox(height: 6),
                                  const Text(
                                    '⚠️ Payment is due now (all paid sessions consumed).',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                ],
                                if (!isFreeCourse && expired) ...[
                                  const SizedBox(height: 6),
                                  const Text(
                                    '⛔ Access expired.',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                ] else if (!isFreeCourse && nearExpiry) ...[
                                  const SizedBox(height: 6),
                                  const Text(
                                    '⚠️ Access is near expiry.',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          const SizedBox(height: 10),
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
                                      if (!_paymentMatchesCourse(
                                        payment: m.cast<String, dynamic>(),
                                        courseKey: courseKey,
                                        courseId: courseId,
                                        courseTitle: courseTitleForMatch,
                                        courseCode: courseCodeForMatch,
                                      )) {
                                        return;
                                      }
                                      items.add({
                                        'paymentId': k.toString(),
                                        ...m,
                                      });
                                    }
                                  });
                                }

                                items.sort(
                                  (a, b) => _asInt(
                                    b['paidAt'],
                                  ).compareTo(_asInt(a['paidAt'])),
                                );

                                if (items.isEmpty) {
                                  return const _MiniState(
                                    text: 'No payments yet.',
                                  );
                                }

                                int effectiveSessionsForPayment(
                                  Map<String, dynamic> pay,
                                ) {
                                  if (_isServicePayment(pay)) return 0;

                                  final payVariant = _normalizeVariantKey(
                                    (pay['variantKey'] ??
                                            pay['deliveryKey'] ??
                                            pay['variant'] ??
                                            variantKey)
                                        .toString(),
                                  );
                                  if (!_variantUsesSessions(payVariant)) {
                                    return 0;
                                  }

                                  var sp = _asInt(pay['sessionsPaid']);
                                  final amount = _asInt(pay['amount']);
                                  if (sp <= 0 &&
                                      amount > 0 &&
                                      (payVariant == 'private' ||
                                          payVariant == 'inclass')) {
                                    sp = 8;
                                  }
                                  return sp;
                                }

                                final oldestFirst = [...items]
                                  ..sort(
                                    (a, b) => _asInt(
                                      a['paidAt'],
                                    ).compareTo(_asInt(b['paidAt'])),
                                  );

                                var remainingToConsume = sessionsDone;
                                final perPaymentLeft = <String, int>{};
                                var derivedSessionsPaidTotal = 0;
                                var derivedTotalPaid = 0;
                                var derivedLastPaymentAt = 0;
                                var derivedLastAmount = 0;
                                var derivedLastExpiresAt = 0;
                                var derivedLastExpiryMonths = 0;
                                var derivedLastDurationMonths = 0;
                                for (final pay in oldestFirst) {
                                  final pid = (pay['paymentId'] ?? '')
                                      .toString();
                                  if (pid.isEmpty) continue;

                                  final sp = effectiveSessionsForPayment(pay);
                                  final isServicePayment = _isServicePayment(
                                    pay,
                                  );
                                  if (!isServicePayment) {
                                    derivedSessionsPaidTotal += sp;
                                  }
                                  final amount = _asInt(pay['amount']);
                                  if (!isServicePayment) {
                                    derivedTotalPaid += amount;
                                  }
                                  final paidAt = _asInt(pay['paidAt']);
                                  if (!isServicePayment &&
                                      paidAt >= derivedLastPaymentAt) {
                                    derivedLastPaymentAt = paidAt;
                                    derivedLastAmount = amount;
                                    derivedLastExpiresAt = _asInt(
                                      pay['expiresAt'],
                                    );
                                    derivedLastExpiryMonths = _asInt(
                                      pay['expiryMonths'],
                                    );
                                    derivedLastDurationMonths = _asInt(
                                      pay['durationMonths'],
                                    );
                                  }

                                  final consumed = remainingToConsume <= 0
                                      ? 0
                                      : (remainingToConsume >= sp
                                            ? sp
                                            : remainingToConsume);
                                  final leftAfterAllocation = sp - consumed;
                                  perPaymentLeft[pid] = leftAfterAllocation < 0
                                      ? 0
                                      : leftAfterAllocation;
                                  remainingToConsume -= consumed;
                                }

                                _scheduleSummaryRepairIfNeeded(
                                  courseKey: courseKey,
                                  summarySessionsPaidTotal: sessionsPaidTotal,
                                  summaryTotalPaid: totalPaid,
                                  summaryLastPaymentAt: lastPaymentAt,
                                  summaryLastAmount: lastAmount,
                                  summaryExpiresAt: summaryExpiresAt,
                                  summaryExpiryMonths: summaryExpiryMonths,
                                  summaryDurationMonths: summaryDurationMonths,
                                  derivedSessionsPaidTotal:
                                      derivedSessionsPaidTotal,
                                  derivedTotalPaid: derivedTotalPaid,
                                  derivedLastPaymentAt: derivedLastPaymentAt,
                                  derivedLastAmount: derivedLastAmount,
                                  derivedExpiresAt: derivedLastExpiresAt,
                                  derivedExpiryMonths: derivedLastExpiryMonths,
                                  derivedDurationMonths:
                                      derivedLastDurationMonths,
                                );

                                return ListView.builder(
                                  padding: EdgeInsets.zero,
                                  itemCount: items.length,
                                  itemBuilder: (context, i) {
                                    final p = items[i];
                                    final fee = _asInt(p['amount']);
                                    final method = (p['method'] ?? '')
                                        .toString();
                                    final notes = (p['notes'] ?? '').toString();

                                    final payVariant = _normalizeVariantKey(
                                      (p['variantKey'] ?? variantKey)
                                          .toString(),
                                    );
                                    final payStudyMode = (p['studyMode'] ?? '')
                                        .toString();
                                    final paidAt = _fmtDateMs(
                                      _asInt(p['paidAt']),
                                    );
                                    final startDate = (p['startDate'] ?? '')
                                        .toString()
                                        .trim();
                                    final expiresAt = _fmtDateMs(
                                      _asInt(p['expiresAt']),
                                    );
                                    final sp = _asInt(p['sessionsPaid']);
                                    final durationMonths = _asInt(
                                      p['durationMonths'],
                                    );
                                    final expiryMonths = _asInt(
                                      p['expiryMonths'],
                                    );
                                    final paymentId = (p['paymentId'] ?? '')
                                        .toString();

                                    final variantBadge =
                                        payVariant == 'private' &&
                                            payStudyMode.trim().isNotEmpty
                                        ? '${_variantLabel(payVariant)} • ${_studyModeLabel(payStudyMode)}'
                                        : _variantLabel(payVariant);

                                    final left = perPaymentLeft[paymentId] ?? 0;

                                    return Padding(
                                      padding: const EdgeInsets.only(bottom: 6),
                                      child: _miniCard(
                                        bg: Colors.white,
                                        borderColor:
                                            AdminLearnersScreen.uiBorders,
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Wrap(
                                              spacing: 8,
                                              runSpacing: 8,
                                              children: [
                                                _miniPill(variantBadge),
                                                _miniPill('Amt: $fee'),
                                                _miniPill(
                                                  paidAt.isEmpty ? '-' : paidAt,
                                                ),
                                                if (_variantUsesSessions(
                                                      payVariant,
                                                    ) &&
                                                    !_isServicePayment(p))
                                                  _miniPill('S: $sp'),
                                                if (_variantUsesReminder(
                                                      payVariant,
                                                    ) &&
                                                    !_isServicePayment(p))
                                                  _miniPill('L: $left'),
                                                if (_variantUsesStartDate(
                                                  payVariant,
                                                ))
                                                  _miniPill(
                                                    'St: ${startDate.isEmpty ? '-' : startDate}',
                                                  ),
                                                if (_variantIsFlexible(
                                                  payVariant,
                                                ))
                                                  _miniPill(
                                                    'Exp: ${expiresAt.isEmpty ? '-' : expiresAt}',
                                                  ),
                                                if (_variantIsFlexible(
                                                  payVariant,
                                                ))
                                                  _miniPill(
                                                    expiryMonths > 0
                                                        ? 'Win: $expiryMonths m'
                                                        : 'Win: -',
                                                  ),
                                                if (_variantIsRecorded(
                                                  payVariant,
                                                ))
                                                  _miniPill(
                                                    durationMonths > 0
                                                        ? 'Dur: $durationMonths m'
                                                        : 'Dur: -',
                                                  ),
                                                if (_variantIsRecorded(
                                                  payVariant,
                                                ))
                                                  _miniPill(
                                                    'Exp: ${expiresAt.isEmpty ? '-' : expiresAt}',
                                                  ),
                                              ],
                                            ),
                                            if (method.trim().isNotEmpty ||
                                                notes.trim().isNotEmpty) ...[
                                              const SizedBox(height: 6),
                                              Text(
                                                [
                                                  if (method.trim().isNotEmpty)
                                                    method,
                                                  if (notes.trim().isNotEmpty)
                                                    notes,
                                                ].join(' • '),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  color: Colors.black
                                                      .withValues(alpha: 0.65),
                                                  fontWeight: FontWeight.w700,
                                                  fontSize: 12,
                                                ),
                                              ),
                                            ],
                                            if (i == 0 &&
                                                usesSessions &&
                                                derivedSessionsPaidTotal > 0 &&
                                                derivedSessionsPaidTotal !=
                                                    effectiveSessionsPaidTotal) ...[
                                              const SizedBox(height: 6),
                                              Text(
                                                'Summary mismatch detected. History sessions: $derivedSessionsPaidTotal, summary: $effectiveSessionsPaidTotal.',
                                                style: TextStyle(
                                                  color: Colors.black
                                                      .withValues(alpha: 0.62),
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
        future: _recordedSyllabusFuture(courseId),
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

          final sessionItems = <Map<String, dynamic>>[];
          final rawModules = _asListOfMaps(root['modules']);
          if (rawModules.isNotEmpty) {
            for (int mi = 0; mi < rawModules.length; mi++) {
              final module = rawModules[mi];
              final moduleLabel =
                  (module['otherTitle'] ?? '').toString().trim().isNotEmpty
                  ? (module['otherTitle'] ?? '').toString().trim()
                  : ((module['title'] ?? '').toString().trim().isNotEmpty
                        ? (module['title'] ?? '').toString().trim()
                        : 'Module ${mi + 1}');
              final rawUnits = _asListOfMaps(module['units']);
              for (final unit in rawUnits) {
                final unitTitle = (unit['title'] ?? '').toString().trim();
                final rawLessons = _asListOfMaps(unit['lessons']);
                for (final lesson in rawLessons) {
                  sessionItems.add({
                    'unitTitle': unitTitle,
                    'moduleTitle': moduleLabel,
                    ...lesson,
                  });
                }
              }
            }
          } else {
            final rawUnits = _asListOfMaps(root['units']);
            for (final unit in rawUnits) {
              final unitTitle = (unit['title'] ?? '').toString().trim();
              final rawSessions = _asListOfMaps(unit['sessions']);

              for (final session in rawSessions) {
                sessionItems.add({'unitTitle': unitTitle, ...session});
              }
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
                        color: Colors.black.withValues(alpha: 0.75),
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
                      ? const Color(0xFF157A3D).withValues(alpha: 0.08)
                      : const Color(0xFF64748B).withValues(alpha: 0.08);

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
                                      color: Colors.black.withValues(
                                        alpha: 0.65,
                                      ),
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
                }),
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
      final totalSessions = _parseTotalSessions(
        (courseNode['duration'] ?? '').toString(),
      );
      final paymentBoundariesFuture = _paymentSessionBoundariesForCourse(
        uid: widget.uid,
        courseKey: courseKey,
        courseId: courseId,
        courseTitle: (courseNode['title'] ?? '').toString(),
        courseCode: (courseNode['course_code'] ?? '').toString(),
        variantKey: variantKey,
      );

      return FutureBuilder<DataSnapshot>(
        key: ValueKey('attendance-online-${widget.uid}-$courseId'),
        future: widget.db
            .ref('booking_progress/${widget.uid}/$courseId/online_attendance')
            .get(),
        builder: (context, progressSnap) {
          if (progressSnap.hasError) {
            return ListView(
              padding: EdgeInsets.zero,
              children: [
                _coursePicker(keys),
                const SizedBox(height: 8),
                const _MiniState(
                  text: 'No attendance recorded yet for this learner.',
                ),
              ],
            );
          }
          if (!progressSnap.hasData) {
            return ListView(
              padding: EdgeInsets.zero,
              children: const [
                SizedBox(height: 8),
                Center(child: CircularProgressIndicator(strokeWidth: 2)),
              ],
            );
          }

          final onlineRaw = progressSnap.data?.value;
          final consumedRows = <Map<String, dynamic>>[];
          if (onlineRaw is Map) {
            onlineRaw.forEach((_, value) {
              if (value is! Map) return;
              final m = value
                  .map((k, v) => MapEntry(k.toString(), v))
                  .cast<String, dynamic>();
              if (!onlineAttendanceRecordConsumesCredit(m)) return;
              consumedRows.add(m);
            });
          }

          int toTs(Map<String, dynamic> m) {
            final raw = m['startAt'] ?? m['updatedAt'] ?? m['createdAt'];
            if (raw is int) return raw;
            if (raw is num) return raw.toInt();
            return int.tryParse(raw?.toString() ?? '') ?? 0;
          }

          consumedRows.sort((a, b) => toTs(a).compareTo(toTs(b)));

          bool asBool(dynamic v) {
            if (v is bool) return v;
            final s = (v ?? '').toString().trim().toLowerCase();
            return s == 'true' || s == '1' || s == 'yes';
          }

          String formatWhen(Map<String, dynamic> m) {
            final dayKey = (m['dayKey'] ?? '').toString().trim();
            final time = (m['time'] ?? '').toString().trim();
            if (dayKey.isNotEmpty && time.isNotEmpty) return '$dayKey $time';
            if (dayKey.isNotEmpty) return dayKey;

            final ts = toTs(m);
            if (ts > 0) {
              final d = DateTime.fromMillisecondsSinceEpoch(ts);
              final mm = d.month.toString().padLeft(2, '0');
              final dd = d.day.toString().padLeft(2, '0');
              final hh = d.hour.toString().padLeft(2, '0');
              final mi = d.minute.toString().padLeft(2, '0');
              return '${d.year}-$mm-$dd $hh:$mi';
            }
            return '-';
          }

          return FutureBuilder<List<int>>(
            future: paymentBoundariesFuture,
            builder: (context, boundariesSnap) {
              final boundaries = boundariesSnap.data ?? const <int>[];
              final attendanceTiles = <Widget>[];
              var consumedCount = 0;
              var boundaryIndex = 0;

              for (final entry in consumedRows.asMap().entries) {
                final i = entry.key;
                final m = entry.value;

                while (boundaryIndex < boundaries.length &&
                    consumedCount >= boundaries[boundaryIndex]) {
                  attendanceTiles.add(_paymentBoundaryDivider(boundaryIndex));
                  boundaryIndex += 1;
                }

                final when = formatWhen(m);
                final sessionNo = _asInt(m['sessionNo']);
                final teacher = (m['teacherName'] ?? '').toString().trim();
                final statusRaw = (m['status'] ?? '')
                    .toString()
                    .trim()
                    .toLowerCase();
                final countedCredit = asBool(m['countedCredit']);
                final hasPresentFlag = m.containsKey('present');
                final present = asBool(m['present']) || statusRaw == 'present';
                final absent =
                    (!present && hasPresentFlag) || statusRaw == 'absent';

                final statusLabel = countedCredit
                    ? 'credit used'
                    : (present ? 'present' : (absent ? 'absent' : 'recorded'));
                final barColor = countedCredit
                    ? const Color(0xFFB45309)
                    : (present ? const Color(0xFF157A3D) : Colors.red);
                final tileColor = countedCredit
                    ? const Color(0xFFB45309).withValues(alpha: 0.08)
                    : (present
                          ? const Color(0xFF157A3D).withValues(alpha: 0.08)
                          : Colors.red.withValues(alpha: 0.08));

                attendanceTiles.add(
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Container(
                      decoration: BoxDecoration(
                        color: tileColor,
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
                              color: barColor,
                              borderRadius: BorderRadius.only(
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
                                    '#${i + 1}  Session ${sessionNo <= 0 ? '-' : sessionNo} — $statusLabel',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w900,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    [
                                      when,
                                      if (teacher.isNotEmpty)
                                        'Teacher: $teacher',
                                    ].join(' • '),
                                    style: TextStyle(
                                      color: Colors.black.withValues(
                                        alpha: 0.65,
                                      ),
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
                  ),
                );
                consumedCount += 1;
              }

              return ListView(
                padding: EdgeInsets.zero,
                children: [
                  _coursePicker(keys),
                  const SizedBox(height: 8),
                  _miniCard(
                    child: Text(
                      totalSessions > 0
                          ? 'Flexible consumed sessions: ${consumedRows.length} / $totalSessions'
                          : 'Flexible consumed sessions: ${consumedRows.length}',
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (consumedRows.isEmpty)
                    const _MiniState(
                      text: 'No consumed attendance recorded yet.',
                    )
                  else
                    ...attendanceTiles,
                ],
              );
            },
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
      future: _courseSnapshotFuture(courseId),
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
        final paymentBoundariesFuture = _paymentSessionBoundariesForCourse(
          uid: widget.uid,
          courseKey: courseKey,
          courseId: courseId,
          courseTitle: (courseNode['title'] ?? cMap['title'] ?? '').toString(),
          courseCode: (courseNode['course_code'] ?? cMap['course_code'] ?? '')
              .toString(),
          variantKey: variantKey,
        );

        return FutureBuilder<DataSnapshot>(
          key: ValueKey('class-att-$classId'),
          future: _classAttendanceFuture(classId),
          builder: (context, classSnap) {
            final classAttendanceRaw = classSnap.data?.value;
            final classSessions = _mapToList(classAttendanceRaw);

            final taughtCount = classSessions.length;
            final label = totalSessions > 0
                ? '$taughtCount / $totalSessions'
                : '$taughtCount';

            return FutureBuilder<List<int>>(
              future: paymentBoundariesFuture,
              builder: (context, boundariesSnap) {
                final boundaries = boundariesSnap.data ?? const <int>[];
                final attendanceTiles = <Widget>[];
                var consumedCount = 0;
                var learnerPresentInTaught = 0;
                var boundaryIndex = 0;

                for (final entry in classSessions.asMap().entries) {
                  final i = entry.key;
                  final classRec = entry.value;

                  while (boundaryIndex < boundaries.length &&
                      consumedCount >= boundaries[boundaryIndex]) {
                    attendanceTiles.add(_paymentBoundaryDivider(boundaryIndex));
                    boundaryIndex += 1;
                  }

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
                    tint = const Color(0xFF157A3D).withValues(alpha: 0.08);
                  } else if (status == 'absent') {
                    bar = Colors.red;
                    tint = Colors.red.withValues(alpha: 0.08);
                  } else {
                    bar = const Color(0xFF64748B);
                    tint = const Color(0xFF64748B).withValues(alpha: 0.08);
                  }

                  final shownStatus = statusRaw.isEmpty
                      ? 'not registered'
                      : statusRaw;
                  if (status == 'present') {
                    learnerPresentInTaught += 1;
                  }

                  attendanceTiles.add(
                    Padding(
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
                                        color: Colors.black.withValues(
                                          alpha: 0.65,
                                        ),
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
                    ),
                  );

                  if (_attendanceRowConsumesPaidSession(
                    variantKey: variantKey,
                    learnerRec: learnerRec,
                  )) {
                    consumedCount += 1;
                  }
                }

                final taughtProgressValue = totalSessions > 0
                    ? (taughtCount / totalSessions).clamp(0.0, 1.0)
                    : 0.0;
                final learnerPresentValue = taughtCount > 0
                    ? (learnerPresentInTaught / taughtCount).clamp(0.0, 1.0)
                    : 0.0;

                return ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    _coursePicker(keys),
                    const SizedBox(height: 8),
                    _miniCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Progress overview',
                            style: TextStyle(fontWeight: FontWeight.w900),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: _compactProgressMetric(
                                  title: 'Lessons taught',
                                  valueText: label,
                                  value: taughtProgressValue,
                                  valueColor: AdminLearnersScreen.primaryBlue,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _compactProgressMetric(
                                  title: 'Learner present',
                                  valueText:
                                      '$learnerPresentInTaught / $taughtCount',
                                  value: learnerPresentValue,
                                  valueColor: const Color(0xFF157A3D),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (classSessions.isEmpty)
                      const _MiniState(text: 'No class sessions recorded yet.')
                    else
                      ...attendanceTiles,
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _reportTab(BuildContext context) {
    final keys = _userCourses.keys.toList()..sort();

    int avgFromMap(dynamic raw, {int max = 5}) {
      if (raw is! Map) return 0;
      var sum = 0;
      var count = 0;
      raw.forEach((_, v) {
        final n = _asInt(v);
        if (n <= 0) return;
        final capped = n > max ? max : n;
        sum += capped;
        count++;
      });
      if (count == 0) return 0;
      return (sum / count).round();
    }

    String shortOneLine(String text, {int max = 140}) {
      final t = text.trim().replaceAll(RegExp(r'\s+'), ' ');
      if (t.length <= max) return t;
      if (max <= 1) return '…';
      return '${t.substring(0, max - 1)}…';
    }

    return ListView(
      padding: EdgeInsets.zero,
      children: [
        _coursePicker(keys),
        const SizedBox(height: 8),
        SizedBox(
          height: 258,
          child: StreamBuilder<DatabaseEvent>(
            stream: widget.db.ref('reports/${widget.uid}').onValue,
            builder: (context, snap) {
              final v = snap.data?.snapshot.value;
              final items = <Map<String, dynamic>>[];

              if (v is Map) {
                v.forEach((k, val) {
                  if (val is! Map) return;
                  final m = val.map((kk, vv) => MapEntry(kk.toString(), vv));
                  items.add({'reportId': k.toString(), ...m});
                });
              }

              if (_selectedCourseKey != null &&
                  _selectedCourseKey!.isNotEmpty) {
                final selected = _selectedCourseKey!.trim();
                items.removeWhere((r) {
                  final rk = (r['courseKey'] ?? '').toString().trim();
                  return rk.isNotEmpty && rk != selected;
                });
              }

              items.sort(
                (a, b) =>
                    _asInt(b['createdAt']).compareTo(_asInt(a['createdAt'])),
              );

              if (items.isEmpty) {
                return const _MiniState(
                  text: 'No reports yet for this learner.',
                );
              }

              return ListView.builder(
                padding: EdgeInsets.zero,
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final r = items[i];
                  final reportId = (r['reportId'] ?? '').toString().trim();
                  final createdAt = _fmtDateMs(_asInt(r['createdAt']));
                  final byName = (r['createdByName'] ?? '').toString().trim();
                  final courseTitle = (r['courseTitle'] ?? '')
                      .toString()
                      .trim();
                  final comment = (r['comment'] ?? '').toString().trim();

                  final behaviorAvg = avgFromMap(r['behavior']);
                  final progressAvg = avgFromMap(r['progress']);

                  final hwRaw = r['homework'];
                  final hw = hwRaw is Map
                      ? hwRaw.map((k, v) => MapEntry(k.toString(), v))
                      : <String, dynamic>{};
                  final hwFinalRaw = hw['final'];
                  final hwFinal = hwFinalRaw is Map
                      ? hwFinalRaw.map((k, v) => MapEntry(k.toString(), v))
                      : <String, dynamic>{};

                  final hwAvg = _asInt(hwFinal['avgScore']);
                  final hwRedo = _asInt(hwFinal['redoCount']);
                  final summaryLine =
                      'Behavior ${behaviorAvg > 0 ? behaviorAvg : '-'} /5 • '
                      'Progress ${progressAvg > 0 ? progressAvg : '-'} /5 • '
                      'HW ${hwAvg > 0 ? hwAvg : '-'} /100 • '
                      'Redo $hwRedo';

                  final diagramUrl = (r['diagramUrl'] ?? '').toString().trim();

                  return Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: _miniCard(
                      bg: Colors.white,
                      borderColor: AdminLearnersScreen.uiBorders,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            summaryLine,
                            style: const TextStyle(fontWeight: FontWeight.w900),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            [
                              if (courseTitle.isNotEmpty) courseTitle,
                              if (byName.isNotEmpty) 'By $byName',
                              if (createdAt.isNotEmpty) createdAt,
                              if (reportId.isNotEmpty) '#$reportId',
                            ].join(' • '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.black.withValues(alpha: 0.65),
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                            ),
                          ),
                          if (comment.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Text(
                              shortOneLine(comment),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.black.withValues(alpha: 0.68),
                                fontWeight: FontWeight.w700,
                                fontSize: 12,
                              ),
                            ),
                          ],
                          if (diagramUrl.isNotEmpty) ...[
                            const SizedBox(height: 6),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton.icon(
                                style: TextButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                ),
                                onPressed: () async {
                                  final uri = Uri.tryParse(diagramUrl);
                                  if (uri == null) {
                                    _toast('Invalid report diagram link.');
                                    return;
                                  }
                                  final ok = await launchUrl(
                                    uri,
                                    mode: LaunchMode.externalApplication,
                                  );
                                  if (!ok) {
                                    _toast(
                                      'Could not open report diagram link.',
                                    );
                                  }
                                },
                                icon: const Icon(
                                  Icons.open_in_new_rounded,
                                  size: 16,
                                ),
                                label: const Text('Open diagram'),
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
    );
  }

  Widget _compactProgressMetric({
    required String title,
    required String valueText,
    required double value,
    required Color valueColor,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: AdminLearnersScreen.appBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AdminLearnersScreen.uiBorders),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: Colors.black.withValues(alpha: 0.68),
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 1),
          Text(valueText, style: const TextStyle(fontWeight: FontWeight.w900)),
          const SizedBox(height: 5),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: value,
              minHeight: 6,
              backgroundColor: Colors.white,
              valueColor: AlwaysStoppedAnimation<Color>(valueColor),
            ),
          ),
        ],
      ),
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

  static int _countUniqueAttendance(dynamic attendance) {
    return countPresentUniqueAttendanceDates(attendance);
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
