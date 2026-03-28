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
    pw.MemoryImage? logo;

    try {
      final logoBytes = await rootBundle.load('assets/images/ybs_logo2.png');
      logo = pw.MemoryImage(logoBytes.buffer.asUint8List());
    } catch (_) {
      try {
        final logoBytes = await rootBundle.load('assets/images/ybs_logo.png');
        logo = pw.MemoryImage(logoBytes.buffer.asUint8List());
      } catch (_) {}
    }

    final now = DateTime.now();
    final issueDate = cert.createdAt > 0
        ? DateTime.fromMillisecondsSinceEpoch(cert.createdAt)
        : now;
    final themeBlue = PdfColor.fromHex('#1A2B48');
    final themeGold = PdfColor.fromHex('#C9A74A');
    final softSlate = PdfColor.fromHex('#334155');

    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        build: (context) {
          return pw.Container(
            decoration: pw.BoxDecoration(
              color: PdfColors.white,
              border: pw.Border.all(color: themeBlue, width: 2.2),
            ),
            padding: const pw.EdgeInsets.all(26),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.stretch,
              children: [
                pw.Container(height: 5, color: themeBlue),
                pw.SizedBox(height: 16),
                pw.Row(
                  crossAxisAlignment: pw.CrossAxisAlignment.center,
                  children: [
                    if (logo != null)
                      pw.Container(
                        width: 72,
                        height: 72,
                        margin: const pw.EdgeInsets.only(right: 12),
                        child: pw.Image(logo, fit: pw.BoxFit.contain),
                      ),
                    pw.Expanded(
                      child: pw.Column(
                        crossAxisAlignment: pw.CrossAxisAlignment.start,
                        children: [
                          pw.Text(
                            'Your Bridge School',
                            style: pw.TextStyle(
                              fontSize: 22,
                              fontWeight: pw.FontWeight.bold,
                              color: themeBlue,
                            ),
                          ),
                          pw.SizedBox(height: 4),
                          pw.Text(
                            'Professional Learning & Achievement',
                            style: pw.TextStyle(
                              fontSize: 12,
                              color: PdfColor.fromHex('#475569'),
                            ),
                          ),
                        ],
                      ),
                    ),
                    pw.Container(
                      padding: const pw.EdgeInsets.symmetric(
                        horizontal: 11,
                        vertical: 6,
                      ),
                      decoration: pw.BoxDecoration(
                        border: pw.Border.all(color: themeGold, width: 1),
                        borderRadius: pw.BorderRadius.circular(99),
                        color: PdfColor.fromHex('#FFF9EA'),
                      ),
                      child: pw.Text(
                        'OFFICIAL',
                        style: pw.TextStyle(
                          fontSize: 9,
                          letterSpacing: 1.3,
                          color: PdfColor.fromHex('#8A6A1F'),
                          fontWeight: pw.FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                pw.SizedBox(height: 22),
                pw.Container(
                  padding: const pw.EdgeInsets.symmetric(vertical: 16),
                  decoration: pw.BoxDecoration(
                    color: PdfColor.fromHex('#F8FAFC'),
                    borderRadius: pw.BorderRadius.circular(10),
                    border: pw.Border.all(color: PdfColor.fromHex('#DDE7F2')),
                  ),
                  child: pw.Center(
                    child: pw.Text(
                      cert.certificateTitle,
                      textAlign: pw.TextAlign.center,
                      style: pw.TextStyle(
                        fontSize: 21,
                        fontWeight: pw.FontWeight.bold,
                        color: PdfColor.fromHex('#0F172A'),
                      ),
                    ),
                  ),
                ),
                pw.SizedBox(height: 24),
                pw.Text(
                  'This is to certify that',
                  textAlign: pw.TextAlign.center,
                  style: pw.TextStyle(fontSize: 13, color: softSlate),
                ),
                pw.SizedBox(height: 12),
                pw.Text(
                  cert.fullName,
                  textAlign: pw.TextAlign.center,
                  style: pw.TextStyle(
                    fontSize: 30,
                    fontWeight: pw.FontWeight.bold,
                    color: themeBlue,
                  ),
                ),
                pw.SizedBox(height: 8),
                pw.Container(
                  margin: const pw.EdgeInsets.symmetric(horizontal: 120),
                  height: 1.3,
                  color: themeGold,
                ),
                pw.SizedBox(height: 14),
                pw.Text(
                  'has successfully completed the training requirements and has'
                  ' demonstrated the required competencies.',
                  textAlign: pw.TextAlign.center,
                  style: pw.TextStyle(
                    fontSize: 13,
                    color: PdfColor.fromHex('#475569'),
                  ),
                ),
                pw.SizedBox(height: 22),
                pw.Container(
                  padding: const pw.EdgeInsets.all(10),
                  decoration: pw.BoxDecoration(
                    color: PdfColor.fromHex('#F0F7FF'),
                    borderRadius: pw.BorderRadius.circular(8),
                    border: pw.Border.all(color: PdfColor.fromHex('#C5D9EE')),
                  ),
                  child: pw.Row(
                    children: [
                      pw.Text(
                        'CVN',
                        style: pw.TextStyle(
                          fontWeight: pw.FontWeight.bold,
                          color: PdfColor.fromHex('#0F3A66'),
                          fontSize: 11,
                        ),
                      ),
                      pw.SizedBox(width: 8),
                      pw.Text(
                        cert.cvn,
                        style: pw.TextStyle(
                          color: PdfColor.fromHex('#0F3A66'),
                          fontSize: 13,
                          fontWeight: pw.FontWeight.bold,
                          letterSpacing: 0.4,
                        ),
                      ),
                    ],
                  ),
                ),
                pw.SizedBox(height: 14),
                pw.Table(
                  border: pw.TableBorder.all(
                    color: PdfColor.fromHex('#CBD5E1'),
                    width: 0.8,
                  ),
                  children: [
                    _row('National ID', cert.nationalIdNumber),
                    _row('Training Date', cert.trainingDate),
                    _row('Expiration Date', cert.expirationDate),
                    _row('Issued On', _fmtDate(issueDate)),
                  ],
                ),
                pw.Spacer(),
                pw.Container(height: 1, color: PdfColor.fromHex('#D8E1EB')),
                pw.SizedBox(height: 10),
                pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Container(width: 170, height: 1, color: softSlate),
                        pw.SizedBox(height: 4),
                        pw.Text(
                          'Authorized Signature',
                          style: pw.TextStyle(
                            fontSize: 11,
                            color: PdfColor.fromHex('#475569'),
                          ),
                        ),
                      ],
                    ),
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.end,
                      children: [
                        pw.Text(
                          'Generated ${_fmtDate(now)}',
                          style: pw.TextStyle(
                            fontSize: 10,
                            color: PdfColor.fromHex('#64748B'),
                          ),
                        ),
                        pw.SizedBox(height: 3),
                        pw.Text(
                          'Verify at: yourbridgeschool.com',
                          style: pw.TextStyle(
                            fontSize: 9,
                            color: PdfColor.fromHex('#64748B'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                pw.SizedBox(height: 10),
                pw.Center(
                  child: pw.Text(
                    'This document is digitally generated and valid without a physical seal.',
                    style: pw.TextStyle(
                      fontSize: 8.5,
                      color: PdfColor.fromHex('#94A3B8'),
                    ),
                    textAlign: pw.TextAlign.center,
                  ),
                ),
                pw.SizedBox(height: 2),
                pw.Container(height: 5, color: themeBlue),
              ],
            ),
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
}
