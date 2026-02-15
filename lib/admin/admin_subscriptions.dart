import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';

import 'admin_learners.dart'; // so we can open LearnerEditorScreen

class AdminSubscriptionsScreen extends StatelessWidget {
  const AdminSubscriptionsScreen({super.key});

  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);

  DatabaseReference get _subsRef => FirebaseDatabase.instance.ref('subscriptions');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: primaryBlue),
        title: const Text(
          'Subscriptions',
          style: TextStyle(color: primaryBlue, fontWeight: FontWeight.w900),
        ),
        actions: [
          IconButton(
            tooltip: 'Add subscription',
            icon: const Icon(Icons.add_circle_rounded, color: actionOrange),
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SubscriptionCreateScreen()),
              );
            },
          ),
        ],
      ),
      body: StreamBuilder<DatabaseEvent>(
        stream: _subsRef.onValue,
        builder: (context, snap) {
          if (snap.hasError) {
            return const Center(child: Text('Error loading subscriptions.'));
          }
          final v = snap.data?.snapshot.value;
          final items = _parseSubscriptions(v);

          if (items.isEmpty) {
            return const Center(child: Text('No subscriptions yet.'));
          }

          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (context, i) {
              final s = items[i];

              return InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => SubscriptionDetailsScreen(sub: s)),
                ),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: uiBorder),
                  ),
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      CircleAvatar(
                        backgroundColor: appBg,
                        child: Text(
                          (s.firstName.isNotEmpty ? s.firstName[0].toUpperCase() : 'S'),
                          style: const TextStyle(fontWeight: FontWeight.w900, color: primaryBlue),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${s.firstName} ${s.lastName}'.trim().isEmpty ? '(No name)' : '${s.firstName} ${s.lastName}'.trim(),
                              style: const TextStyle(fontWeight: FontWeight.w900, color: primaryBlue),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${s.courseTitle}  •  ${s.phone}',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: Colors.black.withOpacity(0.65),
                                fontSize: 12,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.chevron_right_rounded, color: primaryBlue),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

// -------------------- DETAILS --------------------

class SubscriptionDetailsScreen extends StatelessWidget {
  const SubscriptionDetailsScreen({super.key, required this.sub});

  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);

  final SubscriptionItem sub;

  DatabaseReference get _subsRef => FirebaseDatabase.instance.ref('subscriptions');

  Future<bool> _confirmDelete(BuildContext context) async {
    return (await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete subscription?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    )) ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: primaryBlue),
        title: const Text(
          'Subscription Details',
          style: TextStyle(color: primaryBlue, fontWeight: FontWeight.w900),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.delete_forever_rounded),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red,
                    side: const BorderSide(color: Colors.red),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  onPressed: () async {
                    final ok = await _confirmDelete(context);
                    if (!ok) return;

                    await _subsRef.child(sub.id).remove();
                    if (context.mounted) Navigator.pop(context);
                  },
                  label: const Text('Delete'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton.icon(
                  icon: const Icon(Icons.person_add_alt_1_rounded),
                  style: FilledButton.styleFrom(
                    backgroundColor: actionOrange,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  onPressed: () async {
                    // ✅ Open your Add Learner screen with prefilled data
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => LearnerEditorScreen(
                          mode: EditorMode.create,
                          prefill: LearnerPrefill(
                            firstName: sub.firstName,
                            lastName: sub.lastName,
                            phone1: sub.phone,
                            selectedCourseIds: {sub.courseId},
                          ),
                        ),
                      ),
                    );
                  },
                  label: const Text('Create Learner'),
                ),
              ),
            ],
          ),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: _card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _line('Name', '${sub.firstName} ${sub.lastName}'.trim()),
              _line('Phone', sub.phone),
              _line('Course', sub.courseTitle),
              _line('CourseId', sub.courseId),
              _line('CreatedAt', sub.createdAt.toString()),
              _line('SubscriptionId', sub.id),
            ],
          ),
        ),
      ),
    );
  }

  Widget _line(String k, String v) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(k, style: const TextStyle(fontWeight: FontWeight.w900, color: primaryBlue)),
          ),
          Expanded(
            child: Text(v.isEmpty ? '-' : v, style: TextStyle(fontWeight: FontWeight.w700, color: Colors.black.withOpacity(0.7))),
          ),
        ],
      ),
    );
  }

  Widget _card({required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: uiBorder),
      ),
      padding: const EdgeInsets.all(12),
      child: child,
    );
  }
}

// -------------------- CREATE (ADD) --------------------

class SubscriptionCreateScreen extends StatefulWidget {
  const SubscriptionCreateScreen({super.key});

  @override
  State<SubscriptionCreateScreen> createState() => _SubscriptionCreateScreenState();
}

class _SubscriptionCreateScreenState extends State<SubscriptionCreateScreen> {
  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);

  final firstNameC = TextEditingController();
  final lastNameC = TextEditingController();
  final phoneC = TextEditingController();

  String? selectedCourseId;
  String selectedCourseTitle = '';

  bool saving = false;

  DatabaseReference get _subsRef => FirebaseDatabase.instance.ref('subscriptions');
  DatabaseReference get _coursesRef => FirebaseDatabase.instance.ref('courses');

  @override
  void dispose() {
    firstNameC.dispose();
    lastNameC.dispose();
    phoneC.dispose();
    super.dispose();
  }

  Future<void> _pickCourse() async {
    final snap = await _coursesRef.get();
    final v = snap.value;

    final items = <Map<String, String>>[];
    if (v is Map) {
      v.forEach((k, val) {
        if (k == null || val == null) return;
        if (val is Map) {
          final m = val.map((kk, vv) => MapEntry(kk.toString(), vv));
          final title = (m['title'] ?? m['name'] ?? '').toString().trim();
          items.add({'id': k.toString(), 'title': title.isEmpty ? k.toString() : title});
        }
      });
    }

    items.sort((a, b) => a['title']!.compareTo(b['title']!));

    final picked = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Pick a course'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: items.length,
            itemBuilder: (context, i) {
              final c = items[i];
              return ListTile(
                title: Text(c['title']!),
                subtitle: Text(c['id']!, style: TextStyle(color: Colors.black.withOpacity(0.5), fontSize: 12)),
                onTap: () => Navigator.pop(context, c),
              );
            },
          ),
        ),
      ),
    );

    if (picked == null) return;
    setState(() {
      selectedCourseId = picked['id'];
      selectedCourseTitle = picked['title'] ?? '';
    });
  }

  Future<void> _save() async {
    if (selectedCourseId == null || selectedCourseId!.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Pick a course first')));
      return;
    }

    final fn = firstNameC.text.trim();
    final ln = lastNameC.text.trim();
    final ph = phoneC.text.trim();

    if (fn.isEmpty || ln.isEmpty || ph.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Fill first name, last name, phone')));
      return;
    }

    setState(() => saving = true);

    try {
      final newRef = _subsRef.push();
      await newRef.set({
        'courseId': selectedCourseId,
        'courseTitle': selectedCourseTitle,
        'createdAt': ServerValue.timestamp,
        'firstName': fn,
        'lastName': ln,
        'phone': ph,
      });

      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Save failed: $e')));
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: primaryBlue),
        title: const Text('Add Subscription', style: TextStyle(color: primaryBlue, fontWeight: FontWeight.w900)),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: actionOrange,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            ),
            onPressed: saving ? null : _save,
            child: Text(saving ? 'Saving…' : 'Save Subscription'),
          ),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: uiBorder),
          ),
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              TextField(
                controller: firstNameC,
                decoration: const InputDecoration(labelText: 'First name'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: lastNameC,
                decoration: const InputDecoration(labelText: 'Last name'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: phoneC,
                decoration: const InputDecoration(labelText: 'Phone'),
                keyboardType: TextInputType.phone,
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _pickCourse,
                icon: const Icon(Icons.school_rounded),
                label: Text(selectedCourseId == null ? 'Pick course' : 'Course: $selectedCourseTitle'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// -------------------- MODEL + PARSE --------------------

class SubscriptionItem {
  SubscriptionItem({
    required this.id,
    required this.courseId,
    required this.courseTitle,
    required this.createdAt,
    required this.firstName,
    required this.lastName,
    required this.phone,
  });

  final String id;
  final String courseId;
  final String courseTitle;
  final int createdAt;
  final String firstName;
  final String lastName;
  final String phone;
}

List<SubscriptionItem> _parseSubscriptions(dynamic v) {
  if (v is! Map) return [];

  int asInt(dynamic x) {
    if (x is int) return x;
    if (x is num) return x.toInt();
    return int.tryParse(x?.toString() ?? '') ?? 0;
  }

  final out = <SubscriptionItem>[];

  v.forEach((k, val) {
    if (k == null || val == null) return;
    if (val is! Map) return;

    final m = val.map((kk, vv) => MapEntry(kk.toString(), vv));

    out.add(
      SubscriptionItem(
        id: k.toString(),
        courseId: (m['courseId'] ?? '').toString(),
        courseTitle: (m['courseTitle'] ?? '').toString(),
        createdAt: asInt(m['createdAt']),
        firstName: (m['firstName'] ?? '').toString(),
        lastName: (m['lastName'] ?? '').toString(),
        phone: (m['phone'] ?? '').toString(),
      ),
    );
  });

  // newest first
  out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return out;
}
