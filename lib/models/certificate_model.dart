enum CertificateStatus {
  valid,
  expired,
  revoked;

  String get value {
    switch (this) {
      case CertificateStatus.valid:
        return 'valid';
      case CertificateStatus.expired:
        return 'expired';
      case CertificateStatus.revoked:
        return 'revoked';
    }
  }

  String get label {
    switch (this) {
      case CertificateStatus.valid:
        return 'Valid';
      case CertificateStatus.expired:
        return 'Expired';
      case CertificateStatus.revoked:
        return 'Revoked';
    }
  }

  static CertificateStatus fromValue(String? v) {
    switch (v?.toLowerCase()) {
      case 'valid':
        return CertificateStatus.valid;
      case 'expired':
        return CertificateStatus.expired;
      case 'revoked':
        return CertificateStatus.revoked;
      default:
        return CertificateStatus.valid;
    }
  }

  static CertificateStatus fromExpirationDate(DateTime expirationDate) {
    if (DateTime.now().isAfter(expirationDate)) {
      return CertificateStatus.expired;
    }
    return CertificateStatus.valid;
  }
}

class Certificate {
  final String? key;
  final String cvn;
  final String fullName;
  final String nationalIdNumber;
  final String certificateTitle;
  final String trainingDate;
  final String expirationDate;
  final CertificateStatus status;
  final int createdAt;
  final int updatedAt;
  final String? issuedBy;
  final String? notes;
  final String? pdfUrl;
  final String? pdfPreviewUrl;
  final int downloadCount;
  final int? lastDownloadedAt;
  final bool downloadsEnabled;
  final String? source;
  final String? learnerUid;
  final String? recordedCertId;
  final String? certificateKind;
  final String? courseId;
  final String? courseKey;
  final String? moduleKey;
  final String? instructorName;
  final String examCourse;
  final String cpdHours;
  final String shortDescription;

  Certificate({
    this.key,
    required this.cvn,
    required this.fullName,
    required this.nationalIdNumber,
    required this.certificateTitle,
    required this.trainingDate,
    required this.expirationDate,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.issuedBy,
    this.notes,
    this.pdfUrl,
    this.pdfPreviewUrl,
    this.downloadCount = 0,
    this.lastDownloadedAt,
    this.downloadsEnabled = true,
    this.source,
    this.learnerUid,
    this.recordedCertId,
    this.certificateKind,
    this.courseId,
    this.courseKey,
    this.moduleKey,
    this.instructorName,
    this.examCourse = 'course',
    this.cpdHours = '40',
    this.shortDescription = '',
  });

  Map<String, dynamic> toMap() {
    return {
      'cvn': cvn,
      'fullName': fullName,
      'nationalIdNumber': nationalIdNumber,
      'certificateTitle': certificateTitle,
      'trainingDate': trainingDate,
      'expirationDate': expirationDate,
      'status': status.value,
      'createdAt': createdAt,
      'updatedAt': updatedAt,
      if (issuedBy != null) 'issuedBy': issuedBy,
      if (notes != null) 'notes': notes,
      if (pdfUrl != null) 'pdfUrl': pdfUrl,
      if (pdfPreviewUrl != null) 'pdfPreviewUrl': pdfPreviewUrl,
      'downloadCount': downloadCount,
      if (lastDownloadedAt != null) 'lastDownloadedAt': lastDownloadedAt,
      'downloadsEnabled': downloadsEnabled,
      if (source != null) 'source': source,
      if (learnerUid != null) 'learnerUid': learnerUid,
      if (recordedCertId != null) 'recordedCertId': recordedCertId,
      if (certificateKind != null) 'certificateKind': certificateKind,
      if (courseId != null) 'courseId': courseId,
      if (courseKey != null) 'courseKey': courseKey,
      if (moduleKey != null) 'moduleKey': moduleKey,
      if (instructorName != null) 'instructorName': instructorName,
      'exam_course': examCourse,
      if (cpdHours.isNotEmpty) 'cpd_hours': cpdHours,
      if (shortDescription.isNotEmpty) 'short_description': shortDescription,
    };
  }

  factory Certificate.fromMap(Map<dynamic, dynamic> map, {String? key}) {
    return Certificate(
      key: key,
      cvn: (map['cvn'] ?? '').toString(),
      fullName: (map['fullName'] ?? '').toString(),
      nationalIdNumber: (map['nationalIdNumber'] ?? '').toString(),
      certificateTitle: (map['certificateTitle'] ?? '').toString(),
      trainingDate: (map['trainingDate'] ?? '').toString(),
      expirationDate: (map['expirationDate'] ?? '').toString(),
      status: CertificateStatus.fromValue(
        (map['status'] ?? 'valid').toString(),
      ),
      createdAt: _asInt(map['createdAt']),
      updatedAt: _asInt(map['updatedAt']),
      issuedBy: map['issuedBy']?.toString(),
      notes: map['notes']?.toString(),
      pdfUrl: map['pdfUrl']?.toString(),
      pdfPreviewUrl: map['pdfPreviewUrl']?.toString(),
      downloadCount: _asInt(map['downloadCount']),
      lastDownloadedAt: map['lastDownloadedAt'] == null
          ? null
          : _asInt(map['lastDownloadedAt']),
      downloadsEnabled: map['downloadsEnabled'] == null
          ? true
          : map['downloadsEnabled'] == true,
      source: map['source']?.toString(),
      learnerUid: map['learnerUid']?.toString(),
      recordedCertId: map['recordedCertId']?.toString(),
      certificateKind: map['certificateKind']?.toString(),
      courseId: map['courseId']?.toString(),
      courseKey: map['courseKey']?.toString(),
      moduleKey: map['moduleKey']?.toString(),
      instructorName: map['instructorName']?.toString(),
      examCourse: _parseExamCourse(map['exam_course']),
      cpdHours: (map['cpd_hours'] ?? '40').toString(),
      shortDescription: (map['short_description'] ?? '').toString(),
    );
  }

  static String _parseExamCourse(dynamic v) {
    final value = (v ?? '').toString().trim().toLowerCase();
    return value == 'exam' ? 'exam' : 'course';
  }

  static int _asInt(dynamic v) {
    if (v == null) return 0;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString()) ?? 0;
  }

  Certificate copyWith({
    String? key,
    String? cvn,
    String? fullName,
    String? nationalIdNumber,
    String? certificateTitle,
    String? trainingDate,
    String? expirationDate,
    CertificateStatus? status,
    int? createdAt,
    int? updatedAt,
    String? issuedBy,
    String? notes,
    String? pdfUrl,
    String? pdfPreviewUrl,
    int? downloadCount,
    int? lastDownloadedAt,
    bool? downloadsEnabled,
    String? source,
    String? learnerUid,
    String? recordedCertId,
    String? certificateKind,
    String? courseId,
    String? courseKey,
    String? moduleKey,
    String? instructorName,
    String? examCourse,
    String? cpdHours,
    String? shortDescription,
  }) {
    return Certificate(
      key: key ?? this.key,
      cvn: cvn ?? this.cvn,
      fullName: fullName ?? this.fullName,
      nationalIdNumber: nationalIdNumber ?? this.nationalIdNumber,
      certificateTitle: certificateTitle ?? this.certificateTitle,
      trainingDate: trainingDate ?? this.trainingDate,
      expirationDate: expirationDate ?? this.expirationDate,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      issuedBy: issuedBy ?? this.issuedBy,
      notes: notes ?? this.notes,
      pdfUrl: pdfUrl ?? this.pdfUrl,
      pdfPreviewUrl: pdfPreviewUrl ?? this.pdfPreviewUrl,
      downloadCount: downloadCount ?? this.downloadCount,
      lastDownloadedAt: lastDownloadedAt ?? this.lastDownloadedAt,
      downloadsEnabled: downloadsEnabled ?? this.downloadsEnabled,
      source: source ?? this.source,
      learnerUid: learnerUid ?? this.learnerUid,
      recordedCertId: recordedCertId ?? this.recordedCertId,
      certificateKind: certificateKind ?? this.certificateKind,
      courseId: courseId ?? this.courseId,
      courseKey: courseKey ?? this.courseKey,
      moduleKey: moduleKey ?? this.moduleKey,
      instructorName: instructorName ?? this.instructorName,
      examCourse: _parseExamCourse(examCourse ?? this.examCourse),
      cpdHours: cpdHours ?? this.cpdHours,
      shortDescription: shortDescription ?? this.shortDescription,
    );
  }

  String get maskedNationalId {
    if (nationalIdNumber.length <= 4) return nationalIdNumber;
    return '****${nationalIdNumber.substring(nationalIdNumber.length - 4)}';
  }

  bool get isExpired {
    if (status == CertificateStatus.revoked) return false;
    try {
      final parts = expirationDate.split('-');
      if (parts.length != 3) return false;
      final expDate = DateTime(
        int.parse(parts[0]),
        int.parse(parts[1]),
        int.parse(parts[2]),
      );
      return DateTime.now().isAfter(expDate);
    } catch (_) {
      return false;
    }
  }

  CertificateStatus get effectiveStatus {
    if (status == CertificateStatus.revoked) {
      return CertificateStatus.revoked;
    }
    if (isExpired) {
      return CertificateStatus.expired;
    }
    return status;
  }

  bool get needsAutoExpire {
    return status == CertificateStatus.valid && isExpired;
  }
}
