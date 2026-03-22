import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'shared/human_error.dart';

/// ===== Brand Colors (from your palette) =====
class Brand {
  static const primaryBlue = Color(0xFF1A2B48); // #1A2B48
  static const actionOrange = Color(0xFFF98D28); // #F98D28
  static const accentCyan = Color(0xFF00D4FF); // #00D4FF
  static const mainText = Color(0xFF2D2D2D); // #2D2D2D
  static const appBg = Color(0xFFF4F7F9); // #F4F7F9
  static const uiBorder = Color(0xFFD1D9E0); // #D1D9E0
}

/// ===== Enrollment cooldown (kept exactly) =====
class EnrollLimiter {
  static const Duration cooldown = Duration(hours: 1);

  static String _keyForCourse(String courseId) => 'last_enroll_at_ms_$courseId';

  static Future<DateTime?> _getLast(String courseId) async {
    final sp = await SharedPreferences.getInstance();
    final lastMs = sp.getInt(_keyForCourse(courseId));
    if (lastMs == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(lastMs);
  }

  static Future<bool> canEnrollNow(String courseId) async {
    final last = await _getLast(courseId);
    if (last == null) return true;
    return DateTime.now().difference(last) >= cooldown;
  }

  static Future<Duration> remaining(String courseId) async {
    final last = await _getLast(courseId);
    if (last == null) return Duration.zero;
    final diff = DateTime.now().difference(last);
    if (diff >= cooldown) return Duration.zero;
    return cooldown - diff;
  }

  static Future<void> markEnrolledNow(String courseId) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setInt(
      _keyForCourse(courseId),
      DateTime.now().millisecondsSinceEpoch,
    );
  }
}

/// ===== Canonical product keys =====
/// inclass / flexible / private / recorded
String normalizeDeliveryKey(String key) {
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

String canonicalDeliveryLabel(String key) {
  switch (normalizeDeliveryKey(key)) {
    case 'inclass':
      return 'In-Class';
    case 'flexible':
      return 'Flexible';
    case 'private':
      return 'Private';
    case 'recorded':
      return 'Recorded';
    default:
      return key;
  }
}

String normalizeStudyMode(String key) {
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

String studyModeLabel(String key) {
  switch (normalizeStudyMode(key)) {
    case 'online':
      return 'Online';
    case 'inclass':
      return 'In-Class';
    default:
      return '';
  }
}

String studyModeLabelAr(String key) {
  switch (normalizeStudyMode(key)) {
    case 'online':
      return 'أونلاين';
    case 'inclass':
      return 'حضوري';
    default:
      return '';
  }
}

String canonicalShortLabelEn(String key, {String? fallback}) {
  switch (normalizeDeliveryKey(key)) {
    case 'inclass':
      return 'Structured classroom learning';
    case 'flexible':
      return 'Flexible group sessions';
    case 'private':
      return 'Personal one-to-one lessons';
    case 'recorded':
      return 'Self-paced full course';
    default:
      return (fallback ?? key).trim().isEmpty ? key : fallback!.trim();
  }
}

String canonicalShortLabelAr(String key, {String? fallback}) {
  switch (normalizeDeliveryKey(key)) {
    case 'inclass':
      return 'تعلم منظم داخل القسم';
    case 'flexible':
      return 'حصص جماعية مرنة';
    case 'private':
      return 'حصص فردية مخصصة';
    case 'recorded':
      return 'دورة كاملة بتعلم ذاتي';
    default:
      return (fallback ?? key).trim().isEmpty ? key : fallback!.trim();
  }
}

/// ===== New learner delivery model =====
class EnrollDeliveryOption {
  const EnrollDeliveryOption({
    required this.key,
    required this.label,
    required this.shortLabelEn,
    required this.shortLabelAr,
    required this.fee,
    required this.accessMode,
    required this.accessDurationMonths,
    required this.enabled,
  });

  /// Canonical keys used internally:
  /// inclass / flexible / private / recorded
  final String key;

  /// Canonical learner-facing label:
  /// In-Class / Flexible / Private / Recorded
  final String label;

  final String shortLabelEn;
  final String shortLabelAr;
  final double? fee;
  final String accessMode; // lifetime / duration
  final int? accessDurationMonths;
  final bool enabled;

  bool get isSelectable => enabled && (fee ?? 0) > 0;
  bool get requiresStudyMode => normalizeDeliveryKey(key) == 'private';

  EnrollDeliveryOption normalized() {
    final normalizedKey = normalizeDeliveryKey(key);
    final normalizedLabel = canonicalDeliveryLabel(normalizedKey);

    return EnrollDeliveryOption(
      key: normalizedKey,
      label: normalizedLabel,
      shortLabelEn: canonicalShortLabelEn(normalizedKey),
      shortLabelAr: canonicalShortLabelAr(normalizedKey),
      fee: fee,
      accessMode: accessMode.trim().isEmpty ? 'lifetime' : accessMode.trim(),
      accessDurationMonths: accessDurationMonths,
      enabled: enabled,
    );
  }

  String feeLabel() {
    final f = fee;
    if (f == null || f <= 0) return 'Price not specified';
    return '${f.toStringAsFixed(0)} DA';
  }

  String accessLabelEn() {
    if (accessMode == 'duration') {
      final m = accessDurationMonths;
      if (m != null && m > 0) {
        return '$m month${m == 1 ? '' : 's'} access';
      }
    }
    return 'Lifetime access';
  }

  String accessLabelAr() {
    if (accessMode == 'duration') {
      final m = accessDurationMonths;
      if (m != null && m > 0) {
        return 'صلاحية لمدة $m ${m == 1 ? 'شهر' : 'أشهر'}';
      }
    }
    return 'وصول مدى الحياة';
  }

  String explanationEn() {
    switch (normalizeDeliveryKey(key)) {
      case 'inclass':
        return 'Fixed-schedule group classes in class. Best for learners who want routine, classroom interaction, and steady progress.';
      case 'flexible':
        return 'Flexible group sessions you can book based on your availability, online or in class. Best for learners with changing schedules.';
      case 'private':
        return 'Private one-to-one lessons on a fixed schedule, personalized to your level and goals. Best for fast and focused progress.';
      case 'recorded':
        return 'A full recorded course you can study anytime at your own pace. Best for learners who prefer independent and flexible study.';
      default:
        return '';
    }
  }

  String explanationAr() {
    switch (normalizeDeliveryKey(key)) {
      case 'inclass':
        return 'دروس جماعية بجدول ثابت داخل القسم، مناسبة لمن يفضل التعلم المنظم والتفاعل المباشر داخل بيئة تعليمية واضحة.';
      case 'flexible':
        return 'حصص جماعية مرنة يمكنك حجزها حسب الوقت المناسب لك، أونلاين أو حضورياً، وهي مناسبة لمن يحتاج حرية أكبر في تنظيم وقته.';
      case 'private':
        return 'حصص فردية خاصة مع الأستاذ بجدول ثابت، موجهة حسب مستواك وهدفك، ومناسبة لمن يريد تركيزاً أكبر وتقدماً أسرع.';
      case 'recorded':
        return 'دورة كاملة مسجلة يمكنك دراستها في أي وقت وبالسرعة التي تناسبك، وهي مناسبة لمن يفضل التعلم الذاتي والمرن.';
      default:
        return '';
    }
  }

  String bestForAr() {
    switch (normalizeDeliveryKey(key)) {
      case 'inclass':
        return '🎯 مناسب لمن يحب الالتزام والتعلم داخل القسم';
      case 'flexible':
        return '🎯 مناسب لمن يملك وقتاً غير ثابت';
      case 'private':
        return '🎯 مناسب لمن يريد نتائج أسرع وتركيزاً كاملاً';
      case 'recorded':
        return '🎯 مناسب لمن يفضل الدراسة في أي وقت';
      default:
        return '';
    }
  }

  IconData icon() {
    switch (normalizeDeliveryKey(key)) {
      case 'inclass':
        return Icons.groups_rounded;
      case 'flexible':
        return Icons.schedule_rounded;
      case 'private':
        return Icons.person_rounded;
      case 'recorded':
        return Icons.play_circle_fill_rounded;
      default:
        return Icons.menu_book_rounded;
    }
  }
}

class EnrollScreen extends StatefulWidget {
  const EnrollScreen({
    super.key,
    required this.courseId,
    required this.courseTitle,
    required this.deliveryOptions,
  });

  final String courseId;
  final String courseTitle;
  final List<EnrollDeliveryOption> deliveryOptions;

  @override
  State<EnrollScreen> createState() => _EnrollScreenState();
}

class _EnrollScreenState extends State<EnrollScreen> {
  final _formKey = GlobalKey<FormState>();

  final fullNameC = TextEditingController();
  final phoneC = TextEditingController();
  final dobC = TextEditingController();
  final emailC = TextEditingController();

  bool saving = false;
  late final List<EnrollDeliveryOption> deliveryOptions;
  String? selectedDeliveryKey;
  late final PageController _deliveryPageController;
  int _currentDeliveryIndex = 0;

  /// Only required when deliveryKey == private
  String _privateStudyMode = 'online';

  @override
  void initState() {
    super.initState();

    final normalized = widget.deliveryOptions
        .map((e) => e.normalized())
        .where((e) => e.enabled)
        .toList();

    deliveryOptions = _dedupeNormalizedOptions(normalized);

    if (deliveryOptions.isNotEmpty) {
      final firstSelectable = deliveryOptions
          .cast<EnrollDeliveryOption?>()
          .firstWhere(
            (e) => e?.isSelectable == true,
            orElse: () => deliveryOptions.first,
          );
      selectedDeliveryKey = firstSelectable?.key;
      _currentDeliveryIndex = deliveryOptions.indexWhere(
        (e) => e.key == selectedDeliveryKey,
      );
      if (_currentDeliveryIndex < 0) _currentDeliveryIndex = 0;
    }

    _deliveryPageController = PageController(
      viewportFraction: 0.82,
      initialPage: _currentDeliveryIndex,
    );
  }

  List<EnrollDeliveryOption> _dedupeNormalizedOptions(
    List<EnrollDeliveryOption> input,
  ) {
    final Map<String, EnrollDeliveryOption> byKey = {};

    for (final item in input) {
      final key = normalizeDeliveryKey(item.key);

      if (!byKey.containsKey(key)) {
        byKey[key] = item;
        continue;
      }

      final existing = byKey[key]!;

      final existingFee = existing.fee ?? 0;
      final newFee = item.fee ?? 0;

      final shouldReplace =
          newFee > existingFee ||
          (!existing.enabled && item.enabled) ||
          (existing.shortLabelEn.trim().isEmpty &&
              item.shortLabelEn.trim().isNotEmpty);

      if (shouldReplace) {
        byKey[key] = item;
      }
    }

    const preferredOrder = ['flexible', 'inclass', 'private', 'recorded'];

    final out = byKey.values.toList();
    out.sort((a, b) {
      final ai = preferredOrder.indexOf(a.key);
      final bi = preferredOrder.indexOf(b.key);
      return ai.compareTo(bi);
    });
    return out;
  }

  @override
  void dispose() {
    _deliveryPageController.dispose();
    fullNameC.dispose();
    phoneC.dispose();
    dobC.dispose();
    emailC.dispose();
    super.dispose();
  }

  Future<void> _pickDob() async {
    FocusScope.of(context).unfocus();
    final now = DateTime.now();
    DateTime initial = DateTime(now.year - 14, now.month, now.day);

    final existing = dobC.text.trim();
    final parts = existing.split('-');
    if (parts.length == 3) {
      final y = int.tryParse(parts[0]);
      final m = int.tryParse(parts[1]);
      final d = int.tryParse(parts[2]);
      if (y != null && m != null && d != null) {
        initial = DateTime(y, m, d);
      }
    }

    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(1950),
      lastDate: now,
      helpText: 'Date of birth',
    );
    if (picked == null) return;

    String two(int n) => n.toString().padLeft(2, '0');
    setState(() {
      dobC.text = '${picked.year}-${two(picked.month)}-${two(picked.day)}';
    });
  }

  EnrollDeliveryOption? get _selectedOption {
    if (selectedDeliveryKey == null) return null;
    for (final o in deliveryOptions) {
      if (o.key == selectedDeliveryKey) return o;
    }
    return null;
  }

  String _formatDuration(Duration d) {
    if (d <= Duration.zero) return '0m';
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60);
    if (hours <= 0) return '${minutes}m';
    return '${hours}h ${minutes}m';
  }

  String _accessSummary(EnrollDeliveryOption option) {
    if (option.accessMode == 'duration') {
      final m = option.accessDurationMonths;
      if (m != null && m > 0) {
        return 'Access expires $m month${m == 1 ? '' : 's'} after enrollment.';
      }
    }
    return 'Lifetime access.';
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();

    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (saving) return;

    final selected = _selectedOption;
    if (selected == null || !selected.enabled) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please choose a study type.')),
      );
      return;
    }

    if (selected.requiresStudyMode &&
        normalizeStudyMode(_privateStudyMode).isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please choose Online or In-Class for Private.'),
        ),
      );
      return;
    }

    final can = await EnrollLimiter.canEnrollNow(widget.courseId);
    if (!can) {
      final rem = await EnrollLimiter.remaining(widget.courseId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Too many attempts. Please wait ${_formatDuration(rem)} and try again.',
          ),
        ),
      );
      return;
    }

    setState(() => saving = true);

    try {
      final ref = FirebaseDatabase.instance.ref('subscriptions').push();

      final studyMode = selected.requiresStudyMode
          ? normalizeStudyMode(_privateStudyMode)
          : '';

      final studyModeText = selected.requiresStudyMode
          ? studyModeLabel(_privateStudyMode)
          : '';

      await ref.set({
        'courseId': widget.courseId,
        'courseTitle': widget.courseTitle,
        'fullName': fullNameC.text.trim(),
        'phone': phoneC.text.trim(),
        'dob': dobC.text.trim(),
        'dateOfBirth': dobC.text.trim(),
        'email': emailC.text.trim(),

        // legacy-friendly field
        'delivery': selected.label,
        'paymentPlan': 'By delivery option',

        // normalized product-first fields
        'deliveryKey': selected.key,
        'deliveryLabel': selected.label,
        'studyMode': studyMode,
        'studyModeLabel': studyModeText,
        'selectedFee': selected.fee,
        'accessMode': selected.accessMode,
        'accessDurationMonths': selected.accessDurationMonths,
        'accessLabel': _accessSummary(selected),

        'additionalInfo': '',
        'createdAt': ServerValue.timestamp,
      });

      await EnrollLimiter.markEnrolledNow(widget.courseId);

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enrollment sent ✅ We will contact you soon.'),
        ),
      );

      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            toHumanError(
              e,
              fallback: 'Could not complete enrollment. Try again.',
            ),
          ),
        ),
      );
      setState(() => saving = false);
    }
  }

  EdgeInsets _screenPadding(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    final h = w < 400 ? 16.0 : (w < 900 ? 18.0 : 24.0);
    return EdgeInsets.fromLTRB(h, 10, h, 120);
  }

  double _cardRadius(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    return (w < 420 ? 18.0 : 22.0);
  }

  double _fieldRadius(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    return (w < 420 ? 16.0 : 18.0);
  }

  InputDecoration _inputDeco({
    required String label,
    required IconData icon,
    String? hint,
  }) {
    final radius = _fieldRadius(context);

    return InputDecoration(
      labelText: label,
      hintText: hint,
      prefixIcon: Icon(icon),
      filled: true,
      fillColor: Colors.white.withOpacity(0.92),
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      alignLabelWithHint: true,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radius),
        borderSide: const BorderSide(color: Brand.uiBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radius),
        borderSide: BorderSide(color: Brand.uiBorder.withOpacity(0.9)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radius),
        borderSide: const BorderSide(color: Brand.accentCyan, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radius),
        borderSide: const BorderSide(color: Colors.redAccent, width: 1.2),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radius),
        borderSide: const BorderSide(color: Colors.redAccent, width: 2),
      ),
    );
  }

  void _selectDeliveryByIndex(int index) {
    if (index < 0 || index >= deliveryOptions.length) return;
    final option = deliveryOptions[index];
    if (!option.isSelectable || saving) return;

    setState(() {
      _currentDeliveryIndex = index;
      selectedDeliveryKey = option.key;
    });
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selectedOption;
    final showPrivateMode = selected?.requiresStudyMode == true;

    return Scaffold(
      backgroundColor: Brand.appBg,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.white,
        foregroundColor: Brand.primaryBlue,
        title: const Text(
          'Course Enrollment',
          style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18),
        ),
      ),
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Brand.appBg,
                      Colors.white.withOpacity(0.8),
                      Brand.appBg.withOpacity(0.7),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              top: -120,
              left: -120,
              child: _SoftBlob(
                color: Brand.accentCyan.withOpacity(0.10),
                size: 260,
              ),
            ),
            Positioned(
              bottom: -140,
              right: -140,
              child: _SoftBlob(
                color: Brand.actionOrange.withOpacity(0.10),
                size: 300,
              ),
            ),
            SingleChildScrollView(
              padding: _screenPadding(context),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _MascotHeader(courseTitle: widget.courseTitle),
                  const SizedBox(height: 14),

                  _GlassCard(
                    radius: _cardRadius(context),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const _SectionTitle(
                          icon: Icons.menu_book_rounded,
                          title: 'Choose how you want to study',
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Swipe to explore the available study options.',
                          style: TextStyle(
                            color: Brand.mainText.withOpacity(0.72),
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 12),
                        if (deliveryOptions.isEmpty)
                          const _InfoBanner(
                            text:
                                'No study options are available for this course right now.',
                          )
                        else ...[
                          _DeliveryCarousel(
                            controller: _deliveryPageController,
                            options: deliveryOptions,
                            selectedIndex: _currentDeliveryIndex,
                            onTapIndex: _selectDeliveryByIndex,
                            onPageChanged: (index) {
                              setState(() {
                                _currentDeliveryIndex = index;
                                selectedDeliveryKey =
                                    deliveryOptions[index].key;
                              });
                            },
                          ),
                          const SizedBox(height: 10),
                          _CarouselDots(
                            count: deliveryOptions.length,
                            activeIndex: _currentDeliveryIndex,
                          ),
                          const SizedBox(height: 14),
                          if (selected != null)
                            _DeliveryExplanation(option: selected),
                        ],
                      ],
                    ),
                  ),

                  if (showPrivateMode) ...[
                    const SizedBox(height: 14),
                    _GlassCard(
                      radius: _cardRadius(context),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const _SectionTitle(
                            icon: Icons.place_rounded,
                            title: 'Private lesson mode',
                          ),
                          const SizedBox(height: 12),
                          _StudyModeSelector(
                            value: _privateStudyMode,
                            onChanged: saving
                                ? null
                                : (v) => setState(
                                    () => _privateStudyMode = v ?? 'online',
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ],

                  if (selected != null) ...[
                    const SizedBox(height: 14),
                    _SelectedOptionSummary(
                      option: selected,
                      studyMode: showPrivateMode ? _privateStudyMode : '',
                    ),
                  ],

                  const SizedBox(height: 14),

                  _GlassCard(
                    radius: _cardRadius(context),
                    child: Form(
                      key: _formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const _SectionTitle(
                            icon: Icons.assignment_rounded,
                            title: 'Enrollment details',
                          ),
                          const SizedBox(height: 12),

                          TextFormField(
                            controller: fullNameC,
                            textInputAction: TextInputAction.next,
                            decoration: _inputDeco(
                              label: 'Full name',
                              icon: Icons.person_rounded,
                              hint: 'Your full name',
                            ),
                            validator: (v) {
                              final s = (v ?? '').trim();
                              if (s.isEmpty) {
                                return 'Please enter your full name.';
                              }
                              if (s.length < 3) return 'Name looks too short.';
                              return null;
                            },
                          ),
                          const SizedBox(height: 12),

                          TextFormField(
                            controller: phoneC,
                            keyboardType: TextInputType.phone,
                            textInputAction: TextInputAction.next,
                            decoration: _inputDeco(
                              label: 'Phone number',
                              icon: Icons.phone_rounded,
                              hint: 'e.g. 0550 00 00 00',
                            ),
                            validator: (v) {
                              final s = (v ?? '').trim();
                              if (s.isEmpty) {
                                return 'Please enter your phone number.';
                              }
                              if (s.length < 8) {
                                return 'Phone number looks too short.';
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: 12),

                          TextFormField(
                            controller: dobC,
                            readOnly: true,
                            onTap: _pickDob,
                            textInputAction: TextInputAction.next,
                            decoration: _inputDeco(
                              label: 'Date of birth',
                              icon: Icons.cake_rounded,
                              hint: 'YYYY-MM-DD',
                            ),
                            validator: (v) {
                              final s = (v ?? '').trim();
                              if (s.isEmpty) {
                                return 'Please select your date of birth.';
                              }
                              final p = s.split('-');
                              if (p.length != 3) {
                                return 'Use format YYYY-MM-DD.';
                              }
                              final y = int.tryParse(p[0]);
                              final m = int.tryParse(p[1]);
                              final d = int.tryParse(p[2]);
                              if (y == null || m == null || d == null) {
                                return 'Use format YYYY-MM-DD.';
                              }
                              final parsed = DateTime(y, m, d);
                              if (parsed.year != y ||
                                  parsed.month != m ||
                                  parsed.day != d) {
                                return 'Please choose a valid date.';
                              }
                              if (parsed.isAfter(DateTime.now())) {
                                return 'Date of birth cannot be in the future.';
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: 12),

                          TextFormField(
                            controller: emailC,
                            keyboardType: TextInputType.emailAddress,
                            textInputAction: TextInputAction.done,
                            decoration: _inputDeco(
                              label: 'Email (optional)',
                              icon: Icons.alternate_email_rounded,
                              hint: 'name@example.com',
                            ),
                            validator: (v) {
                              final s = (v ?? '').trim();
                              if (s.isEmpty) return null;
                              if (!s.contains('@') || !s.contains('.')) {
                                return 'Please enter a valid email address.';
                              }
                              return null;
                            },
                          ),

                          const SizedBox(height: 14),

                          const _InfoBanner(
                            text:
                                'We will contact you soon to confirm your subscription.',
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _BottomActionBar(saving: saving, onSubmit: _submit),
            ),
          ],
        ),
      ),
    );
  }
}

/// ===== UI =====

class _DeliveryCarousel extends StatelessWidget {
  const _DeliveryCarousel({
    required this.controller,
    required this.options,
    required this.selectedIndex,
    required this.onTapIndex,
    required this.onPageChanged,
  });

  final PageController controller;
  final List<EnrollDeliveryOption> options;
  final int selectedIndex;
  final ValueChanged<int> onTapIndex;
  final ValueChanged<int> onPageChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 170,
      child: PageView.builder(
        controller: controller,
        itemCount: options.length,
        onPageChanged: onPageChanged,
        itemBuilder: (_, i) {
          final option = options[i];
          final selected = i == selectedIndex;

          return AnimatedPadding(
            duration: const Duration(milliseconds: 220),
            padding: EdgeInsets.symmetric(
              horizontal: 6,
              vertical: selected ? 2 : 10,
            ),
            child: GestureDetector(
              onTap: () => onTapIndex(i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  gradient: selected
                      ? LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            Brand.primaryBlue,
                            Brand.primaryBlue.withOpacity(0.92),
                          ],
                        )
                      : LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            Colors.white.withOpacity(0.98),
                            Colors.white.withOpacity(0.92),
                          ],
                        ),
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(
                    color: selected ? Brand.accentCyan : Brand.uiBorder,
                    width: selected ? 2 : 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: selected
                          ? Brand.primaryBlue.withOpacity(0.18)
                          : Colors.black.withOpacity(0.05),
                      blurRadius: selected ? 20 : 12,
                      offset: const Offset(0, 10),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        color: selected
                            ? Colors.white.withOpacity(0.12)
                            : Brand.accentCyan.withOpacity(0.14),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: selected
                              ? Colors.white.withOpacity(0.18)
                              : Brand.uiBorder.withOpacity(0.9),
                        ),
                      ),
                      child: Icon(
                        option.icon(),
                        color: selected ? Colors.white : Brand.primaryBlue,
                        size: 26,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      option.label,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        color: selected ? Colors.white : Brand.primaryBlue,
                        fontSize: 18,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      option.shortLabelAr,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        color: selected
                            ? Colors.white.withOpacity(0.92)
                            : Brand.mainText.withOpacity(0.75),
                        fontWeight: FontWeight.w700,
                        height: 1.2,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _CarouselDots extends StatelessWidget {
  const _CarouselDots({required this.count, required this.activeIndex});

  final int count;
  final int activeIndex;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(count, (i) {
        final active = i == activeIndex;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          margin: const EdgeInsets.symmetric(horizontal: 4),
          width: active ? 22 : 8,
          height: 8,
          decoration: BoxDecoration(
            color: active ? Brand.primaryBlue : Brand.uiBorder,
            borderRadius: BorderRadius.circular(999),
          ),
        );
      }),
    );
  }
}

class _DeliveryExplanation extends StatelessWidget {
  const _DeliveryExplanation({required this.option});

  final EnrollDeliveryOption option;

  List<_FeatureItem> _features() {
    switch (option.key) {
      case 'inclass':
        return const [
          _FeatureItem(Icons.event_rounded, '📅 جدول ثابت وواضح'),
          _FeatureItem(
            Icons.groups_rounded,
            '👥 تعلم مع مجموعة في نفس المستوى',
          ),
          _FeatureItem(
            Icons.school_rounded,
            '🏫 بيئة تعليمية منظمة داخل القسم',
          ),
          _FeatureItem(Icons.trending_up_rounded, '📈 تقدم خطوة بخطوة'),
        ];

      case 'flexible':
        return const [
          _FeatureItem(Icons.schedule_rounded, '⏱ اختر الوقت المناسب لك'),
          _FeatureItem(Icons.groups_rounded, '👥 حصص جماعية'),
          _FeatureItem(Icons.people_alt_rounded, '👤 حتى 6 متعلمين'),
          _FeatureItem(Icons.swap_horiz_rounded, '📍 أونلاين'),
        ];

      case 'private':
        return const [
          _FeatureItem(Icons.person_rounded, '👤 حصص فردية 1 to 1'),
          _FeatureItem(
            Icons.track_changes_rounded,
            '🎯 برنامج حسب مستواك وهدفك',
          ),
          _FeatureItem(Icons.flash_on_rounded, '⚡ تقدم أسرع وتركيز أكبر'),
          _FeatureItem(Icons.swap_horiz_rounded, '📍 أونلاين أو حضوري'),
        ];

      case 'recorded':
        return const [
          _FeatureItem(Icons.video_library_rounded, '🎥 دورة كاملة مسجلة'),
          _FeatureItem(
            Icons.self_improvement_rounded,
            '📚 تعلم ذاتي وبالسرعة المناسبة',
          ),
          _FeatureItem(Icons.replay_rounded, '🔁 أعد مشاهدة الدروس وقتما تشاء'),
          _FeatureItem(Icons.access_time_rounded, '🕒 ادرس في أي وقت'),
        ];

      default:
        return const [];
    }
  }

  @override
  Widget build(BuildContext context) {
    final features = _features();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withOpacity(0.98),
            Brand.accentCyan.withOpacity(0.04),
          ],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Brand.uiBorder.withOpacity(0.95)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 12,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              option.explanationAr(),
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                height: 1.55,
                color: Brand.mainText,
                fontSize: 14.2,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              option.bestForAr(),
              style: const TextStyle(
                fontWeight: FontWeight.w900,
                color: Brand.primaryBlue,
                fontSize: 13.5,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: features
                  .map((item) => _FeatureTag(item: item))
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }
}

class _FeatureItem {
  const _FeatureItem(this.icon, this.label);
  final IconData icon;
  final String label;
}

class _FeatureTag extends StatelessWidget {
  const _FeatureTag({required this.item});

  final _FeatureItem item;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 120, maxWidth: 240),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.96),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Brand.uiBorder.withOpacity(0.9)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(item.icon, size: 17, color: Brand.primaryBlue),
          const SizedBox(width: 8),
          Expanded(
            child: Directionality(
              textDirection: TextDirection.rtl,
              child: Text(
                item.label,
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  color: Brand.mainText,
                  height: 1.25,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StudyModeSelector extends StatelessWidget {
  const _StudyModeSelector({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String?>? onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      initialValue: normalizeStudyMode(value).isEmpty
          ? 'online'
          : normalizeStudyMode(value),
      decoration: InputDecoration(
        labelText: 'Choose mode',
        filled: true,
        fillColor: Colors.white.withOpacity(0.92),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: Brand.uiBorder.withOpacity(0.9)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: Brand.uiBorder.withOpacity(0.9)),
        ),
        focusedBorder: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(16)),
          borderSide: BorderSide(color: Brand.accentCyan, width: 2),
        ),
      ),
      items: const [
        DropdownMenuItem(value: 'online', child: Text('Online')),
        DropdownMenuItem(value: 'inclass', child: Text('In-Class')),
      ],
      onChanged: onChanged,
    );
  }
}

class _SelectedOptionSummary extends StatelessWidget {
  const _SelectedOptionSummary({required this.option, required this.studyMode});

  final EnrollDeliveryOption option;
  final String studyMode;

  @override
  Widget build(BuildContext context) {
    final accessText = option.accessMode == 'duration'
        ? 'Access expires ${option.accessDurationMonths ?? 0} month${(option.accessDurationMonths ?? 0) == 1 ? '' : 's'} after enrollment.'
        : 'Lifetime access.';

    final modeText = option.requiresStudyMode ? studyModeLabel(studyMode) : '';
    final modeTextAr = option.requiresStudyMode
        ? studyModeLabelAr(studyMode)
        : '';

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Brand.actionOrange.withOpacity(0.16),
            Brand.actionOrange.withOpacity(0.08),
          ],
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Brand.actionOrange.withOpacity(0.45)),
        boxShadow: [
          BoxShadow(
            color: Brand.actionOrange.withOpacity(0.10),
            blurRadius: 18,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: Brand.actionOrange.withOpacity(0.16),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Brand.actionOrange.withOpacity(0.25)),
            ),
            child: Icon(option.icon(), color: Brand.actionOrange),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  option.label,
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    color: Brand.primaryBlue,
                    fontSize: 16,
                  ),
                ),
                if (modeText.isNotEmpty || modeTextAr.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    modeTextAr.isNotEmpty
                        ? '$modeText • $modeTextAr'
                        : modeText,
                    style: TextStyle(
                      color: Brand.primaryBlue.withOpacity(0.85),
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
                const SizedBox(height: 4),
                Text(
                  option.feeLabel(),
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    color: Brand.actionOrange,
                    fontSize: 18,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  accessText,
                  style: TextStyle(
                    color: Brand.mainText.withOpacity(0.82),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SoftBlob extends StatelessWidget {
  const _SoftBlob({required this.color, required this.size});
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: color.withOpacity(0.55),
              blurRadius: 90,
              spreadRadius: 20,
            ),
          ],
        ),
      ),
    );
  }
}

class _GlassCard extends StatelessWidget {
  const _GlassCard({required this.child, this.radius = 22});
  final Widget child;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.78),
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: Brand.uiBorder.withOpacity(0.9)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.06),
                blurRadius: 24,
                offset: const Offset(0, 14),
              ),
            ],
          ),
          child: child,
        ),
      ),
    );
  }
}

class _MascotHeader extends StatelessWidget {
  const _MascotHeader({required this.courseTitle});
  final String courseTitle;

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    final compact = w < 380;

    return _GlassCard(
      radius: (w < 420 ? 18 : 22),
      child: Row(
        children: [
          Container(
            width: compact ? 54 : 62,
            height: compact ? 54 : 62,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Brand.appBg,
              border: Border.all(color: Brand.uiBorder.withOpacity(0.9)),
            ),
            padding: const EdgeInsets.all(8),
            child: ClipOval(
              child: Image.asset(
                'assets/images/character.png',
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Icon(
                  Icons.person_rounded,
                  color: Brand.primaryBlue,
                  size: compact ? 30 : 34,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Complete your enrollment',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Brand.primaryBlue,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  courseTitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: Brand.mainText,
                    fontWeight: FontWeight.w900,
                    height: 1.15,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.icon, required this.title});
  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: Brand.accentCyan.withOpacity(0.14),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Brand.uiBorder.withOpacity(0.9)),
          ),
          child: Icon(icon, color: Brand.primaryBlue, size: 18),
        ),
        const SizedBox(width: 10),
        Text(
          title,
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w900,
            color: Brand.primaryBlue,
          ),
        ),
      ],
    );
  }
}

class _InfoBanner extends StatelessWidget {
  const _InfoBanner({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Brand.accentCyan.withOpacity(0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Brand.uiBorder.withOpacity(0.9)),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: Brand.accentCyan.withOpacity(0.16),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.info_outline_rounded,
              color: Brand.primaryBlue,
              size: 18,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Brand.mainText.withOpacity(0.80),
                fontWeight: FontWeight.w700,
                height: 1.25,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BottomActionBar extends StatelessWidget {
  const _BottomActionBar({required this.saving, required this.onSubmit});

  final bool saving;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);

    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + mq.padding.bottom),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.78),
            border: Border(
              top: BorderSide(color: Brand.uiBorder.withOpacity(0.9)),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.08),
                blurRadius: 18,
                offset: const Offset(0, -6),
              ),
            ],
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Center(
              child: SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton.icon(
                  onPressed: saving ? null : onSubmit,
                  style: FilledButton.styleFrom(
                    backgroundColor: Brand.primaryBlue,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: Brand.primaryBlue.withOpacity(
                      0.55,
                    ),
                    disabledForegroundColor: Colors.white.withOpacity(0.9),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  icon: saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.check_circle_rounded),
                  label: Text(
                    saving ? 'Saving...' : 'Submit enrollment',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
