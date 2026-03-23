import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../shared/app_theme.dart';
import '../shared/human_error.dart';
import '../shared/watermark_background.dart';
import '../shared/ybs_busy_logo.dart';
import '../services/backend_api.dart';

enum _LeaveChoice { save, discard, cancel }

class _BioChoice {
  final String ar;
  final String en;

  const _BioChoice({required this.ar, required this.en});
}

class LearnerProfileScreen extends StatefulWidget {
  const LearnerProfileScreen({super.key});

  @override
  State<LearnerProfileScreen> createState() => _LearnerProfileScreenState();
}

class _LearnerProfileScreenState extends State<LearnerProfileScreen> {
  static const usersNode = 'users';
  static const syllabiNode = 'syllabi';
  static const bookingProgressNode = 'booking_progress';

  final _auth = FirebaseAuth.instance;
  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  late final DatabaseReference _usersRef = _db.child(usersNode);
  late final DatabaseReference _syllabiRef = _db.child(syllabiNode);

  final _formKey = GlobalKey<FormState>();

  bool _busy = false;
  bool _uploadingMainPhoto = false;
  bool _uploadingExtraPhotos = false;

  String? _error;

  String _uid = '';
  Map<String, dynamic> _user = {};

  final _fn = TextEditingController();
  final _ln = TextEditingController();
  final _phone1 = TextEditingController();
  final _phone2 = TextEditingController();
  final _dob = TextEditingController();
  final _aboutMe = TextEditingController();

  String? _profilePhotoUrl;
  final List<String> _photoUrls = [];

  String _initialFirstName = '';
  String _initialLastName = '';
  String _initialPhone1 = '';
  String _initialPhone2 = '';
  String _initialDob = '';
  String _initialAboutMe = '';
  String _initialProfilePhotoUrl = '';
  List<String> _initialPhotoUrls = const [];
  Set<String> _initialHobbiesAr = const <String>{};
  Set<String> _initialLearningAr = const <String>{};
  Set<String> _initialTraitsAr = const <String>{};
  String _initialGoalAr = '';

  static const int _maxExtraPhotos = 6;

  final Set<String> _selectedHobbiesAr = <String>{};
  final Set<String> _selectedLearningAr = <String>{};
  final Set<String> _selectedTraitsAr = <String>{};
  String? _selectedGoalAr;

  static const List<_BioChoice> _hobbyChoices = [
    _BioChoice(ar: 'كرة القدم', en: 'football'),
    _BioChoice(ar: 'الرسم', en: 'drawing'),
    _BioChoice(ar: 'الألعاب', en: 'games'),
    _BioChoice(ar: 'القراءة', en: 'reading'),
    _BioChoice(ar: 'الموسيقى', en: 'music'),
    _BioChoice(ar: 'الغناء', en: 'singing'),
    _BioChoice(ar: 'الرقص', en: 'dancing'),
    _BioChoice(ar: 'العلوم', en: 'science'),
    _BioChoice(ar: 'الرياضيات', en: 'math'),
    _BioChoice(ar: 'الفنون', en: 'art'),
    _BioChoice(ar: 'البرمجة', en: 'coding'),
    _BioChoice(ar: 'الحيوانات', en: 'animals'),
    _BioChoice(ar: 'الطبخ', en: 'cooking'),
    _BioChoice(ar: 'اللغات', en: 'languages'),
  ];

  static const List<_BioChoice> _learningChoices = [
    _BioChoice(ar: 'الأنشطة التفاعلية', en: 'interactive activities'),
    _BioChoice(ar: 'الألعاب التعليمية', en: 'learning games'),
    _BioChoice(ar: 'الشرح خطوة بخطوة', en: 'step-by-step explanations'),
    _BioChoice(ar: 'الصور والوسائل البصرية', en: 'visual materials'),
    _BioChoice(ar: 'المحادثة', en: 'speaking activities'),
    _BioChoice(ar: 'العمل الجماعي', en: 'group work'),
    _BioChoice(ar: 'التكرار والمراجعة', en: 'review and repetition'),
    _BioChoice(ar: 'الأنشطة الإبداعية', en: 'creative activities'),
  ];

  static const List<_BioChoice> _traitChoices = [
    _BioChoice(ar: 'خجول قليلاً', en: 'a little shy at first'),
    _BioChoice(ar: 'فضولي', en: 'curious'),
    _BioChoice(ar: 'أحب المشاركة', en: 'enjoy participating'),
    _BioChoice(ar: 'مجتهد', en: 'hardworking'),
    _BioChoice(ar: 'مبدع', en: 'creative'),
    _BioChoice(ar: 'هادئ', en: 'calm and focused'),
    _BioChoice(ar: 'نشيط', en: 'energetic'),
    _BioChoice(ar: 'أحتاج تشجيعاً', en: 'respond well to encouragement'),
  ];

  static const List<_BioChoice> _goalChoices = [
    _BioChoice(ar: 'تحسين لغتي الإنجليزية', en: 'improve my English'),
    _BioChoice(ar: 'التحدث بثقة أكبر', en: 'speak more confidently'),
    _BioChoice(ar: 'الحصول على درجات أفضل', en: 'get better grades'),
    _BioChoice(ar: 'تعلم مهارات جديدة', en: 'learn new skills'),
    _BioChoice(ar: 'فهم الدروس بشكل أفضل', en: 'understand lessons better'),
    _BioChoice(ar: 'الاستمتاع بالتعلم', en: 'enjoy learning more'),
  ];

  int _statCourses = 0;
  int _statAttendancePct = 0;
  int _statLessonsCovered = 0;
  int _statHomeworkPending = 0;

  static final RegExp _specialRegex = RegExp(
    r'[!@#$%^&*(),.?":{}|<>_\-+=/\\\[\]~`]',
  );

  @override
  void initState() {
    super.initState();
    appThemeController.addListener(_onThemeChanged);
    _load();
  }

  @override
  void dispose() {
    appThemeController.removeListener(_onThemeChanged);
    _fn.dispose();
    _ln.dispose();
    _phone1.dispose();
    _phone2.dispose();
    _dob.dispose();
    _aboutMe.dispose();
    super.dispose();
  }

  void _onThemeChanged() {
    if (!mounted) return;
    setState(() {});
  }

  _ProfilePalette get palette => _toProfilePalette(appThemeController.palette);

  _ProfilePalette _toProfilePalette(AppPalette p) {
    return _ProfilePalette(
      primary: p.primary,
      accent: p.accent,
      text: p.text,
      appBg: p.appBg,
      cardBg: p.cardBg,
      border: p.border,
      soft: p.soft,
    );
  }

  static int _toInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  String _learnerAppId(String uid) => 'learner_$uid';

  Future<String> _uploadPlatformFile(PlatformFile file) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('Not logged in.');

    final uploadUri = await BackendApi.withAuthQuery(
      BackendApi.uri('upload_secure.php'),
    );
    final request = http.MultipartRequest('POST', uploadUri);
    request.headers['X-Requested-With'] = 'XMLHttpRequest';
    await BackendApi.applyAuthToMultipart(request);
    request.fields['app_id'] = _learnerAppId(user.uid);

    if (kIsWeb) {
      final bytes = file.bytes;
      if (bytes == null) {
        throw Exception('Could not read selected file bytes.');
      }

      request.files.add(
        http.MultipartFile.fromBytes('file', bytes, filename: file.name),
      );
    } else {
      final path = file.path;
      if (path == null || path.isEmpty) {
        throw Exception('Could not read selected file path.');
      }

      request.files.add(
        await http.MultipartFile.fromPath('file', path, filename: file.name),
      );
    }

    final streamedResponse = await request.send();
    final responseBody = await streamedResponse.stream.bytesToString();

    if (streamedResponse.statusCode != 200) {
      throw Exception(
        'Upload failed (${streamedResponse.statusCode}): $responseBody',
      );
    }

    final decoded = jsonDecode(responseBody);
    if (decoded is! Map || decoded['success'] != true) {
      throw Exception(
        decoded is Map
            ? (decoded['message'] ?? 'Upload failed')
            : 'Upload failed',
      );
    }

    final url = (decoded['url'] ?? '').toString().trim();
    if (url.isEmpty) {
      throw Exception('Upload succeeded but no URL returned.');
    }

    return url;
  }

  Future<void> _pickAndUploadMainPhoto() async {
    if (_busy || _uploadingMainPhoto || _uploadingExtraPhotos) return;

    try {
      setState(() {
        _uploadingMainPhoto = true;
        _error = null;
      });

      final result = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        withData: kIsWeb,
        type: FileType.custom,
        allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp'],
      );

      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      final url = await _uploadPlatformFile(file);

      if (!mounted) return;
      setState(() {
        _profilePhotoUrl = url;
      });
    } catch (e) {
      if (mounted) setState(() => _error = toHumanError(e));
    } finally {
      if (mounted) setState(() => _uploadingMainPhoto = false);
    }
  }

  Future<void> _pickAndUploadExtraPhotos() async {
    if (_busy || _uploadingMainPhoto || _uploadingExtraPhotos) return;

    final remaining = _maxExtraPhotos - _photoUrls.length;
    if (remaining <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('You already reached the 6 extra photo limit.'),
        ),
      );
      return;
    }

    try {
      setState(() {
        _uploadingExtraPhotos = true;
        _error = null;
      });

      final result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        withData: kIsWeb,
        type: FileType.custom,
        allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp'],
      );

      if (result == null || result.files.isEmpty) return;

      final selected = result.files.take(remaining).toList();

      for (final file in selected) {
        final url = await _uploadPlatformFile(file);
        _photoUrls.add(url);
      }

      if (!mounted) return;
      setState(() {});
    } catch (e) {
      if (mounted) setState(() => _error = toHumanError(e));
    } finally {
      if (mounted) setState(() => _uploadingExtraPhotos = false);
    }
  }

  Future<void> _removeMainPhoto() async {
    if ((_profilePhotoUrl ?? '').trim().isEmpty) return;

    final ok = await _confirmDialog(
      title: 'Remove profile photo',
      message: 'Do you want to remove your main profile photo?',
      confirmText: 'Remove',
    );

    if (!ok) return;

    if (!mounted) return;
    setState(() {
      _profilePhotoUrl = null;
    });
  }

  Future<void> _removeExtraPhoto(int index) async {
    if (index < 0 || index >= _photoUrls.length) return;

    final ok = await _confirmDialog(
      title: 'Remove photo',
      message: 'Do you want to remove this extra photo?',
      confirmText: 'Remove',
    );

    if (!ok) return;

    if (!mounted) return;
    setState(() {
      _photoUrls.removeAt(index);
    });
  }

  Future<int> _fetchTotalLessonsForCourse({
    required String courseId,
    required String variantKey,
  }) async {
    if (courseId.trim().isEmpty) return 0;

    try {
      DatabaseReference syllabusRef = _syllabiRef.child(courseId);
      if (variantKey.trim().isNotEmpty) {
        syllabusRef = syllabusRef.child(variantKey.trim().toLowerCase());
      }

      final snap = await syllabusRef.get();
      if (!snap.exists || snap.value == null || snap.value is! Map) return 0;

      final data = Map<String, dynamic>.from(snap.value as Map);
      final units = data['units'];

      int total = 0;
      if (units is List) {
        for (final u in units) {
          if (u is! Map) continue;
          final unit = Map<String, dynamic>.from(u);
          final sessions = unit['sessions'];
          if (sessions is List) total += sessions.length;
        }
      }

      return total;
    } catch (_) {
      return 0;
    }
  }

  Future<Map<int, String>> _loadSessionIdByNumber({
    required String courseId,
    required String variantKey,
  }) async {
    final out = <int, String>{};
    if (courseId.trim().isEmpty) return out;

    try {
      DatabaseReference syllabusRef = _syllabiRef.child(courseId);
      if (variantKey.trim().isNotEmpty) {
        syllabusRef = syllabusRef.child(variantKey.trim().toLowerCase());
      }

      final snap = await syllabusRef.get();
      if (!snap.exists || snap.value == null || snap.value is! Map) return out;

      final data = Map<String, dynamic>.from(snap.value as Map);
      final units = data['units'];

      if (units is List) {
        for (final u in units) {
          if (u is! Map) continue;
          final unit = Map<String, dynamic>.from(u);
          final sessions = unit['sessions'];

          if (sessions is List) {
            for (final ss in sessions) {
              if (ss is! Map) continue;
              final sess = Map<String, dynamic>.from(ss);
              final sn = _toInt(sess['sessionNumber']);
              final sid = (sess['id'] ?? '').toString().trim();
              if (sn > 0 && sid.isNotEmpty) {
                out[sn] = sid;
              }
            }
          }
        }
      }
    } catch (_) {}

    return out;
  }

  Future<Set<String>> _coveredSessionIdsFromCourse({
    required String learnerUid,
    required Map<String, dynamic> course,
  }) async {
    final covered = <String>{};

    final cls = (course['class'] is Map)
        ? Map<String, dynamic>.from(course['class'] as Map)
        : <String, dynamic>{};

    final courseId = (cls['course_id'] ?? course['id'] ?? '').toString().trim();
    final variantKey = (course['variantKey'] ?? course['variant'] ?? '')
        .toString()
        .trim()
        .toLowerCase();

    final sessionIdByNumber = await _loadSessionIdByNumber(
      courseId: courseId,
      variantKey: variantKey,
    );

    final attendance = course['attendance'];
    if (attendance is Map) {
      final attMap = Map<String, dynamic>.from(attendance);

      for (final entry in attMap.entries) {
        final rec = entry.value;
        if (rec is! Map) continue;

        final m = Map<String, dynamic>.from(rec);
        final taughtItems = m['taughtItems'];
        bool usedNew = false;

        if (taughtItems is List) {
          usedNew = true;
          for (final it in taughtItems) {
            if (it is! Map) continue;
            final item = Map<String, dynamic>.from(it);
            final type = (item['type'] ?? '').toString().trim().toLowerCase();
            if (type != 'syllabus') continue;

            final sid = (item['sessionId'] ?? '').toString().trim();
            if (sid.isNotEmpty) {
              covered.add(sid);
              continue;
            }

            final sn = _toInt(item['sessionNumber']);
            if (sn > 0) {
              final mapped = sessionIdByNumber[sn];
              if (mapped != null && mapped.isNotEmpty) {
                covered.add(mapped);
              }
            }
          }
        }

        if (!usedNew) {
          final taught = m['taught'];
          if (taught is Map) {
            final tm = Map<String, dynamic>.from(taught);
            final sid = (tm['sessionId'] ?? '').toString().trim();
            if (sid.isNotEmpty) {
              covered.add(sid);
              continue;
            }

            final sn = _toInt(tm['sessionNumber']);
            if (sn > 0) {
              final mapped = sessionIdByNumber[sn];
              if (mapped != null && mapped.isNotEmpty) {
                covered.add(mapped);
              }
            }
          }
        }
      }
    }

    if (learnerUid.isNotEmpty && courseId.isNotEmpty) {
      try {
        final snap = await _db
            .child(
              '$bookingProgressNode/$learnerUid/$courseId/online_attendance',
            )
            .get();

        if (snap.exists && snap.value is Map) {
          final om = Map<dynamic, dynamic>.from(snap.value as Map);

          for (final e in om.entries) {
            final rec = e.value;
            if (rec is! Map) continue;
            final r = Map<String, dynamic>.from(rec);

            final taughtItems = r['taughtItems'];
            if (taughtItems is List) {
              for (final it in taughtItems) {
                if (it is! Map) continue;
                final item = Map<String, dynamic>.from(it);

                final type = (item['type'] ?? '')
                    .toString()
                    .trim()
                    .toLowerCase();
                if (type != 'syllabus') continue;

                final sid = (item['sessionId'] ?? '').toString().trim();
                if (sid.isNotEmpty) {
                  covered.add(sid);
                  continue;
                }

                final sn = _toInt(item['sessionNumber']);
                if (sn > 0) {
                  final mapped = sessionIdByNumber[sn];
                  if (mapped != null && mapped.isNotEmpty) {
                    covered.add(mapped);
                  }
                }
              }
            } else {
              final sn = _toInt(r['sessionNo']);
              if (sn > 0) {
                final mapped = sessionIdByNumber[sn];
                if (mapped != null && mapped.isNotEmpty) {
                  covered.add(mapped);
                }
              }
            }
          }
        }
      } catch (_) {}
    }

    return covered;
  }

  Future<void> _loadSmallStats() async {
    _statCourses = 0;
    _statAttendancePct = 0;
    _statLessonsCovered = 0;
    _statHomeworkPending = 0;

    if (_uid.isEmpty) return;

    try {
      final snap = await _usersRef.child(_uid).child('courses').get();
      if (!snap.exists || snap.value == null || snap.value is! Map) return;

      final courses = Map<dynamic, dynamic>.from(snap.value as Map);

      int totalAttendance = 0;
      int totalPresent = 0;
      int totalLessonsCovered = 0;
      int homeworkPending = 0;

      for (final entry in courses.entries) {
        final courseVal = entry.value;
        if (courseVal is! Map) continue;

        final course = Map<String, dynamic>.from(courseVal);
        _statCourses += 1;

        final attendance = course['attendance'];
        if (attendance is Map) {
          final attMap = Map<dynamic, dynamic>.from(attendance);

          for (final v in attMap.values) {
            if (v is! Map) continue;
            final rec = Map<String, dynamic>.from(v);

            totalAttendance += 1;
            final status = (rec['status'] ?? '')
                .toString()
                .trim()
                .toLowerCase();
            if (status == 'present') {
              totalPresent += 1;
            }

            final hwAny = rec['homework'];
            if (hwAny is Map) {
              final hw = Map<String, dynamic>.from(hwAny);
              final text = (hw['text'] ?? '').toString().trim();
              final due = (hw['dueDate'] ?? '').toString().trim();
              final doneAt = hw['doneAt'];
              final hasHomework = text.isNotEmpty || due.isNotEmpty;
              final isDone = doneAt != null;

              if (hasHomework && !isDone) {
                homeworkPending += 1;
              }
            }
          }
        }

        final cls = (course['class'] is Map)
            ? Map<String, dynamic>.from(course['class'] as Map)
            : <String, dynamic>{};

        final courseId = (cls['course_id'] ?? course['id'] ?? '')
            .toString()
            .trim();
        if (courseId.isNotEmpty) {
          try {
            final onlineSnap = await _db
                .child('$bookingProgressNode/$_uid/$courseId/online_attendance')
                .get();

            if (onlineSnap.exists && onlineSnap.value is Map) {
              final om = Map<dynamic, dynamic>.from(onlineSnap.value as Map);
              for (final item in om.values) {
                if (item is! Map) continue;
                final rec = Map<String, dynamic>.from(item);

                totalAttendance += 1;
                final present = rec['present'] == true;
                if (present) totalPresent += 1;
              }
            }
          } catch (_) {}
        }

        final coveredSet = await _coveredSessionIdsFromCourse(
          learnerUid: _uid,
          course: course,
        );
        totalLessonsCovered += coveredSet.length;
      }

      _statLessonsCovered = totalLessonsCovered;
      _statHomeworkPending = homeworkPending;
      _statAttendancePct = totalAttendance == 0
          ? 0
          : ((totalPresent / totalAttendance) * 100).round();
    } catch (_) {}
  }

  Future<void> _load() async {
    if (!mounted) return;

    setState(() {
      _busy = true;
      _error = null;
      _user = {};
      _uid = '';
      _profilePhotoUrl = null;
      _photoUrls.clear();
      _statCourses = 0;
      _statAttendancePct = 0;
      _statLessonsCovered = 0;
      _statHomeworkPending = 0;

      _selectedHobbiesAr.clear();
      _selectedLearningAr.clear();
      _selectedTraitsAr.clear();
      _selectedGoalAr = null;
    });

    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('Not logged in.');
      _uid = user.uid;

      final snap = await _usersRef.child(_uid).get();
      if (!snap.exists || snap.value == null || snap.value is! Map) {
        throw Exception('User record not found.');
      }

      _user = Map<String, dynamic>.from(snap.value as Map);

      _fn.text = (_user['first_name'] ?? '').toString();
      _ln.text = (_user['last_name'] ?? '').toString();
      _phone1.text = (_user['phone1'] ?? '').toString();
      _phone2.text = (_user['phone2'] ?? '').toString();
      _dob.text = (_user['dob'] ?? '').toString();
      _aboutMe.text = (_user['about_me'] ?? '').toString();

      _profilePhotoUrl = (_user['profile_photo'] ?? '').toString().trim();
      if (_profilePhotoUrl != null && _profilePhotoUrl!.isEmpty) {
        _profilePhotoUrl = null;
      }

      _photoUrls.clear();
      final rawPhotos = _user['profile_photos'];
      if (rawPhotos is List) {
        for (final item in rawPhotos) {
          final url = item?.toString() ?? '';
          if (url.isNotEmpty) _photoUrls.add(url);
        }
      } else if (rawPhotos is Map) {
        final map = Map<String, dynamic>.from(rawPhotos);
        final sortedKeys = map.keys.toList()..sort();
        for (final k in sortedKeys) {
          final url = map[k]?.toString() ?? '';
          if (url.isNotEmpty) _photoUrls.add(url);
        }
      }

      if (_photoUrls.length > _maxExtraPhotos) {
        _photoUrls.removeRange(_maxExtraPhotos, _photoUrls.length);
      }

      await _loadSmallStats();
      _captureInitialState();
    } catch (e) {
      _error = toHumanError(e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _save({bool showSuccessSnackBar = true}) async {
    FocusScope.of(context).unfocus();

    setState(() {
      _error = null;
    });

    if (!_formKey.currentState!.validate()) return false;

    setState(() => _busy = true);

    try {
      if (_uid.isEmpty) throw Exception('Missing uid');

      final updates = <String, dynamic>{
        'first_name': _fn.text.trim(),
        'last_name': _ln.text.trim(),
        'phone1': _phone1.text.trim(),
        'phone2': _phone2.text.trim(),
        'dob': _dob.text.trim(),
        'about_me': _aboutMe.text.trim(),
        'profile_photo': _profilePhotoUrl ?? '',
        'profile_photos': _photoUrls.take(_maxExtraPhotos).toList(),
        'updatedAt': ServerValue.timestamp,
      };

      await _usersRef.child(_uid).update(updates);

      if (!mounted) return true;
      if (showSuccessSnackBar) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Profile updated ✅')));
      }
      await _load();
      return true;
    } catch (e) {
      if (mounted) setState(() => _error = toHumanError(e));
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _captureInitialState() {
    _initialFirstName = _fn.text.trim();
    _initialLastName = _ln.text.trim();
    _initialPhone1 = _phone1.text.trim();
    _initialPhone2 = _phone2.text.trim();
    _initialDob = _dob.text.trim();
    _initialAboutMe = _aboutMe.text.trim();
    _initialProfilePhotoUrl = (_profilePhotoUrl ?? '').trim();
    _initialPhotoUrls = _photoUrls.map((e) => e.trim()).toList();
    _initialHobbiesAr = Set<String>.from(_selectedHobbiesAr);
    _initialLearningAr = Set<String>.from(_selectedLearningAr);
    _initialTraitsAr = Set<String>.from(_selectedTraitsAr);
    _initialGoalAr = (_selectedGoalAr ?? '').trim();
  }

  bool get _hasUnsavedChanges {
    if (_fn.text.trim() != _initialFirstName) return true;
    if (_ln.text.trim() != _initialLastName) return true;
    if (_phone1.text.trim() != _initialPhone1) return true;
    if (_phone2.text.trim() != _initialPhone2) return true;
    if (_dob.text.trim() != _initialDob) return true;
    if (_aboutMe.text.trim() != _initialAboutMe) return true;
    if ((_profilePhotoUrl ?? '').trim() != _initialProfilePhotoUrl) return true;
    if (!listEquals(
      _photoUrls.map((e) => e.trim()).toList(),
      _initialPhotoUrls,
    )) {
      return true;
    }
    if (!setEquals(_selectedHobbiesAr, _initialHobbiesAr)) return true;
    if (!setEquals(_selectedLearningAr, _initialLearningAr)) return true;
    if (!setEquals(_selectedTraitsAr, _initialTraitsAr)) return true;
    if ((_selectedGoalAr ?? '').trim() != _initialGoalAr) return true;
    return false;
  }

  Future<_LeaveChoice> _askUnsavedChangesAction() async {
    final p = palette;
    final choice = await showDialog<_LeaveChoice>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text(
          'Unsaved changes',
          style: TextStyle(color: p.primary, fontWeight: FontWeight.w900),
        ),
        content: Text(
          'You have profile changes. Save before leaving or discard them?',
          style: TextStyle(color: p.text.withOpacity(0.8)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, _LeaveChoice.cancel),
            child: Text(
              'Cancel',
              style: TextStyle(color: p.primary, fontWeight: FontWeight.w800),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, _LeaveChoice.discard),
            child: Text(
              'Discard',
              style: TextStyle(
                color: Colors.red.shade700,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: p.accent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () => Navigator.pop(ctx, _LeaveChoice.save),
            child: const Text('Save & exit'),
          ),
        ],
      ),
    );
    return choice ?? _LeaveChoice.cancel;
  }

  Future<void> _handleBackNavigation() async {
    if (_busy || !_hasUnsavedChanges) {
      if (!_busy && mounted) Navigator.of(context).pop();
      return;
    }

    final choice = await _askUnsavedChangesAction();
    if (!mounted) return;

    if (choice == _LeaveChoice.discard) {
      Navigator.of(context).pop();
      return;
    }

    if (choice == _LeaveChoice.save) {
      final saved = await _save(showSuccessSnackBar: false);
      if (saved && mounted) {
        Navigator.of(context).pop();
      }
    }
  }

  String? _newPasswordValidator(String? v) {
    final value = (v ?? '').trim();
    if (value.isEmpty) return 'Password is required';
    if (value.length < 8) return 'Must be at least 8 characters';
    if (!_specialRegex.hasMatch(value))
      return 'Add at least 1 special character';
    return null;
  }

  Future<bool> _confirmDialog({
    required String title,
    required String message,
    required String confirmText,
  }) async {
    final p = palette;

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          title,
          style: TextStyle(color: p.primary, fontWeight: FontWeight.w900),
        ),
        content: Text(
          message,
          style: TextStyle(
            color: p.text.withOpacity(0.75),
            fontWeight: FontWeight.w700,
            height: 1.4,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              'Cancel',
              style: TextStyle(color: p.primary, fontWeight: FontWeight.w800),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: p.accent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(confirmText),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _showChangePasswordSheet() async {
    final currentUser = _auth.currentUser;
    final p = palette;

    if (currentUser == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('You must be logged in.')));
      return;
    }

    final currentCtrl = TextEditingController();
    final newCtrl = TextEditingController();
    final confirmCtrl = TextEditingController();
    final sheetKey = GlobalKey<FormState>();

    bool obscureCurrent = true;
    bool obscureNew = true;
    bool obscureConfirm = true;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: p.appBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            final viewInsets = MediaQuery.of(ctx).viewInsets.bottom;
            final bottomSafe = MediaQuery.of(ctx).viewPadding.bottom;

            Future<void> submit() async {
              FocusScope.of(ctx).unfocus();
              if (!(sheetKey.currentState?.validate() ?? false)) return;

              final ok = await _confirmDialog(
                title: 'Confirm password change',
                message: 'Do you want to update your password now?',
                confirmText: 'Yes, change',
              );
              if (!ok) return;

              if (!mounted) return;
              setState(() => _busy = true);

              try {
                final email = currentUser.email;
                if (email == null || email.isEmpty) {
                  throw Exception('No email found for this account.');
                }

                final cred = EmailAuthProvider.credential(
                  email: email,
                  password: currentCtrl.text,
                );

                await currentUser.reauthenticateWithCredential(cred);
                await currentUser.updatePassword(newCtrl.text.trim());

                if (!mounted) return;
                if (!ctx.mounted) return;
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Password updated ✅')),
                );
              } on FirebaseAuthException catch (e) {
                String msg = e.message ?? 'Failed to update password.';
                if (e.code == 'wrong-password')
                  msg = 'Current password is incorrect.';
                if (e.code == 'requires-recent-login') {
                  msg =
                      'Please log in again, then retry changing your password.';
                }
                if (mounted) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text(msg)));
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text(toHumanError(e))));
                }
              } finally {
                if (mounted) setState(() => _busy = false);
              }
            }

            return Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 12,
                bottom: 16 + bottomSafe + viewInsets,
              ),
              child: SingleChildScrollView(
                child: Form(
                  key: sheetKey,
                  autovalidateMode: AutovalidateMode.onUserInteraction,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Change Password',
                        style: TextStyle(
                          color: p.primary,
                          fontWeight: FontWeight.w900,
                          fontSize: 20,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Min 8 characters + at least 1 special character.',
                        style: TextStyle(
                          color: p.text.withOpacity(0.7),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 14),
                      _pwField(
                        palette: p,
                        label: 'Current password',
                        controller: currentCtrl,
                        obscure: obscureCurrent,
                        onToggle: () => setModalState(
                          () => obscureCurrent = !obscureCurrent,
                        ),
                        validator: (v) => (v ?? '').isEmpty
                            ? 'Current password is required'
                            : null,
                        onChanged: (_) => sheetKey.currentState?.validate(),
                      ),
                      const SizedBox(height: 10),
                      _pwField(
                        palette: p,
                        label: 'New password',
                        controller: newCtrl,
                        obscure: obscureNew,
                        onToggle: () =>
                            setModalState(() => obscureNew = !obscureNew),
                        validator: _newPasswordValidator,
                        onChanged: (_) => sheetKey.currentState?.validate(),
                      ),
                      const SizedBox(height: 10),
                      _pwField(
                        palette: p,
                        label: 'Confirm new password',
                        controller: confirmCtrl,
                        obscure: obscureConfirm,
                        onToggle: () => setModalState(
                          () => obscureConfirm = !obscureConfirm,
                        ),
                        validator: (v) {
                          final value = (v ?? '').trim();
                          if (value.isEmpty)
                            return 'Please confirm your new password';
                          if (value != newCtrl.text.trim()) {
                            return 'Passwords do not match';
                          }
                          return null;
                        },
                        onChanged: (_) => sheetKey.currentState?.validate(),
                      ),
                      const SizedBox(height: 14),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          icon: const Icon(Icons.lock_reset_rounded),
                          label: const Text('Update password'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: p.accent,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          onPressed: _busy ? null : submit,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _pwField({
    required _ProfilePalette palette,
    required String label,
    required TextEditingController controller,
    required bool obscure,
    required VoidCallback onToggle,
    required String? Function(String?) validator,
    required ValueChanged<String> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: palette.text.withOpacity(0.75),
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 6),
        TextFormField(
          controller: controller,
          obscureText: obscure,
          validator: validator,
          onChanged: onChanged,
          decoration: InputDecoration(
            filled: true,
            fillColor: palette.cardBg,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 12,
            ),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: palette.border.withOpacity(0.85)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: palette.accent, width: 1.4),
            ),
            suffixIcon: IconButton(
              tooltip: obscure ? 'Show' : 'Hide',
              onPressed: onToggle,
              icon: Icon(
                obscure
                    ? Icons.visibility_rounded
                    : Icons.visibility_off_rounded,
                color: palette.primary,
              ),
            ),
          ),
        ),
      ],
    );
  }

  bool get _hasBioSelections =>
      _selectedHobbiesAr.isNotEmpty ||
      _selectedLearningAr.isNotEmpty ||
      _selectedTraitsAr.isNotEmpty ||
      (_selectedGoalAr != null && _selectedGoalAr!.trim().isNotEmpty);

  _BioChoice? _findChoice(List<_BioChoice> list, String ar) {
    for (final item in list) {
      if (item.ar == ar) return item;
    }
    return null;
  }

  List<String> _mapArabicSetToEnglish(
    Set<String> selected,
    List<_BioChoice> source,
  ) {
    return selected
        .map((ar) => _findChoice(source, ar)?.en ?? '')
        .where((e) => e.trim().isNotEmpty)
        .toList();
  }

  String _joinEnglish(List<String> items) {
    final clean = items.where((e) => e.trim().isNotEmpty).toList();
    if (clean.isEmpty) return '';
    if (clean.length == 1) return clean.first;
    if (clean.length == 2) return '${clean[0]} and ${clean[1]}';
    return '${clean.sublist(0, clean.length - 1).join(', ')}, and ${clean.last}';
  }

  String _joinArabic(List<String> items) {
    final clean = items.where((e) => e.trim().isNotEmpty).toList();
    if (clean.isEmpty) return '';
    if (clean.length == 1) return clean.first;
    if (clean.length == 2) return '${clean[0]} و${clean[1]}';
    return '${clean.sublist(0, clean.length - 1).join('، ')}، و${clean.last}';
  }

  String _generatedEnglishBio() {
    final firstName = _fn.text.trim();
    final hobbiesEn = _mapArabicSetToEnglish(_selectedHobbiesAr, _hobbyChoices);
    final learningEn = _mapArabicSetToEnglish(
      _selectedLearningAr,
      _learningChoices,
    );
    final traitsEn = _mapArabicSetToEnglish(_selectedTraitsAr, _traitChoices);
    final goalEn = _selectedGoalAr == null
        ? ''
        : (_findChoice(_goalChoices, _selectedGoalAr!)?.en ?? '');

    final parts = <String>[];

    if (firstName.isNotEmpty) {
      parts.add('Hi, my name is $firstName.');
    } else {
      parts.add('Hi.');
    }

    if (hobbiesEn.isNotEmpty) {
      parts.add('I enjoy ${_joinEnglish(hobbiesEn)}.');
    }

    if (learningEn.isNotEmpty) {
      parts.add('I learn best through ${_joinEnglish(learningEn)}.');
    }

    if (traitsEn.isNotEmpty) {
      parts.add('I am ${_joinEnglish(traitsEn)}.');
    }

    if (goalEn.isNotEmpty) {
      parts.add('My goal is to $goalEn.');
    }

    return parts.join(' ');
  }

  String _generatedArabicBio() {
    final firstName = _fn.text.trim();
    final hobbiesAr = _selectedHobbiesAr.toList();
    final learningAr = _selectedLearningAr.toList();
    final traitsAr = _selectedTraitsAr.toList();
    final goalAr = (_selectedGoalAr ?? '').trim();

    final parts = <String>[];

    if (firstName.isNotEmpty) {
      parts.add('اسمي $firstName.');
    } else {
      parts.add('هذه نبذتي.');
    }

    if (hobbiesAr.isNotEmpty) {
      parts.add('أحب ${_joinArabic(hobbiesAr)}.');
    }

    if (learningAr.isNotEmpty) {
      parts.add('أفضل التعلم من خلال ${_joinArabic(learningAr)}.');
    }

    if (traitsAr.isNotEmpty) {
      parts.add('أنا ${_joinArabic(traitsAr)}.');
    }

    if (goalAr.isNotEmpty) {
      parts.add('هدفي هو $goalAr.');
    }

    return parts.join(' ');
  }

  void _syncGeneratedBioToController() {
    if (!_hasBioSelections) return;

    final generated = _generatedEnglishBio().trim();
    _aboutMe.text = generated;
    _aboutMe.selection = TextSelection.fromPosition(
      TextPosition(offset: _aboutMe.text.length),
    );
  }

  void _toggleMultiChoice(Set<String> target, String value) {
    setState(() {
      if (target.contains(value)) {
        target.remove(value);
      } else {
        target.add(value);
      }
      _syncGeneratedBioToController();
    });
  }

  void _selectSingleChoice(String value) {
    setState(() {
      if (_selectedGoalAr == value) {
        _selectedGoalAr = null;
      } else {
        _selectedGoalAr = value;
      }
      _syncGeneratedBioToController();
    });
  }

  void _clearBioSelections() {
    setState(() {
      _selectedHobbiesAr.clear();
      _selectedLearningAr.clear();
      _selectedTraitsAr.clear();
      _selectedGoalAr = null;
    });
  }

  Widget _readonlyRow(String label, String value) {
    final p = palette;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          SizedBox(
            width: 86,
            child: Text(
              label,
              style: TextStyle(
                color: p.text.withOpacity(0.7),
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? '-' : value,
              style: TextStyle(color: p.text, fontWeight: FontWeight.w900),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _field(
    String label,
    TextEditingController c, {
    TextInputType keyboard = TextInputType.text,
    String? hintText,
    int maxLines = 1,
    int? maxLength,
    String? Function(String?)? validator,
  }) {
    final p = palette;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: p.text.withOpacity(0.75),
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 6),
        TextFormField(
          controller: c,
          keyboardType: keyboard,
          maxLines: maxLines,
          maxLength: maxLength,
          validator: validator,
          onChanged: (_) => _formKey.currentState?.validate(),
          decoration: InputDecoration(
            hintText: hintText,
            filled: true,
            fillColor: p.cardBg,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 12,
            ),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: p.border.withOpacity(0.85)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: p.accent, width: 1.4),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildChoiceChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final p = palette;

    return FilterChip(
      label: Text(
        label,
        style: TextStyle(
          fontWeight: FontWeight.w800,
          color: selected ? Colors.white : p.text,
        ),
      ),
      selected: selected,
      onSelected: (_) => onTap(),
      selectedColor: p.accent,
      backgroundColor: p.cardBg,
      side: BorderSide(color: selected ? p.accent : p.border.withOpacity(0.9)),
      checkmarkColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
      showCheckmark: false,
    );
  }

  Widget _buildChoiceSection({
    required String title,
    required String subtitle,
    required List<_BioChoice> choices,
    required Set<String> selectedValues,
    required ValueChanged<String> onTap,
  }) {
    final p = palette;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            color: p.primary,
            fontWeight: FontWeight.w900,
            fontSize: 15,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: TextStyle(
            color: p.text.withOpacity(0.65),
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: choices.map((item) {
            return _buildChoiceChip(
              label: item.ar,
              selected: selectedValues.contains(item.ar),
              onTap: () => onTap(item.ar),
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _buildSingleChoiceSection({
    required String title,
    required String subtitle,
    required List<_BioChoice> choices,
    required String? selectedValue,
    required ValueChanged<String> onTap,
  }) {
    final p = palette;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            color: p.primary,
            fontWeight: FontWeight.w900,
            fontSize: 15,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: TextStyle(
            color: p.text.withOpacity(0.65),
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: choices.map((item) {
            return _buildChoiceChip(
              label: item.ar,
              selected: selectedValue == item.ar,
              onTap: () => onTap(item.ar),
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _previewBox({
    required String title,
    required String text,
    required IconData icon,
  }) {
    final p = palette;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: p.soft.withOpacity(0.55),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: p.border.withOpacity(0.9)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: p.accent),
              const SizedBox(width: 8),
              Text(
                title,
                style: TextStyle(
                  color: p.primary,
                  fontWeight: FontWeight.w900,
                  fontSize: 14,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            text.trim().isEmpty ? '-' : text.trim(),
            style: TextStyle(
              color: p.text,
              fontWeight: FontWeight.w700,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAboutMeCard() {
    final p = palette;
    final arabicPreview = _hasBioSelections ? _generatedArabicBio() : '';
    final englishPreview = _hasBioSelections
        ? _generatedEnglishBio()
        : _aboutMe.text.trim();

    return _SectionCard(
      palette: p,
      title: 'Build My Bio',
      subtitle:
          'Pick in Arabic, and we will generate an English profile for the teacher.',
      icon: Icons.auto_awesome_rounded,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _previewBox(
            title: 'Arabic Preview',
            text: arabicPreview,
            icon: Icons.translate_rounded,
          ),
          const SizedBox(height: 10),
          _previewBox(
            title: 'English Teacher Bio',
            text: englishPreview,
            icon: Icons.description_rounded,
          ),
          const SizedBox(height: 14),
          _buildChoiceSection(
            title: 'أنا أحب',
            subtitle: 'اختر الهوايات أو الأشياء التي يحبها المتعلم',
            choices: _hobbyChoices,
            selectedValues: _selectedHobbiesAr,
            onTap: (value) => _toggleMultiChoice(_selectedHobbiesAr, value),
          ),
          const SizedBox(height: 16),
          _buildChoiceSection(
            title: 'أفضل التعلم من خلال',
            subtitle: 'ما نوع الدروس أو الأنشطة التي تناسبه أكثر؟',
            choices: _learningChoices,
            selectedValues: _selectedLearningAr,
            onTap: (value) => _toggleMultiChoice(_selectedLearningAr, value),
          ),
          const SizedBox(height: 16),
          _buildChoiceSection(
            title: 'أنا عادة',
            subtitle: 'اختر الصفات التي تساعد المعلم على فهم المتعلم',
            choices: _traitChoices,
            selectedValues: _selectedTraitsAr,
            onTap: (value) => _toggleMultiChoice(_selectedTraitsAr, value),
          ),
          const SizedBox(height: 16),
          _buildSingleChoiceSection(
            title: 'هدفي هو',
            subtitle: 'اختر هدفاً رئيسياً واحداً',
            choices: _goalChoices,
            selectedValue: _selectedGoalAr,
            onTap: _selectSingleChoice,
          ),
          const SizedBox(height: 14),
          OutlinedButton.icon(
            icon: const Icon(Icons.restart_alt_rounded),
            label: const Text('Clear selections'),
            style: OutlinedButton.styleFrom(
              foregroundColor: p.primary,
              side: BorderSide(color: p.border.withOpacity(0.9)),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            onPressed: _clearBioSelections,
          ),
        ],
      ),
    );
  }

  Widget _buildMainPhotoCard() {
    final p = palette;
    final fullName = '${_fn.text.trim()} ${_ln.text.trim()}'.trim();
    final role = (_user['role'] ?? '').toString();
    final hasPhoto = (_profilePhotoUrl ?? '').trim().isNotEmpty;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [p.primary, p.primary.withOpacity(0.88)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: p.primary.withOpacity(0.18),
            blurRadius: 22,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            width: 112,
            height: 112,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.white.withOpacity(0.80),
                width: 3,
              ),
              color: Colors.white.withOpacity(0.12),
            ),
            clipBehavior: Clip.antiAlias,
            child: hasPhoto
                ? Image.network(
                    _profilePhotoUrl!,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const Icon(
                      Icons.person_rounded,
                      size: 56,
                      color: Colors.white,
                    ),
                  )
                : const Icon(
                    Icons.person_rounded,
                    size: 56,
                    color: Colors.white,
                  ),
          ),
          const SizedBox(height: 14),
          Text(
            fullName.isEmpty ? 'Learner' : fullName,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              fontSize: 22,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            role.isEmpty ? 'Learner' : role,
            style: TextStyle(
              color: Colors.white.withOpacity(0.82),
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            alignment: WrapAlignment.center,
            children: [
              OutlinedButton.icon(
                icon: _uploadingMainPhoto
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: YbsBusyLogo(
                          size: 16,
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      )
                    : const Icon(Icons.add_a_photo_rounded),
                label: Text(
                  _uploadingMainPhoto
                      ? 'Uploading...'
                      : (hasPhoto ? 'Replace main photo' : 'Upload main photo'),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: BorderSide(color: Colors.white.withOpacity(0.35)),
                  backgroundColor: Colors.white.withOpacity(0.10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                onPressed:
                    (_busy || _uploadingMainPhoto || _uploadingExtraPhotos)
                    ? null
                    : _pickAndUploadMainPhoto,
              ),
              if (hasPhoto)
                OutlinedButton.icon(
                  icon: const Icon(Icons.delete_outline_rounded),
                  label: const Text('Remove'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: BorderSide(color: Colors.white.withOpacity(0.28)),
                    backgroundColor: Colors.white.withOpacity(0.08),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  onPressed:
                      (_busy || _uploadingMainPhoto || _uploadingExtraPhotos)
                      ? null
                      : _removeMainPhoto,
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildExtraPhotosCard() {
    final p = palette;

    return _SectionCard(
      palette: p,
      title: 'Photos & Media',
      subtitle: 'Add up to 6 extra photos so teachers can know you better.',
      icon: Icons.collections_rounded,
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          ...List.generate(_photoUrls.length, (index) {
            final url = _photoUrls[index];
            return Stack(
              children: [
                Container(
                  width: 96,
                  height: 96,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: p.border.withOpacity(0.85)),
                    color: p.soft,
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Image.network(
                    url,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Center(
                      child: Icon(
                        Icons.broken_image_outlined,
                        color: p.primary,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 5,
                  right: 5,
                  child: InkWell(
                    onTap: () => _removeExtraPhoto(index),
                    borderRadius: BorderRadius.circular(999),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.55),
                        shape: BoxShape.circle,
                      ),
                      padding: const EdgeInsets.all(5),
                      child: const Icon(
                        Icons.close,
                        color: Colors.white,
                        size: 16,
                      ),
                    ),
                  ),
                ),
              ],
            );
          }),
          if (_photoUrls.length < _maxExtraPhotos)
            InkWell(
              onTap: (_busy || _uploadingMainPhoto || _uploadingExtraPhotos)
                  ? null
                  : _pickAndUploadExtraPhotos,
              borderRadius: BorderRadius.circular(16),
              child: Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  color: p.cardBg,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: p.border),
                ),
                child: _uploadingExtraPhotos
                    ? Center(child: YbsBusyLogo(color: p.primary))
                    : Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.add_photo_alternate_outlined,
                            color: p.primary,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Add photo',
                            style: TextStyle(
                              color: p.primary,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _smallStatTile({
    required IconData icon,
    required String label,
    required String value,
  }) {
    final p = palette;

    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: p.border.withOpacity(0.85)),
        color: p.soft.withOpacity(0.5),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: p.accent.withOpacity(0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, size: 18, color: p.accent),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: p.text.withOpacity(0.72),
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(color: p.primary, fontWeight: FontWeight.w900),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryCard() {
    final p = palette;

    return _SectionCard(
      palette: p,
      title: 'Learning Summary',
      subtitle: 'A quick view of your activity and study progress.',
      icon: Icons.insights_rounded,
      child: Column(
        children: [
          _smallStatTile(
            icon: Icons.school_rounded,
            label: 'Courses',
            value: '$_statCourses',
          ),
          const SizedBox(height: 10),
          _smallStatTile(
            icon: Icons.how_to_reg_rounded,
            label: 'Attendance',
            value: '$_statAttendancePct%',
          ),
          const SizedBox(height: 10),
          _smallStatTile(
            icon: Icons.menu_book_rounded,
            label: 'Lessons Covered',
            value: '$_statLessonsCovered',
          ),
          const SizedBox(height: 10),
          _smallStatTile(
            icon: Icons.assignment_late_rounded,
            label: 'Homework Pending',
            value: '$_statHomeworkPending',
          ),
        ],
      ),
    );
  }

  Widget _buildCredentialsTab({
    required String email,
    required String serial,
    required String role,
    required String status,
  }) {
    final p = palette;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
      children: [
        _buildMainPhotoCard(),
        const SizedBox(height: 16),
        _buildSummaryCard(),
        const SizedBox(height: 16),
        _SectionCard(
          palette: p,
          title: 'Account',
          subtitle: 'Your account credentials and access details.',
          icon: Icons.verified_user_rounded,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _readonlyRow('Email', email),
              _readonlyRow('Serial', serial),
              _readonlyRow('Role', role),
              _readonlyRow('Status', status),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.lock_outline_rounded),
                  label: const Text('Change password'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: p.primary,
                    side: BorderSide(color: p.border.withOpacity(0.9)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 13),
                  ),
                  onPressed: _busy ? null : _showChangePasswordSheet,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _SectionCard(
          palette: p,
          title: 'Edit Information',
          subtitle: 'Update your main profile details.',
          icon: Icons.edit_note_rounded,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _field(
                'First name',
                _fn,
                validator: (v) =>
                    (v ?? '').trim().isEmpty ? 'First name is required' : null,
              ),
              const SizedBox(height: 10),
              _field(
                'Last name',
                _ln,
                validator: (v) =>
                    (v ?? '').trim().isEmpty ? 'Last name is required' : null,
              ),
              const SizedBox(height: 10),
              _field('Phone 1', _phone1, keyboard: TextInputType.phone),
              const SizedBox(height: 10),
              _field('Phone 2', _phone2, keyboard: TextInputType.phone),
              const SizedBox(height: 10),
              _field(
                'Date of birth (YYYY-MM-DD)',
                _dob,
                hintText: 'e.g. 2000-01-31',
                validator: (v) {
                  final value = (v ?? '').trim();
                  if (value.isEmpty) return null;
                  final ok = RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value);
                  if (!ok) return 'Use YYYY-MM-DD format';
                  return null;
                },
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMediaTab() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
      children: [
        _buildExtraPhotosCard(),
        const SizedBox(height: 16),
        _buildAboutMeCard(),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final email = (_user['email'] ?? '').toString();
    final serial = (_user['serial'] ?? '').toString();
    final role = (_user['role'] ?? '').toString();
    final status = (_user['status'] ?? '').toString();

    return DefaultTabController(
      length: 2,
      child: PopScope(
        canPop: !_hasUnsavedChanges && !_busy,
        onPopInvokedWithResult: (didPop, result) async {
          if (didPop || !mounted || _busy) return;
          await _handleBackNavigation();
        },
        child: Scaffold(
          backgroundColor: p.appBg,
          resizeToAvoidBottomInset: true,
          appBar: AppBar(
            backgroundColor: p.cardBg,
            elevation: 0,
            surfaceTintColor: p.cardBg,
            iconTheme: IconThemeData(color: p.primary),
            title: Text(
              'My Profile',
              style: TextStyle(color: p.primary, fontWeight: FontWeight.w900),
            ),
            actions: [
              IconButton(
                tooltip: 'Save',
                onPressed: _busy ? null : _save,
                icon: _busy
                    ? Padding(
                        padding: const EdgeInsets.all(8),
                        child: YbsBusyLogo(size: 18, color: p.accent),
                      )
                    : Icon(Icons.save_rounded, color: p.accent),
              ),
              IconButton(
                tooltip: 'Refresh',
                icon: Icon(Icons.refresh_rounded, color: p.accent),
                onPressed: _busy ? null : _load,
              ),
            ],
            bottom: TabBar(
              dividerColor: Colors.transparent,
              labelColor: p.primary,
              unselectedLabelColor: p.text.withOpacity(0.62),
              indicator: UnderlineTabIndicator(
                borderSide: BorderSide(color: p.accent, width: 3),
                insets: const EdgeInsets.symmetric(horizontal: 20),
              ),
              tabs: const [
                Tab(icon: Icon(Icons.badge_rounded), text: 'Credentials'),
                Tab(icon: Icon(Icons.perm_media_rounded), text: 'Media & Bio'),
              ],
            ),
          ),
          body: SafeArea(
            child: WatermarkBackground(
              child: _busy
                  ? Center(child: YbsBusyLogo(color: p.primary))
                  : _error != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Container(
                          padding: const EdgeInsets.all(18),
                          decoration: BoxDecoration(
                            color: p.cardBg,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: p.border.withOpacity(0.85),
                            ),
                          ),
                          child: Text(
                            _error!,
                            style: TextStyle(
                              color: Colors.red.shade700,
                              fontWeight: FontWeight.w800,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    )
                  : Form(
                      key: _formKey,
                      autovalidateMode: AutovalidateMode.onUserInteraction,
                      child: TabBarView(
                        children: [
                          _buildCredentialsTab(
                            email: email,
                            serial: serial,
                            role: role,
                            status: status,
                          ),
                          _buildMediaTab(),
                        ],
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.palette,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.child,
  });

  final _ProfilePalette palette;
  final String title;
  final String subtitle;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: palette.cardBg,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: palette.border.withOpacity(0.85)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 14,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: palette.soft,
                    borderRadius: BorderRadius.circular(15),
                  ),
                  child: Icon(icon, color: palette.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          color: palette.primary,
                          fontWeight: FontWeight.w900,
                          fontSize: 17,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: TextStyle(
                          color: palette.text.withOpacity(0.64),
                          fontWeight: FontWeight.w700,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
    );
  }
}

class _ProfilePalette {
  const _ProfilePalette({
    required this.primary,
    required this.accent,
    required this.text,
    required this.appBg,
    required this.cardBg,
    required this.border,
    required this.soft,
  });

  final Color primary;
  final Color accent;
  final Color text;
  final Color appBg;
  final Color cardBg;
  final Color border;
  final Color soft;
}
