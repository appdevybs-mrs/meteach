import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../shared/app_theme.dart';
import '../shared/human_error.dart';
import '../shared/screen_help_guide.dart';
import '../shared/teacher_tour_guide.dart';

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
  bool _isOpen = true;
  bool _busy = false;

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

        final timeValue = data['time'];
        if (timeValue != null) {
          final millis = int.tryParse(timeValue.toString());
          if (millis != null) {
            _selectedDateTime = DateTime.fromMillisecondsSinceEpoch(millis);
          }
        }

        _isOpen = (data['status'] ?? 'open').toString() == 'open';
        _hasExistingCircle = true;
      } else {
        _hasExistingCircle = false;
      }
    } catch (e) {
      _error = toHumanError(e);
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
      final circleRef = _db.ref('circle/${user.uid}');
      final existingSnap = await circleRef.get();
      final alreadyExists = existingSnap.exists;

      await circleRef.set({
        'circle_id': user.uid,
        'teacher_uid': user.uid,
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
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = toHumanError(e);
      });
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
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
    TeacherTourGuide.schedule(
      context,
      screenId: 'teacher_online_circle',
      hints: const [
        TeacherTourHint(
          title: 'Online circle',
          line:
              'Create or update your online circle topic, link, and session details.',
        ),
      ],
    );

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
          IconButton(
            tooltip: 'Instructions',
            icon: Icon(Icons.help_outline_rounded, color: p.primary),
            onPressed: () => ScreenHelpGuide.show(
              context,
              role: GuideRole.teacher,
              screenId: 'teacher_online_circle',
              screenTitle: 'Online Circle',
            ),
          ),
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
        onPressed: _busy ? null : _saveCircle,
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
      body: SafeArea(
        child: Column(
          children: [
            if (_busy)
              LinearProgressIndicator(color: p.accent, backgroundColor: p.soft),
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
                                          color: p.text.withValues(alpha: 0.68),
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
    );
  }
}
