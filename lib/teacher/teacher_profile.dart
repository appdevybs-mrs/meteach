import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';

import '../shared/app_theme.dart';
import '../shared/human_error.dart';
import '../shared/ybs_busy_logo.dart';
import '../services/backend_api.dart';
import '../shared/app_feedback.dart';
import '../shared/teacher_tour_guide.dart';

enum _LeaveChoice { save, discard, cancel }

class TeacherProfileScreen extends StatefulWidget {
  const TeacherProfileScreen({super.key});

  @override
  State<TeacherProfileScreen> createState() => _TeacherProfileScreenState();
}

class _TeacherProfileScreenState extends State<TeacherProfileScreen>
    with SingleTickerProviderStateMixin {
  final _auth = FirebaseAuth.instance;
  final _formKey = GlobalKey<FormState>();

  late final TabController _tabController;

  final _firstNameCtrl = TextEditingController();
  final _lastNameCtrl = TextEditingController();
  final _phone1Ctrl = TextEditingController();
  final _phone2Ctrl = TextEditingController();
  final _dobCtrl = TextEditingController();
  final _aboutMeCtrl = TextEditingController();
  final _googleMeetUrlCtrl = TextEditingController();

  bool _busy = false;
  bool _uploadingPhotos = false;
  bool _uploadingVideo = false;

  String? _error;
  String? _ok;

  String _emailReadOnly = '';
  String _roleReadOnly = '';
  String _statusReadOnly = '';

  DatabaseReference? _userRef;

  static const int _maxPhotos = 6;

  final List<String> _photoUrls = [];
  String? _introVideoUrl;

  String _initialFirstName = '';
  String _initialLastName = '';
  String _initialPhone1 = '';
  String _initialPhone2 = '';
  String _initialDob = '';
  String _initialAboutMe = '';
  String _initialGoogleMeetUrl = '';
  List<String> _initialPhotoUrls = const [];
  String _initialIntroVideoUrl = '';

  VideoPlayerController? _videoController;
  bool _videoReady = false;

  static final RegExp _specialRegex = RegExp(
    r'[!@#$%^&*(),.?":{}|<>_\-+=/\\\[\]~`]',
  );

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    appThemeController.addListener(_onThemeChanged);
    _loadProfile();
  }

  @override
  void dispose() {
    appThemeController.removeListener(_onThemeChanged);
    _tabController.dispose();
    _firstNameCtrl.dispose();
    _lastNameCtrl.dispose();
    _phone1Ctrl.dispose();
    _phone2Ctrl.dispose();
    _dobCtrl.dispose();
    _aboutMeCtrl.dispose();
    _disposeVideoController();
    _googleMeetUrlCtrl.dispose();
    super.dispose();
  }

  void _onThemeChanged() {
    if (!mounted) return;
    setState(() {});
  }

  AppPalette get p => appThemeController.palette;

  Future<void> _disposeVideoController() async {
    final controller = _videoController;
    _videoController = null;
    _videoReady = false;
    if (controller != null) {
      await controller.dispose();
    }
  }

  Future<void> _loadProfile() async {
    if (!mounted) return;

    setState(() {
      _busy = true;
      _error = null;
      _ok = null;
    });

    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('Not logged in.');

      _userRef = FirebaseDatabase.instance.ref('users/${user.uid}');
      final snap = await _userRef!.get();

      if (!snap.exists || snap.value == null) {
        throw Exception('No user record found in database.');
      }

      final data = Map<String, dynamic>.from(snap.value as Map);

      _firstNameCtrl.text = (data['first_name'] ?? '').toString();
      _lastNameCtrl.text = (data['last_name'] ?? '').toString();
      _phone1Ctrl.text = (data['phone1'] ?? '').toString();
      _phone2Ctrl.text = (data['phone2'] ?? '').toString();
      _dobCtrl.text = (data['dob'] ?? '').toString();
      _aboutMeCtrl.text = (data['about_me'] ?? '').toString();
      _googleMeetUrlCtrl.text = (data['google_meet_url'] ?? '').toString();

      _emailReadOnly = (data['email'] ?? user.email ?? '').toString();
      _roleReadOnly = (data['role'] ?? '').toString();
      _statusReadOnly = (data['status'] ?? '').toString();

      _photoUrls.clear();
      final rawPhotos = data['profile_photos'];
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

      _introVideoUrl = (data['intro_video_url'] ?? '').toString().trim();
      if (_introVideoUrl!.isEmpty) {
        _introVideoUrl = null;
      }

      if (_introVideoUrl != null) {
        await _initVideoPreview(_introVideoUrl!);
      } else {
        await _disposeVideoController();
      }

      _captureInitialState();
    } catch (e) {
      _error = toHumanError(e);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _initVideoPreview(String url) async {
    try {
      await _disposeVideoController();

      final controller = VideoPlayerController.networkUrl(Uri.parse(url));
      await controller.initialize();
      await controller.setLooping(false);

      if (!mounted) {
        await controller.dispose();
        return;
      }

      setState(() {
        _videoController = controller;
        _videoReady = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _videoReady = false;
      });
    }
  }

  Future<void> _pickDob() async {
    DateTime initial = DateTime(2000, 1, 1);

    try {
      final t = _dobCtrl.text.trim();
      if (t.isNotEmpty) {
        final parts = t.split('-');
        if (parts.length == 3) {
          initial = DateTime(
            int.parse(parts[0]),
            int.parse(parts[1]),
            int.parse(parts[2]),
          );
        }
      }
    } catch (_) {}

    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(1940, 1, 1),
      lastDate: DateTime.now(),
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

    if (picked == null) return;

    final yyyy = picked.year.toString().padLeft(4, '0');
    final mm = picked.month.toString().padLeft(2, '0');
    final dd = picked.day.toString().padLeft(2, '0');
    _dobCtrl.text = '$yyyy-$mm-$dd';

    _formKey.currentState?.validate();
    if (mounted) setState(() {});
  }

  Future<bool> _save({bool showSuccessMessage = true}) async {
    FocusScope.of(context).unfocus();

    setState(() {
      _error = null;
      _ok = null;
    });

    final formState = _formKey.currentState;
    if (formState != null && !formState.validate()) return false;

    setState(() => _busy = true);

    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('Not logged in.');

      final rootRef = FirebaseDatabase.instance.ref();
      final aboutMe = _aboutMeCtrl.text.trim();
      final cleanPhotos = _photoUrls
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
      await rootRef.update({
        'users/${user.uid}/first_name': _firstNameCtrl.text.trim(),
        'users/${user.uid}/last_name': _lastNameCtrl.text.trim(),
        'users/${user.uid}/phone1': _phone1Ctrl.text.trim(),
        'users/${user.uid}/phone2': _phone2Ctrl.text.trim(),
        'users/${user.uid}/dob': _dobCtrl.text.trim(),
        'users/${user.uid}/about_me': aboutMe,
        'users/${user.uid}/profile_photos': cleanPhotos,
        'users/${user.uid}/intro_video_url': _introVideoUrl ?? '',
        'users/${user.uid}/google_meet_url': _googleMeetUrlCtrl.text.trim(),
        'users/${user.uid}/updatedAt': ServerValue.timestamp,
        'website/teachers/${user.uid}/profile/about_me': aboutMe,
        'website/teachers/${user.uid}/profile/intro_video_url':
            _introVideoUrl ?? '',
        'website/teachers/${user.uid}/profile/profile_photos': cleanPhotos,
        'website/teachers/${user.uid}/profile/profile_photo':
            cleanPhotos.isNotEmpty ? cleanPhotos.first : '',
      });

      if (mounted) {
        setState(() {
          _ok = showSuccessMessage ? 'Profile saved successfully ✅' : null;
        });
        _captureInitialState();
      }
      return true;
    } catch (e) {
      if (mounted) {
        setState(() => _error = toHumanError(e));
      }
      return false;
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  void _captureInitialState() {
    _initialFirstName = _firstNameCtrl.text.trim();
    _initialLastName = _lastNameCtrl.text.trim();
    _initialPhone1 = _phone1Ctrl.text.trim();
    _initialPhone2 = _phone2Ctrl.text.trim();
    _initialDob = _dobCtrl.text.trim();
    _initialAboutMe = _aboutMeCtrl.text.trim();
    _initialGoogleMeetUrl = _googleMeetUrlCtrl.text.trim();
    _initialPhotoUrls = _photoUrls.map((e) => e.trim()).toList();
    _initialIntroVideoUrl = (_introVideoUrl ?? '').trim();
  }

  bool get _hasUnsavedChanges {
    if (_firstNameCtrl.text.trim() != _initialFirstName) return true;
    if (_lastNameCtrl.text.trim() != _initialLastName) return true;
    if (_phone1Ctrl.text.trim() != _initialPhone1) return true;
    if (_phone2Ctrl.text.trim() != _initialPhone2) return true;
    if (_dobCtrl.text.trim() != _initialDob) return true;
    if (_aboutMeCtrl.text.trim() != _initialAboutMe) return true;
    if (_googleMeetUrlCtrl.text.trim() != _initialGoogleMeetUrl) return true;
    if (!listEquals(
      _photoUrls.map((e) => e.trim()).toList(),
      _initialPhotoUrls,
    )) {
      return true;
    }
    if ((_introVideoUrl ?? '').trim() != _initialIntroVideoUrl) return true;
    return false;
  }

  Future<_LeaveChoice> _askUnsavedChangesAction() async {
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
          style: TextStyle(color: p.text.withValues(alpha: 0.8)),
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
      final saved = await _save(showSuccessMessage: false);
      if (saved && mounted) {
        Navigator.of(context).pop();
      }
    }
  }

  String _teacherAppId(String uid) => 'teacher_$uid';

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

  Future<void> _mirrorWebsiteUploadUrl({
    required String url,
    required String mediaType,
  }) async {
    final cleanUrl = url.trim();
    if (cleanUrl.isEmpty) return;

    final uid = (_auth.currentUser?.uid ?? '').trim();
    if (uid.isEmpty) return;

    try {
      await FirebaseDatabase.instance
          .ref('website/teachers/$uid/uploads')
          .push()
          .set({
            'url': cleanUrl,
            'type': mediaType,
            'createdAt': ServerValue.timestamp,
          });
    } catch (e) {
      debugPrint('Teacher website URL mirror failed: $e');
    }
  }

  Future<void> _mirrorWebsiteIntroVideoUrl(String url) async {
    final cleanUrl = url.trim();
    final uid = (_auth.currentUser?.uid ?? '').trim();
    if (uid.isEmpty) return;

    try {
      await FirebaseDatabase.instance
          .ref('website/teachers/$uid/profile/intro_video_url')
          .set(cleanUrl);
    } catch (e) {
      debugPrint('Teacher website intro video mirror failed: $e');
    }
  }

  Future<void> _mirrorWebsiteProfilePhotos() async {
    final uid = (_auth.currentUser?.uid ?? '').trim();
    if (uid.isEmpty) return;

    final cleanPhotos = _photoUrls
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    try {
      await FirebaseDatabase.instance
          .ref('website/teachers/$uid/profile')
          .update({
            'profile_photos': cleanPhotos,
            'profile_photo': cleanPhotos.isNotEmpty ? cleanPhotos.first : '',
          });
    } catch (e) {
      debugPrint('Teacher website profile photos mirror failed: $e');
    }
  }

  Future<void> _pickAndUploadPhotos() async {
    if (_uploadingPhotos || _busy) return;

    final remaining = _maxPhotos - _photoUrls.length;
    if (remaining <= 0) {
      AppToast.fromSnackBar(
        context,
        const SnackBar(content: Text('You already reached the 6 photo limit.')),
      );
      return;
    }

    try {
      setState(() {
        _uploadingPhotos = true;
        _error = null;
        _ok = null;
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
        await _mirrorWebsiteUploadUrl(url: url, mediaType: 'photo');
        _photoUrls.add(url);
      }

      await _mirrorWebsiteProfilePhotos();

      if (mounted) {
        setState(() {
          _ok = 'Photos uploaded successfully ✅';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = toHumanError(e));
      }
    } finally {
      if (mounted) {
        setState(() => _uploadingPhotos = false);
      }
    }
  }

  Future<void> _pickAndUploadVideo() async {
    if (_uploadingVideo || _busy) return;

    try {
      setState(() {
        _uploadingVideo = true;
        _error = null;
        _ok = null;
      });

      final result = await FilePicker.platform.pickFiles(
        allowMultiple: false,
        withData: kIsWeb,
        type: FileType.custom,
        allowedExtensions: const ['mp4', 'mov', 'webm', '3gp', 'ogg'],
      );

      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      final url = await _uploadPlatformFile(file);
      await _mirrorWebsiteUploadUrl(url: url, mediaType: 'video');
      await _mirrorWebsiteIntroVideoUrl(url);

      _introVideoUrl = url;
      await _initVideoPreview(url);

      if (mounted) {
        setState(() {
          _ok = 'Intro video uploaded successfully ✅';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = toHumanError(e));
      }
    } finally {
      if (mounted) {
        setState(() => _uploadingVideo = false);
      }
    }
  }

  Future<void> _removePhoto(int index) async {
    if (index < 0 || index >= _photoUrls.length) return;

    final ok = await _confirmDialog(
      title: 'Remove photo',
      message: 'Do you want to remove this photo from your profile?',
      confirmText: 'Remove',
    );

    if (!ok) return;

    setState(() {
      _photoUrls.removeAt(index);
      _ok = 'Photo removed';
      _error = null;
    });

    await _mirrorWebsiteProfilePhotos();
  }

  Future<void> _removeVideo() async {
    if (_introVideoUrl == null) return;

    final ok = await _confirmDialog(
      title: 'Remove intro video',
      message: 'Do you want to remove your intro video?',
      confirmText: 'Remove',
    );

    if (!ok) return;

    await _disposeVideoController();

    if (!mounted) return;

    setState(() {
      _introVideoUrl = null;
      _ok = 'Intro video removed';
      _error = null;
    });
  }

  String? _newPasswordValidator(String? v) {
    final value = (v ?? '').trim();
    if (value.isEmpty) return 'Password is required';
    if (value.length < 8) return 'Must be at least 8 characters';
    if (!_specialRegex.hasMatch(value)) {
      return 'Add at least 1 special character';
    }
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
        backgroundColor: p.cardBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text(
          title,
          style: TextStyle(color: p.primary, fontWeight: FontWeight.w900),
        ),
        content: Text(
          message,
          style: TextStyle(color: p.text, fontWeight: FontWeight.w600),
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
    if (currentUser == null) {
      AppToast.fromSnackBar(
        context,
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
      backgroundColor: p.cardBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
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
                AppToast.fromSnackBar(
                  context,
                  const SnackBar(content: Text('Password updated ✅')),
                );
              } on FirebaseAuthException catch (e) {
                String msg = e.message ?? 'Failed to update password.';
                if (e.code == 'wrong-password') {
                  msg = 'Current password is incorrect.';
                }
                if (e.code == 'requires-recent-login') {
                  msg =
                      'Please log in again, then retry changing your password.';
                }
                if (mounted) {
                  AppToast.fromSnackBar(context, SnackBar(content: Text(msg)));
                }
              } catch (e) {
                if (mounted) {
                  AppToast.fromSnackBar(
                    context,
                    SnackBar(content: Text(toHumanError(e))),
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
                      Text(
                        'Change Password',
                        style: TextStyle(
                          color: p.primary,
                          fontWeight: FontWeight.w900,
                          fontSize: 18,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Minimum 8 characters and at least 1 special character.',
                        style: TextStyle(
                          color: p.text.withValues(alpha: 0.7),
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 14),
                      _pwField(
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
                        label: 'Confirm new password',
                        controller: confirmCtrl,
                        obscure: obscureConfirm,
                        onToggle: () => setModalState(
                          () => obscureConfirm = !obscureConfirm,
                        ),
                        validator: (v) {
                          final value = (v ?? '').trim();
                          if (value.isEmpty) {
                            return 'Please confirm your new password';
                          }
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
                        child: FilledButton.icon(
                          icon: const Icon(Icons.lock_reset_rounded),
                          label: const Text('Update password'),
                          style: FilledButton.styleFrom(
                            backgroundColor: p.accent,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
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

    currentCtrl.dispose();
    newCtrl.dispose();
    confirmCtrl.dispose();
  }

  InputDecoration _dec(String label, {Widget? suffixIcon, String? hintText}) {
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
            color: p.text.withValues(alpha: 0.78),
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 6),
        TextFormField(
          controller: controller,
          obscureText: obscure,
          validator: validator,
          onChanged: onChanged,
          decoration: _dec(
            '',
            suffixIcon: IconButton(
              tooltip: obscure ? 'Show' : 'Hide',
              icon: Icon(
                obscure
                    ? Icons.visibility_rounded
                    : Icons.visibility_off_rounded,
                color: p.primary,
              ),
              onPressed: onToggle,
            ),
          ),
        ),
      ],
    );
  }

  Widget _infoRow({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: p.soft.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: p.border.withValues(alpha: 0.85)),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: p.cardBg,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: p.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: p.text.withValues(alpha: 0.62),
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  value.isEmpty ? '-' : value,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: p.primary,
                    fontWeight: FontWeight.w900,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPhotosSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Profile Photos',
          style: TextStyle(
            color: p.primary,
            fontWeight: FontWeight.w900,
            fontSize: 16,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Upload up to 6 photos to present yourself professionally.',
          style: TextStyle(
            color: p.text.withValues(alpha: 0.68),
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            ...List.generate(_photoUrls.length, (index) {
              final url = _photoUrls[index];
              return Stack(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: p.border),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.03),
                          blurRadius: 8,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(18),
                      child: Image.network(
                        url,
                        width: 110,
                        height: 110,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Container(
                          width: 110,
                          height: 110,
                          color: p.soft,
                          alignment: Alignment.center,
                          child: Icon(
                            Icons.broken_image_outlined,
                            color: p.primary,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 6,
                    right: 6,
                    child: InkWell(
                      onTap: () => _removePhoto(index),
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        padding: const EdgeInsets.all(5),
                        child: const Icon(
                          Icons.close_rounded,
                          color: Colors.white,
                          size: 16,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            }),
            if (_photoUrls.length < _maxPhotos)
              InkWell(
                onTap: (_uploadingPhotos || _busy)
                    ? null
                    : _pickAndUploadPhotos,
                borderRadius: BorderRadius.circular(18),
                child: Container(
                  width: 110,
                  height: 110,
                  decoration: BoxDecoration(
                    color: p.cardBg,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: p.border),
                  ),
                  child: _uploadingPhotos
                      ? Center(child: YbsBusyLogo(color: p.accent))
                      : Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.add_photo_alternate_outlined,
                              color: p.primary,
                            ),
                            const SizedBox(height: 8),
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
      ],
    );
  }

  Widget _buildVideoSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Intro Video',
          style: TextStyle(
            color: p.primary,
            fontWeight: FontWeight.w900,
            fontSize: 16,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'Upload one short introduction video for your profile.',
          style: TextStyle(
            color: p.text.withValues(alpha: 0.68),
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 14),
        if (_introVideoUrl == null)
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: p.cardBg,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: p.border),
            ),
            child: Column(
              children: [
                Container(
                  width: 58,
                  height: 58,
                  decoration: BoxDecoration(
                    color: p.soft,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.video_call_rounded,
                    color: p.primary,
                    size: 30,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'No intro video uploaded yet',
                  style: TextStyle(
                    color: p.primary,
                    fontWeight: FontWeight.w900,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'A short intro helps learners know you better.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: p.text.withValues(alpha: 0.68),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 14),
                OutlinedButton.icon(
                  icon: _uploadingVideo
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: YbsBusyLogo(
                            size: 18,
                            color: p.primary,
                            strokeWidth: 2,
                          ),
                        )
                      : const Icon(Icons.upload_rounded),
                  label: Text(
                    _uploadingVideo ? 'Uploading...' : 'Upload intro video',
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: p.primary,
                    side: BorderSide(color: p.border),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  onPressed: (_uploadingVideo || _busy)
                      ? null
                      : _pickAndUploadVideo,
                ),
              ],
            ),
          )
        else
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.06),
                      blurRadius: 14,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: AspectRatio(
                    aspectRatio: (_videoReady && _videoController != null)
                        ? _videoController!.value.aspectRatio
                        : 16 / 9,
                    child: _videoReady && _videoController != null
                        ? Stack(
                            alignment: Alignment.center,
                            children: [
                              VideoPlayer(_videoController!),
                              Container(
                                decoration: const BoxDecoration(
                                  color: Colors.black26,
                                ),
                              ),
                              IconButton(
                                onPressed: () {
                                  final controller = _videoController!;
                                  if (controller.value.isPlaying) {
                                    controller.pause();
                                  } else {
                                    controller.play();
                                  }
                                  setState(() {});
                                },
                                iconSize: 60,
                                color: Colors.white,
                                icon: Icon(
                                  _videoController!.value.isPlaying
                                      ? Icons.pause_circle_filled_rounded
                                      : Icons.play_circle_fill_rounded,
                                ),
                              ),
                            ],
                          )
                        : const Center(
                            child: Padding(
                              padding: EdgeInsets.all(20),
                              child: YbsBusyLogo(color: Colors.white),
                            ),
                          ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: p.soft.withValues(alpha: 0.48),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  _introVideoUrl!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: p.text.withValues(alpha: 0.72),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  OutlinedButton.icon(
                    icon: _uploadingVideo
                        ? SizedBox(
                            width: 18,
                            height: 18,
                            child: YbsBusyLogo(
                              size: 18,
                              color: p.primary,
                              strokeWidth: 2,
                            ),
                          )
                        : const Icon(Icons.swap_horiz_rounded),
                    label: Text(
                      _uploadingVideo ? 'Uploading...' : 'Replace video',
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: p.primary,
                      side: BorderSide(color: p.border),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    onPressed: (_uploadingVideo || _busy)
                        ? null
                        : _pickAndUploadVideo,
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.delete_outline_rounded),
                    label: const Text('Remove video'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red.shade700,
                      side: BorderSide(color: Colors.red.shade200),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    onPressed: (_uploadingVideo || _busy) ? null : _removeVideo,
                  ),
                ],
              ),
            ],
          ),
      ],
    );
  }

  Widget _buildCredentialsTab() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 120),
      children: [
        _heroCard(),
        const SizedBox(height: 14),
        _sectionCard(
          title: 'Account Credentials',
          subtitle: 'Your account details and access settings',
          child: Column(
            children: [
              _infoRow(
                icon: Icons.email_rounded,
                label: 'Email',
                value: _emailReadOnly,
              ),
              _infoRow(
                icon: Icons.badge_rounded,
                label: 'Role',
                value: _roleReadOnly,
              ),
              _infoRow(
                icon: Icons.verified_user_rounded,
                label: 'Status',
                value: _statusReadOnly,
              ),
              const SizedBox(height: 4),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.lock_outline_rounded),
                  label: const Text('Change password'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: p.primary,
                    side: BorderSide(color: p.border),
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
        const SizedBox(height: 14),
        _sectionCard(
          title: 'Personal Information',
          subtitle: 'Update your public and contact details',
          child: Form(
            key: _formKey,
            autovalidateMode: AutovalidateMode.onUserInteraction,
            child: Column(
              children: [
                TextFormField(
                  controller: _firstNameCtrl,
                  decoration: _dec('First name'),
                  onChanged: (_) => _formKey.currentState?.validate(),
                  validator: (v) => (v ?? '').trim().isEmpty
                      ? 'First name is required'
                      : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _lastNameCtrl,
                  decoration: _dec('Last name'),
                  onChanged: (_) => _formKey.currentState?.validate(),
                  validator: (v) =>
                      (v ?? '').trim().isEmpty ? 'Last name is required' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _phone1Ctrl,
                  keyboardType: TextInputType.phone,
                  decoration: _dec('Phone 1'),
                  onChanged: (_) => _formKey.currentState?.validate(),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _phone2Ctrl,
                  keyboardType: TextInputType.phone,
                  decoration: _dec('Phone 2'),
                  onChanged: (_) => _formKey.currentState?.validate(),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _dobCtrl,
                  readOnly: true,
                  decoration: _dec(
                    'Date of birth (YYYY-MM-DD)',
                    hintText: 'e.g. 1994-01-12',
                    suffixIcon: IconButton(
                      icon: Icon(
                        Icons.calendar_month_rounded,
                        color: p.primary,
                      ),
                      onPressed: _busy ? null : _pickDob,
                    ),
                  ),
                  onTap: _busy ? null : _pickDob,
                  validator: (v) {
                    final value = (v ?? '').trim();
                    if (value.isEmpty) return null;
                    final ok = RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value);
                    if (!ok) return 'Use YYYY-MM-DD format';
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _aboutMeCtrl,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  minLines: 2,
                  maxLines: 3,
                  maxLength: 220,
                  decoration: _dec(
                    'About me',
                    hintText: 'Short introduction about your teaching style',
                  ),
                  onChanged: (_) => _formKey.currentState?.validate(),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _googleMeetUrlCtrl,
                  keyboardType: TextInputType.url,
                  decoration: _dec(
                    'Google Meet URL',
                    hintText: 'https://meet.google.com/xxx-xxxx-xxx',
                  ),
                  onChanged: (_) => _formKey.currentState?.validate(),
                  validator: (v) {
                    final value = (v ?? '').trim();
                    if (value.isEmpty) return null;

                    final uri = Uri.tryParse(value);
                    if (uri == null || !uri.isAbsolute) {
                      return 'Enter a valid URL';
                    }

                    if (uri.scheme != 'https' ||
                        uri.host != 'meet.google.com') {
                      return 'Use a valid Google Meet link';
                    }

                    return null;
                  },
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMediaTab() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 120),
      children: [
        _sectionCard(
          title: 'Profile Media',
          subtitle: 'Manage photos and introduction video',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildPhotosSection(),
              const SizedBox(height: 22),
              Divider(color: p.border),
              const SizedBox(height: 22),
              _buildVideoSection(),
            ],
          ),
        ),
      ],
    );
  }

  Widget _heroCard() {
    final fullName =
        '${_firstNameCtrl.text.trim()} ${_lastNameCtrl.text.trim()}'.trim();
    final displayName = fullName.isEmpty ? 'Teacher Profile' : fullName;
    final subtitle = _roleReadOnly.isEmpty ? 'Teacher' : _roleReadOnly;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [p.primary, p.primary.withValues(alpha: 0.88)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(26),
        boxShadow: [
          BoxShadow(
            color: p.primary.withValues(alpha: 0.18),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 68,
            height: 68,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.16),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white24),
            ),
            child: Center(
              child: Text(
                displayName.isNotEmpty ? displayName[0].toUpperCase() : 'T',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: 28,
                ),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  displayName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize: 22,
                    height: 1.1,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  subtitle.isEmpty ? 'Teacher' : subtitle,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.84),
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _heroPill(
                      icon: Icons.photo_library_rounded,
                      text: '${_photoUrls.length}/$_maxPhotos photos',
                    ),
                    _heroPill(
                      icon: Icons.videocam_rounded,
                      text: _introVideoUrl == null ? 'No video' : 'Video added',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _heroPill({required IconData icon, required String text}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: Colors.white),
          const SizedBox(width: 6),
          Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: 11,
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

  Widget _statusBanner() {
    if (_error == null && _ok == null) return const SizedBox.shrink();

    final bool isError = _error != null;
    final Color bg = isError
        ? const Color(0xFFFFEBEE)
        : p.soft.withValues(alpha: 0.75);
    final Color border = isError ? const Color(0xFFFFCDD2) : p.border;
    final Color textColor = isError ? const Color(0xFFC62828) : p.primary;
    final IconData icon = isError
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

  @override
  Widget build(BuildContext context) {
    TeacherTourGuide.schedule(
      context,
      screenId: 'teacher_profile',
      hints: const [
        TeacherTourHint(
          title: 'Profile settings',
          line:
              'Edit your personal details, teaching info, and media from this screen.',
        ),
        TeacherTourHint(
          title: 'Save changes',
          line: 'Use save actions to keep updates before leaving the page.',
        ),
      ],
    );

    return PopScope(
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
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Teacher Profile',
                style: TextStyle(
                  color: p.primary,
                  fontWeight: FontWeight.w900,
                  fontSize: 18,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'Professional profile and media',
                style: TextStyle(
                  color: p.text.withValues(alpha: 0.65),
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            ],
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
              onPressed: _busy ? null : _loadProfile,
            ),
          ],
          bottom: TabBar(
            controller: _tabController,
            labelColor: p.primary,
            unselectedLabelColor: p.text.withValues(alpha: 0.65),
            indicatorColor: p.accent,
            tabs: const [
              Tab(icon: Icon(Icons.badge_rounded), text: 'Credentials'),
              Tab(icon: Icon(Icons.perm_media_rounded), text: 'Profile Media'),
            ],
          ),
        ),
        body: SafeArea(
          child: Stack(
            children: [
              Positioned.fill(
                child: IgnorePointer(
                  child: Opacity(
                    opacity: 0.045,
                    child: Center(
                      child: FractionallySizedBox(
                        widthFactor: 0.76,
                        child: Image.asset(
                          'assets/images/ybs_logo.png',
                          fit: BoxFit.contain,
                          errorBuilder: (_, _, _) => const SizedBox.shrink(),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Column(
                children: [
                  if (_busy)
                    LinearProgressIndicator(
                      color: p.accent,
                      backgroundColor: p.soft,
                    ),
                  _statusBanner(),
                  Expanded(
                    child: TabBarView(
                      controller: _tabController,
                      children: [_buildCredentialsTab(), _buildMediaTab()],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
