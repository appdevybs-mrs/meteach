import 'dart:convert';

import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../services/backend_api.dart';
import '../shared/admin_tour_guide.dart';
import '../shared/app_feedback.dart';
import '../shared/human_error.dart';

class AdminSharedFilesScreen extends StatefulWidget {
  const AdminSharedFilesScreen({super.key});

  @override
  State<AdminSharedFilesScreen> createState() => _AdminSharedFilesScreenState();
}

class _AdminSharedFilesScreenState extends State<AdminSharedFilesScreen> {
  static const String _deleteUrl =
      'https://www.yourbridgeschool.com/app/secure/delete_file_secure.php';

  final DatabaseReference _sharedRef = FirebaseDatabase.instance.ref(
    'shared_files',
  );

  String _relativeSharedPathFromUrl(String rawUrl) {
    final trimmed = rawUrl.trim();
    if (trimmed.isEmpty) return '';
    try {
      final uri = Uri.parse(trimmed);
      final parts = uri.pathSegments;
      final idx = parts.indexOf('shared');
      if (idx < 0 || idx + 1 >= parts.length) return '';
      return parts.sublist(idx + 1).join('/');
    } catch (_) {
      return '';
    }
  }

  Future<void> _openUrl(String url) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _deleteAny(Map<String, dynamic> item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('حذف الملف؟'),
        content: const Text('سيتم حذف الملف من القسم المشترك لجميع المعلمين.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    try {
      final relPath = _relativeSharedPathFromUrl((item['url'] ?? '').toString());
      if (relPath.isNotEmpty) {
        final deleteUri = await BackendApi.withAuthQuery(Uri.parse(_deleteUrl));
        final headers = await BackendApi.authHeaders();
        final authFields = await BackendApi.authFormFields();
        final resp = await http
            .post(
          deleteUri,
          headers: headers,
          body: {'root': 'shared', 'path': relPath, ...authFields},
        )
            .timeout(const Duration(seconds: 60));
        final raw = resp.body.trim();
        if (raw.startsWith('{')) {
          final data = json.decode(raw);
          if (data is Map && data['success'] != true) {
            throw Exception((data['message'] ?? 'Delete failed').toString());
          }
        }
      }

      final id = (item['id'] ?? '').toString();
      if (id.isNotEmpty) {
        await _sharedRef.child(id).remove();
      }
      if (!mounted) return;
      AppToast.show(context, 'تم حذف الملف بنجاح.', type: AppToastType.success);
    } catch (e) {
      if (!mounted) return;
      AppToast.show(
        context,
        toHumanError(
          e,
          fallback: 'Could not delete this file right now. Please try again.',
        ),
        type: AppToastType.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    AdminTourGuide.scheduleSimple(
      context,
      screenId: 'admin_shared_files',
      title: 'الملفات المشتركة',
      line: 'تعرض هذه الشاشة جميع الملفات المشتركة بين المعلمين مع صلاحية الحذف الإداري.',
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Shared Files')),
      body: StreamBuilder<DatabaseEvent>(
        stream: _sharedRef.onValue,
        builder: (context, snap) {
          final raw = snap.data?.snapshot.value;
          final items = <Map<String, dynamic>>[];
          if (raw is Map) {
            final m = Map<dynamic, dynamic>.from(raw);
            for (final e in m.entries) {
              if (e.value is! Map) continue;
              final item = Map<String, dynamic>.from(e.value as Map);
              item['id'] = item['id'] ?? e.key.toString();
              items.add(item);
            }
          }

          items.sort((a, b) {
            final aa = (a['createdAt'] as num?)?.toInt() ?? 0;
            final bb = (b['createdAt'] as num?)?.toInt() ?? 0;
            return bb.compareTo(aa);
          });

          if (items.isEmpty) {
            return const Center(child: Text('No shared files found.'));
          }

          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (context, i) {
              final item = items[i];
              final title = (item['title'] ?? '').toString().trim();
              final name = (item['name'] ?? 'Document').toString();
              final desc = (item['description'] ?? '').toString().trim();
              final owner = (item['ownerName'] ?? '').toString().trim();
              final url = (item['url'] ?? '').toString().trim();

              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title.isEmpty ? name : title,
                        style: const TextStyle(fontWeight: FontWeight.w900),
                      ),
                      if (desc.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(desc),
                      ],
                      const SizedBox(height: 6),
                      Text(
                        owner.isEmpty ? 'Owner: -' : 'Owner: $owner',
                        style: const TextStyle(fontSize: 12, color: Colors.black54),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          OutlinedButton.icon(
                            onPressed: url.isEmpty ? null : () => _openUrl(url),
                            icon: const Icon(Icons.open_in_new_rounded),
                            label: const Text('Open'),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton.icon(
                            onPressed: url.isEmpty ? null : () => _openUrl(url),
                            icon: const Icon(Icons.download_rounded),
                            label: const Text('Download'),
                          ),
                          const Spacer(),
                          IconButton(
                            tooltip: 'Delete file',
                            onPressed: () => _deleteAny(item),
                            icon: const Icon(Icons.delete_rounded, color: Colors.red),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
