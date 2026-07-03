import 'dart:typed_data';
import 'dart:html' as html;
// ignore_for_file: avoid_web_libraries_in_flutter

String _guessMime(String fileName) {
  final ext = fileName.split('.').last.toLowerCase();
  switch (ext) {
    case 'pdf':
      return 'application/pdf';
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'png':
      return 'image/png';
    case 'gif':
      return 'image/gif';
    case 'webp':
      return 'image/webp';
    case 'svg':
      return 'image/svg+xml';
    case 'mp4':
      return 'video/mp4';
    case 'webm':
      return 'video/webm';
    case 'mov':
      return 'video/quicktime';
    case 'm4v':
      return 'video/x-m4v';
    case 'mp3':
      return 'audio/mpeg';
    case 'wav':
      return 'audio/wav';
    case 'ogg':
      return 'audio/ogg';
    case 'doc':
      return 'application/msword';
    case 'docx':
      return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
    case 'xls':
      return 'application/vnd.ms-excel';
    case 'xlsx':
      return 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
    case 'ppt':
      return 'application/vnd.ms-powerpoint';
    case 'pptx':
      return 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
    case 'txt':
      return 'text/plain';
    case 'html':
    case 'htm':
      return 'text/html';
    case 'json':
      return 'application/json';
    case 'zip':
      return 'application/zip';
    case 'csv':
      return 'text/csv';
    default:
      return 'application/octet-stream';
  }
}

void downloadBytes(Uint8List bytes, String fileName) {
  final mime = _guessMime(fileName);
  final blob = html.Blob([bytes], mime);
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
