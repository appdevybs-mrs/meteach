import 'dart:math';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import '../shared/app_feedback.dart';
import '../shared/app_theme.dart';
import '../shared/learner_web_layout.dart';
import '../shared/watermark_background.dart';

class LearnerStudyCoachScreen extends StatefulWidget {
  const LearnerStudyCoachScreen({super.key});

  @override
  State<LearnerStudyCoachScreen> createState() =>
      _LearnerStudyCoachScreenState();
}

enum _CoachMode { spelling, usage }

enum _CoachSpeed { slow, standard, fast }

class _LearnerStudyCoachScreenState extends State<LearnerStudyCoachScreen> {
  final DatabaseReference _db = FirebaseDatabase.instance.ref();
  final TextEditingController _typedAnswerController = TextEditingController();
  final PageController _deckController = PageController(viewportFraction: 0.9);

  bool _loading = true;
  String? _error;

  final List<_CourseBundle> _courseBundles = <_CourseBundle>[];
  _CourseBundle? _selectedCourse;

  _CoachMode _mode = _CoachMode.spelling;
  _CoachSpeed _speed = _CoachSpeed.standard;

  bool _sessionStarted = false;
  bool _isTestSession = false;
  bool _learningDeckOpen = false;
  bool _learningCompleted = false;
  int _deckPage = 0;
  int _index = 0;
  int _correct = 0;
  int? _pickedOption;
  bool _answered = false;
  bool _answerCorrect = false;
  _Question? _question;

  AppPalette get palette => appThemeController.palette;

  @override
  void initState() {
    super.initState();
    appThemeController.addListener(_onThemeChanged);
    _loadVocabByAssignedCourses();
  }

  @override
  void dispose() {
    appThemeController.removeListener(_onThemeChanged);
    _typedAnswerController.dispose();
    _deckController.dispose();
    super.dispose();
  }

  void _onThemeChanged() {
    if (!mounted) return;
    setState(() {});
  }

  int _wordsPerDay(_CoachSpeed speed) {
    switch (speed) {
      case _CoachSpeed.slow:
        return 5;
      case _CoachSpeed.standard:
        return 10;
      case _CoachSpeed.fast:
        return 15;
    }
  }

  String _speedLabel(_CoachSpeed speed) {
    switch (speed) {
      case _CoachSpeed.slow:
        return 'Easy • 5/day';
      case _CoachSpeed.standard:
        return 'Normal • 10/day';
      case _CoachSpeed.fast:
        return 'Fast • 15/day';
    }
  }

  Future<void> _loadVocabByAssignedCourses() async {
    setState(() {
      _loading = true;
      _error = null;
      _courseBundles.clear();
      _selectedCourse = null;
      _sessionStarted = false;
      _learningCompleted = false;
      _learningDeckOpen = false;
    });

    try {
      final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
      if (uid.isEmpty) {
        throw Exception('Not logged in.');
      }

      final userCoursesSnap = await _db.child('users/$uid/courses').get();
      if (!userCoursesSnap.exists || userCoursesSnap.value is! Map) {
        throw Exception('No assigned courses found.');
      }

      final raw = Map<dynamic, dynamic>.from(userCoursesSnap.value as Map);
      final assigned = <Map<String, dynamic>>[];

      int asInt(dynamic v) {
        if (v is int) return v;
        if (v is num) return v.toInt();
        return int.tryParse(v?.toString() ?? '') ?? 0;
      }

      for (final entry in raw.entries) {
        if (entry.value is! Map) continue;
        final m = Map<dynamic, dynamic>.from(entry.value as Map);
        final cls = m['class'] is Map
            ? Map<dynamic, dynamic>.from(m['class'] as Map)
            : <dynamic, dynamic>{};
        final courseId = (cls['course_id'] ?? m['id'] ?? '').toString().trim();
        if (courseId.isEmpty) continue;
        final title = (m['title'] ?? cls['course_title'] ?? courseId)
            .toString()
            .trim();

        assigned.add({
          'courseId': courseId,
          'courseTitle': title.isEmpty ? courseId : title,
          'assignedAt': asInt(m['assignedAt']),
        });
      }

      assigned.sort(
        (a, b) => (b['assignedAt'] as int).compareTo(a['assignedAt'] as int),
      );

      final bundles = <_CourseBundle>[];
      for (final c in assigned) {
        final courseId = (c['courseId'] ?? '').toString();
        final courseTitle = (c['courseTitle'] ?? '').toString();
        final wordsSnap = await _db.child('vocab_words/$courseId').get();
        if (!wordsSnap.exists || wordsSnap.value is! Map) continue;

        final wordsRaw = Map<dynamic, dynamic>.from(wordsSnap.value as Map);
        final words = <_Word>[];
        for (final entry in wordsRaw.entries) {
          if (entry.value is! Map) continue;
          final map = Map<dynamic, dynamic>.from(entry.value as Map);
          final parsed = _Word.fromMap(entry.key.toString(), map);
          if (parsed.word.isEmpty) continue;
          words.add(parsed);
        }

        if (words.isEmpty) continue;

        bundles.add(
          _CourseBundle(
            courseId: courseId,
            courseTitle: courseTitle,
            words: words,
          ),
        );
      }

      if (bundles.isEmpty) {
        throw Exception(
          'No vocabulary list is linked to your assigned courses yet.',
        );
      }

      if (!mounted) return;
      setState(() {
        _courseBundles
          ..clear()
          ..addAll(bundles);
        _selectedCourse = _courseBundles.first;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  List<_Word> _todayWords() {
    final selected = _selectedCourse;
    if (selected == null) return const <_Word>[];

    final count = _wordsPerDay(_speed);
    final all = List<_Word>.from(selected.words);
    all.shuffle();
    return all.take(min(count, all.length)).toList();
  }

  void _startSession() {
    final selected = _selectedCourse;
    if (selected == null || selected.words.isEmpty) return;

    selected.sessionWords
      ..clear()
      ..addAll(_todayWords());

    if (selected.sessionWords.isEmpty) {
      AppToast.show(
        context,
        'No words available for today.',
        type: AppToastType.info,
      );
      return;
    }

    if (_deckController.hasClients) {
      _deckController.jumpToPage(0);
    }

    setState(() {
      _sessionStarted = false;
      _isTestSession = false;
      _learningDeckOpen = true;
      _learningCompleted = false;
      _deckPage = 0;
      _index = 0;
      _correct = 0;
      _pickedOption = null;
      _answered = false;
      _answerCorrect = false;
      _question = null;
      _typedAnswerController.clear();
    });
  }

  void _startTestSession() {
    final selected = _selectedCourse;
    if (selected == null) return;
    if (!_learningCompleted || selected.sessionWords.isEmpty) {
      AppToast.show(
        context,
        'Finish the learning set first.',
        type: AppToastType.info,
      );
      return;
    }

    final firstWord = selected.sessionWords.first;

    setState(() {
      _sessionStarted = true;
      _isTestSession = true;
      _learningDeckOpen = false;
      _index = 0;
      _correct = 0;
      _pickedOption = null;
      _answered = false;
      _answerCorrect = false;
      _typedAnswerController.clear();
      _question = _buildQuestion(
        mode: _mode,
        word: firstWord,
        allWords: selected.words,
      );
    });
  }

  void _finishLearningDeck() {
    if (!mounted) return;
    setState(() {
      _learningDeckOpen = false;
      _learningCompleted = true;
      _sessionStarted = false;
      _isTestSession = false;
    });
  }

  void _cancelLearningDeck() {
    if (!mounted) return;
    setState(() {
      _learningDeckOpen = false;
      _learningCompleted = false;
      _sessionStarted = false;
      _isTestSession = false;
    });
  }

  _Word? get _currentWord {
    final selected = _selectedCourse;
    if (selected == null || !_sessionStarted) return null;
    if (_index < 0 || _index >= selected.sessionWords.length) return null;
    return selected.sessionWords[_index];
  }

  bool get _sessionDone {
    final selected = _selectedCourse;
    if (selected == null) return true;
    return _sessionStarted && _index >= selected.sessionWords.length;
  }

  _Question _buildQuestion({
    required _CoachMode mode,
    required _Word word,
    required List<_Word> allWords,
  }) {
    final random = Random();

    if (mode == _CoachMode.spelling) {
      final type = random.nextInt(3);
      if (type == 0) {
        final masked = _maskWord(word.word);
        return _Question(
          promptTitle: 'Complete the spelling',
          promptBody: masked,
          answer: word.word,
          options: const <String>[],
          questionType: 'spelling_masked',
        );
      }

      if (type == 1 && word.definition.trim().isNotEmpty) {
        return _Question(
          promptTitle: 'Type the word for this definition',
          promptBody: word.definition,
          answer: word.word,
          options: const <String>[],
          questionType: 'spelling_definition',
        );
      }

      final example = _blankExample(word.example, word.word);
      return _Question(
        promptTitle: 'Fill the missing word',
        promptBody: example,
        answer: word.word,
        options: const <String>[],
        questionType: 'spelling_example',
      );
    }

    final type = random.nextInt(3);
    if (type == 0) {
      final options = _mcqWordOptions(answer: word.word, allWords: allWords);
      return _Question(
        promptTitle: 'Choose the correct word',
        promptBody: word.definition.isEmpty
            ? 'Pick the word that matches the picture/context.'
            : word.definition,
        answer: word.word,
        options: options,
        questionType: 'usage_definition_to_word',
      );
    }

    if (type == 1) {
      final options = _mcqDefinitionOptions(
        answer: word.definition,
        allWords: allWords,
      );
      return _Question(
        promptTitle: 'Choose the correct definition',
        promptBody: word.word,
        answer: word.definition,
        options: options,
        questionType: 'usage_word_to_definition',
      );
    }

    final options = _mcqWordOptions(answer: word.word, allWords: allWords);
    return _Question(
      promptTitle: 'Pick the word that fits the sentence',
      promptBody: _blankExample(word.example, word.word),
      answer: word.word,
      options: options,
      questionType: 'usage_example_to_word',
    );
  }

  String _maskWord(String word) {
    final chars = word.split('');
    if (chars.length <= 3) {
      return '${chars.first}${'_' * max(chars.length - 1, 1)}';
    }

    final random = Random();
    final out = <String>[];
    for (int i = 0; i < chars.length; i++) {
      if (i == 0 || i == chars.length - 1) {
        out.add(chars[i]);
      } else {
        out.add(random.nextBool() ? '_' : chars[i]);
      }
    }
    return out.join();
  }

  String _blankExample(String example, String word) {
    final trimmed = example.trim();
    if (trimmed.isEmpty) {
      return 'Use "$word" in a sentence.';
    }

    final escaped = RegExp.escape(word);
    final reg = RegExp(escaped, caseSensitive: false);
    if (reg.hasMatch(trimmed)) {
      return trimmed.replaceFirst(reg, '_____');
    }
    return '$trimmed\n\n(Choose/type: $word)';
  }

  List<String> _mcqWordOptions({
    required String answer,
    required List<_Word> allWords,
  }) {
    final random = Random();
    final pool = allWords
        .map((e) => e.word)
        .where((w) => w.trim().isNotEmpty)
        .toSet()
        .toList();
    pool.removeWhere((w) => w.toLowerCase() == answer.toLowerCase());
    pool.shuffle(random);

    final options = <String>[answer, ...pool.take(3)];
    options.shuffle(random);
    return options;
  }

  List<String> _mcqDefinitionOptions({
    required String answer,
    required List<_Word> allWords,
  }) {
    final random = Random();
    final fallback = answer.trim().isEmpty
        ? 'Definition not available'
        : answer;
    final pool = allWords
        .map((e) => e.definition.trim())
        .where((d) => d.isNotEmpty)
        .toSet()
        .toList();

    pool.removeWhere((d) => d.toLowerCase() == fallback.toLowerCase());
    pool.shuffle(random);
    final options = <String>[fallback, ...pool.take(3)];
    options.shuffle(random);
    return options;
  }

  void _submitSpelling() {
    final question = _question;
    if (question == null) return;

    final typed = _typedAnswerController.text.trim();
    if (typed.isEmpty) {
      AppToast.show(
        context,
        'Type your answer first.',
        type: AppToastType.info,
      );
      return;
    }

    final correct = typed.toLowerCase() == question.answer.trim().toLowerCase();

    setState(() {
      _answered = true;
      _answerCorrect = correct;
      if (correct) _correct++;
    });
  }

  void _submitUsage() {
    final question = _question;
    if (question == null) return;
    if (_pickedOption == null ||
        _pickedOption! < 0 ||
        _pickedOption! >= question.options.length) {
      AppToast.show(context, 'Pick one option first.', type: AppToastType.info);
      return;
    }

    final selected = question.options[_pickedOption!].trim().toLowerCase();
    final answer = question.answer.trim().toLowerCase();
    final correct = selected == answer;

    setState(() {
      _answered = true;
      _answerCorrect = correct;
      if (correct) _correct++;
    });
  }

  void _nextWord() {
    final selected = _selectedCourse;
    if (selected == null) return;

    final nextIndex = _index + 1;
    setState(() {
      _index = nextIndex;
      _pickedOption = null;
      _typedAnswerController.clear();
      _answered = false;
      _answerCorrect = false;
      if (_index >= selected.sessionWords.length) {
        _question = null;
      } else if (_isTestSession) {
        final w = selected.sessionWords[_index];
        _question = _buildQuestion(
          mode: _mode,
          word: w,
          allWords: selected.words,
        );
      } else {
        _question = null;
      }
      if (_index >= selected.sessionWords.length) {
        _sessionStarted = true;
      }
    });
  }

  void _restartSession() {
    if (_isTestSession) {
      _startTestSession();
      return;
    }
    _startSession();
  }

  Widget _buildSetupCard() {
    final selected = _selectedCourse;
    if (selected == null) {
      return const SizedBox.shrink();
    }
    final compact = MediaQuery.sizeOf(context).width < 380;

    return _CoachPanel(
      palette: palette,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: palette.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.auto_stories_rounded,
                    color: palette.primary,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Vocabulary Coach',
                    style: TextStyle(
                      fontSize: compact ? 18 : 20,
                      fontWeight: FontWeight.w900,
                      color: palette.primary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Course: ${selected.courseTitle}',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            Text(
              'Total words: ${selected.words.length}',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: palette.text.withValues(alpha: 0.78),
              ),
            ),
            if (_courseBundles.length > 1) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<_CourseBundle>(
                initialValue: _selectedCourse,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Course'),
                items: _courseBundles
                    .map(
                      (c) => DropdownMenuItem<_CourseBundle>(
                        value: c,
                        child: Text(c.courseTitle),
                      ),
                    )
                    .toList(),
                onChanged: (v) {
                  if (v == null) return;
                  setState(() {
                    _selectedCourse = v;
                    _sessionStarted = false;
                    _learningCompleted = false;
                  });
                },
              ),
            ],
            const SizedBox(height: 14),
            Text(
              'Mode',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: palette.primary,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  selected: _mode == _CoachMode.spelling,
                  label: const Text('Spelling'),
                  avatar: const Icon(Icons.keyboard_alt_rounded, size: 18),
                  onSelected: (_) =>
                      setState(() => _mode = _CoachMode.spelling),
                ),
                ChoiceChip(
                  selected: _mode == _CoachMode.usage,
                  label: const Text('Usage'),
                  avatar: const Icon(Icons.checklist_rtl_rounded, size: 18),
                  onSelected: (_) => setState(() => _mode = _CoachMode.usage),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              'Daily speed',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: palette.primary,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _CoachSpeed.values
                  .map(
                    (s) => ChoiceChip(
                      selected: _speed == s,
                      label: Text(_speedLabel(s)),
                      onSelected: (_) => setState(() => _speed = s),
                    ),
                  )
                  .toList(),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: Flex(
                direction: compact ? Axis.vertical : Axis.horizontal,
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _startSession,
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: const Text('Learn now'),
                    ),
                  ),
                  SizedBox(width: compact ? 0 : 8, height: compact ? 8 : 0),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _learningCompleted ? _startTestSession : null,
                      icon: const Icon(Icons.quiz_rounded),
                      label: Text(
                        _learningCompleted ? 'Test now' : 'Test locked',
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (!_learningCompleted) ...[
              const SizedBox(height: 8),
              Text(
                'Finish the learning deck to unlock test.',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: palette.text.withValues(alpha: 0.72),
                ),
              ),
            ] else ...[
              const SizedBox(height: 8),
              Text(
                'Learning set completed. You can start the test now.',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF0F766E),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildResultCard() {
    final total = _selectedCourse?.sessionWords.length ?? 0;
    final ratio = total == 0 ? 0.0 : (_correct / total);
    final percent = (ratio * 100).round();

    return _CoachPanel(
      palette: palette,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _isTestSession ? 'Test complete' : 'Session complete',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w900,
                color: palette.primary,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Score: $_correct / $total ($percent%)',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: TweenAnimationBuilder<double>(
                duration: const Duration(milliseconds: 320),
                tween: Tween<double>(begin: 0, end: ratio.clamp(0.0, 1.0)),
                builder: (context, value, _) {
                  return LinearProgressIndicator(value: value, minHeight: 10);
                },
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _restartSession,
                  icon: const Icon(Icons.replay_rounded),
                  label: Text(_isTestSession ? 'Retake test' : 'New set'),
                ),
                OutlinedButton.icon(
                  onPressed: () {
                    setState(() {
                      _sessionStarted = false;
                      _isTestSession = false;
                    });
                  },
                  icon: const Icon(Icons.settings_rounded),
                  label: const Text('Back to setup'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTestCard(_Word word) {
    final question = _question;
    if (question == null) return const SizedBox.shrink();
    final compact = MediaQuery.sizeOf(context).width < 380;
    final total = _selectedCourse?.sessionWords.length ?? 0;
    final progress = total <= 0 ? 0.0 : (_index + 1) / total;

    return _CoachPanel(
      palette: palette,
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, compact ? 12 : 16, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Test ${_index + 1} of $total',
                  style: TextStyle(
                    color: palette.text.withValues(alpha: 0.7),
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: palette.accent.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    _mode == _CoachMode.spelling
                        ? 'Spelling Test'
                        : 'Usage Test',
                    style: TextStyle(
                      fontSize: 11,
                      color: palette.accent,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: TweenAnimationBuilder<double>(
                duration: const Duration(milliseconds: 260),
                tween: Tween<double>(begin: 0, end: progress.clamp(0.0, 1.0)),
                builder: (context, value, _) {
                  return LinearProgressIndicator(value: value, minHeight: 7);
                },
              ),
            ),
            const SizedBox(height: 10),
            if (word.imageUrl.trim().isNotEmpty)
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.network(
                  word.imageUrl,
                  width: double.infinity,
                  height: 160,
                  fit: BoxFit.cover,
                ),
              ),
            if (word.imageUrl.trim().isNotEmpty) const SizedBox(height: 12),
            Text(
              question.promptTitle,
              style: TextStyle(
                fontWeight: FontWeight.w900,
                fontSize: 17,
                color: palette.primary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              question.promptBody,
              style: const TextStyle(fontWeight: FontWeight.w700, height: 1.45),
            ),
            const SizedBox(height: 12),
            if (_mode == _CoachMode.spelling)
              TextField(
                controller: _typedAnswerController,
                enabled: !_answered,
                decoration: const InputDecoration(labelText: 'Type exact word'),
              )
            else
              Column(
                children: List.generate(question.options.length, (i) {
                  final text = question.options[i];
                  final selected = _pickedOption == i;
                  return InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: _answered
                        ? null
                        : () {
                            setState(() => _pickedOption = i);
                          },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 170),
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 11,
                      ),
                      decoration: BoxDecoration(
                        color: selected
                            ? palette.primary.withValues(alpha: 0.11)
                            : palette.cardBg.withValues(alpha: 0.8),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: selected
                              ? palette.primary.withValues(alpha: 0.6)
                              : palette.border,
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            selected
                                ? Icons.radio_button_checked_rounded
                                : Icons.radio_button_unchecked_rounded,
                            size: 20,
                            color: selected
                                ? palette.primary
                                : palette.text.withValues(alpha: 0.7),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              text,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              ),
            const SizedBox(height: 10),
            if (_answered)
              AnimatedOpacity(
                duration: const Duration(milliseconds: 180),
                opacity: _answered ? 1 : 0,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: _answerCorrect
                        ? const Color(0xFF047857).withValues(alpha: 0.12)
                        : const Color(0xFFB91C1C).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: _answerCorrect
                          ? const Color(0xFF047857).withValues(alpha: 0.3)
                          : const Color(0xFFB91C1C).withValues(alpha: 0.3),
                    ),
                  ),
                  child: Text(
                    _answerCorrect
                        ? 'Correct!'
                        : 'Incorrect. Correct answer: ${question.answer}',
                    style: TextStyle(
                      color: _answerCorrect
                          ? const Color(0xFF065F46)
                          : const Color(0xFF7F1D1D),
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _answered
                    ? _nextWord
                    : (_mode == _CoachMode.spelling
                          ? _submitSpelling
                          : _submitUsage),
                icon: Icon(
                  _answered ? Icons.arrow_forward_rounded : Icons.check_rounded,
                ),
                label: Text(_answered ? 'Next' : 'Check'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLearningDeckOverlay() {
    final selected = _selectedCourse;
    if (!_learningDeckOpen ||
        selected == null ||
        selected.sessionWords.isEmpty) {
      return const SizedBox.shrink();
    }

    final compact = MediaQuery.sizeOf(context).width < 380;
    final total = selected.sessionWords.length;
    final progress = total <= 0 ? 0.0 : (_deckPage + 1) / total;

    return Positioned.fill(
      child: Stack(
        children: [
          const ModalBarrier(dismissible: false, color: Color(0x80000000)),
          SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: Container(
                  margin: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: palette.border),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.14),
                        blurRadius: 24,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.style_rounded),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'Learning Deck',
                                style: TextStyle(
                                  fontWeight: FontWeight.w900,
                                  fontSize: compact ? 16 : 18,
                                  color: palette.primary,
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Close deck',
                              onPressed: _cancelLearningDeck,
                              icon: const Icon(Icons.close_rounded),
                            ),
                          ],
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Row(
                            children: [
                              Text(
                                'Card ${_deckPage + 1} of $total',
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: palette.text.withValues(alpha: 0.74),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(999),
                                  child: LinearProgressIndicator(
                                    value: progress.clamp(0.0, 1.0),
                                    minHeight: 7,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        Expanded(
                          child: PageView.builder(
                            controller: _deckController,
                            padEnds: true,
                            itemCount: total,
                            onPageChanged: (v) => setState(() => _deckPage = v),
                            itemBuilder: (context, i) {
                              final word = selected.sessionWords[i];
                              return AnimatedBuilder(
                                animation: _deckController,
                                builder: (context, child) {
                                  double page = _deckPage.toDouble();
                                  if (_deckController.hasClients &&
                                      _deckController
                                          .position
                                          .hasContentDimensions) {
                                    page = _deckController.page ?? page;
                                  }
                                  final distance = (page - i).abs().clamp(
                                    0.0,
                                    1.0,
                                  );
                                  final scale = 1 - (distance * 0.06);
                                  final opacity = 1 - (distance * 0.2);
                                  return Transform.scale(
                                    scale: scale,
                                    child: Opacity(
                                      opacity: opacity,
                                      child: child,
                                    ),
                                  );
                                },
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                  ),
                                  child: Card(
                                    elevation: 0,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(18),
                                      side: BorderSide(color: palette.border),
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                        14,
                                        14,
                                        14,
                                        14,
                                      ),
                                      child: SingleChildScrollView(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            if (word.imageUrl.trim().isNotEmpty)
                                              ClipRRect(
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                                child: Image.network(
                                                  word.imageUrl,
                                                  width: double.infinity,
                                                  height: compact ? 160 : 200,
                                                  fit: BoxFit.cover,
                                                  errorBuilder: (_, _, _) =>
                                                      const SizedBox.shrink(),
                                                ),
                                              )
                                            else
                                              Container(
                                                height: compact ? 130 : 160,
                                                width: double.infinity,
                                                decoration: BoxDecoration(
                                                  borderRadius:
                                                      BorderRadius.circular(12),
                                                  gradient: LinearGradient(
                                                    colors: [
                                                      palette.primary
                                                          .withValues(
                                                            alpha: 0.08,
                                                          ),
                                                      palette.accent.withValues(
                                                        alpha: 0.08,
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                                child: Center(
                                                  child: Opacity(
                                                    opacity: 0.22,
                                                    child: Image.asset(
                                                      'assets/images/ybs_logo.png',
                                                      width: 84,
                                                      height: 84,
                                                      fit: BoxFit.contain,
                                                      errorBuilder: (_, _, _) =>
                                                          Icon(
                                                            Icons
                                                                .text_fields_rounded,
                                                            color:
                                                                palette.primary,
                                                            size: 36,
                                                          ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            const SizedBox(height: 12),
                                            Text(
                                              word.word,
                                              style: TextStyle(
                                                fontSize: compact ? 24 : 29,
                                                fontWeight: FontWeight.w900,
                                                color: palette.primary,
                                              ),
                                            ),
                                            if (word.definition
                                                .trim()
                                                .isNotEmpty) ...[
                                              const SizedBox(height: 8),
                                              Text(
                                                word.definition,
                                                style: const TextStyle(
                                                  fontSize: 16,
                                                  fontWeight: FontWeight.w700,
                                                  height: 1.35,
                                                ),
                                              ),
                                            ],
                                            if (word.example
                                                .trim()
                                                .isNotEmpty) ...[
                                              const SizedBox(height: 10),
                                              Text(
                                                word.example,
                                                style: TextStyle(
                                                  fontWeight: FontWeight.w600,
                                                  color: palette.text
                                                      .withValues(alpha: 0.8),
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: _deckPage <= 0
                                    ? null
                                    : () {
                                        _deckController.previousPage(
                                          duration: const Duration(
                                            milliseconds: 240,
                                          ),
                                          curve: Curves.easeOutCubic,
                                        );
                                      },
                                icon: const Icon(Icons.arrow_back_rounded),
                                label: const Text('Previous'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: FilledButton.icon(
                                onPressed: _deckPage >= total - 1
                                    ? _finishLearningDeck
                                    : () {
                                        _deckController.nextPage(
                                          duration: const Duration(
                                            milliseconds: 240,
                                          ),
                                          curve: Curves.easeOutCubic,
                                        );
                                      },
                                icon: Icon(
                                  _deckPage >= total - 1
                                      ? Icons.check_circle_rounded
                                      : Icons.arrow_forward_rounded,
                                ),
                                label: Text(
                                  _deckPage >= total - 1
                                      ? 'Finish learning set'
                                      : 'Next card',
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selectedCourse;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Study Coach'),
        actions: [
          IconButton(
            tooltip: 'Reload',
            onPressed: _loading ? null : _loadVocabByAssignedCourses,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: WatermarkBackground(
        child: Stack(
          children: [
            learnerWebBodyFrame(
              context: context,
              child: SafeArea(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _error != null
                    ? _ErrorView(message: _error!)
                    : selected == null
                    ? const _ErrorView(
                        message: 'No course vocabulary is available.',
                      )
                    : ListView(
                        padding: const EdgeInsets.only(bottom: 16),
                        children: [
                          if (!_sessionStarted || !_isTestSession)
                            _buildSetupCard(),
                          AnimatedSwitcher(
                            duration: const Duration(milliseconds: 240),
                            switchInCurve: Curves.easeOutCubic,
                            switchOutCurve: Curves.easeInCubic,
                            transitionBuilder: (child, animation) {
                              final offset = Tween<Offset>(
                                begin: const Offset(0, 0.03),
                                end: Offset.zero,
                              ).animate(animation);
                              return FadeTransition(
                                opacity: animation,
                                child: SlideTransition(
                                  position: offset,
                                  child: child,
                                ),
                              );
                            },
                            child: !_sessionStarted
                                ? const SizedBox.shrink(
                                    key: ValueKey('setup_idle'),
                                  )
                                : _sessionDone
                                ? KeyedSubtree(
                                    key: const ValueKey('result_panel'),
                                    child: _buildResultCard(),
                                  )
                                : _isTestSession
                                ? KeyedSubtree(
                                    key: ValueKey('test_panel_$_index'),
                                    child: _buildTestCard(_currentWord!),
                                  )
                                : const SizedBox.shrink(
                                    key: ValueKey('idle_non_test'),
                                  ),
                          ),
                        ],
                      ),
              ),
            ),
            _buildLearningDeckOverlay(),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final p = appThemeController.palette;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: _CoachPanel(
          palette: p,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.info_outline_rounded, size: 32),
                const SizedBox(height: 10),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CoachPanel extends StatelessWidget {
  const _CoachPanel({required this.child, required this.palette});

  final Widget child;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: palette.border),
      ),
      child: Stack(
        children: [
          Positioned(
            right: -20,
            top: -10,
            child: IgnorePointer(
              child: Opacity(
                opacity: 0.055,
                child: Image.asset(
                  'assets/images/ybs_logo.png',
                  width: 132,
                  height: 132,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              ),
            ),
          ),
          Positioned(
            left: -24,
            bottom: -30,
            child: IgnorePointer(
              child: Container(
                width: 110,
                height: 110,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: palette.primary.withValues(alpha: 0.06),
                ),
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

class _CourseBundle {
  _CourseBundle({
    required this.courseId,
    required this.courseTitle,
    required this.words,
  });

  final String courseId;
  final String courseTitle;
  final List<_Word> words;
  final List<_Word> sessionWords = <_Word>[];
}

class _Word {
  const _Word({
    required this.id,
    required this.word,
    required this.definition,
    required this.example,
    required this.trainingExamples,
    required this.imageUrl,
  });

  final String id;
  final String word;
  final String definition;
  final String example;
  final List<String> trainingExamples;
  final String imageUrl;

  factory _Word.fromMap(String id, Map<dynamic, dynamic> map) {
    List<String> parseExamples(dynamic raw) {
      if (raw is List) {
        return raw
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList();
      }
      if (raw is Map) {
        return raw.values
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList();
      }
      return const <String>[];
    }

    return _Word(
      id: id,
      word: (map['word'] ?? '').toString().trim(),
      definition: (map['definition'] ?? '').toString().trim(),
      example: (map['example'] ?? '').toString().trim(),
      trainingExamples: parseExamples(map['trainingExamples']),
      imageUrl: (map['imageUrl'] ?? '').toString().trim(),
    );
  }
}

class _Question {
  const _Question({
    required this.promptTitle,
    required this.promptBody,
    required this.answer,
    required this.options,
    required this.questionType,
  });

  final String promptTitle;
  final String promptBody;
  final String answer;
  final List<String> options;
  final String questionType;
}
