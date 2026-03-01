import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

import '../shared/ui_constants.dart';
import '../shared/watermark_background.dart';
import 'learner_mail_thread_screen.dart';

class LearnerMailScreen extends StatefulWidget {
  const LearnerMailScreen({super.key});

  @override
  State<LearnerMailScreen> createState() => _LearnerMailScreenState();
}

class _LearnerMailScreenState extends State<LearnerMailScreen> {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  // --- Brand colors (ONLY 2 colors + white) ---
  // Use UiK so it matches the rest of the app.
  Color get _navy => UiK.primaryBlue;
  Color get _orange => UiK.actionOrange;

  // Slightly deeper navy for emphasis (still "your blue", just opacity layering)
  Color get _navyDark => UiK.primaryBlue.withOpacity(0.92);

  String get _meUid => FirebaseAuth.instance.currentUser?.uid ?? '';

  int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  String _short(String s, int max) {
    final t = s.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (t.length <= max) return t;
    if (max <= 1) return '…';
    return '${t.substring(0, max - 1)}…';
  }

  String _fmt(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final uid = _meUid;
    final ref = _db.child('mail_index/$uid');

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: IconThemeData(color: _navy),
        title: Text(
          'Mail',
          style: TextStyle(color: _navy, fontWeight: FontWeight.w900),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: _navy.withOpacity(0.14)),
        ),
      ),
      body: WatermarkBackground(
        child: uid.isEmpty
            ? Center(
          child: Text(
            'Not logged in.',
            style: TextStyle(fontWeight: FontWeight.w900, color: _navy),
          ),
        )
            : StreamBuilder<DatabaseEvent>(
          stream: ref.onValue,
          builder: (context, snap) {
            final v = snap.data?.snapshot.value;
            final List<Map<String, dynamic>> threads = [];

            if (v is Map) {
              v.forEach((threadId, vv) {
                if (threadId == null || vv is! Map) return;
                final m = vv.map((k, v) => MapEntry(k.toString(), v));

                // ignore deleted threads for me
                final deletedAt = m['deletedAt'];
                if (deletedAt != null) return;

                threads.add({
                  'threadId': threadId.toString(),
                  'peerUid': (m['peerUid'] ?? '').toString(),
                  'peerName': (m['peerName'] ?? '').toString(),
                  'subject': (m['subject'] ?? '').toString(),
                  'lastMessage': (m['lastMessage'] ?? '').toString(),
                  'unreadCount': _toInt(m['unreadCount']),
                  'updatedAt': _toInt(m['updatedAt']),
                });
              });
            }

            threads.sort((a, b) => (b['updatedAt'] as int).compareTo(a['updatedAt'] as int));

            if (threads.isEmpty) {
              return Center(
                child: Text(
                  'No mail yet.',
                  style: TextStyle(fontWeight: FontWeight.w900, color: _navyDark),
                ),
              );
            }

            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
              itemCount: threads.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, i) {
                final t = threads[i];

                final threadId = (t['threadId'] ?? '').toString();
                final peerUid = (t['peerUid'] ?? '').toString();
                final peerName = (t['peerName'] ?? '').toString().trim().isEmpty
                    ? 'Teacher'
                    : (t['peerName'] ?? '').toString();
                final subject = (t['subject'] ?? '').toString();
                final lastMessage = (t['lastMessage'] ?? '').toString();
                final unread = _toInt(t['unreadCount']);
                final updatedAt = _toInt(t['updatedAt']);

                return InkWell(
                  borderRadius: BorderRadius.circular(18),
                  onTap: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => LearnerMailThreadScreen(
                          threadId: threadId,
                          peerUid: peerUid,
                          peerName: peerName,
                          subject: subject,
                        ),
                      ),
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: _navy.withOpacity(0.14)),
                    ),
                    child: Row(
                      children: [
                        Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Container(
                              width: 46,
                              height: 46,
                              decoration: BoxDecoration(
                                color: _navy.withOpacity(0.06),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(color: _navy.withOpacity(0.14)),
                              ),
                              child: Icon(Icons.mail_rounded, color: _navy.withOpacity(0.92)),
                            ),
                            if (unread > 0)
                              Positioned(
                                right: -8,
                                top: -8,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: _orange, // ✅ orange badge (no red)
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: Text(
                                    unread > 99 ? '99+' : '$unread',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w900,
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      peerName,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontWeight: FontWeight.w900,
                                        color: _navy,
                                        fontSize: 15,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Text(
                                    updatedAt <= 0 ? '' : _fmt(updatedAt),
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w800,
                                      color: _navy.withOpacity(0.55),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),

                              // Subject pill (orange)
                              if (subject.trim().isNotEmpty)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: _orange.withOpacity(0.14),
                                    borderRadius: BorderRadius.circular(999),
                                    border: Border.all(color: _orange.withOpacity(0.24)),
                                  ),
                                  child: Text(
                                    _short(subject, 60),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w900,
                                      color: _navyDark,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),

                              const SizedBox(height: 8),
                              Text(
                                lastMessage.trim().isEmpty ? '—' : _short(lastMessage, 90),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  color: _navy.withOpacity(0.62), // ✅ no grey/black
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        Icon(Icons.chevron_right_rounded, color: _orange.withOpacity(0.85)),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}