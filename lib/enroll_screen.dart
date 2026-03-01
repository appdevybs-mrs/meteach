import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// ===== Brand Colors (from your palette) =====
class Brand {
  static const primaryBlue = Color(0xFF1A2B48); // #1A2B48
  static const actionOrange = Color(0xFFF98D28); // #F98D28
  static const accentCyan = Color(0xFF00D4FF); // #00D4FF
  static const mainText = Color(0xFF2D2D2D); // #2D2D2D
  static const appBg = Color(0xFFF4F7F9); // #F4F7F9
  static const uiBorder = Color(0xFFD1D9E0); // #D1D9E0
}

/// ===== App-only enrollment cooldown (Option A) =====
/// Blocks submitting another enrollment from the SAME device for 1 hour.
/// Note: users can bypass by clearing app data/reinstalling.
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

class EnrollScreen extends StatefulWidget {
  const EnrollScreen({
    super.key,
    required this.courseId,
    required this.courseTitle,
    required this.pricePerMonth,
    required this.pricePerLevel,
    required this.deliveryOptions,
  });

  final String courseId;
  final String courseTitle;
  final double? pricePerMonth;
  final double? pricePerLevel;
  final List<String> deliveryOptions;

  @override
  State<EnrollScreen> createState() => _EnrollScreenState();
}

class _EnrollScreenState extends State<EnrollScreen> {
  final _formKey = GlobalKey<FormState>();

  final fullNameC = TextEditingController();
  final phoneC = TextEditingController();
  final extraInfoC = TextEditingController();

  bool saving = false;

  late final List<String> paymentOptions;
  late String paymentSelected;

  late final List<String> deliveryOptions;
  late String deliverySelected;

  @override
  void initState() {
    super.initState();

    // Payment options
    paymentOptions = [];
    if ((widget.pricePerMonth ?? 0) > 0) paymentOptions.add('Per month');
    if ((widget.pricePerLevel ?? 0) > 0) paymentOptions.add('Per level');
    if (paymentOptions.isEmpty) paymentOptions.add('Not specified');
    paymentSelected = paymentOptions.first;

    // Delivery options
    deliveryOptions =
    widget.deliveryOptions.isNotEmpty ? widget.deliveryOptions : ['Not specified'];
    deliverySelected = deliveryOptions.first;
  }

  @override
  void dispose() {
    fullNameC.dispose();
    phoneC.dispose();
    extraInfoC.dispose();
    super.dispose();
  }

  List<String> _priceLines() {
    final out = <String>[];
    final pm = widget.pricePerMonth;
    final pl = widget.pricePerLevel;

    if (pm != null && pm > 0) out.add('${pm.toStringAsFixed(0)} DA / month');
    if (pl != null && pl > 0) out.add('${pl.toStringAsFixed(0)} DA / level');
    return out;
  }

  String _formatDuration(Duration d) {
    if (d <= Duration.zero) return '0m';
    final hours = d.inHours;
    final minutes = d.inMinutes.remainder(60);
    if (hours <= 0) return '${minutes}m';
    return '${hours}h ${minutes}m';
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();

    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (saving) return;

    // ✅ App-only cooldown (per course)
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

      await ref.set({
        'courseId': widget.courseId,
        'courseTitle': widget.courseTitle,
        'fullName': fullNameC.text.trim(),
        'phone': phoneC.text.trim(),
        'paymentPlan': paymentSelected,
        'delivery': deliverySelected,
        'additionalInfo': extraInfoC.text.trim(),
        'createdAt': ServerValue.timestamp,
      });

      // ✅ mark cooldown only after successful write
      await EnrollLimiter.markEnrolledNow(widget.courseId);

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enrollment sent ✅ We will contact you soon.')),
      );

      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to enroll: $e')),
      );
      setState(() => saving = false);
    }
  }

  // Scales padding/radius a bit, but remains stable across font settings.
  EdgeInsets _screenPadding(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    // clamps: small phones -> 16, tablets -> 24
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

  // More modern: subtle borders, better error spacing, consistent density.
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

  @override
  Widget build(BuildContext context) {
    final prices = _priceLines();

    return Scaffold(
      backgroundColor: Brand.appBg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        foregroundColor: Brand.primaryBlue,
        title: const Text(
          'Enroll',
          style: TextStyle(fontWeight: FontWeight.w900),
        ),
      ),
      body: SafeArea(
        child: Stack(
          children: [
            // Modern, subtle layered background
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

            // A couple soft blobs for depth (no extra packages)
            Positioned(
              top: -120,
              left: -120,
              child: _SoftBlob(color: Brand.accentCyan.withOpacity(0.10), size: 260),
            ),
            Positioned(
              bottom: -140,
              right: -140,
              child: _SoftBlob(color: Brand.actionOrange.withOpacity(0.10), size: 300),
            ),

            // Content
            SingleChildScrollView(
              padding: _screenPadding(context),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _MascotHeader(courseTitle: widget.courseTitle),

                  if (prices.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    _PriceCard(lines: prices),
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
                              if (s.isEmpty) return 'Please enter your full name.';
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
                              if (s.isEmpty) return 'Please enter your phone number.';
                              if (s.length < 8) return 'Phone number looks too short.';
                              return null;
                            },
                          ),
                          const SizedBox(height: 14),

                          LayoutBuilder(
                            builder: (context, constraints) {
                              final twoColumns = constraints.maxWidth >= 560;

                              final paymentField = DropdownButtonFormField<String>(
                                isExpanded: true,
                                value: paymentSelected,
                                items: paymentOptions
                                    .map(
                                      (p) => DropdownMenuItem(
                                    value: p,
                                    child: Text(
                                      p,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                )
                                    .toList(),
                                onChanged: saving
                                    ? null
                                    : (v) => setState(() => paymentSelected = v ?? paymentSelected),
                                decoration: _inputDeco(
                                  label: 'Payment',
                                  icon: Icons.payments_rounded,
                                ),
                              );

                              final deliveryField = DropdownButtonFormField<String>(
                                isExpanded: true,
                                value: deliverySelected,
                                items: deliveryOptions
                                    .map(
                                      (d) => DropdownMenuItem(
                                    value: d,
                                    child: Text(
                                      d,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                )
                                    .toList(),
                                onChanged: saving
                                    ? null
                                    : (v) =>
                                    setState(() => deliverySelected = v ?? deliverySelected),
                                decoration: _inputDeco(
                                  label: 'Delivery',
                                  icon: Icons.videocam_rounded,
                                ),
                              );

                              if (!twoColumns) {
                                return Column(
                                  children: [
                                    paymentField,
                                    const SizedBox(height: 12),
                                    deliveryField,
                                  ],
                                );
                              }

                              return Row(
                                children: [
                                  Expanded(child: paymentField),
                                  const SizedBox(width: 12),
                                  Expanded(child: deliveryField),
                                ],
                              );
                            },
                          ),

                          const SizedBox(height: 12),

                          TextFormField(
                            controller: extraInfoC,
                            keyboardType: TextInputType.multiline,
                            maxLines: 3,
                            decoration: _inputDeco(
                              label: 'Additional information (optional)',
                              icon: Icons.notes_rounded,
                              hint: 'Any note for the administration…',
                            ),
                          ),

                          const SizedBox(height: 14),

                          _InfoBanner(
                            text: 'We will contact you soon to confirm your subscription.',
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Sticky bottom button (now with blur/glass, safe for all sizes)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _BottomActionBar(
                saving: saving,
                onSubmit: _submit,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// ===== UI components (modern + responsive) =====

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
                errorBuilder: (_, __, ___) => Icon(
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

class _PriceCard extends StatelessWidget {
  const _PriceCard({required this.lines});
  final List<String> lines;

  @override
  Widget build(BuildContext context) {
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
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: Brand.actionOrange.withOpacity(0.16),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Brand.actionOrange.withOpacity(0.25)),
            ),
            child: const Icon(Icons.payments_rounded, color: Brand.actionOrange),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: DefaultTextStyle.merge(
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Brand.primaryBlue,
                fontWeight: FontWeight.w900,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Price',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w900,
                      color: Brand.actionOrange,
                    ),
                  ),
                  const SizedBox(height: 4),
                  ...lines.map(
                        (t) => Text(
                      t,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
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
  const _BottomActionBar({
    required this.saving,
    required this.onSubmit,
  });

  final bool saving;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);

    // Edge-to-edge, with safe area padding, blur background.
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          padding: EdgeInsets.fromLTRB(
            16,
            12,
            16,
            12 + mq.padding.bottom, // ✅ safe for gesture nav / iPhones
          ),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.78),
            border: Border(top: BorderSide(color: Brand.uiBorder.withOpacity(0.9))),
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
                    disabledBackgroundColor: Brand.primaryBlue.withOpacity(0.55),
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
