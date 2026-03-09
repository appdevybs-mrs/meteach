import 'dart:async';
import 'dart:math' as math;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../shared/app_theme.dart';
import '../shared/watermark_background.dart';
import '../services/notification_service.dart';

class LearnerStudyCoachScreen extends StatefulWidget {
  const LearnerStudyCoachScreen({super.key});

  @override
  State<LearnerStudyCoachScreen> createState() =>
      _LearnerStudyCoachScreenState();
}

class _LearnerStudyCoachScreenState extends State<LearnerStudyCoachScreen> {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  String? _selectedSkillKey;
  String? _selectedMilestoneId;
  TimeOfDay _selectedTime = const TimeOfDay(hour: 19, minute: 0);

  bool _saving = false;
  bool _normalizing = false;

  _CoachPalette get palette => _CoachPalette.fromApp(appThemeController.palette);

  String get _uid => FirebaseAuth.instance.currentUser?.uid ?? '';

  DatabaseReference get _goalsRef =>
      _db.child('users/$_uid/study_coach/goals');

  List<_CoachSkill> get _skills => _coachSkills;

  _CoachSkill? get _selectedSkill {
    for (final s in _skills) {
      if (s.key == _selectedSkillKey) return s;
    }
    return null;
  }

  _CoachMilestone? get _selectedMilestone {
    final skill = _selectedSkill;
    if (skill == null) return null;

    for (final m in skill.milestones) {
      if (m.id == _selectedMilestoneId) return m;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    appThemeController.addListener(_themeRefresh);
    unawaited(_normalizeAllGoalCycles());
  }

  @override
  void dispose() {
    appThemeController.removeListener(_themeRefresh);
    super.dispose();
  }

  void _themeRefresh() {
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _pickReminderTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _selectedTime,
      helpText: 'Choose study reminder time',
    );

    if (picked == null) return;
    if (!mounted) return;

    setState(() {
      _selectedTime = picked;
    });
  }

  String _two(int n) => n.toString().padLeft(2, '0');

  String _dateKey(DateTime d) {
    return '${d.year}-${_two(d.month)}-${_two(d.day)}';
  }

  String _currentCycleStartKey(String cycleType) {
    final now = DateTime.now();

    if (cycleType == 'weekly') {
      final start = DateTime(now.year, now.month, now.day)
          .subtract(Duration(days: now.weekday - 1));
      return _dateKey(start);
    }

    if (cycleType == 'monthly') {
      return '${now.year}-${_two(now.month)}-01';
    }

    return _dateKey(now);
  }

  bool _needsCycleReset(Map<String, dynamic> goal) {
    final cycleType = (goal['cycleType'] ?? '').toString().trim();
    final stored = (goal['cycleStartKey'] ?? '').toString().trim();

    if (cycleType.isEmpty) return false;
    if (stored.isEmpty) return true;

    return stored != _currentCycleStartKey(cycleType);
  }

  Future<void> _normalizeAllGoalCycles() async {
    if (_uid.isEmpty || _normalizing) return;

    _normalizing = true;
    try {
      final snap = await _goalsRef.get();
      final raw = snap.value;
      if (raw is! Map) return;

      final goals = Map<dynamic, dynamic>.from(raw);

      for (final entry in goals.entries) {
        final goalId = entry.key.toString();
        final val = entry.value;
        if (val is! Map) continue;

        final goal = Map<String, dynamic>.from(val as Map);
        if (!_needsCycleReset(goal)) continue;

        final cycleType = (goal['cycleType'] ?? '').toString().trim();

        await _goalsRef.child(goalId).update({
          'progressCurrent': 0,
          'lastCompletedDateKey': '',
          'cycleStartKey': _currentCycleStartKey(cycleType),
          'updatedAt': ServerValue.timestamp,
        });
      }
    } catch (_) {
      //
    } finally {
      _normalizing = false;
    }
  }

  Future<void> _saveGoal() async {
    if (_uid.isEmpty) return;

    final skill = _selectedSkill;
    final milestone = _selectedMilestone;

    if (skill == null) {
      _showSnack('Please choose a skill.');
      return;
    }

    if (milestone == null) {
      _showSnack('Please choose a goal.');
      return;
    }

    setState(() => _saving = true);

    try {
      await NotificationService.I.init();
      await NotificationService.I.requestPermissions();

      final goalId = _goalsRef.push().key;
      if (goalId == null || goalId.isEmpty) {
        throw Exception('Could not create goal id.');
      }

      await _goalsRef.child(goalId).set({
        'goalId': goalId,
        'skillKey': skill.key,
        'skillTitle': skill.title,
        'skillEmoji': skill.emoji,
        'milestoneId': milestone.id,
        'milestoneTitle': milestone.title,
        'milestoneSubtitle': milestone.subtitle,
        'progressTarget': milestone.targetValue,
        'progressCurrent': 0,
        'unit': milestone.unit,
        'stepValue': milestone.stepValue,
        'cycleType': milestone.cycleType,
        'cycleStartKey': _currentCycleStartKey(milestone.cycleType),
        'reminderHour': _selectedTime.hour,
        'reminderMinute': _selectedTime.minute,
        'remindersEnabled': true,
        'lastCompletedDateKey': '',
        'createdAt': ServerValue.timestamp,
        'updatedAt': ServerValue.timestamp,
      });

      await NotificationService.I.scheduleCoachReminder(
        goalId: goalId,
        title: '${skill.emoji} ${skill.title} time',
        body: 'Today: ${milestone.buttonLabel}',
        hour: _selectedTime.hour,
        minute: _selectedTime.minute,
      );

      if (!mounted) return;

      setState(() {
        _selectedMilestoneId = null;
      });

      _showSnack('Study goal added.');
    } catch (e) {
      _showSnack('Could not save goal: $e');
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _toggleReminder({
    required String goalId,
    required Map<String, dynamic> goal,
    required bool enabled,
  }) async {
    final hour = _toInt(goal['reminderHour']);
    final minute = _toInt(goal['reminderMinute']);
    final skillTitle = (goal['skillTitle'] ?? 'Study').toString().trim();
    final emoji = (goal['skillEmoji'] ?? '📘').toString().trim();
    final buttonLabel = (goal['milestoneSubtitle'] ?? 'Study session')
        .toString()
        .trim();

    try {
      await _goalsRef.child(goalId).update({
        'remindersEnabled': enabled,
        'updatedAt': ServerValue.timestamp,
      });

      if (enabled) {
        await NotificationService.I.scheduleCoachReminder(
          goalId: goalId,
          title: '$emoji $skillTitle time',
          body: buttonLabel,
          hour: hour,
          minute: minute,
        );
      } else {
        await NotificationService.I.cancelCoachReminder(goalId: goalId);
      }

      _showSnack(enabled ? 'Reminder turned on.' : 'Reminder turned off.');
    } catch (e) {
      _showSnack('Could not update reminder: $e');
    }
  }

  Future<void> _markTodayDone({
    required String goalId,
    required Map<String, dynamic> goal,
  }) async {
    final todayKey = _dateKey(DateTime.now());

    if (_needsCycleReset(goal)) {
      final cycleType = (goal['cycleType'] ?? '').toString().trim();

      await _goalsRef.child(goalId).update({
        'progressCurrent': 0,
        'lastCompletedDateKey': '',
        'cycleStartKey': _currentCycleStartKey(cycleType),
        'updatedAt': ServerValue.timestamp,
      });

      goal['progressCurrent'] = 0;
      goal['lastCompletedDateKey'] = '';
      goal['cycleStartKey'] = _currentCycleStartKey(cycleType);
    }

    final lastDone = (goal['lastCompletedDateKey'] ?? '').toString().trim();
    if (lastDone == todayKey) {
      _showSnack('Today is already completed for this goal.');
      return;
    }

    final current = _toInt(goal['progressCurrent']);
    final target = _toInt(goal['progressTarget']);
    final step = _toInt(goal['stepValue']);

    final updated = math.min(target, current + step);

    try {
      await _goalsRef.child(goalId).update({
        'progressCurrent': updated,
        'lastCompletedDateKey': todayKey,
        'updatedAt': ServerValue.timestamp,
      });

      if (updated >= target) {
        _showSnack('Great job — target reached.');
      } else {
        _showSnack('Nice work — progress updated.');
      }
    } catch (e) {
      _showSnack('Could not update goal: $e');
    }
  }

  Future<void> _deleteGoal({
    required String goalId,
  }) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Delete goal?'),
          content: const Text(
            'This will remove the goal and cancel its reminder.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );

    if (yes != true) return;

    try {
      await NotificationService.I.cancelCoachReminder(goalId: goalId);
      await _goalsRef.child(goalId).remove();
      _showSnack('Goal deleted.');
    } catch (e) {
      _showSnack('Could not delete goal: $e');
    }
  }

  int _toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  String _coachMessage(Map<String, dynamic> goal) {
    final current = _toInt(goal['progressCurrent']);
    final target = _toInt(goal['progressTarget']);
    final step = _toInt(goal['stepValue']);
    final unit = (goal['unit'] ?? 'items').toString().trim();
    final cycleType = (goal['cycleType'] ?? 'weekly').toString().trim();

    final remaining = math.max(0, target - current);

    if (current >= target) {
      return 'Target reached. Excellent work.';
    }

    if (remaining <= step) {
      return 'One more study session will likely finish this goal.';
    }

    return '$remaining $unit left this $cycleType.';
  }

  String _cycleChip(Map<String, dynamic> goal) {
    final cycleType = (goal['cycleType'] ?? 'weekly').toString().trim();
    if (cycleType == 'monthly') return 'Monthly';
    if (cycleType == 'daily') return 'Daily';
    return 'Weekly';
  }

  String _timeLabel(int hour, int minute) {
    final t = TimeOfDay(hour: hour, minute: minute);
    return t.format(context);
  }

  void _showSnack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = palette;

    return Scaffold(
      backgroundColor: p.appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        title: Text(
          'Study Coach',
          style: TextStyle(
            color: p.primary,
            fontWeight: FontWeight.w900,
          ),
        ),
        iconTheme: IconThemeData(color: p.primary),
      ),
      body: WatermarkBackground(
        child: RefreshIndicator(
          onRefresh: _normalizeAllGoalCycles,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              _CoachHeroCard(palette: p),
              const SizedBox(height: 14),
              _buildSetupCard(),
              const SizedBox(height: 16),
              Text(
                'My active goals',
                style: TextStyle(
                  color: p.primary,
                  fontWeight: FontWeight.w900,
                  fontSize: 17,
                ),
              ),
              const SizedBox(height: 10),
              _buildGoalsList(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSetupCard() {
    final p = palette;
    final skill = _selectedSkill;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: p.cardBg,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: p.border.withOpacity(0.85)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 14,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Create a study goal',
            style: TextStyle(
              color: p.primary,
              fontWeight: FontWeight.w900,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Choose a skill, choose a milestone, then set the daily study reminder.',
            style: TextStyle(
              color: p.text.withOpacity(0.70),
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 14),
          DropdownButtonFormField<String>(
            value: _selectedSkillKey,
            decoration: const InputDecoration(
              labelText: 'Skill',
              border: OutlineInputBorder(),
            ),
            items: _skills.map((skill) {
              return DropdownMenuItem<String>(
                value: skill.key,
                child: Text('${skill.emoji} ${skill.title}'),
              );
            }).toList(),
            onChanged: (value) {
              setState(() {
                _selectedSkillKey = value;
                _selectedMilestoneId = null;
              });
            },
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: _selectedMilestoneId,
            decoration: const InputDecoration(
              labelText: 'Goal',
              border: OutlineInputBorder(),
            ),
            items: (skill?.milestones ?? const <_CoachMilestone>[])
                .map((m) => DropdownMenuItem<String>(
              value: m.id,
              child: Text(m.title),
            ))
                .toList(),
            onChanged: skill == null
                ? null
                : (value) {
              setState(() {
                _selectedMilestoneId = value;
              });
            },
          ),
          const SizedBox(height: 12),
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: _pickReminderTime,
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: p.soft,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: p.border.withOpacity(0.85)),
              ),
              child: Row(
                children: [
                  Icon(Icons.schedule_rounded, color: p.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Reminder time: ${_selectedTime.format(context)}',
                      style: TextStyle(
                        color: p.primary,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded, color: p.primary),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _saving ? null : _saveGoal,
              icon: _saving
                  ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
                  : const Icon(Icons.add_task_rounded),
              label: const Text(
                'Add study goal',
                style: TextStyle(fontWeight: FontWeight.w900),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: p.accent,
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 48),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGoalsList() {
    final p = palette;

    if (_uid.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: p.cardBg,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: p.border.withOpacity(0.85)),
        ),
        child: Text(
          'Not logged in.',
          style: TextStyle(
            color: p.text,
            fontWeight: FontWeight.w800,
          ),
        ),
      );
    }

    return StreamBuilder<DatabaseEvent>(
      stream: _goalsRef.onValue,
      builder: (context, snap) {
        final raw = snap.data?.snapshot.value;
        if (raw == null) {
          return _emptyGoalsCard();
        }

        if (raw is! Map) {
          return _emptyGoalsCard();
        }

        final map = Map<dynamic, dynamic>.from(raw);
        if (map.isEmpty) {
          return _emptyGoalsCard();
        }

        final items = map.entries.map((e) {
          final id = e.key.toString();
          final val = e.value is Map
              ? Map<String, dynamic>.from(e.value as Map)
              : <String, dynamic>{};
          return MapEntry(id, val);
        }).toList();

        items.sort((a, b) {
          final aa = _toInt(a.value['updatedAt']);
          final bb = _toInt(b.value['updatedAt']);
          return bb.compareTo(aa);
        });

        return Column(
          children: items.map((entry) {
            final goalId = entry.key;
            final goal = entry.value;

            final target = math.max(1, _toInt(goal['progressTarget']));
            final current = _toInt(goal['progressCurrent']);
            final progress = current / target;
            final remindersEnabled = goal['remindersEnabled'] == true;
            final hour = _toInt(goal['reminderHour']);
            final minute = _toInt(goal['reminderMinute']);
            final todayKey = _dateKey(DateTime.now());
            final alreadyDoneToday =
                (goal['lastCompletedDateKey'] ?? '').toString() == todayKey;

            return Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: p.cardBg,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: p.border.withOpacity(0.85)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.04),
                    blurRadius: 14,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: p.soft,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: p.border.withOpacity(0.85),
                          ),
                        ),
                        child: Center(
                          child: Text(
                            (goal['skillEmoji'] ?? '📘').toString(),
                            style: const TextStyle(fontSize: 24),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              (goal['skillTitle'] ?? 'Skill').toString(),
                              style: TextStyle(
                                color: p.primary,
                                fontWeight: FontWeight.w900,
                                fontSize: 16,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              (goal['milestoneTitle'] ?? 'Goal').toString(),
                              style: TextStyle(
                                color: p.text.withOpacity(0.70),
                                fontWeight: FontWeight.w700,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      PopupMenuButton<String>(
                        onSelected: (value) async {
                          if (value == 'delete') {
                            await _deleteGoal(goalId: goalId);
                          }
                        },
                        itemBuilder: (context) => const [
                          PopupMenuItem<String>(
                            value: 'delete',
                            child: Text('Delete goal'),
                          ),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _GoalChip(
                        label:
                        '$current / $target ${(goal['unit'] ?? '').toString()}',
                      ),
                      _GoalChip(label: _cycleChip(goal)),
                      _GoalChip(label: _timeLabel(hour, minute)),
                    ],
                  ),
                  const SizedBox(height: 14),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      value: progress.clamp(0, 1),
                      minHeight: 10,
                      backgroundColor: p.soft,
                      valueColor: AlwaysStoppedAnimation<Color>(p.accent),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    _coachMessage(goal),
                    style: TextStyle(
                      color: p.text.withOpacity(0.82),
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: alreadyDoneToday
                              ? null
                              : () => _markTodayDone(
                            goalId: goalId,
                            goal: goal,
                          ),
                          icon: Icon(
                            alreadyDoneToday
                                ? Icons.check_circle_rounded
                                : Icons.task_alt_rounded,
                          ),
                          label: Text(
                            alreadyDoneToday
                                ? 'Completed today'
                                : 'Mark today done',
                            style: const TextStyle(fontWeight: FontWeight.w900),
                          ),
                          style: FilledButton.styleFrom(
                            backgroundColor: p.accent,
                            foregroundColor: Colors.white,
                            minimumSize: const Size(0, 46),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Container(
                        decoration: BoxDecoration(
                          color: p.soft,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: p.border.withOpacity(0.85),
                          ),
                        ),
                        child: Row(
                          children: [
                            const SizedBox(width: 10),
                            Text(
                              'Reminder',
                              style: TextStyle(
                                color: p.primary,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            Switch(
                              value: remindersEnabled,
                              onChanged: (value) {
                                _toggleReminder(
                                  goalId: goalId,
                                  goal: goal,
                                  enabled: value,
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          }).toList(),
        );
      },
    );
  }

  Widget _emptyGoalsCard() {
    final p = palette;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: p.cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: p.border.withOpacity(0.85)),
      ),
      child: Column(
        children: [
          Icon(
            Icons.psychology_alt_rounded,
            size: 34,
            color: p.primary,
          ),
          const SizedBox(height: 10),
          Text(
            'No study goals yet',
            style: TextStyle(
              color: p.primary,
              fontWeight: FontWeight.w900,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Create your first coach goal above. Example: Vocabulary → 100 words weekly.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: p.text.withOpacity(0.70),
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class _CoachHeroCard extends StatelessWidget {
  const _CoachHeroCard({required this.palette});

  final _CoachPalette palette;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            palette.primary,
            palette.primary.withOpacity(0.88),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(26),
        boxShadow: [
          BoxShadow(
            color: palette.primary.withOpacity(0.18),
            blurRadius: 18,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Your English coach',
            style: TextStyle(
              color: Colors.white.withOpacity(0.82),
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'Pick a skill, set a milestone, study at your time, and build visible progress.',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              fontSize: 21,
              height: 1.18,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Vocabulary, grammar, speaking, listening, reading, and writing — each with simple coach-style targets.',
            style: TextStyle(
              color: Colors.white.withOpacity(0.86),
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

class _GoalChip extends StatelessWidget {
  const _GoalChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final p = _CoachPalette.fromApp(appThemeController.palette);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: p.soft,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: p.border.withOpacity(0.85)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: p.primary,
          fontWeight: FontWeight.w800,
          fontSize: 12,
        ),
      ),
    );
  }
}

class _CoachPalette {
  const _CoachPalette({
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

  factory _CoachPalette.fromApp(AppPalette p) {
    return _CoachPalette(
      primary: p.primary,
      accent: p.accent,
      text: p.text,
      appBg: p.appBg,
      cardBg: p.cardBg,
      border: p.border,
      soft: p.soft,
    );
  }
}

class _CoachSkill {
  const _CoachSkill({
    required this.key,
    required this.title,
    required this.emoji,
    required this.milestones,
  });

  final String key;
  final String title;
  final String emoji;
  final List<_CoachMilestone> milestones;
}

class _CoachMilestone {
  const _CoachMilestone({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.targetValue,
    required this.stepValue,
    required this.unit,
    required this.cycleType,
    required this.buttonLabel,
  });

  final String id;
  final String title;
  final String subtitle;
  final int targetValue;
  final int stepValue;
  final String unit;
  final String cycleType;
  final String buttonLabel;
}

const List<_CoachSkill> _coachSkills = [
  _CoachSkill(
    key: 'vocabulary',
    title: 'Vocabulary',
    emoji: '📚',
    milestones: [
      _CoachMilestone(
        id: 'vocab_50_week',
        title: '50 words per week',
        subtitle: 'Steady vocabulary building',
        targetValue: 50,
        stepValue: 10,
        unit: 'words',
        cycleType: 'weekly',
        buttonLabel: 'Learn 10 new words',
      ),
      _CoachMilestone(
        id: 'vocab_100_week',
        title: '100 words per week',
        subtitle: 'Faster vocabulary growth',
        targetValue: 100,
        stepValue: 15,
        unit: 'words',
        cycleType: 'weekly',
        buttonLabel: 'Learn 15 new words',
      ),
    ],
  ),
  _CoachSkill(
    key: 'grammar',
    title: 'Grammar',
    emoji: '🧩',
    milestones: [
      _CoachMilestone(
        id: 'grammar_level1_month',
        title: 'Level 1 in one month',
        subtitle: '8 grammar lessons this month',
        targetValue: 8,
        stepValue: 1,
        unit: 'lessons',
        cycleType: 'monthly',
        buttonLabel: 'Complete 1 grammar lesson',
      ),
      _CoachMilestone(
        id: 'grammar_level2_month',
        title: 'Level 2 in one month',
        subtitle: '12 grammar lessons this month',
        targetValue: 12,
        stepValue: 1,
        unit: 'lessons',
        cycleType: 'monthly',
        buttonLabel: 'Complete 1 grammar lesson',
      ),
    ],
  ),
  _CoachSkill(
    key: 'speaking',
    title: 'Speaking',
    emoji: '🗣️',
    milestones: [
      _CoachMilestone(
        id: 'speaking_3_week',
        title: '3 speaking sessions per week',
        subtitle: 'Short but regular speaking practice',
        targetValue: 3,
        stepValue: 1,
        unit: 'sessions',
        cycleType: 'weekly',
        buttonLabel: 'Record 1 speaking session',
      ),
      _CoachMilestone(
        id: 'speaking_5_week',
        title: '5 speaking sessions per week',
        subtitle: 'Strong speaking consistency',
        targetValue: 5,
        stepValue: 1,
        unit: 'sessions',
        cycleType: 'weekly',
        buttonLabel: 'Record 1 speaking session',
      ),
    ],
  ),
  _CoachSkill(
    key: 'listening',
    title: 'Listening',
    emoji: '🎧',
    milestones: [
      _CoachMilestone(
        id: 'listening_60_week',
        title: '60 listening minutes per week',
        subtitle: '10 minutes daily style',
        targetValue: 60,
        stepValue: 10,
        unit: 'minutes',
        cycleType: 'weekly',
        buttonLabel: 'Listen for 10 minutes',
      ),
      _CoachMilestone(
        id: 'listening_120_week',
        title: '120 listening minutes per week',
        subtitle: 'Stronger listening routine',
        targetValue: 120,
        stepValue: 20,
        unit: 'minutes',
        cycleType: 'weekly',
        buttonLabel: 'Listen for 20 minutes',
      ),
    ],
  ),
  _CoachSkill(
    key: 'reading',
    title: 'Reading',
    emoji: '📖',
    milestones: [
      _CoachMilestone(
        id: 'reading_3_week',
        title: '3 reading texts per week',
        subtitle: 'Short texts and articles',
        targetValue: 3,
        stepValue: 1,
        unit: 'texts',
        cycleType: 'weekly',
        buttonLabel: 'Read 1 text',
      ),
      _CoachMilestone(
        id: 'reading_5_week',
        title: '5 reading texts per week',
        subtitle: 'Daily reading habit',
        targetValue: 5,
        stepValue: 1,
        unit: 'texts',
        cycleType: 'weekly',
        buttonLabel: 'Read 1 text',
      ),
    ],
  ),
  _CoachSkill(
    key: 'writing',
    title: 'Writing',
    emoji: '✍️',
    milestones: [
      _CoachMilestone(
        id: 'writing_3_week',
        title: '3 writing tasks per week',
        subtitle: 'Simple writing consistency',
        targetValue: 3,
        stepValue: 1,
        unit: 'tasks',
        cycleType: 'weekly',
        buttonLabel: 'Write 1 short task',
      ),
      _CoachMilestone(
        id: 'writing_5_week',
        title: '5 writing tasks per week',
        subtitle: 'Daily writing habit',
        targetValue: 5,
        stepValue: 1,
        unit: 'tasks',
        cycleType: 'weekly',
        buttonLabel: 'Write 1 short task',
      ),
    ],
  ),
];