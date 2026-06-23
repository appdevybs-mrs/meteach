import 'dart:typed_data';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../models/admin_certificate_model.dart';
import '../models/certificate_model.dart';

class HardcopyCertificateInput {
  final String directorName;
  final DateTime examinationDate;
  final String grade;
  final String councilLevel;
  final int overallScore;

  const HardcopyCertificateInput({
    required this.directorName,
    required this.examinationDate,
    required this.grade,
    required this.councilLevel,
    required this.overallScore,
  });
}

class CertificatePdfService {
  static const int _templateRasterDpi = 300;
  static const String _academicDirectorFallback = "Abdelkader B'";
  static final DatabaseReference _appConfigRoot = FirebaseDatabase.instance.ref(
    'appConfig',
  );

  static String buildPdfFileName(Certificate cert) {
    final title = _sanitizeFileNamePart(
      cert.certificateTitle,
      fallback: 'certificate',
    );
    final cvn = _sanitizeFileNamePart(cert.cvn, fallback: 'cvn');
    return 'YBS_${title}_$cvn.pdf';
  }

  static String buildHardcopyPdfFileName(Certificate cert) {
    final title = _sanitizeFileNamePart(
      cert.certificateTitle,
      fallback: 'certificate',
    );
    final cvn = _sanitizeFileNamePart(cert.cvn, fallback: 'cvn');
    return 'YBS_${title}_${cvn}_hardcopy.pdf';
  }

  static String _sanitizeFileNamePart(String raw, {required String fallback}) {
    final cleaned = raw
        .trim()
        .replaceAll(RegExp(r'\s+'), '_')
        .replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    if (cleaned.isEmpty) return fallback;
    return cleaned;
  }

  String _fmtDate(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  Future<pw.MemoryImage?> _loadPdfTemplate(String assetPath) async {
    try {
      final pdfBytes = await rootBundle.load(assetPath);
      await for (final page in Printing.raster(
        pdfBytes.buffer.asUint8List(),
        pages: const [0],
        dpi: _templateRasterDpi.toDouble(),
      )) {
        final rasterBytes = await page.toPng();
        return pw.MemoryImage(rasterBytes);
      }
    } catch (_) {}
    return null;
  }

  static dynamic _valueByAliases(
    Map<String, dynamic> map,
    List<String> aliases,
  ) {
    final normalized = <String, dynamic>{};
    map.forEach((k, v) {
      normalized[k.toString().toLowerCase().replaceAll(
            RegExp(r'[^a-z0-9]'),
            '',
          )] =
          v;
    });

    for (final alias in aliases) {
      final key = alias.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
      if (normalized.containsKey(key)) return normalized[key];
    }
    return null;
  }

  Future<String> _resolveAcademicDirectorName() async {
    const paths = ['Company info', 'companyInfo'];
    const aliases = [
      'academicDirectorName',
      'academic director name',
      'academic_director_name',
      'directorName',
    ];

    try {
      for (final path in paths) {
        final snap = await _appConfigRoot.child(path).get();
        if (snap.value is! Map) continue;
        final map = (snap.value as Map).map(
          (k, v) => MapEntry(k.toString(), v),
        );
        final resolved = _valueByAliases(map, aliases)?.toString().trim() ?? '';
        if (resolved.isNotEmpty) return resolved;
      }
    } catch (_) {}

    return _academicDirectorFallback;
  }

  Future<Uint8List> generateCertificatePdfBytes(Certificate cert) async {
    final doc = pw.Document();
    const double pageHeight = 842;

    final isExam = cert.examCourse == 'exam';
    if (isExam) {
      return _generateExamCertificatePdfBytes(cert, doc);
    }

    final template = await _loadPdfTemplate('assets/images/cpd.pdf');
    final issueDate = cert.createdAt > 0
        ? DateTime.fromMillisecondsSinceEpoch(cert.createdAt)
        : DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final dateStr =
        '${two(issueDate.day)}-${two(issueDate.month)}-${issueDate.year}';

    final cpdHours = cert.cpdHours.trim();
    final showCpd = cpdHours.isNotEmpty;
    final showDescription = cert.shortDescription.trim().isNotEmpty;

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
              pw.Positioned(
                left: 66,
                top: 255,
                child: pw.Text(
                  cert.fullName.toUpperCase(),
                  style: pw.TextStyle(
                    fontSize: 22,
                    font: pw.Font.helveticaBold(),
                    color: PdfColor.fromInt(0xFF111827),
                  ),
                ),
              ),
              pw.Positioned(
                left: 64,
                top: 444.5,
                child: pw.Text(
                  cert.certificateTitle.toUpperCase(),
                  style: pw.TextStyle(
                    fontSize: 14,
                    font: pw.Font.helveticaBold(),
                    color: PdfColor.fromInt(0xFF111827),
                  ),
                ),
              ),
              if (showCpd)
                pw.Positioned(
                  left: 64,
                  top: 471.5,
                  child: pw.Text(
                    '$cpdHours Hours of Continuing Professional Development (CPD)',
                    style: pw.TextStyle(
                      fontSize: 10,
                      font: pw.Font.helveticaBold(),
                      color: PdfColor.fromInt(0xFF111827),
                    ),
                  ),
                ),
              if (showDescription)
                pw.Positioned(
                  left: 64,
                  top: 507,
                  child: pw.SizedBox(
                    width: 460,
                    child: pw.Text(
                      cert.shortDescription.trim(),
                      style: pw.TextStyle(
                        fontSize: 9,
                        font: pw.Font.helvetica(),
                        color: PdfColor.fromInt(0xFF111827),
                      ),
                    ),
                  ),
                ),
              pw.Positioned(
                left: 216,
                top: 639,
                child: pw.Text(
                  cert.cvn.toUpperCase(),
                  style: pw.TextStyle(
                    fontSize: 8,
                    font: pw.Font.helvetica(),
                    color: PdfColor.fromInt(0xFF111827),
                  ),
                ),
              ),
              pw.Positioned(
                left: 469,
                top: 766,
                child: pw.Text(
                  dateStr,
                  style: pw.TextStyle(
                    fontSize: 8,
                    font: pw.Font.helvetica(),
                    color: PdfColor.fromInt(0xFF111827),
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

  Future<Uint8List> _generateExamCertificatePdfBytes(
    Certificate cert,
    pw.Document doc,
  ) async {
    pw.MemoryImage? template;

    template = await _loadPdfTemplate('assets/images/digital_cert_exam.pdf');
    const double pageHeight = 842;

    const double learnerNameTop = 322;
    const double courseTitleTop = 444;
    const double issuedDateTop = 565.00;
    const double instructorTop = 598;
    const double academicDirectorTop = 598;
    const double certificateIdTop = 692.34;

    final issueDate = cert.createdAt > 0
        ? DateTime.fromMillisecondsSinceEpoch(cert.createdAt)
        : DateTime.now();
    final instructor = (cert.instructorName ?? '').trim().isNotEmpty
        ? cert.instructorName!.trim()
        : 'Seddik. B';
    final academicDirectorName = await _resolveAcademicDirectorName();

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
                  font: pw.Font.helveticaBold(),
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
                  font: pw.Font.helveticaBold(),
                  color: PdfColor.fromInt(0xFF111827),
                ),
              ),
              pw.Positioned(
                left: 313.50,
                top: issuedDateTop,
                child: pw.Text(
                  _fmtDate(issueDate),
                  style: pw.TextStyle(
                    fontSize: 14,
                    font: pw.Font.helvetica(),
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
                  font: pw.Font.helveticaBold(),
                  color: PdfColor.fromInt(0xFF1F2937),
                ),
              ),
              centeredText(
                centerX: 466,
                top: academicDirectorTop,
                boxWidth: 170,
                text: academicDirectorName,
                style: pw.TextStyle(
                  fontSize: 14,
                  font: pw.Font.helveticaBold(),
                  color: PdfColor.fromInt(0xFF1F2937),
                ),
              ),
              pw.Positioned(
                left: 218.33,
                top: certificateIdTop,
                child: pw.SizedBox(
                  width: 170,
                  child: pw.Text(
                    cert.cvn.toUpperCase(),
                    maxLines: 2,
                    style: pw.TextStyle(
                      fontSize: 12,
                      font: pw.Font.helvetica(),
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

  Future<Uint8List> generateMilestoneCertificatePdfBytes({
    required Certificate cert,
    required String moduleLabel,
  }) async {
    final doc = pw.Document();
    final template = await _loadPdfTemplate('assets/images/milestone.pdf');
    const double pageHeight = 842;

    final issueDate = cert.createdAt > 0
        ? DateTime.fromMillisecondsSinceEpoch(cert.createdAt)
        : DateTime.now();

    // Bottom-origin Y → top-origin: top = pageHeight - y
    const double fullNameY = 270; // bottom 572
    const double courseTitleY = 472.5; // bottom 369.5 (0.5px up)
    const double moduleLabelY = 499.5; // bottom 342.5 (0.5px up)
    const double cvnY = 640; // bottom 202 (8px up)
    const double timestampY = 751; // bottom 91 (16px up)

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
              pw.Positioned(
                left: 66,
                top: fullNameY,
                child: pw.Text(
                  cert.fullName.toUpperCase(),
                  style: pw.TextStyle(
                    fontSize: 22,
                    font: pw.Font.helveticaBold(),
                    color: PdfColor.fromInt(0xFF111827),
                  ),
                ),
              ),
              pw.Positioned(
                left: 64,
                top: courseTitleY,
                child: pw.Text(
                  cert.certificateTitle.toUpperCase(),
                  style: pw.TextStyle(
                    fontSize: 14,
                    font: pw.Font.helveticaBold(),
                    color: PdfColor.fromInt(0xFF111827),
                  ),
                ),
              ),
              pw.Positioned(
                left: 64,
                top: moduleLabelY,
                child: pw.Text(
                  moduleLabel,
                  style: pw.TextStyle(
                    fontSize: 10,
                    font: pw.Font.helveticaBold(),
                    color: PdfColor.fromInt(0xFF111827),
                  ),
                ),
              ),
              pw.Positioned(
                left: 216,
                top: cvnY,
                child: pw.Text(
                  cert.cvn.toUpperCase(),
                  style: pw.TextStyle(
                    fontSize: 8,
                    font: pw.Font.helvetica(),
                    color: PdfColor.fromInt(0xFF111827),
                  ),
                ),
              ),
              pw.Positioned(
                left: 469,
                top: timestampY,
                child: pw.Text(
                  () {
                    String two(int n) => n.toString().padLeft(2, '0');
                    return '${two(issueDate.day)}-${two(issueDate.month)}-${issueDate.year}';
                  }(),
                  style: pw.TextStyle(
                    fontSize: 8,
                    font: pw.Font.helvetica(),
                    color: PdfColor.fromInt(0xFF111827),
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

  Future<Uint8List> generateHardcopyCertificatePdfBytes({
    required Certificate cert,
    required HardcopyCertificateInput input,
  }) async {
    final doc = pw.Document();
    final template = await _loadPdfTemplate(
      'assets/images/certificate_template.pdf',
    );

    final issueDate = cert.createdAt > 0
        ? DateTime.fromMillisecondsSinceEpoch(cert.createdAt)
        : DateTime.now();

    const double pageWidth = 595.32;
    const double pageHeight = 841.92;
    const double hardcopyLearnerNameTop = 208;
    const double hardcopyGradeTop = 276;
    const double hardcopyCouncilLevelTop = 407;
    const double hardcopyOverallScoreTop = 441;
    const double hardcopyExamDateTop = 586;
    const double hardcopyCvnTop = 586;
    const double hardcopyIssueDateTop = 586;
    const double hardcopyDirectorTop = 694;

    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat(pageWidth, pageHeight),
        margin: pw.EdgeInsets.zero,
        build: (_) {
          return pw.Stack(
            children: [
              if (template != null)
                pw.Positioned.fill(
                  child: pw.Image(template, fit: pw.BoxFit.fill),
                ),
              pw.Positioned(
                left: 64,
                top: hardcopyLearnerNameTop,
                child: pw.SizedBox(
                  width: 500,
                  child: pw.Text(
                    cert.fullName,
                    style: pw.TextStyle(
                      fontSize: 20,
                      fontWeight: pw.FontWeight.bold,
                      font: pw.Font.helveticaBold(),
                      color: PdfColor.fromInt(0xFF111827),
                    ),
                  ),
                ),
              ),
              pw.Positioned(
                left: 118,
                top: hardcopyGradeTop,
                child: pw.Text(
                  input.grade.toUpperCase(),
                  style: pw.TextStyle(
                    fontSize: 14,
                    font: pw.Font.helveticaBold(),
                    color: PdfColor.fromInt(0xFFD35400),
                  ),
                ),
              ),
              pw.Positioned(
                left: 208,
                top: hardcopyCouncilLevelTop,
                child: pw.Text(
                  input.councilLevel,
                  style: pw.TextStyle(
                    fontSize: 14,
                    font: pw.Font.helveticaBold(),
                    color: PdfColor.fromInt(0xFF111827),
                  ),
                ),
              ),
              pw.Positioned(
                left: 142,
                top: hardcopyOverallScoreTop,
                child: pw.Text(
                  '${input.overallScore}',
                  style: pw.TextStyle(
                    fontSize: 14,
                    font: pw.Font.helveticaBold(),
                    color: PdfColor.fromInt(0xFF111827),
                  ),
                ),
              ),
              pw.Positioned(
                left: 150,
                top: hardcopyExamDateTop,
                child: pw.Text(
                  _fmtDate(input.examinationDate),
                  style: pw.TextStyle(
                    fontSize: 10,
                    font: pw.Font.helvetica(),
                    color: PdfColor.fromInt(0xFF111827),
                  ),
                ),
              ),
              pw.Positioned(
                left: 292,
                top: hardcopyCvnTop,
                child: pw.Text(
                  cert.cvn,
                  style: pw.TextStyle(
                    fontSize: 10,
                    font: pw.Font.helvetica(),
                    color: PdfColor.fromInt(0xFF111827),
                  ),
                ),
              ),
              pw.Positioned(
                left: 498,
                top: hardcopyIssueDateTop,
                child: pw.Text(
                  _fmtDate(issueDate),
                  style: pw.TextStyle(
                    fontSize: 10,
                    font: pw.Font.helvetica(),
                    color: PdfColor.fromInt(0xFF111827),
                  ),
                ),
              ),
              pw.Positioned(
                left: 64,
                top: hardcopyDirectorTop,
                child: pw.SizedBox(
                  width: 220,
                  child: pw.Text(
                    input.directorName,
                    style: pw.TextStyle(
                      fontSize: 12,
                      font: pw.Font.helveticaBold(),
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

  Future<Uint8List> generateAdminEflPdfBytes(AdminCertificate cert) async {
    final doc = pw.Document();
    final template = await _loadPdfTemplate(
      cert.grade.isNotEmpty
          ? 'assets/images/cpdgraded.pdf'
          : 'assets/images/cpd.pdf',
    );

    const double pageWidth = 596;
    const double pageHeight = 842;

    const PdfColor deepBlue = PdfColor.fromInt(0xFF0D1B2A);

    String fmtDdMmYyyy(String v) {
      if (v.isEmpty) return '';
      try {
        final parts = v.split('-');
        if (parts.length != 3) return v;
        final d = DateTime(
          int.parse(parts[0]),
          int.parse(parts[1]),
          int.parse(parts[2]),
        );
        String two(int n) => n.toString().padLeft(2, '0');
        return '${two(d.day)}-${two(d.month)}-${d.year}';
      } catch (_) {
        return v;
      }
    }

    doc.addPage(
      pw.Page(
        pageFormat: PdfPageFormat(pageWidth, pageHeight),
        margin: pw.EdgeInsets.zero,
        build: (_) {
          return pw.Stack(
            children: [
              if (template != null)
                pw.Positioned.fill(
                  child: pw.Image(template, fit: pw.BoxFit.fill),
                ),
              pw.Positioned(
                left: 66,
                top: 260,
                child: pw.SizedBox(
                  width: 320,
                  child: pw.Text(
                    cert.fullName.trim().toUpperCase(),
                    style: pw.TextStyle(
                      fontSize: 26,
                      fontWeight: pw.FontWeight.bold,
                      font: pw.Font.helveticaBold(),
                      color: deepBlue,
                    ),
                  ),
                ),
              ),
              if (cert.grade.isNotEmpty)
                pw.Positioned(
                  left: 112,
                  top: 353,
                  child: pw.SizedBox(
                    width: 320,
                    child: pw.Text(
                      cert.grade.toUpperCase(),
                      style: pw.TextStyle(
                        fontSize: 15,
                        fontWeight: pw.FontWeight.bold,
                        font: pw.Font.helveticaBold(),
                        color: deepBlue,
                      ),
                    ),
                  ),
                ),
              pw.Positioned(
                left: 63,
                top: 449,
                child: pw.SizedBox(
                  width: 320,
                  child: pw.Text(
                    cert.certificateName,
                    style: pw.TextStyle(
                      fontSize: 14,
                      fontWeight: pw.FontWeight.bold,
                      font: pw.Font.helveticaBold(),
                      color: deepBlue,
                    ),
                  ),
                ),
              ),
              if (cert.subline.isNotEmpty)
                pw.Positioned(
                  left: 63,
                  top: 471,
                  child: pw.SizedBox(
                    width: 320,
                    child: pw.Text(
                      cert.subline,
                      style: pw.TextStyle(
                        fontSize: 10,
                        fontWeight: pw.FontWeight.bold,
                        font: pw.Font.helveticaBold(),
                        color: deepBlue,
                      ),
                    ),
                  ),
                ),
              if (cert.description.isNotEmpty)
                pw.Positioned(
                  left: 63,
                  top: 502,
                  child: pw.SizedBox(
                    width: 483,
                    child: pw.Text(
                      cert.description,
                      textAlign: pw.TextAlign.justify,
                      style: pw.TextStyle(
                        fontSize: 10,
                        font: pw.Font.helvetica(),
                        color: deepBlue,
                      ),
                    ),
                  ),
                ),
              pw.Positioned(
                left: 469,
                top: 780,
                child: pw.SizedBox(
                  width: 160,
                  child: pw.Text(
                    fmtDdMmYyyy(cert.issueDate),
                    style: pw.TextStyle(
                      fontSize: 8,
                      font: pw.Font.helvetica(),
                      color: deepBlue,
                    ),
                  ),
                ),
              ),
              if (cert.cvn.isNotEmpty)
                pw.Positioned(
                  left: 216,
                  top: 638,
                  child: pw.SizedBox(
                    width: 160,
                    child: pw.Text(
                      cert.cvn,
                      style: pw.TextStyle(
                        fontSize: 8,
                        font: pw.Font.helvetica(),
                        color: deepBlue,
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
}
