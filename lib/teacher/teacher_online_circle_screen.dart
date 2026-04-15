import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

import '../services/backend_api.dart';
import '../shared/app_theme.dart';
import '../shared/human_error.dart';
import '../shared/teacher_web_layout.dart';

class TeacherOnlineCircleScreen extends StatefulWidget {
  const TeacherOnlineCircleScreen({super.key});

  @override
  State<TeacherOnlineCircleScreen> createState() =>
      _TeacherOnlineCircleScreenState();
}

class _TeacherOnlineCircleScreenState extends State<TeacherOnlineCircleScreen> {
  final _auth = FirebaseAuth.instance;
  final _db = FirebaseDatabase.instance;
  final _formKey = GlobalKey<FormState>();

  final _meetingUrlCtrl = TextEditingController();
  final _topicCtrl = TextEditingController();
  final _descriptionCtrl = TextEditingController();
  final _durationCtrl = TextEditingController(text: '60');

  DateTime? _selectedDateTime;
  String? _circleImageUrl;
  bool _isOpen = true;
  bool _busy = false;
  bool _uploadingCircleImage = false;

  bool _hasExistingCircle = false;
  String? _error;
  String? _ok;

  @override
  void initState() {
    super.initState();
    appThemeController.addListener(_onThemeChanged);
    _loadTeacherData();
  }

  @override
  void dispose() {
    appThemeController.removeListener(_onThemeChanged);
    _meetingUrlCtrl.dispose();
    _topicCtrl.dispose();
    _descriptionCtrl.dispose();
    _durationCtrl.dispose();
    super.dispose();
  }

  void _onThemeChanged() {
    if (!mounted) return;
    setState(() {});
  }

  AppPalette get p => appThemeController.palette;

  Future<void> _loadTeacherData() async {
    if (!mounted) return;

    setState(() {
      _busy = true;
      _error = null;
      _ok = null;
    });

    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('Not logged in.');
      debugPrint(
        '[OnlineCircle][Teacher] Loading circle data for uid=${user.uid}',
      );

      final meetingUrlFuture = _db
          .ref('users/${user.uid}/google_meet_url')
          .get();
      final circleFuture = _db.ref('circle/${user.uid}').get();

      final results = await Future.wait([meetingUrlFuture, circleFuture]);

      final meetingSnap = results[0];
      final circleSnap = results[1];

      if (meetingSnap.exists && meetingSnap.value != null) {
        _meetingUrlCtrl.text = meetingSnap.value.toString().trim();
      }

      if (circleSnap.exists && circleSnap.value is Map) {
        final data = Map<String, dynamic>.from(circleSnap.value as Map);

        _topicCtrl.text = (data['topic'] ?? '').toString();
        _descriptionCtrl.text = (data['description'] ?? '').toString();
        _durationCtrl.text = (data['duration'] ?? '60').toString();
        _circleImageUrl = (data['circle_image_url'] ?? '').toString().trim();

        final timeValue = data['time'];
        if (timeValue != null) {
          final millis = int.tryParse(timeValue.toString());
          if (millis != null) {
            _selectedDateTime = DateTime.fromMillisecondsSinceEpoch(millis);
          }
        }

        _isOpen = (data['status'] ?? 'open').toString() == 'open';
        _hasExistingCircle = true;
        debugPrint(
          '[OnlineCircle][Teacher] Existing circle loaded. status=${_isOpen ? 'open' : 'closed'} time=${_selectedDateTime?.millisecondsSinceEpoch ?? 0}',
        );
      } else {
        _hasExistingCircle = false;
        debugPrint('[OnlineCircle][Teacher] No existing circle found.');
      }
    } catch (e) {
      _error = toHumanError(e);
      debugPrint('[OnlineCircle][Teacher] Failed to load circle data: $e');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _pickDateTime() async {
    final now = DateTime.now();
    final initialDate = _selectedDateTime ?? now;

    final pickedDate = await showDatePicker(
      context: context,
      initialDate: initialDate.isBefore(now) ? now : initialDate,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 3),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: Theme.of(context).colorScheme.copyWith(
              primary: p.primary,
              secondary: p.accent,
              surface: p.cardBg,
              onSurface: p.text,
            ),
          ),
          child: child!,
        );
      },
    );

    if (pickedDate == null) return;
    if (!mounted) return;

    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initialDate),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: Theme.of(context).colorScheme.copyWith(
              primary: p.primary,
              secondary: p.accent,
              surface: p.cardBg,
              onSurface: p.text,
            ),
          ),
          child: child!,
        );
      },
    );

    if (pickedTime == null) return;

    setState(() {
      _selectedDateTime = DateTime(
        pickedDate.year,
        pickedDate.month,
        pickedDate.day,
        pickedTime.hour,
        pickedTime.minute,
      );
    });
  }

  String _formattedDateTime() {
    if (_selectedDateTime == null) return 'Select date and time';
    return DateFormat('yyyy-MM-dd hh:mm a').format(_selectedDateTime!);
  }

  InputDecoration _dec(String label, {String? hintText, Widget? suffixIcon}) {
    return InputDecoration(
      labelText: label,
      hintText: hintText,
      filled: true,
      fillColor: p.cardBg,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: p.border.withValues(alpha: 0.95)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide(color: p.primary, width: 1.8),
      ),
      suffixIcon: suffixIcon,
    );
  }

  Future<void> _saveCircle() async {
    FocusScope.of(context).unfocus();

    setState(() {
      _error = null;
      _ok = null;
    });

    final formState = _formKey.currentState;
    if (formState != null && !formState.validate()) return;

    if (_selectedDateTime == null) {
      setState(() {
        _error = 'Please select the circle date and time.';
      });
      return;
    }

    final user = _auth.currentUser;
    if (user == null) {
      setState(() {
        _error = 'Not logged in.';
      });
      return;
    }

    final meetingUrl = _meetingUrlCtrl.text.trim();
    if (meetingUrl.isEmpty) {
      setState(() {
        _error = 'This teacher has no meeting URL in the profile.';
      });
      return;
    }

    final duration = int.tryParse(_durationCtrl.text.trim());
    if (duration == null || duration <= 0) {
      setState(() {
        _error = 'Duration must be a valid number greater than 0.';
      });
      return;
    }

    setState(() => _busy = true);

    try {
      debugPrint(
        '[OnlineCircle][Teacher] Saving circle. topic="${_topicCtrl.text.trim()}" status=${_isOpen ? 'open' : 'closed'} time=${_selectedDateTime?.millisecondsSinceEpoch ?? 0}',
      );
      final circleRef = _db.ref('circle/${user.uid}');
      final userRef = _db.ref('users/${user.uid}');
      final existingSnap = await circleRef.get();
      final userSnap = await userRef.get();
      final alreadyExists = existingSnap.exists;
      final teacherData = userSnap.value is Map
          ? Map<String, dynamic>.from(userSnap.value as Map)
          : <String, dynamic>{};
      final teacherName = _extractTeacherName(teacherData);
      final teacherProfilePhoto = _extractTeacherProfilePhoto(teacherData);

      await circleRef.set({
        'circle_id': user.uid,
        'teacher_uid': user.uid,
        'teacher_name': teacherName,
        'teacher_profile_photo': teacherProfilePhoto,
        'circle_image_url': (_circleImageUrl ?? '').trim(),
        'meeting_url': meetingUrl,
        'topic': _topicCtrl.text.trim(),
        'description': _descriptionCtrl.text.trim(),
        'time': _selectedDateTime!.millisecondsSinceEpoch,
        'duration': duration,
        'status': _isOpen ? 'open' : 'closed',
        'createdAt': alreadyExists
            ? (existingSnap.child('createdAt').value ?? ServerValue.timestamp)
            : ServerValue.timestamp,
        'updatedAt': ServerValue.timestamp,
      });

      if (!mounted) return;

      setState(() {
        _hasExistingCircle = true;
        _ok = alreadyExists
            ? 'Circle updated successfully ✅'
            : 'Circle saved successfully ✅';
      });
      debugPrint(
        '[OnlineCircle][Teacher] Circle saved successfully. existed=$alreadyExists imageSet=${(_circleImageUrl ?? '').trim().isNotEmpty}',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = toHumanError(e);
      });
      debugPrint('[OnlineCircle][Teacher] Save failed: $e');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  String _teacherAppId(String uid) => 'teacher_$uid';

  String _extractTeacherName(Map<String, dynamic> data) {
    final first = (data['first_name'] ?? '').toString().trim();
    final last = (data['last_name'] ?? '').toString().trim();
    final full = '$first $last'.trim();
    if (full.isNotEmpty) return full;
    final fallback = (data['name'] ?? data['display_name'] ?? '')
        .toString()
        .trim();
    return fallback;
  }

  String _extractTeacherProfilePhoto(Map<String, dynamic> data) {
    final direct = (data['profile_photo'] ?? '').toString().trim();
    if (direct.isNotEmpty) return direct;

    final photos = data['profile_photos'];
    if (photos is List) {
      for (final item in photos) {
        final p = item.toString().trim();
        if (p.isNotEmpty) return p;
      }
    }

    if (photos is Map) {
      final entries = photos.entries.toList()
        ..sort((a, b) {
          final ai = int.tryParse(a.key.toString()) ?? 999999;
          final bi = int.tryParse(b.key.toString()) ?? 999999;
          return ai.compareTo(bi);
        });
      for (final e in entries) {
        final p = e.value.toString().trim();
        if (p.isNotEmpty) return p;
      }
    }

    return '';
  }

  Future<String> _uploadPlatformFile(PlatformFile file) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('Not logged in.');

    final uploadUri = await BackendApi.withAuthQuery(
      BackendApi.uri('upload_secure.php'),
    );
    final request = http.MultipartRequest('POST', uploadUri);
    request.headers['X-Requested-With'] = 'XMLHttpRequest';
    await BackendApi.applyAuthToMultipart(request);
    request.fields['app_id'] = _teacherAppId(user.uid);

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

    debugPrint(
      '[OnlineCircle][Teacher] Uploading circle media file="${file.name}"',
    );
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
    debugPrint('[OnlineCircle][Teacher] Upload completed. url=$url');
    return url;
  }

  Future<void> _pickAndUploadCircleImage() async {
    if (_uploadingCircleImage || _busy) return;

    try {
      setState(() {
        _uploadingCircleImage = true;
        _error = null;
        _ok = null;
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
        _circleImageUrl = url;
        _ok = 'Circle image uploaded ✅';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = toHumanError(e));
      debugPrint('[OnlineCircle][Teacher] Image upload failed: $e');
    } finally {
      if (mounted) {
        setState(() => _uploadingCircleImage = false);
      }
    }
  }

  void _removeCircleImage() {
    setState(() {
      _circleImageUrl = null;
      _ok = 'Circle image removed';
      _error = null;
    });
  }

  Widget _circleImagePicker() {
    final imageUrl = (_circleImageUrl ?? '').trim();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Circle Image',
          style: TextStyle(
            color: p.primary,
            fontWeight: FontWeight.w900,
            fontSize: 15,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Upload a cover image for the guest circle card.',
          style: TextStyle(
            color: p.text.withValues(alpha: 0.68),
            fontWeight: FontWeight.w700,
            fontSize: 12,
          ),
        ),
        const SizedBox(height: 10),
        Container(
          width: double.infinity,
          height: 190,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: p.border.withValues(alpha: 0.95)),
            color: p.soft.withValues(alpha: 0.45),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(17),
            child: imageUrl.isEmpty
                ? Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.image_outlined,
                        color: p.primary.withValues(alpha: 0.8),
                        size: 34,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'No image selected',
                        style: TextStyle(
                          color: p.text.withValues(alpha: 0.72),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  )
                : Image.network(
                    imageUrl,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Center(
                      child: Icon(
                        Icons.broken_image_outlined,
                        color: p.primary.withValues(alpha: 0.7),
                        size: 30,
                      ),
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: (_busy || _uploadingCircleImage)
                    ? null
                    : _pickAndUploadCircleImage,
                icon: _uploadingCircleImage
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Icon(
                        imageUrl.isEmpty
                            ? Icons.add_photo_alternate_outlined
                            : Icons.refresh_rounded,
                      ),
                label: Text(
                  _uploadingCircleImage
                      ? 'Uploading...'
                      : imageUrl.isEmpty
                      ? 'Upload image'
                      : 'Replace image',
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: p.accent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ),
            if (imageUrl.isNotEmpty) ...[
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: (_busy || _uploadingCircleImage)
                    ? null
                    : _removeCircleImage,
                icon: const Icon(Icons.delete_outline_rounded),
                label: const Text('Remove'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: p.primary,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 13,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _statusBanner() {
    if (_error == null && _ok == null) return const SizedBox.shrink();

    final isError = _error != null;
    final bg = isError
        ? const Color(0xFFFFEBEE)
        : p.soft.withValues(alpha: 0.75);
    final border = isError ? const Color(0xFFFFCDD2) : p.border;
    final textColor = isError ? const Color(0xFFC62828) : p.primary;
    final icon = isError
        ? Icons.error_outline_rounded
        : Icons.check_circle_rounded;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: border),
      ),
      child: Row(
        children: [
          Icon(icon, color: textColor),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              isError ? _error! : _ok!,
              style: TextStyle(color: textColor, fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionCard({
    required String title,
    required String subtitle,
    required Widget child,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: p.cardBg,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: p.border.withValues(alpha: 0.9)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 14,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                color: p.primary,
                fontWeight: FontWeight.w900,
                fontSize: 17,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: TextStyle(
                color: p.text.withValues(alpha: 0.65),
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: p.appBg,
      appBar: AppBar(
        backgroundColor: p.cardBg,
        elevation: 0,
        surfaceTintColor: p.cardBg,
        iconTheme: IconThemeData(color: p.primary),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Online Circle',
              style: TextStyle(
                color: p.primary,
                fontWeight: FontWeight.w900,
                fontSize: 18,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              _hasExistingCircle
                  ? 'Edit your live teacher circle'
                  : 'Create a live teacher circle',
              style: TextStyle(
                color: p.text.withValues(alpha: 0.65),
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
          ],
        ),
        actions: [
          const SizedBox.shrink(),
          IconButton(
            tooltip: 'Refresh',
            icon: Icon(Icons.refresh_rounded, color: p.accent),
            onPressed: _busy ? null : _loadTeacherData,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: p.accent,
        foregroundColor: Colors.white,
        onPressed: (_busy || _uploadingCircleImage) ? null : _saveCircle,
        icon: _busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Icon(Icons.save_rounded),
        label: Text(
          _busy
              ? 'Saving...'
              : _hasExistingCircle
              ? 'Update Circle'
              : 'Save Circle',
        ),
      ),
      body: teacherWebBodyFrame(
        context: context,
        maxWidth: 1120,
        child: SafeArea(
          child: Column(
            children: [
              if (_busy)
                LinearProgressIndicator(
                  color: p.accent,
                  backgroundColor: p.soft,
                ),
              _statusBanner(),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 120),
                  children: [
                    _sectionCard(
                      title: 'Circle Details',
                      subtitle: 'Set topic, schedule, duration and visibility',
                      child: Form(
                        key: _formKey,
                        autovalidateMode: AutovalidateMode.onUserInteraction,
                        child: Column(
                          children: [
                            _circleImagePicker(),
                            const SizedBox(height: 14),
                            TextFormField(
                              controller: _meetingUrlCtrl,
                              readOnly: true,
                              decoration: _dec(
                                'Meeting URL',
                                hintText: 'Loaded from teacher profile',
                              ),
                              validator: (v) {
                                final value = (v ?? '').trim();
                                if (value.isEmpty) {
                                  return 'No meeting URL found in teacher profile';
                                }

                                final uri = Uri.tryParse(value);
                                if (uri == null || !uri.isAbsolute) {
                                  return 'Meeting URL is invalid';
                                }

                                return null;
                              },
                            ),
                            const SizedBox(height: 12),
                            TextFormField(
                              controller: _topicCtrl,
                              decoration: _dec('Topic'),
                              validator: (v) {
                                if ((v ?? '').trim().isEmpty) {
                                  return 'Topic is required';
                                }
                                return null;
                              },
                            ),
                            const SizedBox(height: 12),
                            TextFormField(
                              controller: _descriptionCtrl,
                              minLines: 3,
                              maxLines: 5,
                              decoration: _dec('Description'),
                              validator: (v) {
                                if ((v ?? '').trim().isEmpty) {
                                  return 'Description is required';
                                }
                                return null;
                              },
                            ),
                            const SizedBox(height: 12),
                            InkWell(
                              borderRadius: BorderRadius.circular(16),
                              onTap: _busy ? null : _pickDateTime,
                              child: Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 16,
                                ),
                                decoration: BoxDecoration(
                                  color: p.cardBg,
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: p.border.withValues(alpha: 0.95),
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.calendar_month_rounded,
                                      color: p.primary,
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        _formattedDateTime(),
                                        style: TextStyle(
                                          color: _selectedDateTime == null
                                              ? p.text.withValues(alpha: 0.65)
                                              : p.text,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextFormField(
                              controller: _durationCtrl,
                              keyboardType: TextInputType.number,
                              decoration: _dec(
                                'Duration (minutes)',
                                hintText: 'e.g. 60',
                              ),
                              validator: (v) {
                                final value = int.tryParse((v ?? '').trim());
                                if (value == null || value <= 0) {
                                  return 'Enter a valid duration';
                                }
                                return null;
                              },
                            ),
                            const SizedBox(height: 18),
                            Container(
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: p.soft.withValues(alpha: 0.55),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: p.border.withValues(alpha: 0.85),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          'Circle Status',
                                          style: TextStyle(
                                            color: p.primary,
                                            fontWeight: FontWeight.w900,
                                            fontSize: 15,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          _isOpen
                                              ? 'This circle is currently open'
                                              : 'This circle is currently closed',
                                          style: TextStyle(
                                            color: p.text.withValues(
                                              alpha: 0.68,
                                            ),
                                            fontWeight: FontWeight.w700,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Switch(
                                    value: _isOpen,
                                    activeThumbColor: p.accent,
                                    onChanged: _busy
                                        ? null
                                        : (v) {
                                            setState(() {
                                              _isOpen = v;
                                            });
                                          },
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
