import 'dart:convert';
import 'dart:typed_data';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../models/certificate_model.dart';
import 'backend_api.dart';

class CertificatePdfService {
  static const String _uploadUrl =
      'https://www.yourbridgeschool.com/app/secure/upload_file_secure.php';

  String _sanitize(String value, {String fallback = 'certificate'}) {
    final cleaned = value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    return cleaned.isEmpty ? fallback : cleaned;
  }

  String _fmtDate(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  pw.TableRow _row(String k, String v) {
    return pw.TableRow(
      children: [
        pw.Container(
          color: PdfColor.fromHex('#F8FAFC'),
          padding: const pw.EdgeInsets.all(8),
          child: pw.Text(
            k,
            style: pw.TextStyle(
              fontWeight: pw.FontWeight.bold,
              color: PdfColor.fromHex('#334155'),
              fontSize: 11,
            ),
          ),
        ),
        pw.Padding(
          padding: const pw.EdgeInsets.all(8),
          child: pw.Text(
            v,
            style: pw.TextStyle(
              color: PdfColor.fromHex('#0F172A'),
              fontSize: 11,
            ),
          ),
        ),
      ],
    );
  }

  Future<Uint8List> generateCertificatePdfBytes(Certificate cert) async {
    final doc = pw.Document();
    pw.MemoryImage? template;
    try {
      final bytes = await rootBundle.load(
        'assets/images/DigitalCertificate.png',
      );
      template = pw.MemoryImage(bytes.buffer.asUint8List());
    } catch (_) {}

    const double pageHeight = 842;

    // Measured bottom-origin Y values converted to top-origin:
    // top = pageHeight - y
    const double learnerNameTop = 322;
    const double courseTitleTop = 444;
    const double issuedDateTop = 548;
    const double instructorTop = 598;
    const double academicDirectorTop = 598;
    const double certificateIdTop = 681;

    final issueDate = cert.createdAt > 0
        ? DateTime.fromMillisecondsSinceEpoch(cert.createdAt)
        : DateTime.now();
    final instructor = (cert.instructorName ?? '').trim().isNotEmpty
        ? cert.instructorName!.trim()
        : 'Seddik. B';

    pw.Widget centeredText({
      required double centerX,
      required double top,
      required double boxWidth,
      required String text,
      required pw.TextStyle style,
    }) {
      return pw.Positioned(
        left: centerX - (boxWidth / 2),
        top: top,
        child: pw.SizedBox(
          width: boxWidth,
          child: pw.Text(text, textAlign: pw.TextAlign.center, style: style),
        ),
      );
    }

    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat(595, pageHeight),
        margin: pw.EdgeInsets.zero,
        build: (_) {
          return pw.Stack(
            children: [
              if (template != null)
                pw.Positioned.fill(
                  child: pw.Image(template, fit: pw.BoxFit.fill),
                ),
              centeredText(
                centerX: 297.5,
                top: learnerNameTop,
                boxWidth: 520,
                text: cert.fullName,
                style: pw.TextStyle(
                  fontSize: 36,
                  fontWeight: pw.FontWeight.bold,
                  color: PdfColor.fromInt(0xFF111827),
                ),
              ),
              centeredText(
                centerX: 297.5,
                top: courseTitleTop,
                boxWidth: 520,
                text: cert.certificateTitle,
                style: pw.TextStyle(
                  fontSize: 24,
                  fontWeight: pw.FontWeight.bold,
                  color: PdfColor.fromInt(0xFF111827),
                ),
              ),
              pw.Positioned(
                left: 322,
                top: issuedDateTop,
                child: pw.Text(
                  _fmtDate(issueDate),
                  style: pw.TextStyle(
                    fontSize: 14,
                    color: PdfColor.fromInt(0xFF1F2937),
                  ),
                ),
              ),
              centeredText(
                centerX: 142,
                top: instructorTop,
                boxWidth: 210,
                text: instructor,
                style: pw.TextStyle(
                  fontSize: 14,
                  color: PdfColor.fromInt(0xFF1F2937),
                ),
              ),
              centeredText(
                centerX: 466,
                top: academicDirectorTop,
                boxWidth: 170,
                text: 'Seddik. B',
                style: pw.TextStyle(
                  fontSize: 14,
                  color: PdfColor.fromInt(0xFF1F2937),
                ),
              ),
              pw.Positioned(
                left: 224,
                top: certificateIdTop,
                child: pw.SizedBox(
                  width: 170,
                  child: pw.Text(
                    cert.cvn,
                    maxLines: 2,
                    style: pw.TextStyle(
                      fontSize: 13,
                      color: PdfColor.fromInt(0xFF111827),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );

    return doc.save();
  }

  Future<String> uploadCertificatePdf({
    required Certificate cert,
    required Uint8List pdfBytes,
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isEmpty) {
      throw Exception('Not logged in.');
    }

    final uri = await BackendApi.withAuthQuery(Uri.parse(_uploadUrl));
    final req = http.MultipartRequest('POST', uri);
    await BackendApi.applyAuthToMultipart(req);

    req.fields['root'] = 'certificates';
    req.fields['path'] = _sanitize(cert.cvn, fallback: 'certificate');
    req.fields['custom_name'] =
        '${_sanitize(cert.cvn, fallback: 'certificate')}.pdf';

    req.files.add(
      http.MultipartFile.fromBytes(
        'file',
        pdfBytes,
        filename: '${_sanitize(cert.cvn, fallback: 'certificate')}.pdf',
      ),
    );

    final streamed = await req.send().timeout(const Duration(minutes: 5));
    final response = await http.Response.fromStream(streamed);
    final raw = response.body.trim();
    if (!raw.startsWith('{')) {
      throw Exception('Server did not return JSON.');
    }

    final data = json.decode(raw);
    if (data is! Map<String, dynamic>) {
      throw Exception('Invalid upload response.');
    }

    if (data['success'] == true) {
      final url = (data['url'] ?? '').toString().trim();
      if (url.isEmpty) {
        throw Exception('Upload succeeded but URL is missing.');
      }
      return url;
    }

    throw Exception((data['message'] ?? 'Upload failed').toString());
  }

  Future<String> uploadCertificatePdfForLearner({
    required Certificate cert,
    required Uint8List pdfBytes,
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (uid.isEmpty) {
      throw Exception('Not logged in.');
    }

    final req = http.MultipartRequest(
      'POST',
      BackendApi.uri('upload_secure.php'),
    );
    await BackendApi.applyAuthToMultipart(req);

    req.fields['app_id'] = 'recorded_certificates_$uid';
    req.files.add(
      http.MultipartFile.fromBytes(
        'file',
        pdfBytes,
        filename: '${_sanitize(cert.cvn, fallback: 'certificate')}.pdf',
      ),
    );

    final streamed = await req.send().timeout(const Duration(minutes: 5));
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Learner upload failed HTTP ${response.statusCode}: ${response.body}',
      );
    }

    dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      throw Exception('Learner upload failed: invalid JSON response');
    }

    if (decoded is! Map || decoded['success'] != true) {
      throw Exception('Learner upload failed: ${response.body}');
    }

    final url = (decoded['url'] ?? '').toString().trim();
    if (url.isEmpty) {
      throw Exception('Learner upload failed: missing URL in response');
    }
    return url;
  }
}
