import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:url_launcher/url_launcher.dart';
import '../shared/human_error.dart';
import '../shared/admin_web_layout.dart';

import 'admin_learners.dart'; // LearnerEditorScreen, EditorMode, LearnerPrefill
import '../shared/app_feedback.dart';

const List<String> _genderOptions = ['Male', 'Female'];

// =======================================================
// ADMIN SUBSCRIPTIONS (FULL REPLACEMENT FILE)
// - Supports new enrollment fields:
//   fullName, phone, courseId, courseTitle, createdAt,
//   deliveryKey, deliveryLabel, studyMode, studyModeLabel,
//   selectedFee, accessMode, accessDurationMonths, accessLabel,
//   dob/dateOfBirth, email, additionalInfo
// - Still supports old data:
//   firstName + lastName
// - Also tolerates snake_case variants if they ever exist
// - Phone is clickable in list + details
// - "Create Learner" splits fullName into first/last
// =======================================================

class AdminSubscriptionsScreen extends StatelessWidget {
  const AdminSubscriptionsScreen({super.key});

  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);

  DatabaseReference get _subsRef =>
      FirebaseDatabase.instance.ref('subscriptions');

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
          const SizedBox.shrink(),
          IconButton(
            tooltip: 'Add subscription',
            icon: const Icon(Icons.add_circle_rounded, color: actionOrange),
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const SubscriptionCreateScreen(),
                ),
              );
            },
          ),
        ],
      ),
      body: adminWebBodyFrame(
        context: context,
        maxWidth: 1380,
        child: StreamBuilder<DatabaseEvent>(
          stream: _subsRef.onValue,
          builder: (context, snap) {
            if (snap.hasError) {
              return const Center(child: Text('Error loading subscriptions.'));
            }

            final v = snap.data?.snapshot.value;
            final items = parseSubscriptions(v);

            if (items.isEmpty) {
              return const Center(child: Text('No subscriptions yet.'));
            }

            final webWide = isWebDesktop(context, minWidth: 1100);

            if (webWide) {
              return GridView.builder(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                  childAspectRatio: 3.4,
                ),
                itemCount: items.length,
                itemBuilder: (context, i) {
                  final s = items[i];
                  return _buildSubscriptionTile(context, s);
                },
              );
            }

            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, i) {
                final s = items[i];
                return _buildSubscriptionTile(context, s);
              },
            );
          },
        ),
      ),
    );
  }

  Widget _buildSubscriptionTile(BuildContext context, SubscriptionItem s) {
    final deliveryText = s.studyTypeDisplay;

    final subtitleParts = <String>[
      if (s.courseTitle.trim().isNotEmpty) s.courseTitle,
      if (deliveryText.trim().isNotEmpty) deliveryText,
      if (s.phone.trim().isNotEmpty) s.phone,
    ];

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
                (s.displayName.isNotEmpty
                    ? s.displayName[0].toUpperCase()
                    : 'S'),
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  color: primaryBlue,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.displayName,
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      color: primaryBlue,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitleParts.isEmpty ? '-' : subtitleParts.join('  •  '),
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: Colors.black.withValues(alpha: 0.65),
                      fontSize: 12,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (s.selectedFee != null ||
                      s.accessLabel.trim().isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (s.selectedFee != null)
                          _pill(
                            label: '${s.selectedFee!.toStringAsFixed(0)} DA',
                            bg: actionOrange.withValues(alpha: 0.10),
                            fg: actionOrange,
                          ),
                        if (s.accessLabel.trim().isNotEmpty)
                          _pill(
                            label: s.accessLabel,
                            bg: primaryBlue.withValues(alpha: 0.08),
                            fg: primaryBlue,
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            IconButton(
              tooltip: 'Call',
              icon: const Icon(Icons.call, color: actionOrange),
              onPressed: s.phone.trim().isEmpty
                  ? null
                  : () => callPhone(s.phone),
            ),
            const Icon(Icons.chevron_right_rounded, color: primaryBlue),
          ],
        ),
      ),
    );
  }

  static Widget _pill({
    required String label,
    required Color bg,
    required Color fg,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: fg),
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

  DatabaseReference get _subsRef =>
      FirebaseDatabase.instance.ref('subscriptions');

  Future<bool> _confirmDelete(BuildContext context) async {
    return (await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Delete subscription?'),
            content: const Text('This cannot be undone.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Colors.red),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        )) ??
        false;
  }

  @override
  Widget build(BuildContext context) {
    final split = splitFullName(sub.fullName);

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
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
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
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  onPressed: () async {
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => LearnerEditorScreen(
                          mode: EditorMode.create,
                          prefill: LearnerPrefill(
                            firstName: split.first,
                            lastName: split.last,
                            gender: sub.gender,
                            phone1: sub.phone,
                            dob: sub.dob,
                            email: sub.email,
                            selectedCourseIds: {
                              if (sub.courseId.trim().isNotEmpty) sub.courseId,
                            },
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
      body: adminWebBodyFrame(
        context: context,
        maxWidth: 980,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: _card(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _line('Name', sub.displayName),
                _phoneLine(context, sub.phone),
                _line('Course', sub.courseTitle),
                _line('Study type', sub.studyTypeDisplay),
                _line('Gender', sub.gender),
                _line('Date of birth', sub.dob),
                _line('Email', sub.email),
                _line('Study mode', sub.studyModeLabel),
                _line(
                  'Selected fee',
                  sub.selectedFee == null
                      ? ''
                      : '${sub.selectedFee!.toStringAsFixed(0)} DA',
                ),
                _line(
                  'Access months',
                  sub.accessDurationMonths == null
                      ? ''
                      : sub.accessDurationMonths.toString(),
                ),
                _line('Access label', sub.accessLabel),
                _line('Additional info', sub.additionalInfo),
                _line('CreatedAt', formatTimestamp(sub.createdAt)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _phoneLine(BuildContext context, String phone) {
    final p = phone.trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(
            width: 110,
            child: Text(
              'Phone',
              style: TextStyle(fontWeight: FontWeight.w900, color: primaryBlue),
            ),
          ),
          Expanded(
            child: InkWell(
              onTap: p.isEmpty ? null : () => callPhone(p),
              child: Text(
                p.isEmpty ? '-' : p,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: p.isEmpty
                      ? Colors.black.withValues(alpha: 0.7)
                      : actionOrange,
                  decoration: p.isEmpty
                      ? TextDecoration.none
                      : TextDecoration.underline,
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Call',
            icon: const Icon(Icons.call, color: actionOrange),
            onPressed: p.isEmpty ? null : () => callPhone(p),
          ),
        ],
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
            child: Text(
              k,
              style: const TextStyle(
                fontWeight: FontWeight.w900,
                color: primaryBlue,
              ),
            ),
          ),
          Expanded(
            child: Text(
              v.trim().isEmpty ? '-' : v,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: Colors.black.withValues(alpha: 0.7),
              ),
            ),
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
  State<SubscriptionCreateScreen> createState() =>
      _SubscriptionCreateScreenState();
}

class _SubscriptionCreateScreenState extends State<SubscriptionCreateScreen> {
  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);

  final firstNameC = TextEditingController();
  final lastNameC = TextEditingController();
  final phoneC = TextEditingController();
  final dobC = TextEditingController();
  final emailC = TextEditingController();
  String? _gender;

  String? selectedCourseId;
  String selectedCourseTitle = '';

  bool saving = false;

  DatabaseReference get _subsRef =>
      FirebaseDatabase.instance.ref('subscriptions');
  DatabaseReference get _coursesRef => FirebaseDatabase.instance.ref('courses');

  @override
  void dispose() {
    firstNameC.dispose();
    lastNameC.dispose();
    phoneC.dispose();
    dobC.dispose();
    emailC.dispose();
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
          items.add({
            'id': k.toString(),
            'title': title.isEmpty ? k.toString() : title,
          });
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
                subtitle: Text(
                  c['id']!,
                  style: TextStyle(
                    color: Colors.black.withValues(alpha: 0.5),
                    fontSize: 12,
                  ),
                ),
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
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Pick a course first')),
      );
      return;
    }

    final fn = firstNameC.text.trim();
    final ln = lastNameC.text.trim();
    final ph = phoneC.text.trim();
    final dob = dobC.text.trim();
    final email = emailC.text.trim();
    final gender = (_gender ?? '').trim();

    if (fn.isEmpty || ln.isEmpty || ph.isEmpty) {
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Fill first name, last name, phone')),
      );
      return;
    }

    if (!_genderOptions.contains(gender)) {
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('Select gender')),
      );
      return;
    }

    setState(() => saving = true);

    try {
      final newRef = _subsRef.push();
      await newRef.set({
        'courseId': selectedCourseId,
        'courseTitle': selectedCourseTitle,
        'createdAt': ServerValue.timestamp,

        // compatible with old + new UI
        'firstName': fn,
        'lastName': ln,
        'fullName': '$fn $ln'.trim(),
        'phone': ph,
        'gender': gender,
        'dob': dob,
        'dateOfBirth': dob,
        'email': email,
      });

      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      AppToast.fromSnackBar(
        context,
        SnackBar(
          content: Text(
            toHumanError(e, fallback: 'Could not save subscription changes.'),
          ),
        ),
      );
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
        title: const Text(
          'Add Subscription',
          style: TextStyle(color: primaryBlue, fontWeight: FontWeight.w900),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: actionOrange,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            onPressed: saving ? null : _save,
            child: Text(saving ? 'Saving…' : 'Save Subscription'),
          ),
        ),
      ),
      body: adminWebBodyFrame(
        context: context,
        maxWidth: 980,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: uiBorder),
            ),
            padding: const EdgeInsets.all(12),
            child: LayoutBuilder(
              builder: (context, c) {
                final twoCols =
                    isWebDesktop(context, minWidth: 900) && c.maxWidth >= 700;
                final fieldWidth = twoCols ? (c.maxWidth - 10) / 2 : c.maxWidth;
                return Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    SizedBox(
                      width: fieldWidth,
                      child: TextField(
                        controller: firstNameC,
                        decoration: const InputDecoration(
                          labelText: 'First name',
                        ),
                      ),
                    ),
                    SizedBox(
                      width: fieldWidth,
                      child: TextField(
                        controller: lastNameC,
                        decoration: const InputDecoration(
                          labelText: 'Last name',
                        ),
                      ),
                    ),
                    SizedBox(
                      width: fieldWidth,
                      child: TextField(
                        controller: phoneC,
                        decoration: const InputDecoration(labelText: 'Phone'),
                        keyboardType: TextInputType.phone,
                      ),
                    ),
                    SizedBox(
                      width: fieldWidth,
                      child: DropdownButtonFormField<String>(
                        initialValue: _gender,
                        decoration: const InputDecoration(labelText: 'Gender'),
                        items: _genderOptions
                            .map(
                              (value) => DropdownMenuItem<String>(
                                value: value,
                                child: Text(value),
                              ),
                            )
                            .toList(),
                        onChanged: (v) => setState(() => _gender = v),
                      ),
                    ),
                    SizedBox(
                      width: fieldWidth,
                      child: TextField(
                        controller: dobC,
                        decoration: const InputDecoration(
                          labelText: 'Date of birth',
                        ),
                      ),
                    ),
                    SizedBox(
                      width: fieldWidth,
                      child: TextField(
                        controller: emailC,
                        decoration: const InputDecoration(
                          labelText: 'Email (optional)',
                        ),
                        keyboardType: TextInputType.emailAddress,
                      ),
                    ),
                    SizedBox(
                      width: twoCols ? c.maxWidth : fieldWidth,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton.icon(
                          onPressed: _pickCourse,
                          icon: const Icon(Icons.school_rounded),
                          label: Text(
                            selectedCourseId == null
                                ? 'Pick course'
                                : 'Course: $selectedCourseTitle',
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

// -------------------- MODEL + HELPERS --------------------

String _normalizeDeliveryKey(String key) {
  final v = key.trim().toLowerCase();

  switch (v) {
    case 'online':
    case 'flexible':
      return 'flexible';

    case 'live':
    case 'private':
      return 'private';

    case 'recorded':
      return 'recorded';

    case 'inclass':
    case 'in-class':
    case 'in class':
    case 'in_class':
      return 'inclass';

    default:
      return v;
  }
}

String _canonicalDeliveryLabel(String key) {
  switch (_normalizeDeliveryKey(key)) {
    case 'inclass':
      return 'In-Class';
    case 'flexible':
      return 'Flexible';
    case 'private':
      return 'Private';
    case 'recorded':
      return 'Recorded';
    default:
      return key.trim();
  }
}

String _normalizeStudyMode(String key) {
  final v = key.trim().toLowerCase();

  switch (v) {
    case 'online':
      return 'online';
    case 'inclass':
    case 'in-class':
    case 'in class':
    case 'in_class':
      return 'inclass';
    default:
      return '';
  }
}

String _studyModeLabel(String key) {
  switch (_normalizeStudyMode(key)) {
    case 'online':
      return 'Online';
    case 'inclass':
      return 'In-Class';
    default:
      return '';
  }
}

class SubscriptionItem {
  SubscriptionItem({
    required this.id,
    required this.courseId,
    required this.courseTitle,
    required this.createdAt,
    required this.fullName,
    required this.phone,
    required this.gender,
    required this.deliveryKey,
    required this.deliveryLabel,
    required this.studyMode,
    required this.studyModeLabel,
    required this.selectedFee,
    required this.accessMode,
    required this.accessDurationMonths,
    required this.accessLabel,
    required this.dob,
    required this.email,
    required this.additionalInfo,
  });

  final String id;
  final String courseId;
  final String courseTitle;
  final int createdAt;
  final String fullName;
  final String phone;
  final String gender;

  final String deliveryKey;
  final String deliveryLabel;
  final String studyMode;
  final String studyModeLabel;
  final double? selectedFee;
  final String accessMode;
  final int? accessDurationMonths;
  final String accessLabel;
  final String dob;
  final String email;
  final String additionalInfo;

  String get displayName =>
      fullName.trim().isEmpty ? '(No name)' : fullName.trim();

  String get studyTypeDisplay {
    final delivery = deliveryLabel.trim();
    final mode = studyModeLabel.trim();

    if (delivery.isEmpty && mode.isEmpty) return '';
    if (_normalizeDeliveryKey(deliveryKey) == 'private' && mode.isNotEmpty) {
      return delivery.isEmpty ? mode : '$delivery • $mode';
    }
    return delivery;
  }
}

List<SubscriptionItem> parseSubscriptions(dynamic v) {
  if (v is! Map) return [];

  int asInt(dynamic x) {
    if (x is int) return x;
    if (x is num) return x.toInt();
    return int.tryParse(x?.toString() ?? '') ?? 0;
  }

  double? asDouble(dynamic x) {
    if (x == null) return null;
    if (x is double) return x;
    if (x is int) return x.toDouble();
    if (x is num) return x.toDouble();
    return double.tryParse(x.toString().trim());
  }

  String readString(Map<String, dynamic> m, List<String> keys) {
    for (final key in keys) {
      final value = m[key];
      if (value == null) continue;
      final s = value.toString().trim();
      if (s.isNotEmpty) return s;
    }
    return '';
  }

  final out = <SubscriptionItem>[];

  v.forEach((k, val) {
    if (k == null || val == null) return;
    if (val is! Map) return;

    final m = val.map((kk, vv) => MapEntry(kk.toString(), vv));

    final dbFullName = readString(m, ['fullName', 'full_name']);
    final fn = readString(m, ['firstName', 'first_name']);
    final ln = readString(m, ['lastName', 'last_name']);
    final computedName = dbFullName.isNotEmpty
        ? dbFullName
        : ('$fn $ln').trim();

    final rawDeliveryKey = readString(m, ['deliveryKey', 'delivery_key']);
    final normalizedDeliveryKey = _normalizeDeliveryKey(rawDeliveryKey);

    final rawDeliveryLabel = readString(m, [
      'deliveryLabel',
      'delivery_label',
      'delivery',
    ]);
    final normalizedDeliveryLabel = rawDeliveryLabel.isNotEmpty
        ? rawDeliveryLabel
        : _canonicalDeliveryLabel(normalizedDeliveryKey);

    final rawStudyMode = readString(m, ['studyMode', 'study_mode']);
    final normalizedStudyMode = _normalizeStudyMode(rawStudyMode);

    final rawStudyModeLabel = readString(m, [
      'studyModeLabel',
      'study_mode_label',
    ]);
    final normalizedStudyModeLabel = rawStudyModeLabel.isNotEmpty
        ? rawStudyModeLabel
        : _studyModeLabel(normalizedStudyMode);

    out.add(
      SubscriptionItem(
        id: k.toString(),
        courseId: readString(m, ['courseId', 'course_id']),
        courseTitle: readString(m, ['courseTitle', 'course_title']),
        createdAt: asInt(m['createdAt'] ?? m['created_at']),
        fullName: computedName,
        phone: readString(m, ['phone', 'phone1', 'phone_1']),
        gender: readString(m, ['gender']),
        deliveryKey: normalizedDeliveryKey,
        deliveryLabel: normalizedDeliveryLabel,
        studyMode: normalizedStudyMode,
        studyModeLabel: normalizedStudyModeLabel,
        selectedFee: asDouble(m['selectedFee'] ?? m['selected_fee']),
        accessMode: readString(m, ['accessMode', 'access_mode']),
        accessDurationMonths:
            (m['accessDurationMonths'] ?? m['access_duration_months']) == null
            ? null
            : asInt(m['accessDurationMonths'] ?? m['access_duration_months']),
        accessLabel: readString(m, ['accessLabel', 'access_label']),
        dob: readString(m, ['dob', 'dateOfBirth', 'date_of_birth']),
        email: readString(m, ['email', 'mail']),
        additionalInfo: readString(m, ['additionalInfo', 'additional_info']),
      ),
    );
  });

  out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return out;
}

({String first, String last}) splitFullName(String fullName) {
  final cleaned = fullName.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (cleaned.isEmpty) return (first: '', last: '');

  final parts = cleaned.split(' ');
  if (parts.length == 1) return (first: parts[0], last: '');

  return (first: parts.first, last: parts.sublist(1).join(' '));
}

String formatTimestamp(int value) {
  if (value <= 0) return '-';
  final dt = DateTime.fromMillisecondsSinceEpoch(value);
  final y = dt.year.toString().padLeft(4, '0');
  final m = dt.month.toString().padLeft(2, '0');
  final d = dt.day.toString().padLeft(2, '0');
  final hh = dt.hour.toString().padLeft(2, '0');
  final mm = dt.minute.toString().padLeft(2, '0');
  return '$y-$m-$d $hh:$mm';
}

Future<void> callPhone(String phone) async {
  final cleaned = phone.trim();
  if (cleaned.isEmpty) return;

  final uri = Uri(scheme: 'tel', path: cleaned);
  await launchUrl(uri);
}
