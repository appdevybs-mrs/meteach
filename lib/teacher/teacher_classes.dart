import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';

class TeacherClassesScreen extends StatefulWidget {
  const TeacherClassesScreen({super.key});

  @override
  State<TeacherClassesScreen> createState() => _TeacherClassesScreenState();
}

class _TeacherClassesScreenState extends State<TeacherClassesScreen> {
  // ===== Brand colors (same style as AdminHome) =====
  static const primaryBlue = Color(0xFF1A2B48);
  static const actionOrange = Color(0xFFF98D28);
  static const mainText = Color(0xFF2D2D2D);
  static const appBg = Color(0xFFF4F7F9);
  static const uiBorder = Color(0xFFD1D9E0);

  // ===== DB NODES =====
  static const String usersNode = "users";
  static const String classesNode = "classes";

  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  late final DatabaseReference _usersRef = _db.child(usersNode);
  late final DatabaseReference _classesRef = _db.child(classesNode);

  bool _busy = true;
  String? _error;

  String _teacherUid = '';
  String _teacherSerial = '';
  String _teacherName = '';

  List<Map<String, dynamic>> _myClasses = [];

  @override
  void initState() {
    super.initState();
    _loadMyClasses();
  }

  String _norm(String s) => s.trim().toLowerCase();

  // ✅ role check: teacher / Teacher / TEACHER / teachers / teacher(s)
  bool _isTeacherRole(dynamic role) {
    final r = (role ?? "").toString().trim().toLowerCase();
    return r == "teacher" || r == "teachers" || r == "teacher(s)";
  }

  Future<void> _loadMyClasses() async {
    setState(() {
      _busy = true;
      _error = null;
      _myClasses = [];
      _teacherUid = '';
      _teacherSerial = '';
      _teacherName = '';
    });

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw Exception('Not logged in.');

      _teacherUid = user.uid;

      // 1) Load teacher data from users/<uid>
      final userSnap = await _usersRef.child(_teacherUid).get();
      if (!userSnap.exists) throw Exception('Teacher user record not found in /users/<uid>.');

      final u = (userSnap.value is Map)
          ? Map<String, dynamic>.from(userSnap.value as Map)
          : <String, dynamic>{};

      // ✅ IMPORTANT: your DB uses "serial" not "instructorserial"
      _teacherSerial = (u['serial'] ?? '').toString().trim();
      final fn = (u['first_name'] ?? '').toString().trim();
      final ln = (u['last_name'] ?? '').toString().trim();
      _teacherName = ('$fn $ln').trim();

      // Optional: ensure this user is really a teacher
      if (!_isTeacherRole(u['role'])) {
        throw Exception('Your account role is not "teacher". Found: "${u['role']}"');
      }

      // 2) Load all classes and filter by instructor_current.uid (NEW NODE)
      final classesSnap = await _classesRef.get();

      if (!classesSnap.exists || classesSnap.value == null) {
        setState(() {
          _myClasses = [];
          _busy = false;
        });
        return;
      }

      final raw = (classesSnap.value is Map)
          ? Map<dynamic, dynamic>.from(classesSnap.value as Map)
          : <dynamic, dynamic>{};

      final List<Map<String, dynamic>> mine = [];

      raw.forEach((key, value) {
        final c = (value is Map)
            ? Map<String, dynamic>.from(value as Map)
            : <String, dynamic>{};

        // ✅ NEW: instructor_current.uid
        String curUid = '';
        String curName = '';

        final cur = c['instructor_current'];
        if (cur is Map) {
          final curMap = Map<String, dynamic>.from(cur);
          curUid = (curMap['uid'] ?? '').toString().trim();
          curName = (curMap['name'] ?? '').toString().trim();
        }

        // OLD fallback: instructor is string name
        final legacyInstructorName = (c['instructor'] ?? '').toString().trim();

        final matchesUid = curUid.isNotEmpty && curUid == _teacherUid;

        // backup match by name (in case old classes have no instructor_current)
        final matchesName = _teacherName.isNotEmpty &&
            _norm(legacyInstructorName.isNotEmpty ? legacyInstructorName : curName) == _norm(_teacherName);

        // (Optional) last fallback by serial if you still have older classes with serial stored
        final legacySerial = (c['instructorserial'] ?? c['serial'] ?? '').toString().trim();
        final matchesSerial = _teacherSerial.isNotEmpty && legacySerial == _teacherSerial;

        if (matchesUid || matchesName || matchesSerial) {
          mine.add({
            'id': key.toString(),
            ...c.map((k, v) => MapEntry(k.toString(), v)),
          });
        }
      });

      // Optional: sort by updated_at / updatedAt / created_at desc
      mine.sort((a, b) {
        int numVal(dynamic v) {
          if (v is num) return v.toInt();
          return int.tryParse(v?.toString() ?? '') ?? 0;
        }

        final aU = numVal(a['updated_at'] ?? a['updatedAt'] ?? 0);
        final bU = numVal(b['updated_at'] ?? b['updatedAt'] ?? 0);

        if (aU != bU) return bU.compareTo(aU);

        final aC = numVal(a['created_at'] ?? a['createdAt'] ?? 0);
        final bC = numVal(b['created_at'] ?? b['createdAt'] ?? 0);
        return bC.compareTo(aC);
      });

      setState(() {
        _myClasses = mine;
        _busy = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _busy = false;
      });
    }
  }

  int _learnersCount(Map<String, dynamic> classData) {
    final learners = classData['learners'];
    if (learners is Map) return learners.length;
    return 0;
  }

  List<String> _learnerUids(Map<String, dynamic> classData) {
    final learners = classData['learners'];
    if (learners is Map) {
      return learners.keys.map((e) => e.toString()).toList();
    }
    return [];
  }

  String _scheduleSummary(Map<String, dynamic> classData) {
    final schedule = classData['schedule'];
    if (schedule is Map) {
      final firstDate = (schedule['first_session_date'] ?? '').toString();
      final sessionsCount = (schedule['sessions_count'] ?? '').toString();
      return 'First: ${firstDate.isEmpty ? '-' : firstDate} • Sessions: ${sessionsCount.isEmpty ? '-' : sessionsCount}';
    }
    return '-';
  }

  Future<Map<String, dynamic>> _loadLearner(String uid) async {
    final snap = await _usersRef.child(uid).get();
    if (!snap.exists) return {'uid': uid};

    final data = (snap.value is Map)
        ? Map<String, dynamic>.from(snap.value as Map)
        : <String, dynamic>{};

    return {
      'uid': uid,
      'first_name': (data['first_name'] ?? '').toString(),
      'last_name': (data['last_name'] ?? '').toString(),
      'email': (data['email'] ?? '').toString(),
      'phone1': (data['phone1'] ?? '').toString(),
      'status': (data['status'] ?? '').toString(),
    };
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
          'My Classes',
          style: TextStyle(
            color: primaryBlue,
            fontWeight: FontWeight.w900,
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded, color: actionOrange),
            onPressed: _busy ? null : _loadMyClasses,
          ),
        ],
      ),
      body: Stack(
        children: [
          Container(color: appBg),

          // Watermark
          Positioned.fill(
            child: IgnorePointer(
              child: Opacity(
                opacity: 0.05,
                child: Center(
                  child: FractionallySizedBox(
                    widthFactor: 0.75,
                    child: Image.asset(
                      'assets/images/ybs_logo.png',
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                    ),
                  ),
                ),
              ),
            ),
          ),

          if (_busy)
            const Center(child: CircularProgressIndicator())
          else if (_error != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  _error!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontWeight: FontWeight.w800,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          else
            ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Teacher header info
                Card(
                  elevation: 0,
                  color: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                    side: BorderSide(color: uiBorder.withOpacity(0.8)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Teacher',
                          style: TextStyle(
                            color: primaryBlue,
                            fontWeight: FontWeight.w900,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _teacherName.isEmpty ? '-' : _teacherName,
                          style: const TextStyle(
                            color: mainText,
                            fontWeight: FontWeight.w900,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Serial: ${_teacherSerial.isEmpty ? '-' : _teacherSerial}',
                          style: TextStyle(
                            color: mainText.withOpacity(0.75),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'UID: ${_teacherUid.isEmpty ? '-' : _teacherUid}',
                          style: TextStyle(
                            color: mainText.withOpacity(0.55),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 14),

                if (_myClasses.isEmpty)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'No classes found for you yet.',
                        style: TextStyle(
                          color: mainText,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  )
                else
                  ..._myClasses.map((c) => _classCard(c)).toList(),
              ],
            ),
        ],
      ),
    );
  }

  Widget _classCard(Map<String, dynamic> c) {
    final title = (c['course_title'] ?? 'Class').toString();
    final code = (c['course_code'] ?? '').toString();
    final level = (c['course_level'] ?? '').toString();
    final duration = (c['course_duration'] ?? '').toString();
    final status = (c['status'] ?? '').toString();
    final classId = (c['class_id'] ?? c['id'] ?? '').toString();

    final learnersCount = _learnersCount(c);
    final learnersUids = _learnerUids(c);

    return Card(
      elevation: 0,
      color: Colors.white,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: uiBorder.withOpacity(0.8)),
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        collapsedIconColor: primaryBlue,
        iconColor: primaryBlue,
        title: Text(
          title,
          style: const TextStyle(
            color: primaryBlue,
            fontWeight: FontWeight.w900,
          ),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Code: ${code.isEmpty ? '-' : code}  •  Level: ${level.isEmpty ? '-' : level}',
                style: TextStyle(
                  color: mainText.withOpacity(0.8),
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Duration: ${duration.isEmpty ? '-' : duration}  •  Status: ${status.isEmpty ? '-' : status}',
                style: TextStyle(
                  color: mainText.withOpacity(0.8),
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _scheduleSummary(c),
                style: TextStyle(
                  color: mainText.withOpacity(0.8),
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Class ID: ${classId.isEmpty ? '-' : classId}',
                style: TextStyle(
                  color: mainText.withOpacity(0.6),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        children: [
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.people_alt_rounded, color: primaryBlue, size: 18),
              const SizedBox(width: 8),
              Text(
                'Learners ($learnersCount)',
                style: const TextStyle(
                  color: mainText,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (learnersUids.isEmpty)
            Text(
              'No learners in this class yet.',
              style: TextStyle(
                color: mainText.withOpacity(0.7),
                fontWeight: FontWeight.w700,
              ),
            )
          else
            Column(
              children: learnersUids.map((uid) => _learnerTile(uid)).toList(),
            ),
        ],
      ),
    );
  }

  Widget _learnerTile(String uid) {
    return FutureBuilder<Map<String, dynamic>>(
      future: _loadLearner(uid),
      builder: (context, snap) {
        final loading = snap.connectionState == ConnectionState.waiting;
        final data = snap.data ?? {'uid': uid};

        final fn = (data['first_name'] ?? '').toString().trim();
        final ln = (data['last_name'] ?? '').toString().trim();
        final name = ('$fn $ln').trim();
        final email = (data['email'] ?? '').toString().trim();
        final phone = (data['phone1'] ?? '').toString().trim();

        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: uiBorder.withOpacity(0.85)),
          ),
          child: ListTile(
            dense: true,
            leading: CircleAvatar(
              backgroundColor: primaryBlue.withOpacity(0.08),
              child: const Icon(Icons.person_rounded, color: primaryBlue),

            ),
            title: Text(
              loading ? 'Loading...' : (name.isEmpty ? 'Learner: $uid' : name),
              style: const TextStyle(
                color: mainText,
                fontWeight: FontWeight.w900,
              ),
            ),
            subtitle: Text(
              [
                if (email.isNotEmpty) email,
                if (phone.isNotEmpty) phone,
                if (email.isEmpty && phone.isEmpty) 'UID: $uid',
              ].join(' • '),
              style: TextStyle(
                color: mainText.withOpacity(0.7),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        );
      },
    );
  }
}
