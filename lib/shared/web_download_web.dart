import 'dart:typed_data';
import 'dart:html' as html;
// ignore_for_file: avoid_web_libraries_in_flutter

void downloadBytes(Uint8List bytes, String fileName) {
  final blob = html.Blob([bytes], 'application/pdf');
  final url = html.Url.createObjectUrlFromBlob(blob);
  final anchor = html.document.createElement('a') as html.AnchorElement
    ..href = url
    ..download = fileName
    ..style.display = 'none';
  html.document.body!.append(anchor);
  anchor.click();
  html.Url.revokeObjectUrl(url);
  anchor.remove();
}
