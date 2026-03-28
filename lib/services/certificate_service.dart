import 'dart:convert';

import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_core/firebase_core.dart' show FirebaseException;
import 'package:http/http.dart' as http;
import '../models/certificate_model.dart';
import 'certificate_pdf_service.dart';

class CertificateServiceException implements Exception {
  final String message;
  final bool isPermissionError;

  CertificateServiceException(this.message, {this.isPermissionError = false});

  @override
  String toString() => message;
}

class CertificateService {
  static const String _certificatesPath = 'certificates';
  static const String _prefix = 'DZ01SB';
  static const String _downloadPingUrl =
      'https://www.yourbridgeschool.com/app/secure/certificate_download_ping.php';

  final FirebaseDatabase _db = FirebaseDatabase.instance;
  final CertificatePdfService _pdfService = CertificatePdfService();

  DatabaseReference get _certificatesRef => _db.ref(_certificatesPath);

  String _cvnFromKey(String key, {required int nowMs}) {
    final year = DateTime.fromMillisecondsSinceEpoch(nowMs).year;
    final hash = key.codeUnits.fold<int>(
      0,
      (a, b) => (a * 31 + b) & 0x7fffffff,
    );
    final sequence = (hash % 100000).toString().padLeft(5, '0');
    return '$_prefix-$year-$sequence';
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
      final bytes = await _pdfService.generateCertificatePdfBytes(cert);
      final url = await _pdfService.uploadCertificatePdf(
        cert: cert,
        pdfBytes: bytes,
      );
      await _certificatesRef.child(key).update({
        'pdfUrl': url,
        'pdfPreviewUrl': url,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (e) {
      throw CertificateServiceException(
        'Certificate PDF generation/upload failed: $e',
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

      final bytes = await _pdfService.generateCertificatePdfBytes(certBase);
      final url = await _pdfService.uploadCertificatePdf(
        cert: certBase,
        pdfBytes: bytes,
      );

      final certFinal = certBase.copyWith(pdfUrl: url, pdfPreviewUrl: url);
      await newRef.set(certFinal.toMap());
      return certFinal;
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
