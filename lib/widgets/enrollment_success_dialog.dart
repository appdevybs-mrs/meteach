import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:confetti/confetti.dart';

class EnrollmentSuccessDialog extends StatefulWidget {
  const EnrollmentSuccessDialog({super.key});

  @override
  State<EnrollmentSuccessDialog> createState() =>
      _EnrollmentSuccessDialogState();
}

class _EnrollmentSuccessDialogState extends State<EnrollmentSuccessDialog> {
  late final ConfettiController _confettiController;
  String? _waNumber;
  bool _loadingInfo = true;

  static const List<String> _companyNodeCandidates = [
    'appConfig/Company info',
    'appConfig/companyInfo',
    'company',
    'companyProfile',
    'appConfig/company',
    'app/company',
  ];

  @override
  void initState() {
    super.initState();
    _confettiController = ConfettiController(
      duration: const Duration(seconds: 6),
    );
    _confettiController.play();
    _loadCompanyPhone();
  }

  Future<void> _loadCompanyPhone() async {
    final db = FirebaseDatabase.instance;
    for (final path in _companyNodeCandidates) {
      try {
        final snap = await db.ref(path).get();
        final val = snap.value;
        if (val is Map) {
          final m = val.map((k, v) => MapEntry(k.toString(), v));
          final phone = _pickString(m, [
            'companyPhone',
            'company phone',
            'company_phone',
            'phone',
          ]);
          if (phone.isNotEmpty) {
            final normalized = phone.replaceAll(RegExp(r'[^0-9+]'), '');
            final waNumber = normalized.startsWith('+')
                ? normalized.substring(1)
                : normalized;
            if (mounted) {
              setState(() {
                _waNumber = waNumber;
                _loadingInfo = false;
              });
            }
            return;
          }
        }
      } catch (_) {}
    }
    if (mounted) {
      setState(() => _loadingInfo = false);
    }
  }

  String _pickString(Map<String, dynamic> m, List<String> keys) {
    for (final key in keys) {
      final v = m[key];
      final s = (v ?? '').toString().trim();
      if (s.isNotEmpty) return s;
    }
    return '';
  }

  @override
  void dispose() {
    _confettiController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ConfettiWidget(
      confettiController: _confettiController,
      blastDirectionality: BlastDirectionality.explosive,
      numberOfParticles: 40,
      emissionFrequency: 0.06,
      maxBlastForce: 50,
      minBlastForce: 20,
      colors: const [
        Color(0xFF22C55E),
        Color(0xFF3B82F6),
        Color(0xFFF59E0B),
        Color(0xFFEC4899),
        Color(0xFF8B5CF6),
        Color(0xFFEF4444),
        Color(0xFF14B8A6),
        Color(0xFFF97316),
      ],
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
          child: _buildCard(),
        ),
      ),
    );
  }

  Widget _buildCard() {
    return Container(
      constraints: const BoxConstraints(maxWidth: 360),
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 36),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 40,
            offset: const Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: const Color(0xFF22C55E).withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.check_circle_rounded,
              size: 48,
              color: Color(0xFF22C55E),
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'شكراً لاهتمامك!',
            textDirection: TextDirection.rtl,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w800,
              color: Color(0xFF1A2B48),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'تم استلام طلب التسجيل بنجاح.\nسنتواصل معك قريباً على الرقم الذي قدمته.',
            textDirection: TextDirection.rtl,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: Color(0xFF2D2D2D),
              height: 1.6,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'يرجى إبقاء هاتفك مفتوحاً.',
            textDirection: TextDirection.rtl,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: Color(0xFFF98D28),
              height: 1.6,
            ),
          ),
          const SizedBox(height: 24),
          Container(
            height: 1,
            color: const Color(0xFFD1D9E0).withValues(alpha: 0.5),
          ),
          const SizedBox(height: 20),
          const Text(
            'يمكنك أيضاً التواصل معنا مباشرة:',
            textDirection: TextDirection.rtl,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Color(0xFF2D2D2D),
            ),
          ),
          const SizedBox(height: 12),
          _buildWhatsAppButton(),
          const SizedBox(height: 16),
          const Text(
            'تابعنا على وسائل التواصل الاجتماعي',
            textDirection: TextDirection.rtl,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Color(0xFF2D2D2D),
            ),
          ),
          const SizedBox(height: 12),
          _buildSocialRow(),
          const SizedBox(height: 28),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton(
              onPressed: () => Navigator.pop(context),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1A2B48),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                elevation: 0,
              ),
              child: const Text(
                'تم',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWhatsAppButton() {
    final canLaunch = _waNumber != null && _waNumber!.isNotEmpty;
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: ElevatedButton.icon(
        onPressed: canLaunch
            ? () async {
                final uri = Uri.parse('https://wa.me/${_waNumber!}');
                final ok = await launchUrl(
                  uri,
                  mode: LaunchMode.externalApplication,
                );
                if (!ok && mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Could not open WhatsApp.')),
                  );
                }
              }
            : null,
        icon: const Icon(Icons.chat_rounded, size: 20),
        label: Text(
          _loadingInfo ? '...' : 'تواصل عبر واتساب',
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF25D366),
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          elevation: 0,
        ),
      ),
    );
  }

  Widget _buildSocialRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _socialIcon(Icons.facebook_rounded, 'Facebook'),
        const SizedBox(width: 16),
        _socialIcon(Icons.photo_camera_rounded, 'Instagram'),
        const SizedBox(width: 16),
        _socialIcon(Icons.music_note_rounded, 'TikTok'),
      ],
    );
  }

  Widget _socialIcon(IconData icon, String label) {
    return Tooltip(
      message: label,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: const Color(0xFF1A2B48).withValues(alpha: 0.06),
          shape: BoxShape.circle,
        ),
        child: Icon(
          icon,
          color: const Color(0xFF1A2B48).withValues(alpha: 0.7),
          size: 22,
        ),
      ),
    );
  }
}
