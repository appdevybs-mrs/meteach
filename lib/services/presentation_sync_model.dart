class PresentationSyncState {
  const PresentationSyncState({
    required this.active,
    required this.presenterUid,
    required this.sourceType,
    required this.source,
    required this.slideH,
    required this.slideV,
    required this.fragment,
    required this.scrollY,
    required this.ts,
  });

  final bool active;
  final String presenterUid;
  final String sourceType; // url | asset | html
  final String source;

  final int slideH;
  final int slideV;
  final int fragment;
  final double scrollY;

  final int ts;

  factory PresentationSyncState.initial() {
    return const PresentationSyncState(
      active: false,
      presenterUid: '',
      sourceType: '',
      source: '',
      slideH: 0,
      slideV: 0,
      fragment: 0,
      scrollY: 0,
      ts: 0,
    );
  }

  PresentationSyncState copyWith({
    bool? active,
    String? presenterUid,
    String? sourceType,
    String? source,
    int? slideH,
    int? slideV,
    int? fragment,
    double? scrollY,
    int? ts,
  }) {
    return PresentationSyncState(
      active: active ?? this.active,
      presenterUid: presenterUid ?? this.presenterUid,
      sourceType: sourceType ?? this.sourceType,
      source: source ?? this.source,
      slideH: slideH ?? this.slideH,
      slideV: slideV ?? this.slideV,
      fragment: fragment ?? this.fragment,
      scrollY: scrollY ?? this.scrollY,
      ts: ts ?? this.ts,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'active': active ? 1 : 0,
      'presenterUid': presenterUid,
      'sourceType': sourceType,
      'source': source,
      'slideH': slideH,
      'slideV': slideV,
      'fragment': fragment,
      'scrollY': scrollY,
      'ts': ts,
    };
  }

  factory PresentationSyncState.fromMap(Map<dynamic, dynamic> map) {
    bool parseActive(dynamic v) {
      if (v is bool) return v;
      if (v is int) return v == 1;
      final s = (v ?? '').toString().trim().toLowerCase();
      return s == '1' || s == 'true';
    }

    int parseInt(dynamic v) {
      if (v is int) return v;
      return int.tryParse((v ?? '').toString()) ?? 0;
    }

    double parseDouble(dynamic v) {
      if (v is num) return v.toDouble();
      return double.tryParse((v ?? '').toString()) ?? 0;
    }

    return PresentationSyncState(
      active: parseActive(map['active']),
      presenterUid: (map['presenterUid'] ?? '').toString(),
      sourceType: (map['sourceType'] ?? '').toString(),
      source: (map['source'] ?? '').toString(),
      slideH: parseInt(map['slideH']),
      slideV: parseInt(map['slideV']),
      fragment: parseInt(map['fragment']),
      scrollY: parseDouble(map['scrollY']),
      ts: parseInt(map['ts']),
    );
  }

  bool get hasSource => source.trim().isNotEmpty;
}