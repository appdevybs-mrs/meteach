class AdminCertificate {
  final String? key;
  final String cvn;
  final String grade;
  final String fullName;
  final String dateOfBirth;
  final String nationalIdNumber;
  final String idType; // 'national_id' or 'passport'
  final String certificateName;
  final String subline;
  final String description;
  final String issueDate;
  final String? frontIdUrl;
  final String? backIdUrl;
  final String? passportUrl;
  final String? profilePicUrl;
  final int createdAt;
  final int updatedAt;

  AdminCertificate({
    this.key,
    this.cvn = '',
    this.grade = 'A',
    required this.fullName,
    required this.dateOfBirth,
    required this.nationalIdNumber,
    required this.idType,
    required this.certificateName,
    required this.subline,
    required this.description,
    required this.issueDate,
    this.frontIdUrl,
    this.backIdUrl,
    this.passportUrl,
    this.profilePicUrl,
    this.createdAt = 0,
    this.updatedAt = 0,
  });

  Map<String, dynamic> toMap() {
    return {
      'cvn': cvn,
      'grade': grade,
      'fullName': fullName,
      'dateOfBirth': dateOfBirth,
      'nationalIdNumber': nationalIdNumber,
      'idType': idType,
      'certificateName': certificateName,
      'subline': subline,
      'description': description,
      'issueDate': issueDate,
      if (frontIdUrl != null) 'frontIdUrl': frontIdUrl,
      if (backIdUrl != null) 'backIdUrl': backIdUrl,
      if (passportUrl != null) 'passportUrl': passportUrl,
      if (profilePicUrl != null) 'profilePicUrl': profilePicUrl,
      'createdAt': createdAt,
      'updatedAt': updatedAt,
    };
  }

  factory AdminCertificate.fromMap(Map<dynamic, dynamic> map, {String? key}) {
    return AdminCertificate(
      key: key,
      cvn: (map['cvn'] ?? '').toString(),
      grade: (map['grade'] ?? 'A').toString(),
      fullName: (map['fullName'] ?? '').toString(),
      dateOfBirth: (map['dateOfBirth'] ?? '').toString(),
      nationalIdNumber: (map['nationalIdNumber'] ?? '').toString(),
      idType: (map['idType'] ?? 'national_id').toString(),
      certificateName: (map['certificateName'] ?? '').toString(),
      subline: (map['subline'] ?? '').toString(),
      description: (map['description'] ?? '').toString(),
      issueDate: (map['issueDate'] ?? '').toString(),
      frontIdUrl: map['frontIdUrl']?.toString(),
      backIdUrl: map['backIdUrl']?.toString(),
      passportUrl: map['passportUrl']?.toString(),
      profilePicUrl: map['profilePicUrl']?.toString(),
      createdAt: _asInt(map['createdAt']),
      updatedAt: _asInt(map['updatedAt']),
    );
  }

  static int _asInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  AdminCertificate copyWith({
    String? key,
    String? cvn,
    String? grade,
    String? fullName,
    String? dateOfBirth,
    String? nationalIdNumber,
    String? idType,
    String? certificateName,
    String? subline,
    String? description,
    String? issueDate,
    String? frontIdUrl,
    String? backIdUrl,
    String? passportUrl,
    String? profilePicUrl,
    int? createdAt,
    int? updatedAt,
  }) {
    return AdminCertificate(
      key: key ?? this.key,
      cvn: cvn ?? this.cvn,
      grade: grade ?? this.grade,
      fullName: fullName ?? this.fullName,
      dateOfBirth: dateOfBirth ?? this.dateOfBirth,
      nationalIdNumber: nationalIdNumber ?? this.nationalIdNumber,
      idType: idType ?? this.idType,
      certificateName: certificateName ?? this.certificateName,
      subline: subline ?? this.subline,
      description: description ?? this.description,
      issueDate: issueDate ?? this.issueDate,
      frontIdUrl: frontIdUrl ?? this.frontIdUrl,
      backIdUrl: backIdUrl ?? this.backIdUrl,
      passportUrl: passportUrl ?? this.passportUrl,
      profilePicUrl: profilePicUrl ?? this.profilePicUrl,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  String get effectivePicUrl => profilePicUrl ?? frontIdUrl ?? passportUrl ?? '';
}

class AdminCertificateSuggestion {
  final String? key;
  final String value;

  AdminCertificateSuggestion({this.key, required this.value});

  Map<String, dynamic> toMap() => {'value': value};

  factory AdminCertificateSuggestion.fromMap(
    Map<dynamic, dynamic> map, {
    String? key,
  }) {
    return AdminCertificateSuggestion(
      key: key,
      value: (map['value'] ?? '').toString(),
    );
  }
}
