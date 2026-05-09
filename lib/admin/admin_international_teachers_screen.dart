import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

class AdminInternationalTeachersScreen extends StatefulWidget {
  const AdminInternationalTeachersScreen({super.key});

  @override
  State<AdminInternationalTeachersScreen> createState() =>
      _AdminInternationalTeachersScreenState();
}

class _AdminInternationalTeachersScreenState
    extends State<AdminInternationalTeachersScreen> {
  final _db = FirebaseDatabase.instance.ref();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('International Teachers')),
      body: StreamBuilder<DatabaseEvent>(
        stream: _db.child('users').onValue,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final rows = <Map<String, String>>[];
          final v = snap.data?.snapshot.value;
          if (v is Map) {
            v.forEach((k, raw) {
              if (raw is! Map) return;
              final m = raw.map((kk, vv) => MapEntry(kk.toString(), vv));
              final role = (m['role'] ?? '').toString().trim().toLowerCase();
              if (role != 'oteacher') return;
              final name =
                  '${(m['first_name'] ?? '').toString()} ${(m['last_name'] ?? '').toString()}'
                      .trim();
              rows.add({
                'uid': k.toString(),
                'name': name.isEmpty ? 'International Teacher' : name,
                'email': (m['email'] ?? '').toString(),
              });
            });
          }
          rows.sort(
            (a, b) => (a['name'] ?? '').toLowerCase().compareTo(
              (b['name'] ?? '').toLowerCase(),
            ),
          );
          if (rows.isEmpty) {
            return const Center(
              child: Text('No international teachers found in staff.'),
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: rows.length,
            itemBuilder: (context, i) {
              final t = rows[i];
              return Card(
                child: ListTile(
                  leading: const Icon(Icons.person_outline),
                  title: Text(t['name']!),
                  subtitle: Text(t['email'] ?? ''),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => _AdminInternationalTeacherDetailsScreen(
                          uid: t['uid']!,
                          name: t['name']!,
                        ),
                      ),
                    );
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _AdminInternationalTeacherDetailsScreen extends StatefulWidget {
  const _AdminInternationalTeacherDetailsScreen({
    required this.uid,
    required this.name,
  });
  final String uid;
  final String name;

  @override
  State<_AdminInternationalTeacherDetailsScreen> createState() =>
      _AdminInternationalTeacherDetailsScreenState();
}

class _AdminInternationalTeacherDetailsScreenState
    extends State<_AdminInternationalTeacherDetailsScreen> {
  final _db = FirebaseDatabase.instance.ref();
  final _amountC = TextEditingController();
  final _expiryC = TextEditingController();
  bool _saving = false;
  Map<String, bool> _selected = <String, bool>{};
  List<Map<String, String>> _courses = <Map<String, String>>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _amountC.dispose();
    _expiryC.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final snaps = await Future.wait([
      _db.child('courses').get(),
      _db
          .child('international_teacher_assignments/${widget.uid}/courses')
          .get(),
      _db.child('international_teacher_subscription/${widget.uid}').get(),
    ]);
    final courses = <Map<String, String>>[];
    final cv = snaps[0].value;
    if (cv is Map) {
      cv.forEach((k, raw) {
        if (raw is! Map) return;
        final m = raw.map((kk, vv) => MapEntry(kk.toString(), vv));
        courses.add({
          'id': k.toString(),
          'title': (m['title'] ?? '').toString(),
          'code': (m['course_code'] ?? '').toString(),
        });
      });
    }
    courses.sort(
      (a, b) => (a['title'] ?? '').toLowerCase().compareTo(
        (b['title'] ?? '').toLowerCase(),
      ),
    );

    final selected = <String, bool>{};
    final av = snaps[1].value;
    if (av is Map) {
      av.forEach((k, v) {
        selected[k.toString()] = v == true;
      });
    }

    final sv = snaps[2].value;
    if (sv is Map) {
      final m = sv.map((k, v) => MapEntry(k.toString(), v));
      _amountC.text = (m['amountPaidUsd'] ?? '').toString();
      _expiryC.text = (m['expiresOn'] ?? '').toString();
    }

    if (!mounted) return;
    setState(() {
      _courses = courses;
      _selected = selected;
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final updates = <String, dynamic>{};
      for (final c in _courses) {
        final id = c['id']!;
        updates['international_teacher_assignments/${widget.uid}/courses/$id'] =
            _selected[id] == true;
      }
      updates['international_teacher_subscription/${widget.uid}/amountPaidUsd'] =
          double.tryParse(_amountC.text.trim()) ?? 0;
      updates['international_teacher_subscription/${widget.uid}/expiresOn'] =
          _expiryC.text.trim();
      updates['international_teacher_subscription/${widget.uid}/updatedAt'] =
          ServerValue.timestamp;
      await _db.update(updates);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Saved.')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Save failed: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.name)),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Subscription',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _amountC,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Amount Paid (USD)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _expiryC,
                    decoration: const InputDecoration(
                      labelText: 'Expires On (YYYY-MM-DD)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Assigned Courses',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  for (final c in _courses)
                    CheckboxListTile(
                      dense: true,
                      value: _selected[c['id']] == true,
                      title: Text(
                        (c['title'] ?? '').isEmpty ? 'Untitled' : c['title']!,
                      ),
                      subtitle: Text(c['code'] ?? ''),
                      onChanged: (v) => setState(() {
                        _selected[c['id']!] = v == true;
                      }),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'Saving...' : 'Save Assignments'),
          ),
        ],
      ),
    );
  }
}
