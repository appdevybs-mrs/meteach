import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../admin/mail_topic_thread_screen.dart';
import '../teacher/teacher_mail_thread_screen.dart';
import '../learner/learner_mail_thread_screen.dart';

/// Opens a mail thread from notification using threadId.
/// It reads:
/// - users/{me}/role
/// - mail_index/{me}/{threadId}
/// Then routes to the correct thread UI by current user role.
class MailThreadByIdScreen extends StatefulWidget {
  const MailThreadByIdScreen({
    super.key,
    required this.threadId,
    required this.peerUid, // fallback only
  });

  final String threadId;
  final String peerUid;

  @override
  State<MailThreadByIdScreen> createState() => _MailThreadByIdScreenState();
}

class _MailThreadByIdScreenState extends State<MailThreadByIdScreen> {
  final _db = FirebaseDatabase.instance;

  @override
  void initState() {
    super.initState();
    _go();
  }

  String _normalizeRole(dynamic raw) {
    final s = (raw ?? '').toString().trim().toLowerCase();

    if (s == 'admin' ||
        s == 'adin' ||
        s == 'admn' ||
        s == 'adm' ||
        s == 'administration' ||
        s == 'administrator') {
      return 'admin';
    }

    if (s == 'teacher' ||
        s == 'teachers' ||
        s == 'teacher(s)' ||
        s == 'teach' ||
        s == 'instructor' ||
        s == 'prof') {
      return 'teacher';
    }

    if (s == 'learner' ||
        s == 'learners' ||
        s == 'learner(s)' ||
        s == 'lerner' ||
        s == 'student' ||
        s == 'pupil') {
      return 'learner';
    }

    return 'learner';
  }

  Future<void> _go() async {
    final me = FirebaseAuth.instance.currentUser;
    if (me == null) {
      if (!mounted) return;
      Navigator.of(context).pop();
      return;
    }

    try {
      // 1) Read current user role
      final roleSnap = await _db.ref('users/${me.uid}/role').get();
      final myRole = _normalizeRole(roleSnap.value);

      // 2) Read index for this thread to get correct peer info + subject
      final snap = await _db
          .ref('mail_index/${me.uid}/${widget.threadId}')
          .get();
      final v = snap.value;

      String peerUid = widget.peerUid.trim();
      String peerName = 'User';
      String subject = '';

      if (v is Map) {
        final m = v.map((k, vv) => MapEntry(k.toString(), vv));

        final idxPeerUid = (m['peerUid'] ?? '').toString().trim();
        final idxPeerName = (m['peerName'] ?? '').toString().trim();
        final idxSubject = (m['subject'] ?? '').toString();

        if (idxPeerUid.isNotEmpty) peerUid = idxPeerUid;
        if (idxPeerName.isNotEmpty) peerName = idxPeerName;
        subject = idxSubject;
      }

      // 3) Mark read
      final now = DateTime.now().millisecondsSinceEpoch;
      await _db.ref('mail_index/${me.uid}/${widget.threadId}').update({
        'unreadCount': 0,
      });
      await _db.ref('mail_state/${me.uid}/${widget.threadId}').update({
        'lastReadAt': now,
        'lastDeliveredAt': now,
      });

      if (!mounted) return;

      Widget target;

      if (myRole == 'admin') {
        target = MailTopicThreadScreen(
          threadId: widget.threadId,
          peerUid: peerUid,
          peerName: peerName.isEmpty ? 'User' : peerName,
        );
      } else if (myRole == 'teacher') {
        target = TeacherMailThreadScreen(
          threadId: widget.threadId,
          peerUid: peerUid,
          peerName: peerName.isEmpty ? 'User' : peerName,
          subject: subject,
        );
      } else {
        target = LearnerMailThreadScreen(
          threadId: widget.threadId,
          peerUid: peerUid,
          peerName: peerName.isEmpty ? 'User' : peerName,
          subject: subject,
        );
      }

      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          settings: RouteSettings(name: '/mail/thread/${widget.threadId}'),
          builder: (_) => target,
        ),
      );
    } catch (_) {
      if (!mounted) return;
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}
