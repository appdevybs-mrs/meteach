import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../shared/app_theme.dart';
import '../shared/learner_web_layout.dart';
import '../shared/watermark_background.dart';
import '../shared/app_feedback.dart';

class LearnerStudyCoachScreen extends StatefulWidget {
  const LearnerStudyCoachScreen({super.key});

  @override
  State<LearnerStudyCoachScreen> createState() =>
      _LearnerStudyCoachScreenState();
}

class _LearnerStudyCoachScreenState extends State<LearnerStudyCoachScreen> {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();

  bool _normalizing = false;
  bool _updatingTask = false;

  _CoachLang _lang = _CoachLang.en;
  String? _expandedDayKey;

  _CoachPalette get palette =>
      _CoachPalette.fromApp(appThemeController.palette);

  String get _uid => FirebaseAuth.instance.currentUser?.uid ?? '';

  DatabaseReference get _planRef =>
      _db.child('users/$_uid/study_plan/current_week');

  bool get _isArabic => _lang == _CoachLang.ar;

  @override
  void initState() {
    super.initState();
    appThemeController.addListener(_themeRefresh);
    _expandedDayKey = _todayDay.key;
    unawaited(_normalizeCurrentWeekPlan());
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

  String _tr(String en, String ar) => _isArabic ? ar : en;

  String _two(int n) => n.toString().padLeft(2, '0');

  String _dateKey(DateTime d) {
    return '${d.year}-${_two(d.month)}-${_two(d.day)}';
  }

  String _weekStartKey(DateTime now) {
    final day = DateTime(now.year, now.month, now.day);
    final mondayStart = day.subtract(Duration(days: day.weekday - 1));
    return _dateKey(mondayStart);
  }

  String _currentWeekKey() {
    return _weekStartKey(DateTime.now());
  }

  Map<String, bool> _emptyCheckedMap() {
    return {for (final task in _allTasks) task.id: false};
  }

  int _quoteIndexForWeek(String weekKey) {
    final hash = weekKey.codeUnits.fold<int>(0, (a, b) => a + b);
    return hash % _quotes.length;
  }

  Future<void> _normalizeCurrentWeekPlan() async {
    if (_uid.isEmpty || _normalizing) return;

    _normalizing = true;
    try {
      final snap = await _planRef.get();
      final raw = snap.value;
      final currentWeekKey = _currentWeekKey();

      if (raw == null || raw is! Map) {
        await _planRef.set({
          'weekStartKey': currentWeekKey,
          'quoteIndex': _quoteIndexForWeek(currentWeekKey),
          'checked': _emptyCheckedMap(),
          'updatedAt': ServerValue.timestamp,
        });
        return;
      }

      final map = Map<dynamic, dynamic>.from(raw);
      final storedWeekKey = (map['weekStartKey'] ?? '').toString().trim();

      if (storedWeekKey != currentWeekKey) {
        await _planRef.set({
          'weekStartKey': currentWeekKey,
          'quoteIndex': _quoteIndexForWeek(currentWeekKey),
          'checked': _emptyCheckedMap(),
          'updatedAt': ServerValue.timestamp,
        });
        return;
      }

      final rawChecked = map['checked'];
      final checked = <String, bool>{};

      if (rawChecked is Map) {
        final checkedMap = Map<dynamic, dynamic>.from(rawChecked);
        for (final task in _allTasks) {
          checked[task.id] = checkedMap[task.id] == true;
        }
      } else {
        for (final task in _allTasks) {
          checked[task.id] = false;
        }
      }

      await _planRef.update({
        'weekStartKey': currentWeekKey,
        'quoteIndex': _quoteIndexForWeek(currentWeekKey),
        'checked': checked,
        'updatedAt': ServerValue.timestamp,
      });
    } catch (_) {
      //
    } finally {
      _normalizing = false;
    }
  }

  Future<void> _toggleTask(String taskId, bool currentValue) async {
    if (_uid.isEmpty || _updatingTask) return;

    setState(() => _updatingTask = true);
    try {
      await _planRef.child('checked/$taskId').set(!currentValue);
      await _planRef.update({
        'weekStartKey': _currentWeekKey(),
        'quoteIndex': _quoteIndexForWeek(_currentWeekKey()),
        'updatedAt': ServerValue.timestamp,
      });
    } catch (e) {
      _showSnack(_tr('Could not update task: $e', 'تعذر تحديث المهمة: $e'));
    } finally {
      if (mounted) {
        setState(() => _updatingTask = false);
      }
    }
  }

  Future<void> _resetWeek() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) {
        return Directionality(
          textDirection: _isArabic ? TextDirection.rtl : TextDirection.ltr,
          child: AlertDialog(
            title: Text(_tr('Reset this week?', 'إعادة تعيين هذا الأسبوع؟')),
            content: Text(
              _tr(
                'This will clear all completed tasks for the current week.',
                'سيؤدي هذا إلى مسح كل المهام المكتملة لهذا الأسبوع الحالي.',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(_tr('Cancel', 'إلغاء')),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(_tr('Reset', 'إعادة تعيين')),
              ),
            ],
          ),
        );
      },
    );

    if (yes != true) return;

    try {
      await _planRef.set({
        'weekStartKey': _currentWeekKey(),
        'quoteIndex': _quoteIndexForWeek(_currentWeekKey()),
        'checked': _emptyCheckedMap(),
        'updatedAt': ServerValue.timestamp,
      });

      _showSnack(_tr('This week was reset.', 'تمت إعادة تعيين هذا الأسبوع.'));
    } catch (e) {
      _showSnack(
        _tr('Could not reset week: $e', 'تعذر إعادة تعيين الأسبوع: $e'),
      );
    }
  }

  void _showHowToUse() {
    showDialog<void>(
      context: context,
      builder: (context) {
        return Directionality(
          textDirection: _isArabic ? TextDirection.rtl : TextDirection.ltr,
          child: AlertDialog(
            title: Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: const Color(0xFF6C63FF).withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: const Text(
                    '!',
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF6C63FF),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _tr('How to use Study Coach', 'طريقة استخدام مدرب الدراسة'),
                  ),
                ),
              ],
            ),
            content: SingleChildScrollView(
              child: Text(
                _tr(
                  '1) This screen is a weekly guided study plan.\n\n'
                      '2) Each day has one small English task set.\n\n'
                      '3) Tap any day card to open its tasks.\n\n'
                      '4) Tap a task to mark it complete.\n\n'
                      '5) Your weekly progress bar updates automatically.\n\n'
                      '6) The plan resets automatically when a new week starts.\n\n'
                      '7) Use the language switch at the top to change between English and Arabic.\n\n'
                      '8) You do not need to do everything at once. Only open one day, follow the steps, and finish that day.\n\n'
                      'Best way to use it:\n'
                      '• Open today’s card\n'
                      '• Read the task steps\n'
                      '• Do them in order\n'
                      '• Mark each task complete\n'
                      '• Come back tomorrow for the next day\n\n'
                      'This screen is designed to be clear, guided, and simple — not a goal tracker and not a complex dashboard.',
                  '1) هذه الشاشة هي خطة دراسة أسبوعية موجهة.\n\n'
                      '2) كل يوم يحتوي على مجموعة صغيرة وواضحة من مهام تعلم الإنجليزية.\n\n'
                      '3) اضغط على بطاقة أي يوم لفتح مهامه.\n\n'
                      '4) اضغط على المهمة عند الانتهاء منها لوضع علامة الإكمال.\n\n'
                      '5) شريط التقدم الأسبوعي يتحدث تلقائياً.\n\n'
                      '6) يتم إعادة تعيين الخطة تلقائياً عند بداية أسبوع جديد.\n\n'
                      '7) استخدم زر اللغة في الأعلى للتبديل بين العربية والإنجليزية.\n\n'
                      '8) لا تحتاج إلى تنفيذ كل شيء دفعة واحدة. افتح يوماً واحداً فقط، اتبع الخطوات، وأنهِ ذلك اليوم.\n\n'
                      'أفضل طريقة للاستخدام:\n'
                      '• افتح بطاقة اليوم الحالي\n'
                      '• اقرأ خطوات المهام\n'
                      '• نفذها بالترتيب\n'
                      '• علّم كل مهمة بعد إكمالها\n'
                      '• ارجع غداً لليوم التالي\n\n'
                      'هذه الشاشة مصممة لتكون واضحة وموجهة وبسيطة — وليست متتبّع أهداف معقداً ولا لوحة مزدحمة.',
                ),
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  height: 1.55,
                ),
              ),
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(_tr('Got it', 'فهمت')),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showSnack(String text) {
    if (!mounted) return;
    AppToast.fromSnackBar(context, SnackBar(content: Text(text)));
  }

  Map<String, bool> _extractCheckedMap(dynamic raw) {
    final checked = _emptyCheckedMap();

    if (raw is! Map) return checked;

    final map = Map<dynamic, dynamic>.from(raw);
    final rawChecked = map['checked'];

    if (rawChecked is! Map) return checked;

    final checkedMap = Map<dynamic, dynamic>.from(rawChecked);
    for (final task in _allTasks) {
      checked[task.id] = checkedMap[task.id] == true;
    }

    return checked;
  }

  int _extractQuoteIndex(dynamic raw) {
    if (raw is Map) {
      final map = Map<dynamic, dynamic>.from(raw);
      final v = map['quoteIndex'];
      final parsed = int.tryParse(v?.toString() ?? '');
      if (parsed != null && parsed >= 0 && parsed < _quotes.length) {
        return parsed;
      }
    }
    return _quoteIndexForWeek(_currentWeekKey());
  }

  _PlanDay get _todayDay {
    final weekday = DateTime.now().weekday;
    return _weekPlanDays[weekday - 1];
  }

  int _doneCountForDay(_PlanDay day, Map<String, bool> checked) {
    return day.tasks.where((t) => checked[t.id] == true).length;
  }

  int _daysStartedCount(Map<String, bool> checked) {
    return _weekPlanDays.where((day) {
      return day.tasks.any((t) => checked[t.id] == true);
    }).length;
  }

  @override
  Widget build(BuildContext context) {

    final p = palette;

    return Directionality(
      textDirection: _isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        backgroundColor: p.appBg,
        appBar: AppBar(
          backgroundColor: Colors.white,
          elevation: 0,
          surfaceTintColor: Colors.white,
          title: Text(
            _tr('Study Coach', 'مدرب الدراسة'),
            style: TextStyle(color: p.primary, fontWeight: FontWeight.w900),
          ),
          iconTheme: IconThemeData(color: p.primary),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: IconButton(
                onPressed: _showHowToUse,
                tooltip: _tr('How to use', 'طريقة الاستخدام'),
                icon: Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: const Color(0xFF6C63FF).withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: const Text(
                    '!',
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF6C63FF),
                      fontSize: 16,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        body: learnerWebBodyFrame(
          context: context,
          maxWidth: 1260,
          child: WatermarkBackground(
            child: RefreshIndicator(
              onRefresh: _normalizeCurrentWeekPlan,
              child: StreamBuilder<DatabaseEvent>(
                stream: _planRef.onValue,
                builder: (context, snap) {
                  final raw = snap.data?.snapshot.value;
                  final checked = _extractCheckedMap(raw);

                  final total = _allTasks.length;
                  final done = checked.values.where((v) => v).length;
                  final progress = total == 0 ? 0.0 : done / total;
                  final percent = (progress * 100).round();
                  final daysStarted = _daysStartedCount(checked);

                  final quote = _quotes[_extractQuoteIndex(raw)].text(_lang);
                  final today = _todayDay;
                  final todayDone = _doneCountForDay(today, checked);

                  return ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
                    children: [
                      _HeroCard(
                        lang: _lang,
                        onChangeLang: (lang) {
                          setState(() {
                            _lang = lang;
                          });
                        },
                        progress: progress,
                        done: done,
                        total: total,
                        title: _tr(
                          'My English Learning Plan',
                          'خطة تعلم الإنجليزية',
                        ),
                        subtitle: _tr(
                          'One clear weekly plan · one tracking method · simple daily steps',
                          'خطة أسبوعية واضحة · طريقة تتبع واحدة · خطوات يومية بسيطة',
                        ),
                      ),
                      const SizedBox(height: 16),
                      _QuoteBanner(quote: quote),
                      const SizedBox(height: 16),
                      _TodayFocusCard(
                        day: today,
                        lang: _lang,
                        doneCount: todayDone,
                        totalCount: today.tasks.length,
                        onOpen: () {
                          setState(() {
                            _expandedDayKey = today.key;
                          });
                        },
                      ),
                      const SizedBox(height: 16),
                      _StatsRow(
                        lang: _lang,
                        done: done,
                        daysStarted: daysStarted,
                        percent: percent,
                      ),
                      const SizedBox(height: 18),
                      Text(
                        _tr('Weekly study days', 'أيام الدراسة الأسبوعية'),
                        style: TextStyle(
                          color: p.primary,
                          fontWeight: FontWeight.w900,
                          fontSize: 18,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _tr(
                          'Tap one day only, follow its steps, then mark tasks done.',
                          'افتح يوماً واحداً فقط، اتبع خطواته، ثم علّم المهام كمكتملة.',
                        ),
                        style: TextStyle(
                          color: p.text.withValues(alpha: 0.70),
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                      const SizedBox(height: 14),
                      ..._weekPlanDays.map((day) {
                        final doneCount = _doneCountForDay(day, checked);
                        final expanded = _expandedDayKey == day.key;

                        return _DayCard(
                          day: day,
                          lang: _lang,
                          checked: checked,
                          doneCount: doneCount,
                          expanded: expanded,
                          isToday: day.key == today.key,
                          onHeaderTap: () {
                            setState(() {
                              _expandedDayKey = expanded ? null : day.key;
                            });
                          },
                          onToggleTask: (taskId, currentValue) {
                            _toggleTask(taskId, currentValue);
                          },
                        );
                      }),
                      const SizedBox(height: 16),
                      _ResetCard(
                        lang: _lang,
                        done: done,
                        total: total,
                        onReset: _resetWeek,
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HeroCard extends StatelessWidget {
  const _HeroCard({
    required this.lang,
    required this.onChangeLang,
    required this.progress,
    required this.done,
    required this.total,
    required this.title,
    required this.subtitle,
  });

  final _CoachLang lang;
  final ValueChanged<_CoachLang> onChangeLang;
  final double progress;
  final int done;
  final int total;
  final String title;
  final String subtitle;

  bool get _isArabic => lang == _CoachLang.ar;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF6C63FF), Color(0xFF5B8DEF)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF6C63FF).withValues(alpha: 0.28),
            blurRadius: 22,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Stack(
        children: [
          Positioned(
            top: -28,
            right: _isArabic ? null : -20,
            left: _isArabic ? -20 : null,
            child: Container(
              width: 130,
              height: 130,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.08),
                shape: BoxShape.circle,
              ),
            ),
          ),
          Positioned(
            bottom: -34,
            left: _isArabic ? null : -16,
            right: _isArabic ? -16 : null,
            child: Container(
              width: 110,
              height: 110,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.06),
                shape: BoxShape.circle,
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text('🎓', style: TextStyle(fontSize: 34)),
                  const Spacer(),
                  _LangSwitch(selected: lang, onChanged: onChangeLang),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: 26,
                  height: 1.1,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                subtitle,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.92),
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.20),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Container(
                  height: 18,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: progress.clamp(0, 1),
                      child: Container(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            colors: [Color(0xFFFFD700), Color(0xFFFF9F43)],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _isArabic
                    ? '$done من $total مهام مكتملة — ${((progress * 100).round())}%'
                    : '$done / $total tasks completed — ${((progress * 100).round())}%',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.96),
                  fontWeight: FontWeight.w900,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LangSwitch extends StatelessWidget {
  const _LangSwitch({required this.selected, required this.onChanged});

  final _CoachLang selected;
  final ValueChanged<_CoachLang> onChanged;

  @override
  Widget build(BuildContext context) {
    Widget chip({
      required String label,
      required bool active,
      required VoidCallback onTap,
    }) {
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: active ? Colors.white : Colors.white.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: Colors.white.withValues(alpha: active ? 0 : 0.25),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: active ? const Color(0xFF5B57F4) : Colors.white,
              fontWeight: FontWeight.w900,
              fontSize: 12,
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        chip(
          label: 'EN',
          active: selected == _CoachLang.en,
          onTap: () => onChanged(_CoachLang.en),
        ),
        const SizedBox(width: 8),
        chip(
          label: 'AR',
          active: selected == _CoachLang.ar,
          onTap: () => onChanged(_CoachLang.ar),
        ),
      ],
    );
  }
}

class _QuoteBanner extends StatelessWidget {
  const _QuoteBanner({required this.quote});

  final String quote;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: const Border(
          left: BorderSide(color: Color(0xFF6C63FF), width: 5),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Text(
        quote,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Color(0xFF6C63FF),
          fontWeight: FontWeight.w800,
          fontSize: 14,
          height: 1.4,
        ),
      ),
    );
  }
}

class _TodayFocusCard extends StatelessWidget {
  const _TodayFocusCard({
    required this.day,
    required this.lang,
    required this.doneCount,
    required this.totalCount,
    required this.onOpen,
  });

  final _PlanDay day;
  final _CoachLang lang;
  final int doneCount;
  final int totalCount;
  final VoidCallback onOpen;

  bool get _isArabic => lang == _CoachLang.ar;

  String _tr(String en, String ar) => _isArabic ? ar : en;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              color: day.lightColor,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Text(day.emoji, style: const TextStyle(fontSize: 28)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _tr('Today focus', 'تركيز اليوم'),
                  style: const TextStyle(
                    color: Color(0xFF6C63FF),
                    fontWeight: FontWeight.w900,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${day.dayName(lang)} · ${day.title(lang)}',
                  style: const TextStyle(
                    color: Color(0xFF2F3152),
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _isArabic
                      ? '$doneCount من $totalCount مهام مكتملة'
                      : '$doneCount / $totalCount tasks completed',
                  style: TextStyle(
                    color: const Color(0xFF2F3152).withValues(alpha: 0.70),
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          FilledButton(
            onPressed: onOpen,
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF6C63FF),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            child: Text(_tr('Open', 'افتح')),
          ),
        ],
      ),
    );
  }
}

class _StatsRow extends StatelessWidget {
  const _StatsRow({
    required this.lang,
    required this.done,
    required this.daysStarted,
    required this.percent,
  });

  final _CoachLang lang;
  final int done;
  final int daysStarted;
  final int percent;

  bool get _isArabic => lang == _CoachLang.ar;

  String _tr(String en, String ar) => _isArabic ? ar : en;

  @override
  Widget build(BuildContext context) {
    Widget card({
      required String number,
      required String label,
      required Color color,
    }) {
      return Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 16,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            children: [
              Text(
                number,
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w900,
                  fontSize: 26,
                  height: 1,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                label,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Color(0xFF888AAA),
                  fontWeight: FontWeight.w800,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Row(
      children: [
        card(
          number: '$done',
          label: _tr('Tasks Done', 'المهام المكتملة'),
          color: const Color(0xFF6C63FF),
        ),
        const SizedBox(width: 10),
        card(
          number: '$daysStarted',
          label: _tr('Days Started', 'الأيام التي بدأت'),
          color: const Color(0xFFFF9F43),
        ),
        const SizedBox(width: 10),
        card(
          number: '$percent%',
          label: _tr('This Week', 'هذا الأسبوع'),
          color: const Color(0xFF43B89C),
        ),
      ],
    );
  }
}

class _DayCard extends StatelessWidget {
  const _DayCard({
    required this.day,
    required this.lang,
    required this.checked,
    required this.doneCount,
    required this.expanded,
    required this.isToday,
    required this.onHeaderTap,
    required this.onToggleTask,
  });

  final _PlanDay day;
  final _CoachLang lang;
  final Map<String, bool> checked;
  final int doneCount;
  final bool expanded;
  final bool isToday;
  final VoidCallback onHeaderTap;
  final void Function(String taskId, bool currentValue) onToggleTask;

  bool get _isArabic => lang == _CoachLang.ar;

  String _tr(String en, String ar) => _isArabic ? ar : en;

  @override
  Widget build(BuildContext context) {
    final allDone = doneCount == day.tasks.length;

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: isToday
              ? day.color.withValues(alpha: 0.28)
              : const Color(0xFFF0F1F8),
          width: isToday ? 1.4 : 1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        children: [
          InkWell(
            onTap: onHeaderTap,
            borderRadius: BorderRadius.circular(22),
            child: Container(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
              decoration: BoxDecoration(
                color: day.lightColor,
                borderRadius: BorderRadius.circular(22),
              ),
              child: Row(
                children: [
                  Container(
                    width: 54,
                    height: 54,
                    decoration: BoxDecoration(
                      color: day.color.withValues(alpha: 0.13),
                      shape: BoxShape.circle,
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      day.emoji,
                      style: const TextStyle(fontSize: 27),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              day.dayName(lang),
                              style: TextStyle(
                                color: day.color,
                                fontWeight: FontWeight.w900,
                                fontSize: 18,
                              ),
                            ),
                            if (isToday)
                              _MiniTag(
                                text: _tr('Today', 'اليوم'),
                                background: day.color.withValues(alpha: 0.16),
                                color: day.color,
                              ),
                            if (allDone)
                              _MiniTag(
                                text: _tr('Done', 'مكتمل'),
                                background: const Color(
                                  0xFF43B89C,
                                ).withValues(alpha: 0.16),
                                color: const Color(0xFF43B89C),
                              ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(
                          day.title(lang),
                          style: TextStyle(
                            color: const Color(
                              0xFF555777,
                            ).withValues(alpha: 0.80),
                            fontWeight: FontWeight.w800,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            _MiniTag(
                              text: day.skill(lang),
                              background: day.color.withValues(alpha: 0.14),
                              color: day.color,
                            ),
                            _MiniTag(
                              text: day.duration(lang),
                              background: const Color(0xFFF1F2FA),
                              color: const Color(0xFF888AAA),
                            ),
                            _MiniTag(
                              text: '$doneCount/${day.tasks.length}',
                              background: const Color(0xFFF1F2FA),
                              color: const Color(0xFF888AAA),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    color: day.color,
                    size: 28,
                  ),
                ],
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                children: [
                  ...day.tasks.map((task) {
                    final done = checked[task.id] == true;

                    return InkWell(
                      onTap: () => onToggleTask(task.id, done),
                      borderRadius: BorderRadius.circular(12),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 7),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 24,
                              height: 24,
                              margin: const EdgeInsets.only(top: 1),
                              decoration: BoxDecoration(
                                color: done ? day.color : Colors.white,
                                borderRadius: BorderRadius.circular(7),
                                border: Border.all(
                                  color: done
                                      ? day.color
                                      : const Color(0xFFD2D5E8),
                                  width: 2.3,
                                ),
                              ),
                              child: done
                                  ? const Center(
                                      child: Icon(
                                        Icons.check,
                                        size: 14,
                                        color: Colors.white,
                                      ),
                                    )
                                  : null,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Container(
                                padding: const EdgeInsets.only(bottom: 10),
                                decoration: const BoxDecoration(
                                  border: Border(
                                    bottom: BorderSide(
                                      color: Color(0xFFF0F0F8),
                                    ),
                                  ),
                                ),
                                child: Text(
                                  task.text(lang),
                                  style: TextStyle(
                                    color: const Color(
                                      0xFF35375A,
                                    ).withValues(alpha: done ? 0.45 : 1),
                                    fontWeight: FontWeight.w700,
                                    fontSize: 14,
                                    height: 1.45,
                                    decoration: done
                                        ? TextDecoration.lineThrough
                                        : null,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: day.lightColor,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Text(
                      day.tip(lang),
                      style: TextStyle(
                        color: day.color,
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                        height: 1.45,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      const Text('🔗', style: TextStyle(fontSize: 14)),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          day.resource(lang),
                          style: const TextStyle(
                            color: Color(0xFF888AAA),
                            fontWeight: FontWeight.w800,
                            fontSize: 12,
                            height: 1.35,
                          ),
                        ),
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
}

class _MiniTag extends StatelessWidget {
  const _MiniTag({
    required this.text,
    required this.background,
    required this.color,
  });

  final String text;
  final Color background;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w800,
          fontSize: 11,
        ),
      ),
    );
  }
}

class _ResetCard extends StatelessWidget {
  const _ResetCard({
    required this.lang,
    required this.done,
    required this.total,
    required this.onReset,
  });

  final _CoachLang lang;
  final int done;
  final int total;
  final VoidCallback onReset;

  bool get _isArabic => lang == _CoachLang.ar;

  String _tr(String en, String ar) => _isArabic ? ar : en;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        children: [
          Text(
            _isArabic
                ? 'التقدم الأسبوعي: $done من $total'
                : 'Weekly progress: $done / $total',
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Color(0xFF6C63FF),
              fontWeight: FontWeight.w900,
              fontSize: 15,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: onReset,
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF6C63FF),
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 48),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              child: Text(
                _tr('Reset This Week', 'إعادة تعيين هذا الأسبوع'),
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
          ),
        ],
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

enum _CoachLang { en, ar }

class _LocalizedText {
  const _LocalizedText({required this.en, required this.ar});

  final String en;
  final String ar;

  String text(_CoachLang lang) {
    return lang == _CoachLang.ar ? ar : en;
  }
}

class _PlanTask {
  const _PlanTask({required this.id, required this.textData});

  final String id;
  final _LocalizedText textData;

  String text(_CoachLang lang) => textData.text(lang);
}

class _PlanDay {
  const _PlanDay({
    required this.key,
    required this.nameData,
    required this.titleData,
    required this.skillData,
    required this.durationData,
    required this.tipData,
    required this.resourceData,
    required this.emoji,
    required this.color,
    required this.lightColor,
    required this.tasks,
  });

  final String key;
  final _LocalizedText nameData;
  final _LocalizedText titleData;
  final _LocalizedText skillData;
  final _LocalizedText durationData;
  final _LocalizedText tipData;
  final _LocalizedText resourceData;
  final String emoji;
  final Color color;
  final Color lightColor;
  final List<_PlanTask> tasks;

  String dayName(_CoachLang lang) => nameData.text(lang);
  String title(_CoachLang lang) => titleData.text(lang);
  String skill(_CoachLang lang) => skillData.text(lang);
  String duration(_CoachLang lang) => durationData.text(lang);
  String tip(_CoachLang lang) => tipData.text(lang);
  String resource(_CoachLang lang) => resourceData.text(lang);
}

const List<_LocalizedText> _quotes = [
  _LocalizedText(
    en: 'Every expert was once a beginner. Keep going! 🌟',
    ar: 'كل خبير كان في يوم من الأيام مبتدئاً. استمر! 🌟',
  ),
  _LocalizedText(
    en: 'Small steps every day create big progress. 🚀',
    ar: 'الخطوات الصغيرة كل يوم تصنع تقدماً كبيراً. 🚀',
  ),
  _LocalizedText(
    en: 'Consistency is stronger than motivation. ✨',
    ar: 'الاستمرارية أقوى من الحماس المؤقت. ✨',
  ),
  _LocalizedText(
    en: 'Learning English opens real-life opportunities. 🚪',
    ar: 'تعلم الإنجليزية يفتح فرصاً حقيقية في الحياة. 🚪',
  ),
  _LocalizedText(
    en: 'You do not need perfection. You only need progress. 💪',
    ar: 'أنت لا تحتاج إلى الكمال، أنت تحتاج فقط إلى التقدم. 💪',
  ),
];

const List<_PlanDay> _weekPlanDays = [
  _PlanDay(
    key: 'monday',
    nameData: _LocalizedText(en: 'Monday', ar: 'الاثنين'),
    titleData: _LocalizedText(en: 'Grammar Focus', ar: 'تركيز القواعد'),
    skillData: _LocalizedText(en: 'Grammar', ar: 'القواعد'),
    durationData: _LocalizedText(en: '25 min', ar: '25 دقيقة'),
    tipData: _LocalizedText(
      en: '💡 Keep it simple. Learn one rule well before moving to another one.',
      ar: '💡 اجعل الأمر بسيطاً. تعلّم قاعدة واحدة جيداً قبل الانتقال إلى قاعدة أخرى.',
    ),
    resourceData: _LocalizedText(
      en: 'Use a grammar book, teacher notes, or a trusted grammar app.',
      ar: 'استخدم كتاب قواعد أو ملاحظات المعلم أو تطبيق قواعد موثوق.',
    ),
    emoji: '📘',
    color: Color(0xFF6C63FF),
    lightColor: Color(0xFFEEF0FF),
    tasks: [
      _PlanTask(
        id: 'mon1',
        textData: _LocalizedText(
          en: 'Study one grammar rule only.',
          ar: 'ادرس قاعدة نحوية واحدة فقط.',
        ),
      ),
      _PlanTask(
        id: 'mon2',
        textData: _LocalizedText(
          en: 'Read 3 example sentences carefully.',
          ar: 'اقرأ 3 جمل مثال بعناية.',
        ),
      ),
      _PlanTask(
        id: 'mon3',
        textData: _LocalizedText(
          en: 'Write 5 simple sentences using that rule.',
          ar: 'اكتب 5 جمل بسيطة باستخدام هذه القاعدة.',
        ),
      ),
    ],
  ),
  _PlanDay(
    key: 'tuesday',
    nameData: _LocalizedText(en: 'Tuesday', ar: 'الثلاثاء'),
    titleData: _LocalizedText(en: 'Speaking Practice', ar: 'تدريب التحدث'),
    skillData: _LocalizedText(en: 'Speaking', ar: 'التحدث'),
    durationData: _LocalizedText(en: '20 min', ar: '20 دقيقة'),
    tipData: _LocalizedText(
      en: '💡 Speak slowly. Clear speech is better than fast speech.',
      ar: '💡 تحدث ببطء. الكلام الواضح أفضل من الكلام السريع.',
    ),
    resourceData: _LocalizedText(
      en: 'Use your phone voice recorder.',
      ar: 'استخدم مسجل الصوت في هاتفك.',
    ),
    emoji: '🗣️',
    color: Color(0xFF43B89C),
    lightColor: Color(0xFFEDFAF5),
    tasks: [
      _PlanTask(
        id: 'tue1',
        textData: _LocalizedText(
          en: 'Choose one topic: My day, my work, or my family.',
          ar: 'اختر موضوعاً واحداً: يومي أو عملي أو عائلتي.',
        ),
      ),
      _PlanTask(
        id: 'tue2',
        textData: _LocalizedText(
          en: 'Speak for 1 to 2 minutes and record yourself.',
          ar: 'تحدث لمدة دقيقة إلى دقيقتين وسجل صوتك.',
        ),
      ),
      _PlanTask(
        id: 'tue3',
        textData: _LocalizedText(
          en: 'Listen once and repeat better one more time.',
          ar: 'استمع مرة واحدة ثم أعد التحدث بشكل أفضل مرة أخرى.',
        ),
      ),
    ],
  ),
  _PlanDay(
    key: 'wednesday',
    nameData: _LocalizedText(en: 'Wednesday', ar: 'الأربعاء'),
    titleData: _LocalizedText(en: 'Listening Day', ar: 'يوم الاستماع'),
    skillData: _LocalizedText(en: 'Listening', ar: 'الاستماع'),
    durationData: _LocalizedText(en: '20 min', ar: '20 دقيقة'),
    tipData: _LocalizedText(
      en: '💡 If you miss words, listen again. Repetition is part of learning.',
      ar: '💡 إذا فاتتك كلمات، استمع مرة أخرى. التكرار جزء من التعلم.',
    ),
    resourceData: _LocalizedText(
      en: 'Use BBC Learning English or any short clear English audio.',
      ar: 'استخدم BBC Learning English أو أي مقطع إنجليزي قصير وواضح.',
    ),
    emoji: '🎧',
    color: Color(0xFFFF9F43),
    lightColor: Color(0xFFFFF4E9),
    tasks: [
      _PlanTask(
        id: 'wed1',
        textData: _LocalizedText(
          en: 'Listen to one short English audio or video.',
          ar: 'استمع إلى مقطع صوتي أو فيديو إنجليزي قصير.',
        ),
      ),
      _PlanTask(
        id: 'wed2',
        textData: _LocalizedText(
          en: 'Write 3 words or phrases you heard.',
          ar: 'اكتب 3 كلمات أو عبارات سمعتها.',
        ),
      ),
      _PlanTask(
        id: 'wed3',
        textData: _LocalizedText(
          en: 'Listen one more time to confirm them.',
          ar: 'استمع مرة أخرى للتأكد منها.',
        ),
      ),
    ],
  ),
  _PlanDay(
    key: 'thursday',
    nameData: _LocalizedText(en: 'Thursday', ar: 'الخميس'),
    titleData: _LocalizedText(en: 'Writing Day', ar: 'يوم الكتابة'),
    skillData: _LocalizedText(en: 'Writing', ar: 'الكتابة'),
    durationData: _LocalizedText(en: '25 min', ar: '25 دقيقة'),
    tipData: _LocalizedText(
      en: '💡 Simple correct sentences are excellent practice.',
      ar: '💡 الجمل البسيطة والصحيحة تعتبر تدريباً ممتازاً.',
    ),
    resourceData: _LocalizedText(
      en: 'Use a notebook, notes app, or document file.',
      ar: 'استخدم دفتراً أو تطبيق ملاحظات أو ملفاً كتابياً.',
    ),
    emoji: '✍️',
    color: Color(0xFF5B8DEF),
    lightColor: Color(0xFFEEF4FF),
    tasks: [
      _PlanTask(
        id: 'thu1',
        textData: _LocalizedText(
          en: 'Write 5 to 6 sentences about your day.',
          ar: 'اكتب من 5 إلى 6 جمل عن يومك.',
        ),
      ),
      _PlanTask(
        id: 'thu2',
        textData: _LocalizedText(
          en: 'Use 2 new words from this week.',
          ar: 'استخدم كلمتين جديدتين من هذا الأسبوع.',
        ),
      ),
      _PlanTask(
        id: 'thu3',
        textData: _LocalizedText(
          en: 'Read your writing again and fix obvious mistakes.',
          ar: 'اقرأ كتابتك مرة أخرى وصحح الأخطاء الواضحة.',
        ),
      ),
    ],
  ),
  _PlanDay(
    key: 'friday',
    nameData: _LocalizedText(en: 'Friday', ar: 'الجمعة'),
    titleData: _LocalizedText(en: 'Vocabulary Day', ar: 'يوم المفردات'),
    skillData: _LocalizedText(en: 'Vocabulary', ar: 'المفردات'),
    durationData: _LocalizedText(en: '20 min', ar: '20 دقيقة'),
    tipData: _LocalizedText(
      en: '💡 Learn useful words from your real life, not random words.',
      ar: '💡 تعلّم كلمات مفيدة من حياتك الحقيقية وليس كلمات عشوائية.',
    ),
    resourceData: _LocalizedText(
      en: 'Use Quizlet, a dictionary, or your own vocabulary notebook.',
      ar: 'استخدم Quizlet أو قاموساً أو دفتر مفرداتك الخاص.',
    ),
    emoji: '📚',
    color: Color(0xFFC753D0),
    lightColor: Color(0xFFFAF0FB),
    tasks: [
      _PlanTask(
        id: 'fri1',
        textData: _LocalizedText(
          en: 'Learn 5 new useful English words.',
          ar: 'تعلّم 5 كلمات إنجليزية جديدة ومفيدة.',
        ),
      ),
      _PlanTask(
        id: 'fri2',
        textData: _LocalizedText(
          en: 'Write one short sentence for each word.',
          ar: 'اكتب جملة قصيرة واحدة لكل كلمة.',
        ),
      ),
      _PlanTask(
        id: 'fri3',
        textData: _LocalizedText(
          en: 'Say the 5 words out loud.',
          ar: 'انطق الكلمات الخمس بصوت عالٍ.',
        ),
      ),
    ],
  ),
  _PlanDay(
    key: 'saturday',
    nameData: _LocalizedText(en: 'Saturday', ar: 'السبت'),
    titleData: _LocalizedText(en: 'Weekly Review', ar: 'مراجعة أسبوعية'),
    skillData: _LocalizedText(en: 'Review', ar: 'مراجعة'),
    durationData: _LocalizedText(en: '15 min', ar: '15 دقيقة'),
    tipData: _LocalizedText(
      en: '💡 Review makes learning stay longer in your memory.',
      ar: '💡 المراجعة تجعل التعلم يبقى لفترة أطول في الذاكرة.',
    ),
    resourceData: _LocalizedText(
      en: 'Use your notes from the whole week.',
      ar: 'استخدم ملاحظاتك من كامل الأسبوع.',
    ),
    emoji: '🏆',
    color: Color(0xFFF7A440),
    lightColor: Color(0xFFFFF7EE),
    tasks: [
      _PlanTask(
        id: 'sat1',
        textData: _LocalizedText(
          en: 'Review this week’s new words.',
          ar: 'راجع كلمات هذا الأسبوع الجديدة.',
        ),
      ),
      _PlanTask(
        id: 'sat2',
        textData: _LocalizedText(
          en: 'Read your best writing or speaking notes again.',
          ar: 'اقرأ أفضل ملاحظاتك في الكتابة أو التحدث مرة أخرى.',
        ),
      ),
      _PlanTask(
        id: 'sat3',
        textData: _LocalizedText(
          en: 'Write one small goal for next week.',
          ar: 'اكتب هدفاً صغيراً واحداً للأسبوع القادم.',
        ),
      ),
    ],
  ),
  _PlanDay(
    key: 'sunday',
    nameData: _LocalizedText(en: 'Sunday', ar: 'الأحد'),
    titleData: _LocalizedText(en: 'Reading Day', ar: 'يوم القراءة'),
    skillData: _LocalizedText(en: 'Reading', ar: 'القراءة'),
    durationData: _LocalizedText(en: '20 min', ar: '20 دقيقة'),
    tipData: _LocalizedText(
      en: '💡 Read for meaning first. Do not stop at every unknown word.',
      ar: '💡 اقرأ للفهم أولاً. لا تتوقف عند كل كلمة غير معروفة.',
    ),
    resourceData: _LocalizedText(
      en: 'Use a short article, simple story, or learning website.',
      ar: 'استخدم مقالاً قصيراً أو قصة بسيطة أو موقع تعلم.',
    ),
    emoji: '📖',
    color: Color(0xFFFF6584),
    lightColor: Color(0xFFFFF0F3),
    tasks: [
      _PlanTask(
        id: 'sun1',
        textData: _LocalizedText(
          en: 'Read one short English text.',
          ar: 'اقرأ نصاً إنجليزياً قصيراً واحداً.',
        ),
      ),
      _PlanTask(
        id: 'sun2',
        textData: _LocalizedText(
          en: 'Underline 3 new words or phrases.',
          ar: 'حدد 3 كلمات أو عبارات جديدة.',
        ),
      ),
      _PlanTask(
        id: 'sun3',
        textData: _LocalizedText(
          en: 'Write one or two sentences about what you understood.',
          ar: 'اكتب جملة أو جملتين عما فهمته.',
        ),
      ),
    ],
  ),
];

final List<_PlanTask> _allTasks = _weekPlanDays
    .expand((day) => day.tasks)
    .toList(growable: false);
