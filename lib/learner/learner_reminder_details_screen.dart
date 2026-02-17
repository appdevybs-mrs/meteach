import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

import '../shared/ui_constants.dart';
import '../shared/watermark_background.dart';

class LearnerReminderDetailsScreen extends StatefulWidget {
  const LearnerReminderDetailsScreen({
    super.key,
    required this.reminderId,
  });

  final String reminderId;

  @override
  State<LearnerReminderDetailsScreen> createState() => _LearnerReminderDetailsScreenState();
}

class _LearnerReminderDetailsScreenState extends State<LearnerReminderDetailsScreen> {
  final _db = FirebaseDatabase.instance.ref();

  @override
  void initState() {
    super.initState();
    _markAsRead();
  }

  Future<void> _markAsRead() async {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isEmpty) return;

    final ref = _db.child('reminders/$uid/${widget.reminderId}');

    final snap = await ref.child('readAt').get();
    if (snap.exists) return; // already read

    await ref.update({
      'readAt': ServerValue.timestamp,
      'status': 'read',
    });
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    final ref = _db.child('reminders/$uid/${widget.reminderId}');

    return Scaffold(
      backgroundColor: UiK.appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: UiK.primaryBlue),
        title: const Text(
          'Reminder',
          style: TextStyle(color: UiK.primaryBlue, fontWeight: FontWeight.w900),
        ),
      ),
      body: WatermarkBackground(
        child: StreamBuilder<DatabaseEvent>(
          stream: uid.isEmpty ? const Stream.empty() : ref.onValue,
          builder: (context, snap) {
            final v = snap.data?.snapshot.value;

            if (v is! Map) {
              return const Center(
                child: Text('Reminder not found.', style: TextStyle(fontWeight: FontWeight.w800)),
              );
            }

            final m = v.map((k, v) => MapEntry(k.toString(), v));

            final title = (m['title'] ?? 'Reminder').toString();
            final desc = (m['description'] ?? '').toString();
            final status = (m['status'] ?? '').toString();
            final teacher = (m['teacher'] is Map) ? (m['teacher']['name'] ?? '').toString() : '';

            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  elevation: 0,
                  color: Colors.white,
                  shape: UiK.cardShape(),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: UiK.titleText(size: 18)),
                        const SizedBox(height: 8),
                        if (teacher.trim().isNotEmpty)
                          Text('From: $teacher', style: UiK.subtleText()),
                        const SizedBox(height: 10),
                        Text(
                          desc.isEmpty ? '—' : desc,
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 14),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: UiK.primaryBlue.withOpacity(0.06),
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(color: UiK.uiBorder.withOpacity(0.85)),
                          ),
                          child: Text(
                            status.isEmpty ? '—' : status,
                            style: const TextStyle(
                              fontWeight: FontWeight.w900,
                              color: UiK.primaryBlue,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
