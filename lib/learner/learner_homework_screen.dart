import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

import '../shared/ui_constants.dart';
import '../shared/watermark_background.dart';

class LearnerHomeworkScreen extends StatefulWidget {
  final String courseKey; // course_1, course_2...
  final String courseTitle;

  const LearnerHomeworkScreen({
    super.key,
    required this.courseKey,
    required this.courseTitle,
  });

  @override
  State<LearnerHomeworkScreen> createState() => _LearnerHomeworkScreenState();
}

class _LearnerHomeworkScreenState extends State<LearnerHomeworkScreen> {
  static const usersNode = 'users';

  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  late final DatabaseReference _usersRef = _db.child(usersNode);

  bool _busy = true;
  String? _error;

  String _uid = '';
  List<Map<String, dynamic>> _items = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
      _items = [];
      _uid = '';
    });

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw Exception('Not logged in.');
      _uid = user.uid;

      final snap = await _usersRef.child(_uid).child('courses').child(widget.courseKey).child('attendance').get();
      if (!snap.exists || snap.value == null) {
        setState(() => _busy = false);
        return;
      }

      final raw = Map<String, dynamic>.from(snap.value as Map);
      final List<Map<String, dynamic>> list = [];

      for (final entry in raw.entries) {
        if (entry.value is! Map) continue;
        final rec = Map<String, dynamic>.from(entry.value as Map);

        final hw = (rec['homework'] is Map) ? Map<String, dynamic>.from(rec['homework'] as Map) : <String, dynamic>{};
        final text = (hw['text'] ?? '').toString().trim();
        final due = (hw['dueDate'] ?? '').toString().trim();

        if (text.isEmpty && due.isEmpty) continue;

        final taught = (rec['taught'] is Map) ? Map<String, dynamic>.from(rec['taught'] as Map) : <String, dynamic>{};
        final taughtTitle = (taught['title'] ?? '').toString();

        list.add({
          'sessionId': entry.key.toString(),
          'date': (rec['date'] ?? '').toString(),
          'taughtTitle': taughtTitle,
          'text': text,
          'dueDate': due,
        });
      }

      list.sort((a, b) => (b['date'] ?? '').toString().compareTo((a['date'] ?? '').toString()));

      setState(() {
        _items = list;
        _busy = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: UiK.appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: UiK.primaryBlue),
        title: Text(
          '${widget.courseTitle} - Homework',
          style: const TextStyle(color: UiK.primaryBlue, fontWeight: FontWeight.w900),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded, color: UiK.actionOrange),
            onPressed: _busy ? null : _load,
          ),
        ],
      ),
      body: WatermarkBackground(
        child: _busy
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error, fontWeight: FontWeight.w800),
              textAlign: TextAlign.center,
            ),
          ),
        )
            : _items.isEmpty
            ? const Center(
          child: Text('No homework yet.',
              style: TextStyle(color: UiK.mainText, fontWeight: FontWeight.w800)),
        )
            : ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: _items.length,
          itemBuilder: (_, i) {
            final it = _items[i];
            final date = (it['date'] ?? '').toString();
            final due = (it['dueDate'] ?? '').toString();
            final text = (it['text'] ?? '').toString();
            final taughtTitle = (it['taughtTitle'] ?? '').toString();

            return Card(
              elevation: 0,
              color: Colors.white,
              shape: UiK.cardShape(),
              margin: const EdgeInsets.only(bottom: 12),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(date.isEmpty ? 'Session' : date, style: UiK.titleText(size: 15)),
                    const SizedBox(height: 6),
                    if (taughtTitle.isNotEmpty)
                      Text('Taught: $taughtTitle', style: UiK.subtleText()),
                    if (due.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text('Due: $due', style: UiK.subtleText()),
                    ],
                    if (text.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text(text, style: UiK.subtleText()),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
