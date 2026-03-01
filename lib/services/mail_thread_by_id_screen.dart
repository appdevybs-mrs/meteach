import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../admin/mail_topic_thread_screen.dart';

/// Opens a topic thread from notification using threadId.
/// It reads /mail_index/{me}/{threadId} to know peer info.
class MailThreadByIdScreen extends StatefulWidget {
  const MailThreadByIdScreen({
    super.key,
    required this.threadId,
    required this.peerUid, // sender uid from notification (may not be correct in all cases)
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

  Future<void> _go() async {
    final me = FirebaseAuth.instance.currentUser;
    if (me == null) return;

    try {
      // ✅ read index to get correct peerUid/peerName for THIS thread
      final snap = await _db.ref('mail_index/${me.uid}/${widget.threadId}').get();
      final v = snap.value;

      String peerUid = widget.peerUid;
      String peerName = 'User';

      if (v is Map) {
        final m = v.map((k, vv) => MapEntry(k.toString(), vv));
        peerUid = (m['peerUid'] ?? peerUid).toString();
        peerName = (m['peerName'] ?? peerName).toString();
      }

      // ✅ mark read quickly
      await _db.ref('mail_index/${me.uid}/${widget.threadId}').update({'unreadCount': 0});

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => MailTopicThreadScreen(
            threadId: widget.threadId,
            peerUid: peerUid,
            peerName: peerName.isEmpty ? 'User' : peerName,
          ),
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
