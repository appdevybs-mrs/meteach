class CityAssetMeta {
  const CityAssetMeta({required this.file});

  final String file;

  factory CityAssetMeta.fromJson(Map<dynamic, dynamic> json) {
    return CityAssetMeta(file: (json['file'] ?? '').toString());
  }
}

class CityOption {
  CityOption({
    required this.name,
    required this.ascii,
    required this.alternates,
    required this.lat,
    required this.lng,
  }) : _searchText = normalize([name, ascii, ...alternates].join(' '));

  final String name;
  final String ascii;
  final List<String> alternates;
  final double lat;
  final double lng;
  final String _searchText;

  factory CityOption.fromJson(Map<dynamic, dynamic> json) {
    final alternatesRaw = json['alternates'];
    return CityOption(
      name: (json['name'] ?? '').toString(),
      ascii: (json['ascii'] ?? json['name'] ?? '').toString(),
      alternates: alternatesRaw is List
          ? alternatesRaw.map((e) => e.toString()).toList()
          : const [],
      lat: (json['lat'] as num).toDouble(),
      lng: (json['lng'] as num).toDouble(),
    );
  }

  bool matches(String normalizedQuery) => _searchText.contains(normalizedQuery);

  static String normalize(String value) {
    const accents = {
      'á': 'a',
      'à': 'a',
      'â': 'a',
      'ä': 'a',
      'ã': 'a',
      'å': 'a',
      'ā': 'a',
      'ă': 'a',
      'ą': 'a',
      'ç': 'c',
      'ć': 'c',
      'č': 'c',
      'ď': 'd',
      'đ': 'd',
      'é': 'e',
      'è': 'e',
      'ê': 'e',
      'ë': 'e',
      'ē': 'e',
      'ė': 'e',
      'ę': 'e',
      'ě': 'e',
      'ğ': 'g',
      'í': 'i',
      'ì': 'i',
      'î': 'i',
      'ï': 'i',
      'ī': 'i',
      'ı': 'i',
      'ł': 'l',
      'ñ': 'n',
      'ń': 'n',
      'ň': 'n',
      'ó': 'o',
      'ò': 'o',
      'ô': 'o',
      'ö': 'o',
      'õ': 'o',
      'ø': 'o',
      'ō': 'o',
      'ř': 'r',
      'ś': 's',
      'š': 's',
      'ş': 's',
      'ť': 't',
      'ú': 'u',
      'ù': 'u',
      'û': 'u',
      'ü': 'u',
      'ū': 'u',
      'ů': 'u',
      'ý': 'y',
      'ÿ': 'y',
      'ž': 'z',
      'ź': 'z',
      'ż': 'z',
    };
    final lower = value.toLowerCase().trim();
    final out = StringBuffer();
    for (final rune in lower.runes) {
      final ch = String.fromCharCode(rune);
      out.write(accents[ch] ?? ch);
    }
    return out.toString().replaceAll(RegExp(r'\s+'), ' ');
  }
}
