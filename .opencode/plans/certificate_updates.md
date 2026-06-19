# Certificate Layout & Short Description Changes

## 1. Certificate model — add `shortDescription`
**File:** `lib/models/certificate_model.dart`

- Add field: `final String shortDescription;`
- Constructor: add `this.shortDescription = ''`
- `toMap()`: add `if (shortDescription.isNotEmpty) 'short_description': shortDescription`
- `fromMap()`: add `shortDescription: (map['short_description'] ?? '').toString()`
- `copyWith()`: add `String? shortDescription` parameter and assign

## 2. Certificate service — thread `shortDescription`
**File:** `lib/services/certificate_service.dart`

- `issueRecordedCertificate()`: add `String shortDescription = ''` parameter
- Pass to `Certificate(...)`: add `shortDescription: existing?.certificate.shortDescription ?? shortDescription`

## 3. Recorded screen — read & pass `shortDescription`
**File:** `lib/learner/recorded_course_study_screen.dart`

- `_issueRecordedCertificate()`: add `String shortDescription = ''` parameter
- Pass to `_certificateService.issueRecordedCertificate(...)`: add `shortDescription: shortDescription`
- `_onCertificateTap()`: after reading `cpdHours`, also read:
  `final shortDescription = (widget.courseData['short_description'] ?? '').toString();`
- Pass `shortDescription: shortDescription` to `_issueRecordedCertificate(call)`

## 4. PDF service — update layout
**File:** `lib/services/certificate_pdf_service.dart` — inside `generateCertificatePdfBytes()`

### Changes to existing items:

| Item | Old position | New position | Font |
|------|-------------|-------------|------|
| CVN | left=216, top=640 | left=216, **top=620** | unchanged |
| Instructor name | centered x=297.5, top=751, w=300 | centered x=297.5, **top=730**, w=300 | **16pt** bold (was 8pt) |
| Issue date | left=469, top=751 | **left=469, top=770** | unchanged (moved down to avoid overlap with instructor label) |

### New items:
- **"Instructor" label**: centered x=297.5, **top=750**, w=300, Helvetica **8pt** regular
- **Short description**: left=64, **top=515**, Helvetica **9pt** regular (only if not empty)

### Rendering logic for instructor + label + date:
```dart
pw.Positioned(
  left: 297.5 - 150,
  top: 730,
  child: pw.SizedBox(
    width: 300,
    child: pw.Text(
      instructor,
      textAlign: pw.TextAlign.center,
      style: pw.TextStyle(
        fontSize: 16,
        font: pw.Font.helveticaBold(),
        color: PdfColor.fromInt(0xFF111827),
      ),
    ),
  ),
),
pw.Positioned(
  left: 297.5 - 150,
  top: 750,
  child: pw.SizedBox(
    width: 300,
    child: pw.Text(
      'Instructor',
      textAlign: pw.TextAlign.center,
      style: pw.TextStyle(
        fontSize: 8,
        font: pw.Font.helvetica(),
        color: PdfColor.fromInt(0xFF111827),
      ),
    ),
  ),
),
```

### Short description after CPD subline:
```dart
if (cert.shortDescription.isNotEmpty)
  pw.Positioned(
    left: 64,
    top: 515,
    child: pw.SizedBox(
      width: 460,
      child: pw.Text(
        cert.shortDescription,
        style: pw.TextStyle(
          fontSize: 9,
          font: pw.Font.helvetica(),
          color: PdfColor.fromInt(0xFF111827),
        ),
      ),
    ),
  ),
```
