import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../shared/ui_constants.dart';
import '../shared/watermark_background.dart';

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

  static const int _maxExtraPhotos = 6;

  // Small profile statistics only
  int _statCourses = 0;
  int _statAttendancePct = 0;
  int _statLessonsCovered = 0;
  int _statHomeworkPending = 0;

  // IMPORTANT:
  // Use the SAME working values from your TeacherProfileScreen.
  static const String _uploadEndpoint =
      'https://www.yourbridgeschool.com/app/upload.php';

  // Use the SAME working key from your TeacherProfileScreen.
  static const String _uploadKeySha1 =
      'a7a995d9c499128351d827eaad7285bcc891919b';

  // Password rule: 8+ and at least 1 special character
  static final RegExp _specialRegex =
  RegExp(r'[!@#$%^&*(),.?":{}|<>_\-+=/\\\[\]~`]');

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _fn.dispose();
    _ln.dispose();
    _phone1.dispose();
    _phone2.dispose();
    _dob.dispose();
    _aboutMe.dispose();
    super.dispose();
  }

  // ---------------------------
  // Small safe helpers
  // ---------------------------

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

    final request = http.MultipartRequest(
      'POST',
      Uri.parse(_uploadEndpoint),
    );

    request.headers['X-Requested-With'] = 'XMLHttpRequest';
    request.fields['key'] = _uploadKeySha1;
    request.fields['app_id'] = _learnerAppId(user.uid);

    if (kIsWeb) {
      final bytes = file.bytes;
      if (bytes == null) {
        throw Exception('Could not read selected file bytes.');
      }

      request.files.add(
        http.MultipartFile.fromBytes(
          'file',
          bytes,
          filename: file.name,
        ),
      );
    } else {
      final path = file.path;
      if (path == null || path.isEmpty) {
        throw Exception('Could not read selected file path.');
      }

      request.files.add(
        await http.MultipartFile.fromPath(
          'file',
          path,
          filename: file.name,
        ),
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
        decoded is Map ? (decoded['message'] ?? 'Upload failed') : 'Upload failed',
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
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _uploadingMainPhoto = false);
    }
  }

  Future<void> _pickAndUploadExtraPhotos() async {
    if (_busy || _uploadingMainPhoto || _uploadingExtraPhotos) return;

    final remaining = _maxExtraPhotos - _photoUrls.length;
    if (remaining <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('You already reached the 6 extra photo limit.')),
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
      if (mounted) setState(() => _error = e.toString());
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
    final variantKey =
    (course['variantKey'] ?? course['variant'] ?? '').toString().trim().toLowerCase();

    final sessionIdByNumber = await _loadSessionIdByNumber(
      courseId: courseId,
      variantKey: variantKey,
    );

    // In-class attendance
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

    // Online attendance
    if (learnerUid.isNotEmpty && courseId.isNotEmpty) {
      try {
        final snap = await _db
            .child('$bookingProgressNode/$learnerUid/$courseId/online_attendance')
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

        // In-class attendance
        final attendance = course['attendance'];
        if (attendance is Map) {
          final attMap = Map<dynamic, dynamic>.from(attendance);

          for (final v in attMap.values) {
            if (v is! Map) continue;
            final rec = Map<String, dynamic>.from(v);

            totalAttendance += 1;
            final status = (rec['status'] ?? '').toString().trim().toLowerCase();
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

        // Online attendance
        final cls = (course['class'] is Map)
            ? Map<String, dynamic>.from(course['class'] as Map)
            : <String, dynamic>{};

        final courseId = (cls['course_id'] ?? course['id'] ?? '').toString().trim();
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

        // Lessons covered
        final coveredSet = await _coveredSessionIdsFromCourse(
          learnerUid: _uid,
          course: course,
        );
        totalLessonsCovered += coveredSet.length;
      }

      _statLessonsCovered = totalLessonsCovered;
      _statHomeworkPending = homeworkPending;
      _statAttendancePct =
      totalAttendance == 0 ? 0 : ((totalPresent / totalAttendance) * 100).round();
    } catch (_) {
      // Keep stats quiet if anything fails
    }
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
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();

    setState(() {
      _error = null;
    });

    if (!_formKey.currentState!.validate()) return;

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

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Profile updated ✅')),
      );
      await _load();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------------------------
  // Password change UI/logic
  // ---------------------------

  String? _newPasswordValidator(String? v) {
    final value = (v ?? '').trim();
    if (value.isEmpty) return 'Password is required';
    if (value.length < 8) return 'Must be at least 8 characters';
    if (!_specialRegex.hasMatch(value)) return 'Add at least 1 special character';
    return null;
  }

  Future<bool> _confirmDialog({
    required String title,
    required String message,
    required String confirmText,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: UiK.actionOrange,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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
    if (currentUser == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('You must be logged in.')),
      );
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
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
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
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Password updated ✅')),
                );
              } on FirebaseAuthException catch (e) {
                String msg = e.message ?? 'Failed to update password.';
                if (e.code == 'wrong-password') msg = 'Current password is incorrect.';
                if (e.code == 'requires-recent-login') {
                  msg = 'Please log in again, then retry changing your password.';
                }
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(msg)),
                  );
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(e.toString())),
                  );
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
                      Text('Change Password', style: UiK.titleText()),
                      const SizedBox(height: 10),
                      Text(
                        'Min 8 characters + at least 1 special character.',
                        style: TextStyle(
                          color: UiK.mainText.withOpacity(0.7),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 14),
                      _pwField(
                        label: 'Current password',
                        controller: currentCtrl,
                        obscure: obscureCurrent,
                        onToggle: () => setModalState(() => obscureCurrent = !obscureCurrent),
                        validator: (v) =>
                        (v ?? '').isEmpty ? 'Current password is required' : null,
                        onChanged: (_) => sheetKey.currentState?.validate(),
                      ),
                      const SizedBox(height: 10),
                      _pwField(
                        label: 'New password',
                        controller: newCtrl,
                        obscure: obscureNew,
                        onToggle: () => setModalState(() => obscureNew = !obscureNew),
                        validator: _newPasswordValidator,
                        onChanged: (_) => sheetKey.currentState?.validate(),
                      ),
                      const SizedBox(height: 10),
                      _pwField(
                        label: 'Confirm new password',
                        controller: confirmCtrl,
                        obscure: obscureConfirm,
                        onToggle: () => setModalState(() => obscureConfirm = !obscureConfirm),
                        validator: (v) {
                          final value = (v ?? '').trim();
                          if (value.isEmpty) return 'Please confirm your new password';
                          if (value != newCtrl.text.trim()) return 'Passwords do not match';
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
                            backgroundColor: UiK.actionOrange,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
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
            color: UiK.mainText.withOpacity(0.75),
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
            fillColor: Colors.white,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: UiK.uiBorder.withOpacity(0.85)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: UiK.actionOrange, width: 1.2),
            ),
            suffixIcon: IconButton(
              tooltip: obscure ? 'Show' : 'Hide',
              onPressed: onToggle,
              icon: Icon(
                obscure ? Icons.visibility_rounded : Icons.visibility_off_rounded,
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ---------------------------
  // UI helpers
  // ---------------------------

  Widget _readonlyRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: TextStyle(
                color: UiK.mainText.withOpacity(0.7),
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? '-' : value,
              style: const TextStyle(
                color: UiK.mainText,
                fontWeight: FontWeight.w900,
              ),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: UiK.mainText.withOpacity(0.75),
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
            fillColor: Colors.white,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: UiK.uiBorder.withOpacity(0.85)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: UiK.actionOrange, width: 1.2),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMainPhotoCard() {
    final fullName = '${_fn.text.trim()} ${_ln.text.trim()}'.trim();
    final role = (_user['role'] ?? '').toString();
    final hasPhoto = (_profilePhotoUrl ?? '').trim().isNotEmpty;

    return Card(
      elevation: 0,
      color: Colors.white,
      shape: UiK.cardShape(),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            Container(
              width: 108,
              height: 108,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: UiK.uiBorder.withOpacity(0.9), width: 2),
                color: UiK.primaryBlue.withOpacity(0.06),
              ),
              clipBehavior: Clip.antiAlias,
              child: hasPhoto
                  ? Image.network(
                _profilePhotoUrl!,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Icon(
                  Icons.person_rounded,
                  size: 54,
                  color: UiK.primaryBlue.withOpacity(0.8),
                ),
              )
                  : Icon(
                Icons.person_rounded,
                size: 54,
                color: UiK.primaryBlue.withOpacity(0.8),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              fullName.isEmpty ? 'Learner' : fullName,
              textAlign: TextAlign.center,
              style: UiK.titleText(size: 18),
            ),
            const SizedBox(height: 4),
            Text(
              role.isEmpty ? 'Learner' : role,
              style: UiK.subtleText(),
            ),
            const SizedBox(height: 14),
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
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                      : const Icon(Icons.add_a_photo_rounded),
                  label: Text(
                    _uploadingMainPhoto
                        ? 'Uploading...'
                        : (hasPhoto ? 'Replace main photo' : 'Upload main photo'),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: UiK.primaryBlue,
                    side: BorderSide(color: UiK.uiBorder.withOpacity(0.9)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  onPressed: (_busy || _uploadingMainPhoto || _uploadingExtraPhotos)
                      ? null
                      : _pickAndUploadMainPhoto,
                ),
                if (hasPhoto)
                  OutlinedButton.icon(
                    icon: const Icon(Icons.delete_outline_rounded),
                    label: const Text('Remove'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red.shade700,
                      side: BorderSide(color: Colors.red.shade200),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    onPressed: (_busy || _uploadingMainPhoto || _uploadingExtraPhotos)
                        ? null
                        : _removeMainPhoto,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildExtraPhotosCard() {
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: UiK.cardShape(),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Extra Photos', style: UiK.titleText()),
            const SizedBox(height: 8),
            Text(
              'Add up to 6 extra photos so teachers can know you better.',
              style: UiK.subtleText(),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                ...List.generate(_photoUrls.length, (index) {
                  final url = _photoUrls[index];
                  return Stack(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: Image.network(
                          url,
                          width: 96,
                          height: 96,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Container(
                            width: 96,
                            height: 96,
                            color: Colors.grey.shade200,
                            alignment: Alignment.center,
                            child: const Icon(Icons.broken_image_outlined),
                          ),
                        ),
                      ),
                      Positioned(
                        top: 4,
                        right: 4,
                        child: InkWell(
                          onTap: () => _removeExtraPhoto(index),
                          child: Container(
                            decoration: const BoxDecoration(
                              color: Colors.black54,
                              shape: BoxShape.circle,
                            ),
                            padding: const EdgeInsets.all(4),
                            child: const Icon(
                              Icons.close,
                              color: Colors.white,
                              size: 18,
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
                    borderRadius: BorderRadius.circular(14),
                    child: Container(
                      width: 96,
                      height: 96,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: UiK.uiBorder),
                      ),
                      child: _uploadingExtraPhotos
                          ? const Center(child: CircularProgressIndicator())
                          : const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.add_photo_alternate_outlined, color: UiK.primaryBlue),
                          SizedBox(height: 6),
                          Text(
                            'Add photo',
                            style: TextStyle(
                              color: UiK.primaryBlue,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _smallStatTile({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: UiK.uiBorder.withOpacity(0.85)),
        color: UiK.primaryBlue.withOpacity(0.04),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: UiK.actionOrange),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: UiK.mainText.withOpacity(0.72),
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              color: UiK.mainText,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryCard() {
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: UiK.cardShape(),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Learning Summary', style: UiK.titleText()),
            const SizedBox(height: 10),
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
      ),
    );
  }

  // ---------------------------
  // Main UI
  // ---------------------------

  @override
  Widget build(BuildContext context) {
    final email = (_user['email'] ?? '').toString();
    final serial = (_user['serial'] ?? '').toString();
    final role = (_user['role'] ?? '').toString();
    final status = (_user['status'] ?? '').toString();

    return Scaffold(
      backgroundColor: UiK.appBg,
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        iconTheme: const IconThemeData(color: UiK.primaryBlue),
        title: const Text(
          'My Profile',
          style: TextStyle(color: UiK.primaryBlue, fontWeight: FontWeight.w900),
        ),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh_rounded, color: UiK.actionOrange),
            onPressed: _busy ? null : _load,
          ),
        ],
      ),
      body: SafeArea(
        child: WatermarkBackground(
          child: _busy
              ? const Center(child: CircularProgressIndicator())
              : _error != null
              ? Center(
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
              : Form(
            key: _formKey,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            child: LayoutBuilder(
              builder: (ctx, constraints) {
                return SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: constraints.maxHeight),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildMainPhotoCard(),
                        const SizedBox(height: 14),
                        _buildExtraPhotosCard(),
                        const SizedBox(height: 14),
                        _buildSummaryCard(),
                        const SizedBox(height: 14),
                        Card(
                          elevation: 0,
                          color: Colors.white,
                          shape: UiK.cardShape(),
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('About Me', style: UiK.titleText()),
                                const SizedBox(height: 10),
                                _field(
                                  'Write something about yourself',
                                  _aboutMe,
                                  maxLines: 5,
                                  maxLength: 400,
                                  hintText:
                                  'Your interests, goals, hobbies, or anything you want teachers to know.',
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
                        Card(
                          elevation: 0,
                          color: Colors.white,
                          shape: UiK.cardShape(),
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Account', style: UiK.titleText()),
                                const SizedBox(height: 10),
                                _readonlyRow('Email', email),
                                _readonlyRow('Serial', serial),
                                _readonlyRow('Role', role),
                                _readonlyRow('Status', status),
                                const SizedBox(height: 10),
                                OutlinedButton.icon(
                                  icon: const Icon(Icons.lock_outline_rounded),
                                  label: const Text('Change password'),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: UiK.primaryBlue,
                                    side: BorderSide(
                                      color: UiK.uiBorder.withOpacity(0.9),
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                    padding: const EdgeInsets.symmetric(vertical: 12),
                                  ),
                                  onPressed: _busy ? null : _showChangePasswordSheet,
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
                        Card(
                          elevation: 0,
                          color: Colors.white,
                          shape: UiK.cardShape(),
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Edit Information', style: UiK.titleText()),
                                const SizedBox(height: 10),
                                _field(
                                  'First name',
                                  _fn,
                                  validator: (v) => (v ?? '').trim().isEmpty
                                      ? 'First name is required'
                                      : null,
                                ),
                                const SizedBox(height: 10),
                                _field(
                                  'Last name',
                                  _ln,
                                  validator: (v) => (v ?? '').trim().isEmpty
                                      ? 'Last name is required'
                                      : null,
                                ),
                                const SizedBox(height: 10),
                                _field(
                                  'Phone 1',
                                  _phone1,
                                  keyboard: TextInputType.phone,
                                ),
                                const SizedBox(height: 10),
                                _field(
                                  'Phone 2',
                                  _phone2,
                                  keyboard: TextInputType.phone,
                                ),
                                const SizedBox(height: 10),
                                _field(
                                  'Date of birth (YYYY-MM-DD)',
                                  _dob,
                                  hintText: 'e.g. 2000-01-31',
                                  validator: (v) {
                                    final value = (v ?? '').trim();
                                    if (value.isEmpty) return null;
                                    final ok = RegExp(r'^\d{4}-\d{2}-\d{2}$')
                                        .hasMatch(value);
                                    if (!ok) return 'Use YYYY-MM-DD format';
                                    return null;
                                  },
                                ),
                                const SizedBox(height: 14),
                                ElevatedButton.icon(
                                  icon: const Icon(Icons.save_rounded),
                                  label: const Text('Save'),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: UiK.actionOrange,
                                    foregroundColor: Colors.white,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(14),
                                    ),
                                    padding: const EdgeInsets.symmetric(vertical: 14),
                                  ),
                                  onPressed: _busy ? null : _save,
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}