import 'dart:convert';

import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_core/firebase_core.dart' show FirebaseException;
import 'package:http/http.dart' as http;
import '../models/certificate_model.dart';

class CertificateServiceException implements Exception {
  final String message;
  final bool isPermissionError;

  CertificateServiceException(this.message, {this.isPermissionError = false});

  @override
  String toString() => message;
}

class CertificateService {
  static const String _certificatesPath = 'certificates';
  static const String _usersPath = 'users';
  static const String _recordedCertificatesPath = 'recorded_certificates';
  static const String _cvnIndexPath = 'certificate_cvn_index';
  static const String _prefix = 'DZ01SB';
  static const String _downloadPingUrl =
      'https://www.yourbridgeschool.com/app/secure/certificate_download_ping.php';

  final FirebaseDatabase _db = FirebaseDatabase.instance;

  DatabaseReference get _certificatesRef => _db.ref(_certificatesPath);
  DatabaseReference get _usersRef => _db.ref(_usersPath);
  DatabaseReference get _cvnIndexRef => _db.ref(_cvnIndexPath);

  String _cvnFromKey(String key, {required int nowMs}) {
    final year = DateTime.fromMillisecondsSinceEpoch(nowMs).year;
    final hash = key.codeUnits.fold<int>(
      0,
      (a, b) => (a * 31 + b) & 0x7fffffff,
    );
    final sequence = (hash % 100000).toString().padLeft(5, '0');
    return '$_prefix-$year-$sequence';
  }

  String _cvnFromRecordedId({
    required String learnerUid,
    required String certId,
    required int nowMs,
  }) {
    final year = DateTime.fromMillisecondsSinceEpoch(nowMs).year;
    final seed = '$learnerUid|$certId';
    final hash = seed.codeUnits.fold<int>(
      0,
      (a, b) => (a * 33 + b) & 0x7fffffff,
    );
    final sequence = (hash % 100000).toString().padLeft(5, '0');
    return '$_prefix-R$year-$sequence';
  }

  DatabaseReference _recordedCertRef(String learnerUid, String certId) {
    return _usersRef
        .child(learnerUid)
        .child(_recordedCertificatesPath)
        .child(certId);
  }

  Future<void> upsertRecordedCvnIndex({
    required String cvn,
    required String learnerUid,
    required String certId,
  }) async {
    await _cvnIndexRef.child(cvn).set({
      'source': 'recorded',
      'learnerUid': learnerUid,
      'certId': certId,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<void> deleteRecordedCvnIndex(String cvn) async {
    final safe = cvn.trim();
    if (safe.isEmpty) return;
    await _cvnIndexRef.child(safe).remove();
  }

  Future<bool> isRecordedCVNUnique(
    String cvn, {
    String? learnerUid,
    String? certId,
  }) async {
    final existingGlobal = await getCertificateByCVN(cvn);
    if (existingGlobal != null && existingGlobal.source != 'recorded') {
      return false;
    }

    final idxSnap = await _cvnIndexRef.child(cvn).get();
    if (!idxSnap.exists || idxSnap.value is! Map) return true;
    final m = Map<String, dynamic>.from(idxSnap.value as Map);
    final sameLearner =
        (m['learnerUid'] ?? '').toString() == (learnerUid ?? '');
    final sameCert = (m['certId'] ?? '').toString() == (certId ?? '');
    return sameLearner && sameCert;
  }

  Future<bool> isCVNUnique(String cvn, {String? excludeKey}) async {
    try {
      final snapshot = await _certificatesRef
          .orderByChild('cvn')
          .equalTo(cvn)
          .get();

      if (snapshot.value != null && snapshot.value is Map) {
        final map = snapshot.value as Map;
        if (excludeKey != null) {
          return !map.keys.any((k) => k.toString() != excludeKey);
        }
        return map.isEmpty;
      }
      return true;
    } catch (e) {
      return true;
    }
  }

  Future<void> attachGeneratedPdf(String key, Certificate cert) async {
    try {
      await _certificatesRef.child(key).update({
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      });
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') {
        throw CertificateServiceException(
          'Permission denied. Please ensure you are logged in as an admin or teacher.',
          isPermissionError: true,
        );
      }
      throw CertificateServiceException(
        'Failed to update certificate: ${e.message}',
      );
    }
  }

  Future<void> incrementDownloadCount(String key, {String? cvn}) async {
    final k = key.trim();
    if (k.isEmpty) return;

    final response = await http
        .post(
          Uri.parse(_downloadPingUrl),
          headers: const {'Content-Type': 'application/json'},
          body: json.encode({
            'certificateKey': k,
            if ((cvn ?? '').trim().isNotEmpty) 'cvn': cvn!.trim(),
          }),
        )
        .timeout(const Duration(seconds: 12));

    final raw = response.body.trim();
    if (!raw.startsWith('{')) {
      throw CertificateServiceException('Invalid server response.');
    }

    final data = json.decode(raw);
    if (data is! Map<String, dynamic>) {
      throw CertificateServiceException('Invalid server response.');
    }

    if (data['success'] != true) {
      final msg = (data['message'] ?? 'Could not update download count')
          .toString();
      throw CertificateServiceException(msg);
    }
  }

  Future<Certificate> createCertificateWithPdf(Certificate draft) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final newRef = _certificatesRef.push();
    final key = newRef.key;
    if (key == null || key.isEmpty) {
      throw CertificateServiceException('Failed to allocate certificate key');
    }

    try {
      var cvn = _cvnFromKey(key, nowMs: now);
      var unique = await isCVNUnique(cvn);
      if (!unique) {
        final fallbackSeq = (now % 100000).toString().padLeft(5, '0');
        cvn = '$_prefix-${DateTime.now().year}-$fallbackSeq';
        unique = await isCVNUnique(cvn);
      }
      if (!unique) {
        throw CertificateServiceException(
          'Could not allocate unique CVN. Please retry.',
        );
      }

      final certBase = draft.copyWith(
        key: key,
        cvn: cvn,
        createdAt: now,
        updatedAt: now,
        downloadCount: 0,
      );

      await newRef.set(certBase.toMap());
      return certBase;
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') {
        throw CertificateServiceException(
          'Permission denied. Please ensure you are logged in as an admin or teacher.',
          isPermissionError: true,
        );
      }
      throw CertificateServiceException(
        'Failed to create certificate: ${e.message}',
      );
    } on CertificateServiceException {
      rethrow;
    } catch (e) {
      throw CertificateServiceException('Failed to create certificate: $e');
    }
  }

  Future<void> updateCertificate(String key, Certificate cert) async {
    try {
      final isUnique = await isCVNUnique(cert.cvn, excludeKey: key);
      if (!isUnique) {
        throw CertificateServiceException('CVN already exists');
      }

      await _certificatesRef.child(key).update(cert.toMap());
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') {
        throw CertificateServiceException(
          'Permission denied. Please ensure you are logged in as an admin or teacher.',
          isPermissionError: true,
        );
      }
      throw CertificateServiceException(
        'Failed to update certificate: ${e.message}',
      );
    }
  }

  Future<void> deleteCertificate(String key) async {
    try {
      await _certificatesRef.child(key).remove();
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') {
        throw CertificateServiceException(
          'Permission denied. Please ensure you are logged in as an admin or teacher.',
          isPermissionError: true,
        );
      }
      throw CertificateServiceException(
        'Failed to delete certificate: ${e.message}',
      );
    }
  }

  Future<Certificate?> getCertificateByKey(String key) async {
    try {
      final snapshot = await _certificatesRef.child(key).get();
      if (snapshot.value != null && snapshot.value is Map) {
        return Certificate.fromMap(
          snapshot.value as Map<dynamic, dynamic>,
          key: key,
        );
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  Future<Certificate?> getCertificateByCVN(String cvn) async {
    try {
      final snapshot = await _certificatesRef
          .orderByChild('cvn')
          .equalTo(cvn)
          .get();

      if (snapshot.value != null && snapshot.value is Map) {
        final map = snapshot.value as Map;
        if (map.isNotEmpty) {
          final firstKey = map.keys.first.toString();
          final firstValue = map.values.first;
          if (firstValue is Map) {
            return Certificate.fromMap(firstValue, key: firstKey);
          }
        }
      }

      final idxSnap = await _cvnIndexRef.child(cvn).get();
      if (idxSnap.exists && idxSnap.value is Map) {
        final idx = Map<String, dynamic>.from(idxSnap.value as Map);
        final learnerUid = (idx['learnerUid'] ?? '').toString().trim();
        final certId = (idx['certId'] ?? '').toString().trim();
        if (learnerUid.isNotEmpty && certId.isNotEmpty) {
          final rec = await getRecordedCertificateByPath(
            learnerUid: learnerUid,
            certId: certId,
          );
          if (rec != null) {
            return rec.certificate;
          }
        }
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  Stream<DatabaseEvent> watchAllCertificates() {
    return _certificatesRef.orderByChild('createdAt').onValue;
  }

  Future<void> syncExpiredCertificates() async {
    try {
      final snapshot = await _certificatesRef.get();

      if (snapshot.value == null || snapshot.value is! Map) return;

      final map = snapshot.value as Map;
      final updates = <String, dynamic>{};

      map.forEach((key, value) {
        if (value is Map) {
          final cert = Certificate.fromMap(value, key: key.toString());
          if (cert.needsAutoExpire) {
            updates['$key/status'] = CertificateStatus.expired.value;
            updates['$key/updatedAt'] = DateTime.now().millisecondsSinceEpoch;
          }
        }
      });

      if (updates.isNotEmpty) {
        await _certificatesRef.update(updates);
      }
    } catch (e) {
      // Silent fail for background sync
    }
  }

  Future<List<Certificate>> getAllCertificates() async {
    try {
      await syncExpiredCertificates();

      final snapshot = await _certificatesRef.get();
      final List<Certificate> certs = [];

      if (snapshot.value != null && snapshot.value is Map) {
        final map = snapshot.value as Map;
        map.forEach((key, value) {
          if (value is Map) {
            certs.add(Certificate.fromMap(value, key: key.toString()));
          }
        });
      }

      certs.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return certs;
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') {
        throw CertificateServiceException(
          'Permission denied. Please ensure you are logged in as an admin or teacher.',
          isPermissionError: true,
        );
      }
      rethrow;
    }
  }

  Future<List<RecordedCertificateEntry>> getAllRecordedCertificates() async {
    final out = <RecordedCertificateEntry>[];
    final usersSnap = await _usersRef.get();
    if (!usersSnap.exists || usersSnap.value is! Map) return out;

    final users = usersSnap.value as Map;
    users.forEach((uidRaw, userRaw) {
      if (userRaw is! Map) return;
      final uid = uidRaw.toString();
      final user = Map<String, dynamic>.from(userRaw);
      final node = user[_recordedCertificatesPath];
      if (node is! Map) return;

      final certs = Map<dynamic, dynamic>.from(node);
      certs.forEach((certIdRaw, certRaw) {
        if (certRaw is! Map) return;
        final certId = certIdRaw.toString();
        final cert = Certificate.fromMap(
          certRaw,
          key: certId,
        ).copyWith(source: 'recorded', learnerUid: uid, recordedCertId: certId);
        out.add(
          RecordedCertificateEntry(
            learnerUid: uid,
            certId: certId,
            certificate: cert,
          ),
        );
      });
    });

    out.sort(
      (a, b) => b.certificate.createdAt.compareTo(a.certificate.createdAt),
    );
    return out;
  }

  Future<RecordedCertificateEntry?> getRecordedCertificateByPath({
    required String learnerUid,
    required String certId,
  }) async {
    final snap = await _recordedCertRef(learnerUid, certId).get();
    if (!snap.exists || snap.value is! Map) return null;
    final cert = Certificate.fromMap(snap.value as Map, key: certId).copyWith(
      source: 'recorded',
      learnerUid: learnerUid,
      recordedCertId: certId,
    );
    return RecordedCertificateEntry(
      learnerUid: learnerUid,
      certId: certId,
      certificate: cert,
    );
  }

  Future<Certificate> issueRecordedCertificate({
    required String learnerUid,
    required String certId,
    required String fullName,
    required String nationalIdNumber,
    required String certificateTitle,
    required String trainingDate,
    required String expirationDate,
    required String courseId,
    required String courseKey,
    required String kind,
    required String instructorName,
    String? moduleKey,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = await getRecordedCertificateByPath(
      learnerUid: learnerUid,
      certId: certId,
    );

    var cvn = existing?.certificate.cvn ?? '';
    if (cvn.isEmpty) {
      cvn = _cvnFromRecordedId(
        learnerUid: learnerUid,
        certId: certId,
        nowMs: now,
      );
      var unique = await isRecordedCVNUnique(
        cvn,
        learnerUid: learnerUid,
        certId: certId,
      );
      if (!unique) {
        final fallbackSeq = (now % 100000).toString().padLeft(5, '0');
        cvn = '$_prefix-R${DateTime.now().year}-$fallbackSeq';
        unique = await isRecordedCVNUnique(
          cvn,
          learnerUid: learnerUid,
          certId: certId,
        );
      }
      if (!unique) {
        throw CertificateServiceException(
          'Could not allocate unique CVN. Please retry.',
        );
      }
    }

    bool looksBrokenInstructor(String value) {
      final v = value.trim().toLowerCase();
      return v.contains('{') ||
          v.contains('uid:') ||
          v.contains('teacheruid') ||
          v.contains('teacher_uid');
    }

    final incomingInstructor = instructorName.trim();
    final existingInstructor = (existing?.certificate.instructorName ?? '')
        .trim();
    final chosenInstructor =
        incomingInstructor.isNotEmpty &&
            !looksBrokenInstructor(incomingInstructor)
        ? incomingInstructor
        : (existingInstructor.isNotEmpty &&
                  !looksBrokenInstructor(existingInstructor)
              ? existingInstructor
              : incomingInstructor.isNotEmpty
              ? incomingInstructor
              : existingInstructor);

    final certBase = Certificate(
      key: certId,
      cvn: cvn,
      fullName: existing?.certificate.fullName ?? fullName,
      nationalIdNumber:
          existing?.certificate.nationalIdNumber ?? nationalIdNumber,
      certificateTitle:
          existing?.certificate.certificateTitle ?? certificateTitle,
      trainingDate: existing?.certificate.trainingDate ?? trainingDate,
      expirationDate: existing?.certificate.expirationDate ?? expirationDate,
      status: existing?.certificate.status ?? CertificateStatus.valid,
      createdAt: existing?.certificate.createdAt ?? now,
      updatedAt: now,
      issuedBy: learnerUid,
      notes: existing?.certificate.notes,
      downloadCount: existing?.certificate.downloadCount ?? 0,
      lastDownloadedAt: existing?.certificate.lastDownloadedAt,
      downloadsEnabled: existing?.certificate.downloadsEnabled ?? true,
      source: 'recorded',
      learnerUid: learnerUid,
      recordedCertId: certId,
      certificateKind: existing?.certificate.certificateKind ?? kind,
      courseId: existing?.certificate.courseId ?? courseId,
      courseKey: existing?.certificate.courseKey ?? courseKey,
      moduleKey: existing?.certificate.moduleKey ?? moduleKey,
      instructorName: chosenInstructor,
    );

    await _recordedCertRef(learnerUid, certId).set(certBase.toMap());
    await upsertRecordedCvnIndex(
      cvn: certBase.cvn,
      learnerUid: learnerUid,
      certId: certId,
    );
    return certBase;
  }

  Future<void> updateRecordedCertificate({
    required String learnerUid,
    required String certId,
    required Certificate cert,
  }) async {
    await _recordedCertRef(learnerUid, certId).update(
      cert
          .copyWith(
            source: 'recorded',
            learnerUid: learnerUid,
            recordedCertId: certId,
            updatedAt: DateTime.now().millisecondsSinceEpoch,
          )
          .toMap(),
    );
    await upsertRecordedCvnIndex(
      cvn: cert.cvn,
      learnerUid: learnerUid,
      certId: certId,
    );
  }

  Future<void> deleteRecordedCertificate({
    required String learnerUid,
    required String certId,
    String? cvn,
  }) async {
    await _recordedCertRef(learnerUid, certId).remove();
    final safeCvn = (cvn ?? '').trim();
    if (safeCvn.isNotEmpty) {
      await deleteRecordedCvnIndex(safeCvn);
    }
  }

  Future<void> incrementRecordedDownloadCount({
    required String learnerUid,
    required String certId,
  }) async {
    final ref = _recordedCertRef(learnerUid, certId);
    final snap = await ref.get();
    if (!snap.exists || snap.value is! Map) return;
    final m = Map<String, dynamic>.from(snap.value as Map);
    final current = (m['downloadCount'] is num)
        ? (m['downloadCount'] as num).toInt()
        : int.tryParse((m['downloadCount'] ?? '').toString()) ?? 0;
    await ref.update({
      'downloadCount': current + 1,
      'lastDownloadedAt': DateTime.now().millisecondsSinceEpoch,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<List<Certificate>> searchCertificates({
    String? query,
    CertificateStatus? statusFilter,
    String? titleFilter,
    String? trainingDateFrom,
    String? trainingDateTo,
    String? expirationDateFrom,
    String? expirationDateTo,
  }) async {
    final allCerts = await getAllCertificates();

    return allCerts.where((cert) {
      if (query != null && query.isNotEmpty) {
        final q = query.toLowerCase();
        final matchesName = cert.fullName.toLowerCase().contains(q);
        final matchesCVN = cert.cvn.toLowerCase().contains(q);
        final matchesTitle = cert.certificateTitle.toLowerCase().contains(q);
        final matchesNationalId = cert.nationalIdNumber.contains(q);
        if (!matchesName &&
            !matchesCVN &&
            !matchesTitle &&
            !matchesNationalId) {
          return false;
        }
      }

      if (statusFilter != null) {
        if (cert.effectiveStatus != statusFilter) return false;
      }

      if (titleFilter != null && titleFilter.isNotEmpty) {
        if (cert.certificateTitle.toLowerCase() != titleFilter.toLowerCase()) {
          return false;
        }
      }

      if (trainingDateFrom != null && trainingDateFrom.isNotEmpty) {
        if (cert.trainingDate.compareTo(trainingDateFrom) < 0) return false;
      }

      if (trainingDateTo != null && trainingDateTo.isNotEmpty) {
        if (cert.trainingDate.compareTo(trainingDateTo) > 0) return false;
      }

      if (expirationDateFrom != null && expirationDateFrom.isNotEmpty) {
        if (cert.expirationDate.compareTo(expirationDateFrom) < 0) return false;
      }

      if (expirationDateTo != null && expirationDateTo.isNotEmpty) {
        if (cert.expirationDate.compareTo(expirationDateTo) > 0) return false;
      }

      return true;
    }).toList();
  }

  Future<List<String>> getUniqueCertificateTitles() async {
    try {
      final certs = await getAllCertificates();
      final titles = certs.map((c) => c.certificateTitle).toSet().toList();
      titles.sort();
      return titles;
    } catch (e) {
      return [];
    }
  }

  Future<CertificateVerificationResult> verifyCertificate(String cvn) async {
    final cert = await getCertificateByCVN(cvn);

    if (cert == null) {
      return CertificateVerificationResult(
        found: false,
        message: 'Certificate not found. Please check the CVN and try again.',
        isValid: false,
      );
    }

    final effectiveStatus = cert.effectiveStatus;

    String message;
    switch (effectiveStatus) {
      case CertificateStatus.valid:
        message = 'This certificate is valid and authentic.';
        break;
      case CertificateStatus.expired:
        message = 'This certificate has expired on ${cert.expirationDate}.';
        break;
      case CertificateStatus.revoked:
        message = 'This certificate has been revoked and is no longer valid.';
        break;
    }

    return CertificateVerificationResult(
      found: true,
      certificate: cert,
      message: message,
      isValid: effectiveStatus == CertificateStatus.valid,
    );
  }
}

class CertificateVerificationResult {
  final bool found;
  final Certificate? certificate;
  final String message;
  final bool isValid;

  CertificateVerificationResult({
    required this.found,
    this.certificate,
    required this.message,
    required this.isValid,
  });
}

class RecordedCertificateEntry {
  final String learnerUid;
  final String certId;
  final Certificate certificate;

  RecordedCertificateEntry({
    required this.learnerUid,
    required this.certId,
    required this.certificate,
  });
}
