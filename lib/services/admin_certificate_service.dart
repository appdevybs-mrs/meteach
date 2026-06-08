import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import '../models/admin_certificate_model.dart';
import 'backend_api.dart';

class AdminCertificateService {
  static const String _certPath = 'admin_certificates';
  static const String _nameSuggestPath = 'admin_certificate_names';
  static const String _sublineSuggestPath = 'admin_certificate_sublines';
  static const String _uploadEndpoint = 'upload_certificate_id.php';

  final FirebaseDatabase _db = FirebaseDatabase.instance;

  DatabaseReference get _certRef => _db.ref(_certPath);
  DatabaseReference get _nameRef => _db.ref(_nameSuggestPath);
  DatabaseReference get _sublineRef => _db.ref(_sublineSuggestPath);

  Future<List<AdminCertificate>> getAll() async {
    final snap = await _certRef.get();
    final list = <AdminCertificate>[];
    if (snap.value != null && snap.value is Map) {
      (snap.value as Map).forEach((key, value) {
        if (value is Map) {
          list.add(AdminCertificate.fromMap(value, key: key.toString()));
        }
      });
    }
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  Future<void> save(AdminCertificate cert) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final data = cert.copyWith(createdAt: now, updatedAt: now);
    await _certRef.push().set(data.toMap());
  }

  Future<void> update(String key, AdminCertificate cert) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final data = cert.copyWith(updatedAt: now);
    await _certRef.child(key).update(data.toMap());
  }

  Future<void> delete(String key) async {
    await _certRef.child(key).remove();
  }

  Future<List<String>> getSuggestedNames() async {
    final snap = await _nameRef.get();
    final list = <String>[];
    if (snap.value != null && snap.value is Map) {
      (snap.value as Map).forEach((_, value) {
        if (value is Map) {
          final v = (value['value'] ?? '').toString().trim();
          if (v.isNotEmpty) list.add(v);
        }
      });
    }
    return list;
  }

  Future<void> addSuggestedName(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final existing = await getSuggestedNames();
    if (existing.contains(trimmed)) return;
    await _nameRef.push().set({'value': trimmed});
  }

  Future<List<String>> getSuggestedSublines() async {
    final snap = await _sublineRef.get();
    final list = <String>[];
    if (snap.value != null && snap.value is Map) {
      (snap.value as Map).forEach((_, value) {
        if (value is Map) {
          final v = (value['value'] ?? '').toString().trim();
          if (v.isNotEmpty) list.add(v);
        }
      });
    }
    return list;
  }

  Future<void> addSuggestedSubline(String subline) async {
    final trimmed = subline.trim();
    if (trimmed.isEmpty) return;
    final existing = await getSuggestedSublines();
    if (existing.contains(trimmed)) return;
    await _sublineRef.push().set({'value': trimmed});
  }

  Future<String> uploadIdImage({
    required PlatformFile file,
    required String certificateName,
  }) async {
    final request = http.MultipartRequest(
      'POST',
      BackendApi.uri(_uploadEndpoint),
    );
    await BackendApi.applyAuthToMultipart(request);
    request.fields['certificate_name'] = certificateName.trim();

    if (kIsWeb) {
      final bytes = file.bytes;
      if (bytes == null) throw Exception('Could not read file bytes.');
      request.files.add(
        http.MultipartFile.fromBytes('file', bytes, filename: file.name),
      );
    } else {
      final path = file.path;
      if (path == null || path.isEmpty) {
        throw Exception('Could not read file path.');
      }
      request.files.add(
        await http.MultipartFile.fromPath('file', path, filename: file.name),
      );
    }

    final streamed = await request.send();
    final response = await http.Response.fromStream(streamed);

    if (response.statusCode != 200) {
      throw Exception('Upload failed (${response.statusCode}): ${response.body}');
    }

    final decoded = json.decode(response.body);
    if (decoded is! Map || decoded['success'] != true) {
      final msg = decoded is Map ? (decoded['message'] ?? 'Unknown error') : 'Unknown error';
      throw Exception('Upload failed: $msg');
    }

    return (decoded['url'] ?? '').toString();
  }
}
