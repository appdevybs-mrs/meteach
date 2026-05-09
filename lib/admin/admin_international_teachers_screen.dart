import 'package:firebase_auth/firebase_auth.dart';
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
  final _startC = TextEditingController();
  final _expiryC = TextEditingController();
  final _noteC = TextEditingController();

  bool _saving = false;
  bool _addingSubscription = false;
  Map<String, bool> _selected = <String, bool>{};
  List<Map<String, String>> _courses = <Map<String, String>>[];
  List<Map<String, dynamic>> _subs = <Map<String, dynamic>>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _amountC.dispose();
    _startC.dispose();
    _expiryC.dispose();
    _noteC.dispose();
    super.dispose();
  }

  Future<void> _pickDate(TextEditingController c, String help) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final initial = DateTime.tryParse(c.text.trim()) ?? today;
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(today.year - 1, 1, 1),
      lastDate: DateTime(today.year + 10, 12, 31),
      helpText: help,
    );
    if (picked == null) return;
    final mm = picked.month.toString().padLeft(2, '0');
    final dd = picked.day.toString().padLeft(2, '0');
    c.text = '${picked.year}-$mm-$dd';
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final snaps = await Future.wait([
      _db.child('courses').get(),
      _db
          .child('international_teacher_assignments/${widget.uid}/courses')
          .get(),
      _db.child('international_teacher_subscriptions/${widget.uid}').get(),
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

    final subs = <Map<String, dynamic>>[];
    final sv = snaps[2].value;
    if (sv is Map) {
      sv.forEach((k, v) {
        if (v is! Map) return;
        final m = v.map((kk, vv) => MapEntry(kk.toString(), vv));
        m['id'] = k.toString();
        subs.add(m);
      });
      subs.sort((a, b) {
        final at = (a['createdAt'] is num)
            ? (a['createdAt'] as num).toInt()
            : 0;
        final bt = (b['createdAt'] is num)
            ? (b['createdAt'] as num).toInt()
            : 0;
        return bt.compareTo(at);
      });
    }

    if (!mounted) return;
    setState(() {
      _courses = courses;
      _selected = selected;
      _subs = subs;
    });
  }

  Future<void> _saveAssignments() async {
    setState(() => _saving = true);
    try {
      final updates = <String, dynamic>{};
      for (final c in _courses) {
        final id = c['id']!;
        updates['international_teacher_assignments/${widget.uid}/courses/$id'] =
            _selected[id] == true;
      }
      await _db.update(updates);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Assignments saved.')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Save failed: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _addSubscription() async {
    setState(() => _addingSubscription = true);
    try {
      final amount = double.tryParse(_amountC.text.trim()) ?? 0;
      final startsOn = _startC.text.trim();
      final expiresOn = _expiryC.text.trim();
      if (startsOn.isEmpty || expiresOn.isEmpty) {
        throw Exception('Please select start and expiry dates.');
      }

      final rowRef = _db
          .child('international_teacher_subscriptions/${widget.uid}')
          .push();
      final adminUid = FirebaseAuth.instance.currentUser?.uid ?? '';
      await rowRef.set({
        'amountPaidUsd': amount,
        'startsOn': startsOn,
        'expiresOn': expiresOn,
        'note': _noteC.text.trim(),
        'status': 'active',
        'createdAt': ServerValue.timestamp,
        'createdBy': adminUid,
      });

      await _recomputeCurrentSubscription();

      _amountC.clear();
      _startC.clear();
      _expiryC.clear();
      _noteC.clear();
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Subscription added.')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Add failed: $e')));
    } finally {
      if (mounted) setState(() => _addingSubscription = false);
    }
  }

  Future<void> _recomputeCurrentSubscription() async {
    final snap = await _db
        .child('international_teacher_subscriptions/${widget.uid}')
        .get();
    if (!snap.exists || snap.value is! Map) {
      await _db
          .child('international_teacher_subscription/${widget.uid}')
          .remove();
      return;
    }
    final rows = <Map<String, dynamic>>[];
    final m = (snap.value as Map).map((k, v) => MapEntry(k.toString(), v));
    m.forEach((k, v) {
      if (v is! Map) return;
      final row = v.map((kk, vv) => MapEntry(kk.toString(), vv));
      row['id'] = k;
      rows.add(row);
    });

    if (rows.isEmpty) {
      await _db
          .child('international_teacher_subscription/${widget.uid}')
          .remove();
      return;
    }

    rows.sort((a, b) {
      final ae =
          DateTime.tryParse((a['expiresOn'] ?? '').toString()) ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final be =
          DateTime.tryParse((b['expiresOn'] ?? '').toString()) ??
          DateTime.fromMillisecondsSinceEpoch(0);
      return be.compareTo(ae);
    });
    final best = rows.first;

    await _db.child('international_teacher_subscription/${widget.uid}').set({
      'amountPaidUsd': best['amountPaidUsd'] ?? 0,
      'startsOn': (best['startsOn'] ?? '').toString(),
      'expiresOn': (best['expiresOn'] ?? '').toString(),
      'status': (best['status'] ?? 'active').toString(),
      'sourceSubId': (best['id'] ?? '').toString(),
      'updatedAt': ServerValue.timestamp,
    });
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
                    'Add Subscription',
                    style: TextStyle(fontWeight: FontWeight.w900),
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
                    controller: _startC,
                    readOnly: true,
                    onTap: () => _pickDate(_startC, 'Select start date'),
                    decoration: InputDecoration(
                      labelText: 'Starts On (YYYY-MM-DD)',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.calendar_month_outlined),
                        onPressed: () =>
                            _pickDate(_startC, 'Select start date'),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _expiryC,
                    readOnly: true,
                    onTap: () => _pickDate(_expiryC, 'Select expiry date'),
                    decoration: InputDecoration(
                      labelText: 'Expires On (YYYY-MM-DD)',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.calendar_month_outlined),
                        onPressed: () =>
                            _pickDate(_expiryC, 'Select expiry date'),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _noteC,
                    decoration: const InputDecoration(
                      labelText: 'Note (optional)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  FilledButton.icon(
                    onPressed: _addingSubscription ? null : _addSubscription,
                    icon: const Icon(Icons.add_card_outlined),
                    label: Text(
                      _addingSubscription ? 'Adding...' : 'Add Subscription',
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
                    style: TextStyle(fontWeight: FontWeight.w900),
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
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Subscription History',
                    style: TextStyle(fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 8),
                  if (_subs.isEmpty)
                    const Text('No subscriptions yet.')
                  else
                    for (final s in _subs)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.history_rounded),
                        title: Text(
                          'USD ${(s['amountPaidUsd'] ?? 0).toString()}',
                        ),
                        subtitle: Text(
                          '${(s['startsOn'] ?? '').toString()} -> ${(s['expiresOn'] ?? '').toString()}',
                        ),
                        trailing: Text((s['status'] ?? 'active').toString()),
                      ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _saving ? null : _saveAssignments,
            child: Text(_saving ? 'Saving...' : 'Save Assignments'),
          ),
        ],
      ),
    );
  }
}
