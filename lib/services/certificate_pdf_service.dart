import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../models/certificate_model.dart';

class CertificatePdfService {
  static const int _templateRasterDpi = 300;

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

  Future<pw.MemoryImage?> _loadPngTemplate(String assetPath) async {
    try {
      final bytes = await rootBundle.load(assetPath);
      return pw.MemoryImage(bytes.buffer.asUint8List());
    } catch (_) {}
    return null;
  }

  Future<Uint8List> generateCertificatePdfBytes(Certificate cert) async {
    final doc = pw.Document();
    pw.MemoryImage? template;
    pw.Font? playfairRegular;
    pw.Font? playfairBold;
    final isExam = cert.examCourse == 'exam';
    if (isExam) {
      template = await _loadPdfTemplate('assets/images/digital_cert_exam.pdf');
      template ??= await _loadPngTemplate(
        'assets/images/digital_cert_exam.png',
      );
    } else {
      template = await _loadPdfTemplate('assets/images/DigitalCertificate.pdf');
      template ??= await _loadPngTemplate(
        'assets/images/DigitalCertificate.png',
      );
    }
    template ??= await _loadPngTemplate('assets/images/DigitalCertificate.png');
    try {
      final bytes = await rootBundle.load(
        'assets/fonts/PlayfairDisplay-Regular.ttf',
      );
      playfairRegular = pw.Font.ttf(bytes);
    } catch (_) {}
    try {
      final bytes = await rootBundle.load(
        'assets/fonts/PlayfairDisplay-Bold.ttf',
      );
      playfairBold = pw.Font.ttf(bytes);
    } catch (_) {}
    const double pageHeight = 842;

    // Measured bottom-origin Y values converted to top-origin:
    // top = pageHeight - y
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
                  font: playfairBold,
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
                  font: playfairBold,
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
                    font: playfairRegular,
                    color: PdfColor.fromInt(0xFF1F2937),
                  ),
                ),
              ),
              if (!isExam)
                centeredText(
                  centerX: 142,
                  top: instructorTop,
                  boxWidth: 210,
                  text: instructor,
                  style: pw.TextStyle(
                    fontSize: 14,
                    font: playfairBold,
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
                  font: playfairBold,
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
                      font: playfairRegular,
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
}
