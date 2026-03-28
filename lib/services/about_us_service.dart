import 'package:firebase_database/firebase_database.dart';

class AboutUsInfo {
  const AboutUsInfo({
    required this.description,
    required this.facebookUrl,
    required this.instagramUrl,
    required this.email,
  });

  final String description;
  final String facebookUrl;
  final String instagramUrl;
  final String email;

  bool get hasDescription => description.trim().isNotEmpty;
  bool get hasFacebook => _looksLikeUrl(facebookUrl);
  bool get hasInstagram => _looksLikeUrl(instagramUrl);
  bool get hasEmail => _looksLikeEmail(email);

  static bool _looksLikeUrl(String value) {
    final text = value.trim();
    if (text.isEmpty) {
      return false;
    }
    final uri = Uri.tryParse(text);
    return uri != null && uri.hasScheme && uri.hasAuthority;
  }

  static bool _looksLikeEmail(String value) {
    final text = value.trim();
    if (text.isEmpty) {
      return false;
    }
    return RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(text);
  }
}

class AboutUsService {
  Future<AboutUsInfo> fetch() async {
    var description = '';
    var facebookUrl = '';
    var instagramUrl = '';
    var email = '';

    try {
      final snap = await FirebaseDatabase.instance
          .ref('/aboutus')
          .get()
          .timeout(const Duration(seconds: 8));
      if (snap.exists && snap.value is Map) {
        final data = snap.value as Map;
        for (final key in data.keys) {
          final value = data[key]?.toString() ?? '';
          final normalizedKey = key.toString().trim();
          if (normalizedKey == 'us') {
            description = value.trim();
          } else if (normalizedKey == 'FacebookURL') {
            facebookUrl = _normalizeUrl(value);
          } else if (normalizedKey == 'InstagramURL') {
            instagramUrl = _normalizeUrl(value);
          } else if (normalizedKey.toLowerCase() == 'email') {
            email = _normalizeEmail(value);
          }
        }
      }
    } catch (_) {
      // Keep defaults when about-us fetch fails.
    }

    return AboutUsInfo(
      description: description,
      facebookUrl: facebookUrl,
      instagramUrl: instagramUrl,
      email: email,
    );
  }

  String _normalizeUrl(String raw) {
    final text = raw.trim();
    if (text.isEmpty) {
      return '';
    }
    if (text.startsWith('http://') || text.startsWith('https://')) {
      return text;
    }
    return 'https://$text';
  }

  String _normalizeEmail(String raw) {
    return raw.trim().replaceAll(',', '.');
  }
}
