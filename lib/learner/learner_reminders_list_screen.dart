import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

import '../shared/ui_constants.dart';
import '../shared/watermark_background.dart';
import 'learner_reminder_details_screen.dart';

class LearnerRemindersListScreen extends StatelessWidget {
  const LearnerRemindersListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final ref = FirebaseDatabase.instance.ref('reminders/$uid');

    return Scaffold(
      backgroundColor: UiK.appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: UiK.primaryBlue),
        title: const Text(
          'Reminders',
          style: TextStyle(color: UiK.primaryBlue, fontWeight: FontWeight.w900),
        ),
      ),
      body: WatermarkBackground(
        child: StreamBuilder<DatabaseEvent>(
          stream: uid.isEmpty ? const Stream.empty() : ref.onValue,
          builder: (context, snap) {
            final v = snap.data?.snapshot.value;

            final items = <Map<String, dynamic>>[];

            if (v is Map) {
              v.forEach((key, vv) {
                if (vv is! Map) return;
                final m = vv.map((k, v) => MapEntry(k.toString(), v));

                int toInt(dynamic x) {
                  if (x is int) return x;
                  if (x is num) return x.toInt();
                  return int.tryParse(x?.toString() ?? '') ?? 0;
                }

                items.add({
                  'id': key.toString(),
                  'title': (m['title'] ?? 'Reminder').toString(),
                  'description': (m['description'] ?? '').toString(),
                  'createdAt': toInt(m['createdAt']),
                  'readAt': m['readAt'],
                  'kind': (m['kind'] ?? '').toString(),
                  'status': (m['status'] ?? '').toString(),
                  'teacherName': ((m['teacher'] is Map) ? (m['teacher']['name'] ?? '') : '').toString(),
                });
              });
            }

            items.sort((a, b) => (b['createdAt'] as int).compareTo(a['createdAt'] as int));

            if (items.isEmpty) {
              return const Center(
                child: Text('No reminders yet.', style: TextStyle(fontWeight: FontWeight.w800)),
              );
            }

            return ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, i) {
                final it = items[i];
                final isUnread = it['readAt'] == null;

                return InkWell(
                  borderRadius: BorderRadius.circular(18),
                  onTap: () async {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => LearnerReminderDetailsScreen(
                          reminderId: it['id'] as String,
                        ),
                      ),
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: UiK.uiBorder.withOpacity(0.85)),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: UiK.primaryBlue.withOpacity(0.06),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: UiK.uiBorder.withOpacity(0.85)),
                          ),
                          child: Icon(
                            Icons.notifications_active_rounded,
                            color: isUnread ? Colors.red : UiK.primaryBlue,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                it['title'] as String,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontWeight: FontWeight.w900,
                                  color: UiK.primaryBlue,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                (it['description'] as String).isEmpty ? '—' : (it['description'] as String),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: Colors.grey.shade600,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
                        if (isUnread)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.red,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: const Text(
                              'NEW',
                              style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w900,
                                fontSize: 11,
                              ),
                            ),
                          )
                        else
                          const Icon(Icons.chevron_right_rounded, color: UiK.primaryBlue),
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
