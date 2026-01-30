import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';

/// ===== Brand Colors (from your palette) =====
class Brand {
  static const primaryBlue = Color(0xFF1A2B48); // #1A2B48
  static const actionOrange = Color(0xFFF98D28); // #F98D28
  static const accentCyan = Color(0xFF00D4FF); // #00D4FF
  static const mainText = Color(0xFF2D2D2D); // #2D2D2D
  static const appBg = Color(0xFFF4F7F9); // #F4F7F9
  static const uiBorder = Color(0xFFD1D9E0); // #D1D9E0
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
    deliveryOptions = widget.deliveryOptions.isNotEmpty
        ? widget.deliveryOptions
        : ['Not specified'];
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

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();

    if (!(_formKey.currentState?.validate() ?? false)) return;

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

  InputDecoration _inputDeco({
    required String label,
    required IconData icon,
    String? hint,
  }) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      prefixIcon: Icon(icon),
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Brand.uiBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Brand.uiBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Brand.accentCyan, width: 2),
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
            // soft gradient background
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Brand.appBg,
                      Brand.appBg.withOpacity(0.85),
                      Colors.white.withOpacity(0.55),
                    ],
                  ),
                ),
              ),
            ),

            SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 110),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _MascotHeader(courseTitle: widget.courseTitle),

                  if (prices.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _PriceCard(lines: prices),
                  ],

                  const SizedBox(height: 14),

                  _CardShell(
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
                              final twoColumns = constraints.maxWidth >= 520; // adjust if you want

                              final paymentField = DropdownButtonFormField<String>(
                                isExpanded: true, // ✅ important
                                value: paymentSelected,
                                items: paymentOptions
                                    .map((p) => DropdownMenuItem(
                                  value: p,
                                  child: Text(
                                    p,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ))
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
                                isExpanded: true, // ✅ important
                                value: deliverySelected,
                                items: deliveryOptions
                                    .map((d) => DropdownMenuItem(
                                  value: d,
                                  child: Text(
                                    d,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ))
                                    .toList(),
                                onChanged: saving
                                    ? null
                                    : (v) => setState(() => deliverySelected = v ?? deliverySelected),
                                decoration: _inputDeco(
                                  label: 'Delivery',
                                  icon: Icons.videocam_rounded,
                                ),
                              );

                              if (!twoColumns) {
                                // ✅ stacked (no overflow)
                                return Column(
                                  children: [
                                    paymentField,
                                    const SizedBox(height: 12),
                                    deliveryField,
                                  ],
                                );
                              }

                              // ✅ side by side (nice on wide screens)
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

                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Brand.accentCyan.withOpacity(0.08),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: Brand.uiBorder),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 34,
                                  height: 34,
                                  decoration: BoxDecoration(
                                    color: Brand.accentCyan.withOpacity(0.18),
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
                                    'We will contact you soon to confirm your subscription.',
                                    style: TextStyle(
                                      color: Brand.mainText.withOpacity(0.78),
                                      fontWeight: FontWeight.w700,
                                      height: 1.3,
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
                ],
              ),
            ),

            // Sticky bottom button
            Positioned(
              left: 16,
              right: 16,
              bottom: 16,
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

/// ===== UI components =====

class _MascotHeader extends StatelessWidget {
  const _MascotHeader({required this.courseTitle});
  final String courseTitle;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.92),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Brand.uiBorder),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.06),
            blurRadius: 28,
            offset: const Offset(0, 14),
          )
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 62,
            height: 62,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Brand.appBg,
              border: Border.all(color: Brand.uiBorder),
            ),
            padding: const EdgeInsets.all(8),
            child: ClipOval(
              child: Image.asset(
                'assets/images/character.png', // <-- change if your path differs
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const Icon(
                  Icons.person_rounded,
                  color: Brand.primaryBlue,
                  size: 34,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Complete your enrollment',
                  style: TextStyle(
                    color: Brand.primaryBlue,
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  courseTitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Brand.mainText,
                    fontWeight: FontWeight.w900,
                    fontSize: 18,
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
        color: Brand.actionOrange.withOpacity(0.12),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Brand.actionOrange.withOpacity(0.45)),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: Brand.actionOrange.withOpacity(0.18),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.payments_rounded, color: Brand.actionOrange),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Price',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: Brand.actionOrange,
                  ),
                ),
                const SizedBox(height: 4),
                ...lines.map(
                      (t) => Text(
                    t,
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      color: Brand.primaryBlue,
                      fontSize: 14,
                    ),
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

class _CardShell extends StatelessWidget {
  const _CardShell({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.92),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Brand.uiBorder),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.06),
            blurRadius: 28,
            offset: const Offset(0, 14),
          )
        ],
      ),
      child: child,
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
            color: Brand.accentCyan.withOpacity(0.12),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Brand.uiBorder),
          ),
          child: Icon(icon, color: Brand.primaryBlue, size: 18),
        ),
        const SizedBox(width: 10),
        Text(
          title,
          style: const TextStyle(
            fontWeight: FontWeight.w900,
            color: Brand.primaryBlue,
            fontSize: 15,
          ),
        ),
      ],
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
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.94),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Brand.uiBorder),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.10),
            blurRadius: 18,
            offset: const Offset(0, 10),
          )
        ],
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 52,
          child: FilledButton.icon(
            onPressed: saving ? null : onSubmit,
            style: FilledButton.styleFrom(
              backgroundColor: Brand.primaryBlue,
              foregroundColor: Colors.white,
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
              style: const TextStyle(fontWeight: FontWeight.w900),
            ),
          ),
        ),
      ),
    );
  }
}
